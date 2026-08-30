// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Private helper for bounded, mutation-detecting restore staging. The
// destination parent must already exist; this program creates "tree" below it.

#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/fs.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/random.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

enum {
	COPY_ERROR = 1,
	ENTRY_LIMIT = 42,
	BYTE_LIMIT = 44,
	CAPACITY_LIMIT = 45,
	DEPTH_LIMIT = 46,
	SOURCE_CHANGED = 47,
	STATE_LIMIT = 48,
	USAGE_ERROR = 64,
};

enum {
	SOURCE_BUCKETS = 262144,
	PATH_BUCKETS = 262144,
	COPY_BUFFER_SIZE = 131072,
	REGULAR_DIGEST_SIZE = 32,
	SHA256_BLOCK_SIZE = 64,
	MAXIMUM_DEPTH_CAP = 128,
	RELATIVE_PATH_MAX = 4095,
	FIXED_COPY_DESCRIPTORS = 10,
	DESCRIPTORS_PER_DEPTH = 3,
};

#ifndef SOURCE_STATE_MAX_BYTES
#define SOURCE_STATE_MAX_BYTES UINT64_C(536870912)
#endif

#ifndef SOURCE_STATE_CHUNK_BYTES
#define SOURCE_STATE_CHUNK_BYTES UINT64_C(1048576)
#endif

static const uint64_t source_state_max_bytes = SOURCE_STATE_MAX_BYTES;

union source_state_value {
	long double wide;
	uintmax_t integer;
	void *pointer;
};

struct source_state_chunk {
	struct source_state_chunk *next;
	size_t mapping_size;
	size_t used;
	size_t capacity;
	union source_state_value data[];
};

struct source_record {
	dev_t device;
	ino_t inode;
	mode_t mode;
	uid_t uid;
	gid_t gid;
	nlink_t links;
	off_t size;
	struct timespec atime;
	struct timespec ctime;
	struct timespec mtime;
	uint64_t captured_occurrences;
	uint64_t copied_occurrences;
	uint64_t verified_occurrences;
	unsigned char regular_digest[REGULAR_DIGEST_SIZE];
	char *destination_path;
	char *symlink_target;
	size_t symlink_target_length;
	struct source_record *next;
};

struct source_path {
	struct source_path *parent;
	struct source_record *inode;
	char *name;
	unsigned char copied;
	unsigned char verified;
	struct source_path *next;
};

struct sha256_state {
	uint32_t words[8];
	uint64_t bytes;
	unsigned char block[SHA256_BLOCK_SIZE];
	size_t used;
};

static struct source_record *source_records[SOURCE_BUCKETS];
static struct source_path *source_paths[PATH_BUCKETS];
static struct source_state_chunk *source_state_chunks;
static struct source_state_chunk *source_state_current;
static uint64_t source_state_bytes = sizeof(source_records) +
				     sizeof(source_paths);
static uint64_t hash_seed;
static uint64_t maximum_bytes;
static uint64_t maximum_entries;
static uint64_t maximum_depth;
static uint64_t reserve_bytes;
static uint64_t reserve_inodes;
static uint64_t captured_bytes;
static uint64_t captured_entries;
static uint64_t copied_bytes;
static uint64_t copied_entries;
static dev_t source_device;
static uint64_t source_mount_id;
static int source_mount_initialized;
static int destination_root_fd = -1;

static int fail_errno(const char *operation, const char *path);
static int fail_source_errno(const char *operation, const char *path);

static int parse_u64(const char *text, uint64_t *result)
{
	char *end = NULL;
	unsigned long long value;

	if (!text[0] || text[0] == '-')
		return -1;
	errno = 0;
	value = strtoull(text, &end, 10);
	if (errno || !end || *end)
		return -1;
	*result = (uint64_t)value;
	return 0;
}

static int configure_hash_seed(void)
{
	ssize_t count;

	do {
		count = getrandom(&hash_seed, sizeof(hash_seed), 0);
	} while (count < 0 && errno == EINTR);
	if (count != (ssize_t)sizeof(hash_seed)) {
		if (count >= 0)
			errno = EIO;
		return fail_errno("cannot initialize source-state hashing below", "tree");
	}
	return 0;
}

static int fail_errno(const char *operation, const char *path)
{
	fprintf(stderr, "%s '%s': %s\n", operation, path, strerror(errno));
	return COPY_ERROR;
}

static int require_source_mount(int directory_fd, const char *name, int flags,
				const char *path, int initialize)
{
	struct statx status;

	if (statx(directory_fd, name, flags | AT_NO_AUTOMOUNT, STATX_MNT_ID,
		  &status))
		return fail_source_errno("source mount changed at", path);
	if (!(status.stx_mask & STATX_MNT_ID)) {
		fprintf(stderr, "source mount identity is unavailable at '%s'\n", path);
		return COPY_ERROR;
	}
	if (initialize) {
		source_mount_id = status.stx_mnt_id;
		source_mount_initialized = 1;
		return 0;
	}
	if (!source_mount_initialized || status.stx_mnt_id != source_mount_id) {
		fprintf(stderr, "source crosses a mount boundary at '%s'\n", path);
		return COPY_ERROR;
	}
	return 0;
}

static int timespec_equal(struct timespec left, struct timespec right)
{
	return left.tv_sec == right.tv_sec && left.tv_nsec == right.tv_nsec;
}

static int source_changed(const char *operation, const char *path)
{
	fprintf(stderr, "%s '%s'\n", operation, path);
	return SOURCE_CHANGED;
}

static int fail_source_errno(const char *operation, const char *path)
{
	if (errno == ENOENT || errno == ESTALE || errno == ELOOP ||
	    errno == ENOTDIR)
		return source_changed(operation, path);
	return fail_errno(operation, path);
}

static uint32_t rotate_right(uint32_t value, unsigned int count)
{
	return (value >> count) | (value << (32U - count));
}

static uint32_t load_be32(const unsigned char *bytes)
{
	return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
	       ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

static void store_be32(unsigned char *bytes, uint32_t value)
{
	bytes[0] = (unsigned char)(value >> 24);
	bytes[1] = (unsigned char)(value >> 16);
	bytes[2] = (unsigned char)(value >> 8);
	bytes[3] = (unsigned char)value;
}

static void sha256_transform(struct sha256_state *state)
{
	static const uint32_t constants[64] = {
		UINT32_C(0x428a2f98), UINT32_C(0x71374491),
		UINT32_C(0xb5c0fbcf), UINT32_C(0xe9b5dba5),
		UINT32_C(0x3956c25b), UINT32_C(0x59f111f1),
		UINT32_C(0x923f82a4), UINT32_C(0xab1c5ed5),
		UINT32_C(0xd807aa98), UINT32_C(0x12835b01),
		UINT32_C(0x243185be), UINT32_C(0x550c7dc3),
		UINT32_C(0x72be5d74), UINT32_C(0x80deb1fe),
		UINT32_C(0x9bdc06a7), UINT32_C(0xc19bf174),
		UINT32_C(0xe49b69c1), UINT32_C(0xefbe4786),
		UINT32_C(0x0fc19dc6), UINT32_C(0x240ca1cc),
		UINT32_C(0x2de92c6f), UINT32_C(0x4a7484aa),
		UINT32_C(0x5cb0a9dc), UINT32_C(0x76f988da),
		UINT32_C(0x983e5152), UINT32_C(0xa831c66d),
		UINT32_C(0xb00327c8), UINT32_C(0xbf597fc7),
		UINT32_C(0xc6e00bf3), UINT32_C(0xd5a79147),
		UINT32_C(0x06ca6351), UINT32_C(0x14292967),
		UINT32_C(0x27b70a85), UINT32_C(0x2e1b2138),
		UINT32_C(0x4d2c6dfc), UINT32_C(0x53380d13),
		UINT32_C(0x650a7354), UINT32_C(0x766a0abb),
		UINT32_C(0x81c2c92e), UINT32_C(0x92722c85),
		UINT32_C(0xa2bfe8a1), UINT32_C(0xa81a664b),
		UINT32_C(0xc24b8b70), UINT32_C(0xc76c51a3),
		UINT32_C(0xd192e819), UINT32_C(0xd6990624),
		UINT32_C(0xf40e3585), UINT32_C(0x106aa070),
		UINT32_C(0x19a4c116), UINT32_C(0x1e376c08),
		UINT32_C(0x2748774c), UINT32_C(0x34b0bcb5),
		UINT32_C(0x391c0cb3), UINT32_C(0x4ed8aa4a),
		UINT32_C(0x5b9cca4f), UINT32_C(0x682e6ff3),
		UINT32_C(0x748f82ee), UINT32_C(0x78a5636f),
		UINT32_C(0x84c87814), UINT32_C(0x8cc70208),
		UINT32_C(0x90befffa), UINT32_C(0xa4506ceb),
		UINT32_C(0xbef9a3f7), UINT32_C(0xc67178f2),
	};
	uint32_t schedule[64];
	uint32_t a = state->words[0];
	uint32_t b = state->words[1];
	uint32_t c = state->words[2];
	uint32_t d = state->words[3];
	uint32_t e = state->words[4];
	uint32_t f = state->words[5];
	uint32_t g = state->words[6];
	uint32_t h = state->words[7];
	size_t index;

	for (index = 0; index < 16; index++)
		schedule[index] = load_be32(&state->block[index * 4]);
	for (; index < 64; index++) {
		uint32_t left = schedule[index - 15];
		uint32_t right = schedule[index - 2];
		uint32_t sigma0 = rotate_right(left, 7) ^
				  rotate_right(left, 18) ^ (left >> 3);
		uint32_t sigma1 = rotate_right(right, 17) ^
				  rotate_right(right, 19) ^ (right >> 10);

		schedule[index] = schedule[index - 16] + sigma0 +
				  schedule[index - 7] + sigma1;
	}
	for (index = 0; index < 64; index++) {
		uint32_t sum1 = rotate_right(e, 6) ^ rotate_right(e, 11) ^
				rotate_right(e, 25);
		uint32_t choice = (e & f) ^ (~e & g);
		uint32_t temporary1 = h + sum1 + choice + constants[index] +
				      schedule[index];
		uint32_t sum0 = rotate_right(a, 2) ^ rotate_right(a, 13) ^
				rotate_right(a, 22);
		uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
		uint32_t temporary2 = sum0 + majority;

		h = g;
		g = f;
		f = e;
		e = d + temporary1;
		d = c;
		c = b;
		b = a;
		a = temporary1 + temporary2;
	}
	state->words[0] += a;
	state->words[1] += b;
	state->words[2] += c;
	state->words[3] += d;
	state->words[4] += e;
	state->words[5] += f;
	state->words[6] += g;
	state->words[7] += h;
}

static void sha256_initialize(struct sha256_state *state)
{
	static const uint32_t initial[8] = {
		UINT32_C(0x6a09e667), UINT32_C(0xbb67ae85),
		UINT32_C(0x3c6ef372), UINT32_C(0xa54ff53a),
		UINT32_C(0x510e527f), UINT32_C(0x9b05688c),
		UINT32_C(0x1f83d9ab), UINT32_C(0x5be0cd19),
	};

	memcpy(state->words, initial, sizeof(initial));
	state->bytes = 0;
	state->used = 0;
}

static int sha256_update(struct sha256_state *state,
			 const unsigned char *bytes, size_t length)
{
	if ((uint64_t)length > UINT64_MAX - state->bytes)
		return -1;
	state->bytes += (uint64_t)length;
	while (length) {
		size_t available = sizeof(state->block) - state->used;
		size_t take = length < available ? length : available;

		memcpy(&state->block[state->used], bytes, take);
		state->used += take;
		bytes += take;
		length -= take;
		if (state->used == sizeof(state->block)) {
			sha256_transform(state);
			state->used = 0;
		}
	}
	return 0;
}

static void sha256_finish(struct sha256_state *state,
			  unsigned char digest[REGULAR_DIGEST_SIZE])
{
	uint64_t bits = state->bytes * 8;
	size_t index;

	state->block[state->used++] = 0x80;
	if (state->used > 56) {
		memset(&state->block[state->used], 0,
		       sizeof(state->block) - state->used);
		sha256_transform(state);
		state->used = 0;
	}
	memset(&state->block[state->used], 0, 56 - state->used);
	for (index = 0; index < 8; index++)
		state->block[63 - index] = (unsigned char)(bits >> (index * 8));
	sha256_transform(state);
	for (index = 0; index < 8; index++)
		store_be32(&digest[index * 4], state->words[index]);
}

static int digest_regular_fd(int fd, off_t size, const char *path,
			     const char *read_operation,
			     const char *short_operation,
			     int source_input,
			     unsigned char digest[REGULAR_DIGEST_SIZE])
{
	unsigned char buffer[COPY_BUFFER_SIZE];
	struct sha256_state state;
	off_t offset = 0;

	if (size < 0 || (uint64_t)size > UINT64_MAX / 8) {
		fprintf(stderr, "regular file is too large to digest at '%s'\n", path);
		return BYTE_LIMIT;
	}
	sha256_initialize(&state);
	while (offset < size) {
		size_t wanted = (uint64_t)(size - offset) > sizeof(buffer) ?
				    sizeof(buffer) : (size_t)(size - offset);
		ssize_t count = pread(fd, buffer, wanted, offset);

		if (count < 0) {
			if (errno == EINTR)
				continue;
			return source_input ? fail_source_errno(read_operation, path) :
					      fail_errno(read_operation, path);
		}
		if (!count) {
			if (source_input)
				return source_changed(short_operation, path);
			errno = EIO;
			return fail_errno(short_operation, path);
		}
		if (sha256_update(&state, buffer, (size_t)count))
			return source_changed("source digest length overflow at", path);
		offset += count;
	}
	sha256_finish(&state, digest);
	return 0;
}

static int source_state_limit(const char *path)
{
	fprintf(stderr, "source-state memory limit exceeded at '%s'\n", path);
	return STATE_LIMIT;
}

static struct source_state_chunk *source_state_chunk_create(size_t units,
						     const char *path,
						     int *status)
{
	const size_t header = offsetof(struct source_state_chunk, data);
	const size_t unit = sizeof(union source_state_value);
	uint64_t target = SOURCE_STATE_CHUNK_BYTES;
	uint64_t remaining;
	uint64_t needed;
	uint64_t page_size;
	long page_result;
	void *mapping;
	struct source_state_chunk *chunk;

	if (units > (SIZE_MAX - header) / unit) {
		*status = source_state_limit(path);
		return NULL;
	}
	needed = (uint64_t)header + (uint64_t)units * (uint64_t)unit;
	if (source_state_bytes > source_state_max_bytes ||
	    needed > source_state_max_bytes - source_state_bytes) {
		*status = source_state_limit(path);
		return NULL;
	}
	page_result = sysconf(_SC_PAGESIZE);
	if (page_result <= 0) {
		errno = EINVAL;
		*status = fail_errno("cannot determine allocation granularity below",
					    path);
		return NULL;
	}
	page_size = (uint64_t)page_result;
	if (needed > UINT64_MAX - (page_size - 1)) {
		*status = source_state_limit(path);
		return NULL;
	}
	needed = ((needed + page_size - 1) / page_size) * page_size;
	remaining = source_state_max_bytes - source_state_bytes;
	if (target < needed)
		target = needed;
	if (target > remaining)
		target = (remaining / page_size) * page_size;
	if (target < needed || target > SIZE_MAX) {
		*status = source_state_limit(path);
		return NULL;
	}
	mapping = mmap(NULL, (size_t)target, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	if (mapping == MAP_FAILED) {
		*status = fail_errno("cannot allocate source state for", path);
		return NULL;
	}
	chunk = mapping;
	chunk->next = source_state_chunks;
	chunk->mapping_size = (size_t)target;
	chunk->used = 0;
	chunk->capacity = ((size_t)target - header) / unit;
	source_state_chunks = chunk;
	source_state_current = chunk;
	source_state_bytes += target;
	*status = 0;
	return chunk;
}

static void *source_state_allocate(size_t size, int clear, const char *path,
				   int *status)
{
	const size_t unit = sizeof(union source_state_value);
	size_t units;
	void *allocation;

	if (!size || size > SIZE_MAX - (unit - 1)) {
		*status = source_state_limit(path);
		return NULL;
	}
	units = (size + unit - 1) / unit;
	if (!source_state_current ||
	    units > source_state_current->capacity - source_state_current->used) {
		if (!source_state_chunk_create(units, path, status))
			return NULL;
	}
	allocation = &source_state_current->data[source_state_current->used];
	source_state_current->used += units;
	if (clear)
		memset(allocation, 0, size);
	*status = 0;
	return allocation;
}

static int source_state_duplicate(const char *text, const char *path,
				  char **result)
{
	size_t size = strlen(text) + 1;
	int status;
	char *copy = source_state_allocate(size, 0, path, &status);

	if (!copy)
		return status;
	memcpy(copy, text, size);
	*result = copy;
	return status;
}

static size_t source_bucket(dev_t device, ino_t inode)
{
	uint64_t value = (uint64_t)(uintmax_t)device ^ hash_seed;

	value ^= (uint64_t)(uintmax_t)inode + UINT64_C(0x9e3779b97f4a7c15) +
		 (value << 6) + (value >> 2);
	return (size_t)(value % SOURCE_BUCKETS);
}

static struct source_record *source_record_find(dev_t device, ino_t inode)
{
	struct source_record *record;

	for (record = source_records[source_bucket(device, inode)]; record;
	     record = record->next) {
		if (record->device == device && record->inode == inode)
			return record;
	}
	return NULL;
}

static int source_metadata_equal(const struct source_record *record,
				 const struct stat *status)
{
	if (!record || !status)
		return 0;
	return record->device == status->st_dev &&
	       record->inode == status->st_ino && record->mode == status->st_mode &&
	       record->uid == status->st_uid && record->gid == status->st_gid &&
	       record->links == status->st_nlink && record->size == status->st_size &&
	       timespec_equal(record->ctime, status->st_ctim) &&
	       timespec_equal(record->mtime, status->st_mtim);
}

static int source_record_capture(const struct stat *status, const char *path,
				 struct source_record **result, int *is_new)
{
	size_t bucket = source_bucket(status->st_dev, status->st_ino);
	struct source_record *record = source_record_find(status->st_dev,
							status->st_ino);

	*is_new = 0;
	if (record) {
		if (!source_metadata_equal(record, status))
			return source_changed("source changed during capture at", path);
		if (S_ISDIR(status->st_mode))
			return source_changed("source directory appears more than once at",
					      path);
	} else {
		int allocation_status;

		record = source_state_allocate(sizeof(*record), 1, path,
					       &allocation_status);

		if (!record)
			return allocation_status;
		record->device = status->st_dev;
		record->inode = status->st_ino;
		record->mode = status->st_mode;
		record->uid = status->st_uid;
		record->gid = status->st_gid;
		record->links = status->st_nlink;
		record->size = status->st_size;
		record->atime = status->st_atim;
		record->ctime = status->st_ctim;
		record->mtime = status->st_mtim;
		record->next = source_records[bucket];
		source_records[bucket] = record;
		*is_new = 1;
	}
	if (record->captured_occurrences == UINT64_MAX)
		return source_changed("source occurrence count overflow at", path);
	record->captured_occurrences++;
	*result = record;
	return 0;
}

static int source_record_remember_destination(struct source_record *record,
					      const char *path)
{
	return source_state_duplicate(path, path, &record->destination_path);
}

static size_t path_bucket(const struct source_path *parent, const char *name)
{
	uint64_t value = (uint64_t)(uintptr_t)parent ^ hash_seed ^
			 UINT64_C(1469598103934665603);
	size_t index;
	size_t length = strlen(name);

	for (index = 0; index < length; index++) {
		value ^= (unsigned char)name[index];
		value *= UINT64_C(1099511628211);
	}
	return (size_t)(value % PATH_BUCKETS);
}

static struct source_path *source_path_find(struct source_path *parent,
					    const char *name)
{
	struct source_path *entry;

	for (entry = source_paths[path_bucket(parent, name)]; entry;
	     entry = entry->next) {
		if (entry->parent == parent && !strcmp(entry->name, name))
			return entry;
	}
	return NULL;
}

static int source_path_capture(struct source_path *parent, const char *name,
			       struct source_record *inode, const char *path,
			       struct source_path **result)
{
	size_t bucket = path_bucket(parent, name);
	struct source_path *entry;
	int status;

	if (source_path_find(parent, name))
		return source_changed("source path appeared more than once at", path);
	entry = source_state_allocate(sizeof(*entry), 1, path, &status);
	if (!entry)
		return status;
	status = source_state_duplicate(name, path, &entry->name);
	if (status)
		return status;
	entry->parent = parent;
	entry->inode = inode;
	entry->next = source_paths[bucket];
	source_paths[bucket] = entry;
	*result = entry;
	return 0;
}

static int source_path_mark(struct source_path *parent, const char *name,
			    const struct stat *status, const char *path,
			    int verified, struct source_path **result)
{
	struct source_path *entry = source_path_find(parent, name);
	unsigned char *seen;

	if (!entry || !source_metadata_equal(entry->inode, status))
		return source_changed(verified ? "source path changed after copy at" :
						  "source path changed before copy at",
				      path);
	seen = verified ? &entry->verified : &entry->copied;
	if (*seen)
		return source_changed("source path appeared more than once at", path);
	*seen = 1;
	if (verified)
		entry->inode->verified_occurrences++;
	else
		entry->inode->copied_occurrences++;
	*result = entry;
	return 0;
}

static int source_paths_complete(int verified)
{
	size_t bucket;

	for (bucket = 0; bucket < PATH_BUCKETS; bucket++) {
		struct source_path *entry;

		for (entry = source_paths[bucket]; entry; entry = entry->next) {
			if ((verified && !entry->verified) || (!verified && !entry->copied))
				return source_changed(verified ?
					"source path disappeared after copy below" :
					"source path disappeared before copy below",
					"tree");
		}
	}
	return 0;
}

static int source_records_complete(int verified)
{
	size_t bucket;

	for (bucket = 0; bucket < SOURCE_BUCKETS; bucket++) {
		struct source_record *record;

		for (record = source_records[bucket]; record; record = record->next) {
			uint64_t occurrences = verified ? record->verified_occurrences :
							 record->copied_occurrences;

			if (occurrences != record->captured_occurrences)
				return source_changed(verified ?
					"source entry disappeared after copy below" :
					"source entry disappeared before copy below",
					"tree");
		}
	}
	return 0;
}

static void source_records_free_all(void)
{
	while (source_state_chunks) {
		struct source_state_chunk *chunk = source_state_chunks;

		source_state_chunks = chunk->next;
		munmap(chunk, chunk->mapping_size);
	}
}

static char *relative_join(const char *directory, const char *name)
{
	size_t directory_length = strlen(directory);
	size_t name_length = strlen(name);
	size_t separator = directory_length ? 1 : 0;
	char *path;

	if (directory_length > SIZE_MAX - name_length - separator - 1) {
		errno = ENAMETOOLONG;
		return NULL;
	}
	path = malloc(directory_length + separator + name_length + 1);
	if (!path)
		return NULL;
	if (directory_length)
		memcpy(path, directory, directory_length);
	if (separator)
		path[directory_length] = '/';
	memcpy(path + directory_length + separator, name, name_length + 1);
	return path;
}

static int require_path_length(const char *path)
{
	if (strlen(path) > RELATIVE_PATH_MAX) {
		fprintf(stderr, "source relative-path limit exceeded at '%s'\n", path);
		return DEPTH_LIMIT;
	}
	return 0;
}

static int require_component_depth(uint64_t parent_depth, const char *path)
{
	if (parent_depth >= MAXIMUM_DEPTH_CAP) {
		fprintf(stderr,
			"source path-component limit (%d) exceeded at '%s'\n",
			MAXIMUM_DEPTH_CAP, path);
		return DEPTH_LIMIT;
	}
	return 0;
}

static uint64_t available_bytes(const struct statvfs *space)
{
	uint64_t blocks = (uint64_t)space->f_bavail;
	uint64_t size = (uint64_t)space->f_frsize;

	if (size && blocks > UINT64_MAX / size)
		return UINT64_MAX;
	return blocks * size;
}

static int count_open_descriptors(uint64_t *result)
{
	DIR *directory = opendir("/proc/self/fd");
	struct dirent *entry;
	uint64_t count = 0;

	if (!directory)
		return fail_errno("cannot inspect open descriptors below", "tree");
	errno = 0;
	while ((entry = readdir(directory))) {
		if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
			continue;
		count++;
		errno = 0;
	}
	if (errno) {
		int status = fail_errno("cannot count open descriptors below", "tree");

		closedir(directory);
		return status;
	}
	if (closedir(directory))
		return fail_errno("cannot close descriptor scan below", "tree");
	if (!count)
		return source_changed("open-descriptor count underflow below", "tree");
	*result = count - 1;
	return 0;
}

static int configure_maximum_depth(void)
{
	struct rlimit limit;
	uint64_t open_descriptors;
	uint64_t descriptor_depth;
	int result;

	if (getrlimit(RLIMIT_NOFILE, &limit))
		return fail_errno("cannot inspect descriptor limit below", "tree");
	maximum_depth = MAXIMUM_DEPTH_CAP;
	if (limit.rlim_cur == RLIM_INFINITY)
		return 0;
	result = count_open_descriptors(&open_descriptors);
	if (result)
		return result;
	if (open_descriptors >= (uint64_t)limit.rlim_cur ||
	    (uint64_t)limit.rlim_cur - open_descriptors <= FIXED_COPY_DESCRIPTORS) {
		fprintf(stderr, "descriptor limit leaves no safe staging depth\n");
		return DEPTH_LIMIT;
	}
	descriptor_depth = ((uint64_t)limit.rlim_cur - open_descriptors -
			    FIXED_COPY_DESCRIPTORS) /
			   DESCRIPTORS_PER_DEPTH;
	if (descriptor_depth < maximum_depth)
		maximum_depth = descriptor_depth;
	return 0;
}

static int require_child_depth(uint64_t current_depth, const char *path)
{
	if (current_depth >= maximum_depth) {
		fprintf(stderr,
			"source nesting-depth limit (%" PRIu64 ") exceeded at '%s'\n",
			maximum_depth, path);
		return DEPTH_LIMIT;
	}
	return 0;
}

static int require_capacity(uint64_t bytes, uint64_t inodes)
{
	struct statvfs space;
	uint64_t free_bytes;

	if (fstatvfs(destination_root_fd, &space))
		return fail_errno("cannot inspect destination capacity below", "tree");
	free_bytes = available_bytes(&space);
	if (free_bytes <= reserve_bytes || bytes > free_bytes - reserve_bytes) {
		fprintf(stderr, "destination free-space reserve would be crossed\n");
		return CAPACITY_LIMIT;
	}
	if (space.f_files &&
	    ((uint64_t)space.f_favail <= reserve_inodes ||
	     inodes > (uint64_t)space.f_favail - reserve_inodes)) {
		fprintf(stderr, "destination free-inode reserve would be crossed\n");
		return CAPACITY_LIMIT;
	}
	return 0;
}

static int reserve_captured_entry(const char *path)
{
	if (captured_entries >= maximum_entries) {
		fprintf(stderr, "entry limit exceeded at '%s'\n", path);
		return ENTRY_LIMIT;
	}
	captured_entries++;
	return 0;
}

static int reserve_captured_regular_bytes(const struct stat *status,
					  const char *path)
{
	uint64_t size;

	if (status->st_size < 0) {
		fprintf(stderr, "negative regular-file size at '%s'\n", path);
		return COPY_ERROR;
	}
	size = (uint64_t)status->st_size;
	if (size > maximum_bytes || captured_bytes > maximum_bytes - size) {
		fprintf(stderr, "logical-byte limit exceeded at '%s'\n", path);
		return BYTE_LIMIT;
	}
	captured_bytes += size;
	return 0;
}

static int reserve_copied_entry(const char *path)
{
	if (copied_entries >= maximum_entries) {
		fprintf(stderr, "entry limit exceeded during copy at '%s'\n", path);
		return ENTRY_LIMIT;
	}
	copied_entries++;
	return 0;
}

static int reserve_copied_regular_bytes(const struct stat *status,
					const char *path)
{
	uint64_t size;

	if (status->st_size < 0) {
		fprintf(stderr, "negative regular-file size at '%s'\n", path);
		return COPY_ERROR;
	}
	size = (uint64_t)status->st_size;
	if (size > maximum_bytes || copied_bytes > maximum_bytes - size) {
		fprintf(stderr, "logical-byte limit exceeded during copy at '%s'\n",
			path);
		return BYTE_LIMIT;
	}
	copied_bytes += size;
	return 0;
}

static int capture_regular_digest(int directory_fd, const char *name,
				  const char *path,
				  struct source_record *record)
{
	struct stat opened;
	struct stat after;
	int fd = openat(directory_fd, name,
			O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
	int result = 0;

	if (fd < 0)
		return fail_source_errno("source changed during capture at", path);
	if (fstat(fd, &opened))
		result = fail_source_errno("cannot inspect captured regular file", path);
	if (!result)
		result = require_source_mount(fd, "", AT_EMPTY_PATH, path, 0);
	if (!result && !source_metadata_equal(record, &opened))
		result = source_changed("source changed during capture at", path);
	if (!result)
		result = digest_regular_fd(fd, opened.st_size, path,
					   "cannot digest captured source at",
					   "source changed while digesting",
					   1,
					   record->regular_digest);
	if (!result && fstat(fd, &after))
		result = fail_source_errno("cannot reinspect captured regular file", path);
	if (!result && !source_metadata_equal(record, &after))
		result = source_changed("source changed during capture at", path);
	if (close(fd) && !result)
		result = fail_errno("cannot close captured regular file", path);
	return result;
}

static int read_symlink_target(int directory_fd, const char *name,
			       const struct stat *status, const char *path,
			       char **result, size_t *result_length)
{
	size_t capacity;
	size_t target_length;
	ssize_t length;
	char *target;

	if (status->st_size < 0 || (uint64_t)status->st_size > 65535) {
		errno = ENAMETOOLONG;
		return fail_errno("symlink target is too long at", path);
	}
	capacity = status->st_size > 0 ? (size_t)status->st_size + 1 : 4096;
	target = calloc(capacity + 1, 1);
	if (!target)
		return fail_errno("cannot allocate symlink target for", path);
	length = readlinkat(directory_fd, name, target, capacity);
	if (length < 0) {
		int read_status = errno == EINVAL ?
			source_changed("symlink changed at", path) :
			fail_source_errno("cannot read source symlink at", path);

		free(target);
		return read_status;
	}
	target_length = (size_t)length;
	if (target_length >= capacity) {
		free(target);
		errno = ENAMETOOLONG;
		return fail_errno("symlink target changed at", path);
	}
	*result = target;
	*result_length = target_length;
	return 0;
}

static int capture_symlink_target(int directory_fd, const char *name,
				  const struct stat *initial, const char *path,
				  struct source_record *record, int is_new)
{
	struct stat after;
	char *target = NULL;
	size_t length = 0;
	int result = read_symlink_target(directory_fd, name, initial, path,
					 &target, &length);

	if (result)
		return result;
	if (fstatat(directory_fd, name, &after, AT_SYMLINK_NOFOLLOW))
		result = fail_source_errno("symlink changed during capture at", path);
	if (!result)
		result = require_source_mount(directory_fd, name,
					      AT_SYMLINK_NOFOLLOW, path, 0);
	if (!result && !source_metadata_equal(record, &after))
		result = source_changed("symlink changed during capture at", path);
	if (!result && !is_new &&
	    (length != record->symlink_target_length ||
	     memcmp(target, record->symlink_target, length) != 0))
		result = source_changed("hard-linked symlink target changed at", path);
	if (!result && is_new) {
		record->symlink_target = source_state_allocate(length + 1, 0, path,
							       &result);
		if (record->symlink_target) {
			memcpy(record->symlink_target, target, length + 1);
			record->symlink_target_length = length;
		}
	}
	free(target);
	return result;
}

static int capture_directory(int source_fd, const char *relative,
			     uint64_t depth, struct source_path *parent,
			     struct source_record *directory_record);

static int capture_entry(int source_directory_fd, const char *name,
			 const char *relative, uint64_t depth,
			 struct source_path *parent)
{
	struct source_record *record = NULL;
	struct source_path *entry = NULL;
	struct stat status;
	char *path = relative_join(relative, name);
	int child_fd = -1;
	int is_new;
	int result;

	if (!path)
		return fail_errno("cannot allocate path below", relative);
	result = require_path_length(path);
	if (result)
		goto out;
	result = require_component_depth(depth, path);
	if (result)
		goto out;
	result = reserve_captured_entry(path);
	if (result)
		goto out;
	if (fstatat(source_directory_fd, name, &status, AT_SYMLINK_NOFOLLOW)) {
		result = fail_source_errno("source changed during capture at", path);
		goto out;
	}
	result = require_source_mount(source_directory_fd, name,
				      AT_SYMLINK_NOFOLLOW, path, 0);
	if (result)
		goto out;
	if (status.st_dev != source_device) {
		fprintf(stderr, "source crosses a filesystem boundary at '%s'\n", path);
		result = COPY_ERROR;
		goto out;
	}
	if (!S_ISREG(status.st_mode) && !S_ISLNK(status.st_mode) &&
	    !S_ISDIR(status.st_mode)) {
		fprintf(stderr, "unsupported source type at '%s'\n", path);
		result = COPY_ERROR;
		goto out;
	}
	result = source_record_capture(&status, path, &record, &is_new);
	if (result)
		goto out;
	result = source_path_capture(parent, name, record, path, &entry);
	if (result)
		goto out;
	if (S_ISLNK(status.st_mode)) {
		result = capture_symlink_target(source_directory_fd, name, &status,
						path, record, is_new);
		if (result)
			goto out;
	}
	if (is_new && S_ISREG(status.st_mode)) {
		result = reserve_captured_regular_bytes(&status, path);
		if (result)
			goto out;
		result = capture_regular_digest(source_directory_fd, name, path,
						record);
		if (result)
			goto out;
	}
	if (!S_ISDIR(status.st_mode)) {
		result = 0;
		goto out;
	}
	result = require_child_depth(depth, path);
	if (result)
		goto out;
	child_fd = openat(source_directory_fd, name,
			  O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
	if (child_fd < 0) {
		result = fail_source_errno("source directory changed during capture at",
					  path);
		goto out;
	}
	if (fstat(child_fd, &status) || !source_metadata_equal(record, &status)) {
		result = source_changed("source directory changed during capture at",
					path);
		goto out;
	}
	result = require_source_mount(child_fd, "", AT_EMPTY_PATH, path, 0);
	if (result)
		goto out;
	result = capture_directory(child_fd, path, depth + 1, entry, record);

out:
	if (child_fd >= 0 && close(child_fd) && !result)
		result = fail_errno("cannot close source directory", path);
	free(path);
	return result;
}

static int capture_directory(int source_fd, const char *relative,
			     uint64_t depth, struct source_path *parent,
			     struct source_record *directory_record)
{
	DIR *directory;
	struct dirent *entry;
	struct stat after;
	int scan_fd = openat(source_fd, ".",
			     O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
	int result = 0;

	if (scan_fd < 0)
		return fail_errno("cannot open source directory scan", relative);
	directory = fdopendir(scan_fd);
	if (!directory) {
		close(scan_fd);
		return fail_errno("cannot scan source directory", relative);
	}
	errno = 0;
	while ((entry = readdir(directory))) {
		if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
			continue;
		result = capture_entry(source_fd, entry->d_name, relative, depth,
				       parent);
		if (result)
			break;
		errno = 0;
	}
	if (!result && errno)
		result = fail_errno("cannot continue scanning", relative);
	if (!result &&
	    (fstat(source_fd, &after) ||
	     !source_metadata_equal(directory_record, &after)))
		result = source_changed("source directory changed during capture at",
					relative[0] ? relative : "tree");
	if (!result)
		result = require_source_mount(source_fd, "", AT_EMPTY_PATH,
					      relative[0] ? relative : "tree", 0);
	if (closedir(directory) && !result)
		result = fail_errno("cannot close source scan", relative);
	return result;
}

static int apply_fd_metadata(int fd, const struct source_record *record,
			     const char *path)
{
	struct timespec times[2] = { record->atime, record->mtime };

	if (fd < 0) {
		errno = EBADF;
		return fail_errno("invalid metadata descriptor for", path);
	}
	if (fchown(fd, record->uid, record->gid))
		return fail_errno("cannot preserve ownership on", path);
	if (fchmod(fd, record->mode & 07777))
		return fail_errno("cannot preserve mode on", path);
	if (futimens(fd, times))
		return fail_errno("cannot preserve timestamps on", path);
	return 0;
}

static int apply_symlink_metadata(int directory_fd, const char *name,
				  const struct source_record *record,
				  const char *path)
{
	struct timespec times[2] = { record->atime, record->mtime };

	if (fchownat(directory_fd, name, record->uid, record->gid,
		     AT_SYMLINK_NOFOLLOW))
		return fail_errno("cannot preserve symlink ownership on", path);
	if (utimensat(directory_fd, name, times, AT_SYMLINK_NOFOLLOW))
		return fail_errno("cannot preserve symlink timestamps on", path);
	return 0;
}

static int write_all_at(int fd, const unsigned char *buffer, size_t length,
			off_t offset, const char *path)
{
	size_t written = 0;
	int result;

	result = require_capacity((uint64_t)length, 0);
	if (result)
		return result;
	while (written < length) {
		ssize_t count = pwrite(fd, buffer + written, length - written,
				       offset + (off_t)written);

		if (count < 0) {
			if (errno == EINTR)
				continue;
			return fail_errno("cannot write", path);
		}
		if (!count) {
			errno = EIO;
			return fail_errno("short write to", path);
		}
		written += (size_t)count;
	}
	return 0;
}

static int copy_extent(int source_fd, int destination_fd, off_t start,
		       off_t end, const char *path)
{
	unsigned char buffer[COPY_BUFFER_SIZE];
	off_t offset = start;

	while (offset < end) {
		size_t wanted = (uint64_t)(end - offset) > sizeof(buffer) ?
				    sizeof(buffer) : (size_t)(end - offset);
		ssize_t count = pread(source_fd, buffer, wanted, offset);
		int result;

		if (count < 0) {
			if (errno == EINTR)
				continue;
			return fail_source_errno("cannot read source at", path);
		}
		if (!count) {
			return source_changed("source changed while copying", path);
		}
		result = write_all_at(destination_fd, buffer, (size_t)count,
				      offset, path);
		if (result)
			return result;
		offset += count;
	}
	return 0;
}

static int buffer_has_data(const unsigned char *buffer, size_t length)
{
	size_t index;

	for (index = 0; index < length; index++) {
		if (buffer[index])
			return 1;
	}
	return 0;
}

static int copy_zero_scanned(int source_fd, int destination_fd, off_t size,
			     const char *path)
{
	unsigned char buffer[4096];
	off_t offset = 0;

	while (offset < size) {
		size_t wanted = (uint64_t)(size - offset) > sizeof(buffer) ?
				    sizeof(buffer) : (size_t)(size - offset);
		ssize_t count = pread(source_fd, buffer, wanted, offset);
		int result;

		if (count < 0) {
			if (errno == EINTR)
				continue;
			return fail_source_errno("cannot read source at", path);
		}
		if (!count) {
			return source_changed("source changed while copying", path);
		}
		if (buffer_has_data(buffer, (size_t)count)) {
			result = write_all_at(destination_fd, buffer, (size_t)count,
					      offset, path);
			if (result)
				return result;
		}
		offset += count;
	}
	if (ftruncate(destination_fd, size))
		return fail_errno("cannot size", path);
	return 0;
}

static int copy_file_data(int source_fd, int destination_fd, off_t size,
			  const char *path)
{
	off_t offset = 0;

	if (!ioctl(destination_fd, FICLONE, source_fd))
		return 0;
	if (ftruncate(destination_fd, 0))
		return fail_errno("cannot reset clone destination", path);
	if (!size)
		return 0;

	errno = 0;
	off_t first_data = lseek(source_fd, 0, SEEK_DATA);
	if (first_data < 0) {
		if (errno == ENXIO) {
			if (ftruncate(destination_fd, size))
				return fail_errno("cannot size sparse file", path);
			return 0;
		}
		if (errno == EINVAL)
			return copy_zero_scanned(source_fd, destination_fd, size, path);
		return fail_source_errno("cannot inspect sparse extents in", path);
	}
	offset = first_data;
	while (offset < size) {
		off_t hole = lseek(source_fd, offset, SEEK_HOLE);
		off_t next;
		int result;

		if (hole < 0)
			return fail_source_errno("cannot inspect sparse extent in", path);
		if (hole > size)
			hole = size;
		result = copy_extent(source_fd, destination_fd, offset, hole, path);
		if (result)
			return result;
		if (hole >= size)
			break;
		next = lseek(source_fd, hole, SEEK_DATA);
		if (next < 0) {
			if (errno == ENXIO)
				break;
			return fail_source_errno("cannot inspect sparse extents in", path);
		}
		offset = next;
	}
	if (ftruncate(destination_fd, size))
		return fail_errno("cannot size", path);
	return 0;
}

static int copy_directory(int source_fd, int destination_fd,
			  const char *relative, uint64_t depth,
			  struct source_path *parent,
			  struct source_record *directory_record);

static int copy_regular(int source_directory_fd, int destination_directory_fd,
			const char *name, const char *path,
			struct source_record *record)
{
	struct stat opened;
	struct stat copied;
	unsigned char digest[REGULAR_DIGEST_SIZE];
	int source_fd = -1;
	int destination_fd = -1;
	int result;

	if (source_directory_fd < 0 || destination_directory_fd < 0 ||
	    destination_root_fd < 0) {
		errno = EBADF;
		return fail_errno("invalid copy directory for", path);
	}
	if (record->copied_occurrences > 1) {
		if (!record->destination_path)
			return source_changed("hard-link source order changed at", path);
		result = require_capacity(4096, 1);
		if (result)
			return result;
		if (linkat(destination_root_fd, record->destination_path,
			   destination_directory_fd, name, 0))
			return fail_errno("cannot preserve hard link at", path);
		return 0;
	}

	source_fd = openat(source_directory_fd, name,
			   O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
	if (source_fd < 0)
		return fail_source_errno("source changed before copy at", path);
	if (fstat(source_fd, &opened)) {
		result = fail_source_errno("cannot inspect opened source file", path);
		goto out;
	}
	result = require_source_mount(source_fd, "", AT_EMPTY_PATH, path, 0);
	if (result)
		goto out;
	if (!source_metadata_equal(record, &opened)) {
		result = source_changed("source changed before copy at", path);
		goto out;
	}
	result = reserve_copied_regular_bytes(&opened, path);
	if (result)
		goto out;
	result = require_capacity(4096, 1);
	if (result)
		goto out;
	destination_fd = openat(destination_directory_fd, name,
				O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC |
					O_NOFOLLOW,
				0600);
	if (destination_fd < 0) {
		result = fail_errno("cannot create regular file", path);
		goto out;
	}
	result = copy_file_data(source_fd, destination_fd, opened.st_size, path);
	if (!result) {
		struct stat after;

		if (fstat(source_fd, &after))
			result = fail_source_errno("cannot reinspect source file", path);
		else if (!source_metadata_equal(record, &after))
			result = source_changed("source changed during copy at", path);
	}
	if (!result && fstat(destination_fd, &copied))
		result = fail_errno("cannot inspect copied data for", path);
	if (!result && (!S_ISREG(copied.st_mode) || copied.st_size != record->size))
		result = source_changed("copied data size changed at", path);
	if (!result)
		result = digest_regular_fd(destination_fd, copied.st_size, path,
					   "cannot verify copied data at",
					   "copied data became incomplete at",
					   0,
					   digest);
	if (!result && memcmp(digest, record->regular_digest, sizeof(digest)) != 0)
		result = source_changed("copied data differs from captured source at",
					path);
	if (!result)
		result = apply_fd_metadata(destination_fd, record, path);
	if (destination_fd >= 0 && close(destination_fd) && !result)
		result = fail_errno("cannot close destination file", path);
	destination_fd = -1;
	if (!result && record->captured_occurrences > 1)
		result = source_record_remember_destination(record, path);

out:
	if (destination_fd >= 0)
		close(destination_fd);
	if (source_fd >= 0 && close(source_fd) && !result)
		result = fail_errno("cannot close source file", path);
	return result;
}

static int copy_symlink(int source_directory_fd, int destination_directory_fd,
			const char *name, const char *path,
			struct source_record *record)
{
	char *target = NULL;
	size_t length = 0;
	struct stat after;
	struct stat initial;
	int result;

	if (source_directory_fd < 0 || destination_directory_fd < 0 ||
	    destination_root_fd < 0) {
		errno = EBADF;
		return fail_errno("invalid copy directory for", path);
	}
	if (record->copied_occurrences > 1) {
		if (!record->destination_path)
			return source_changed("hard-link source order changed at", path);
		result = require_capacity(4096, 1);
		if (result)
			return result;
		if (linkat(destination_root_fd, record->destination_path,
			   destination_directory_fd, name, 0))
			return fail_errno("cannot preserve hard-linked symlink at", path);
		return 0;
	}

	if (fstatat(source_directory_fd, name, &initial, AT_SYMLINK_NOFOLLOW))
		return fail_source_errno("symlink changed before copy at", path);
	result = require_source_mount(source_directory_fd, name,
				      AT_SYMLINK_NOFOLLOW, path, 0);
	if (result)
		return result;
	result = read_symlink_target(source_directory_fd, name, &initial, path,
				     &target, &length);
	if (result)
		return result;
	if (!target) {
		errno = EIO;
		return fail_errno("cannot read symlink target for", path);
	}
	if (length != record->symlink_target_length ||
	    (length && memcmp(target, record->symlink_target, length) != 0)) {
		result = source_changed("symlink target changed before copy at", path);
		goto out;
	}
	if (fstatat(source_directory_fd, name, &after, AT_SYMLINK_NOFOLLOW)) {
		result = fail_source_errno("symlink changed during copy at", path);
		goto out;
	}
	if (!source_metadata_equal(record, &after)) {
		result = source_changed("symlink changed during copy at", path);
		goto out;
	}
	result = require_capacity(4096, 1);
	if (!result && symlinkat(target, destination_directory_fd, name))
		result = fail_errno("cannot create symlink", path);
	if (!result)
		result = apply_symlink_metadata(destination_directory_fd, name,
						record, path);
	if (!result && record->captured_occurrences > 1)
		result = source_record_remember_destination(record, path);

out:
	free(target);
	return result;
}

static int copy_entry(int source_directory_fd, int destination_directory_fd,
		      const char *name, const char *relative, uint64_t depth,
		      struct source_path *parent)
{
	struct source_path *entry;
	struct stat status;
	char *path = relative_join(relative, name);
	int child_source_fd = -1;
	int child_destination_fd = -1;
	int result;

	if (!path)
		return fail_errno("cannot allocate path below", relative);
	if (source_directory_fd < 0 || destination_directory_fd < 0) {
		errno = EBADF;
		result = fail_errno("invalid copy directory for", path);
		goto out;
	}
	result = require_path_length(path);
	if (result)
		goto out;
	result = require_component_depth(depth, path);
	if (result)
		goto out;
	result = reserve_copied_entry(path);
	if (result)
		goto out;
	if (fstatat(source_directory_fd, name, &status, AT_SYMLINK_NOFOLLOW)) {
		result = fail_source_errno("source changed before copy at", path);
		goto out;
	}
	result = require_source_mount(source_directory_fd, name,
				      AT_SYMLINK_NOFOLLOW, path, 0);
	if (result)
		goto out;
	result = source_path_mark(parent, name, &status, path, 0, &entry);
	if (result)
		goto out;

	if (S_ISREG(status.st_mode)) {
		result = copy_regular(source_directory_fd, destination_directory_fd,
				      name, path, entry->inode);
	} else if (S_ISLNK(status.st_mode)) {
		result = copy_symlink(source_directory_fd, destination_directory_fd,
				      name, path, entry->inode);
	} else if (S_ISDIR(status.st_mode)) {
		struct stat opened;

		result = require_child_depth(depth, path);
		if (result)
			goto out;
		result = require_capacity(4096, 1);
		if (result)
			goto out;
		if (mkdirat(destination_directory_fd, name, 0700)) {
			result = fail_errno("cannot create directory", path);
			goto out;
		}
		child_source_fd = openat(source_directory_fd, name,
					 O_RDONLY | O_CLOEXEC | O_DIRECTORY |
						 O_NOFOLLOW);
		if (child_source_fd < 0) {
			result = fail_source_errno("source directory changed before copy at",
						  path);
			goto out;
		}
		child_destination_fd = openat(destination_directory_fd, name,
					      O_RDONLY | O_CLOEXEC | O_DIRECTORY |
						      O_NOFOLLOW);
		if (child_destination_fd < 0) {
			result = fail_errno("cannot open destination directory", path);
			goto out;
		}
		if (fstat(child_source_fd, &opened)) {
			result = fail_errno("cannot inspect source directory", path);
			goto out;
		}
		result = require_source_mount(child_source_fd, "", AT_EMPTY_PATH,
						      path, 0);
		if (result)
			goto out;
		if (!source_metadata_equal(entry->inode, &opened)) {
			result = source_changed("source directory changed before copy at",
						path);
			goto out;
		}
		result = copy_directory(child_source_fd, child_destination_fd, path,
					depth + 1, entry, entry->inode);
		if (!result)
			result = apply_fd_metadata(child_destination_fd, entry->inode,
						   path);
	} else {
		result = source_changed("source type changed before copy at", path);
	}

out:
	if (child_destination_fd >= 0 && close(child_destination_fd) && !result)
		result = fail_errno("cannot close destination directory", path);
	if (child_source_fd >= 0 && close(child_source_fd) && !result)
		result = fail_errno("cannot close source directory", path);
	free(path);
	return result;
}

static int copy_directory(int source_fd, int destination_fd,
			  const char *relative, uint64_t depth,
			  struct source_path *parent,
			  struct source_record *directory_record)
{
	DIR *directory;
	struct dirent *entry;
	struct stat after;
	int scan_fd = openat(source_fd, ".",
			     O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
	int result = 0;

	if (scan_fd < 0)
		return fail_errno("cannot open source directory scan", relative);
	directory = fdopendir(scan_fd);
	if (!directory) {
		close(scan_fd);
		return fail_errno("cannot scan source directory", relative);
	}
	errno = 0;
	while ((entry = readdir(directory))) {
		if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
			continue;
		result = copy_entry(source_fd, destination_fd, entry->d_name,
				    relative, depth, parent);
		if (result)
			break;
		errno = 0;
	}
	if (!result && errno)
		result = fail_errno("cannot continue scanning", relative);
	if (!result &&
	    (fstat(source_fd, &after) ||
	     !source_metadata_equal(directory_record, &after)))
		result = source_changed("source directory changed during copy at",
					relative[0] ? relative : "tree");
	if (!result)
		result = require_source_mount(source_fd, "", AT_EMPTY_PATH,
					      relative[0] ? relative : "tree", 0);
	if (closedir(directory) && !result)
		result = fail_errno("cannot close source scan", relative);
	return result;
}

static int verify_directory(int source_fd, const char *relative,
			    uint64_t depth, struct source_path *parent,
			    struct source_record *directory_record);

static int verify_symlink_target(int directory_fd, const char *name,
				 const struct stat *initial, const char *path,
				 struct source_record *record)
{
	struct stat after;
	char *target = NULL;
	size_t length = 0;
	int result = read_symlink_target(directory_fd, name, initial, path,
					 &target, &length);

	if (result)
		return result;
	if (length != record->symlink_target_length ||
	    (length && memcmp(target, record->symlink_target, length) != 0))
		result = source_changed("symlink target changed after copy at", path);
	if (!result && fstatat(directory_fd, name, &after, AT_SYMLINK_NOFOLLOW))
		result = fail_source_errno("symlink changed after copy at", path);
	if (!result)
		result = require_source_mount(directory_fd, name,
					      AT_SYMLINK_NOFOLLOW, path, 0);
	if (!result && !source_metadata_equal(record, &after))
		result = source_changed("symlink changed after copy at", path);
	free(target);
	return result;
}

static int verify_regular_digest(int directory_fd, const char *name,
				 const char *path,
				 struct source_record *record)
{
	struct stat opened;
	struct stat after;
	unsigned char digest[REGULAR_DIGEST_SIZE];
	int fd;
	int result = 0;

	if (record->verified_occurrences > 1)
		return 0;
	fd = openat(directory_fd, name,
		    O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0)
		return fail_source_errno("source changed after copy at", path);
	if (fstat(fd, &opened))
		result = fail_source_errno("cannot inspect regular file for verification",
					   path);
	if (!result)
		result = require_source_mount(fd, "", AT_EMPTY_PATH, path, 0);
	if (!result && !source_metadata_equal(record, &opened))
		result = source_changed("source changed after copy at", path);
	if (!result)
		result = digest_regular_fd(fd, opened.st_size, path,
					   "cannot verify source data at",
					   "source became incomplete after copy at",
					   1,
					   digest);
	if (!result && memcmp(digest, record->regular_digest, sizeof(digest)) != 0)
		result = source_changed("source data changed after copy at", path);
	if (!result && fstat(fd, &after))
		result = fail_source_errno("cannot reinspect verified regular file", path);
	if (!result && !source_metadata_equal(record, &after))
		result = source_changed("source changed after copy at", path);
	if (close(fd) && !result)
		result = fail_errno("cannot close verified regular file", path);
	return result;
}

static int verify_entry(int source_directory_fd, const char *name,
			const char *relative, uint64_t depth,
			struct source_path *parent)
{
	struct source_path *entry;
	struct stat status;
	char *path = relative_join(relative, name);
	int child_fd = -1;
	int result;

	if (!path)
		return fail_errno("cannot allocate path below", relative);
	result = require_path_length(path);
	if (result)
		goto out;
	result = require_component_depth(depth, path);
	if (result)
		goto out;
	if (fstatat(source_directory_fd, name, &status, AT_SYMLINK_NOFOLLOW)) {
		result = fail_source_errno("source changed after copy at", path);
		goto out;
	}
	result = require_source_mount(source_directory_fd, name,
				      AT_SYMLINK_NOFOLLOW, path, 0);
	if (result)
		goto out;
	result = source_path_mark(parent, name, &status, path, 1, &entry);
	if (result)
		goto out;
	if (S_ISLNK(status.st_mode)) {
		result = verify_symlink_target(source_directory_fd, name, &status,
						path, entry->inode);
		goto out;
	}
	if (S_ISREG(status.st_mode)) {
		result = verify_regular_digest(source_directory_fd, name, path,
						entry->inode);
		goto out;
	}
	if (!S_ISDIR(status.st_mode)) {
		result = 0;
		goto out;
	}
	result = require_child_depth(depth, path);
	if (result)
		goto out;
	child_fd = openat(source_directory_fd, name,
			  O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
	if (child_fd < 0) {
		result = fail_source_errno("source directory changed after copy at",
					  path);
		goto out;
	}
	if (fstat(child_fd, &status)) {
		result = fail_errno("cannot reinspect source directory", path);
		goto out;
	}
	result = require_source_mount(child_fd, "", AT_EMPTY_PATH, path, 0);
	if (result)
		goto out;
	if (!source_metadata_equal(entry->inode, &status)) {
		result = source_changed("source directory changed after copy at", path);
		goto out;
	}
	result = verify_directory(child_fd, path, depth + 1, entry, entry->inode);

out:
	if (child_fd >= 0 && close(child_fd) && !result)
		result = fail_errno("cannot close source directory", path);
	free(path);
	return result;
}

static int verify_directory(int source_fd, const char *relative,
			    uint64_t depth, struct source_path *parent,
			    struct source_record *directory_record)
{
	DIR *directory;
	struct dirent *entry;
	struct stat after;
	int scan_fd = openat(source_fd, ".",
			     O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
	int result = 0;

	if (scan_fd < 0)
		return fail_errno("cannot open source directory rescan", relative);
	directory = fdopendir(scan_fd);
	if (!directory) {
		close(scan_fd);
		return fail_errno("cannot scan source directory", relative);
	}
	errno = 0;
	while ((entry = readdir(directory))) {
		if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
			continue;
		result = verify_entry(source_fd, entry->d_name, relative, depth,
				      parent);
		if (result)
			break;
		errno = 0;
	}
	if (!result && errno)
		result = fail_errno("cannot continue rescanning", relative);
	if (!result &&
	    (fstat(source_fd, &after) ||
	     !source_metadata_equal(directory_record, &after)))
		result = source_changed("source directory changed after copy at",
					relative[0] ? relative : "tree");
	if (!result)
		result = require_source_mount(source_fd, "", AT_EMPTY_PATH,
					      relative[0] ? relative : "tree", 0);
	if (closedir(directory) && !result)
		result = fail_errno("cannot close source rescan", relative);
	return result;
}

int main(int argc, char *argv[])
{
	struct source_record *root_record = NULL;
	struct source_path *root_path = NULL;
	struct source_path *marked_path;
	struct stat source_status;
	int source_root_fd = -1;
	int destination_parent_fd = -1;
	int is_new = 0;
	int result = COPY_ERROR;

	if (argc != 7 || parse_u64(argv[3], &maximum_bytes) ||
	    parse_u64(argv[4], &maximum_entries) ||
	    parse_u64(argv[5], &reserve_bytes) ||
	    parse_u64(argv[6], &reserve_inodes) || !maximum_entries) {
		fprintf(stderr,
			"usage: %s source destination-parent max-bytes max-entries "
			"reserve-bytes reserve-inodes\n",
			argv[0]);
		return USAGE_ERROR;
	}
	result = configure_hash_seed();
	if (result)
		goto out;
	result = configure_maximum_depth();
	if (result)
		goto out;

	source_root_fd = open(argv[1], O_RDONLY | O_CLOEXEC | O_DIRECTORY |
					 O_NOFOLLOW);
	if (source_root_fd < 0) {
		result = fail_errno("cannot open source tree", argv[1]);
		goto out;
	}
	if (fstat(source_root_fd, &source_status)) {
		result = fail_errno("cannot inspect source tree", argv[1]);
		goto out;
	}
	result = require_source_mount(source_root_fd, "", AT_EMPTY_PATH,
				      argv[1], 1);
	if (result)
		goto out;
	source_device = source_status.st_dev;
	destination_parent_fd = open(argv[2], O_RDONLY | O_CLOEXEC | O_DIRECTORY |
						 O_NOFOLLOW);
	if (destination_parent_fd < 0) {
		result = fail_errno("cannot open destination parent", argv[2]);
		goto out;
	}
	destination_root_fd = destination_parent_fd;
	result = require_capacity(4096, 1);
	if (result)
		goto out;
	result = source_record_capture(&source_status, "tree", &root_record,
				       &is_new);
	if (result)
		goto out;
	if (!is_new) {
		result = source_changed("source root identity repeated at", "tree");
		goto out;
	}
	result = source_path_capture(NULL, "", root_record, "tree", &root_path);
	if (result)
		goto out;
	result = capture_directory(source_root_fd, "", 0, root_path, root_record);
	if (result)
		goto out;
	if (mkdirat(destination_parent_fd, "tree", 0700)) {
		result = fail_errno("cannot create destination", "tree");
		goto out;
	}
	destination_root_fd = openat(destination_parent_fd, "tree",
				     O_RDONLY | O_CLOEXEC | O_DIRECTORY |
					     O_NOFOLLOW);
	if (destination_root_fd < 0) {
		result = fail_errno("cannot open destination", "tree");
		goto out;
	}
	if (fstat(source_root_fd, &source_status)) {
		result = fail_source_errno("cannot reinspect source tree", argv[1]);
		goto out;
	}
	result = require_source_mount(source_root_fd, "", AT_EMPTY_PATH,
				      argv[1], 0);
	if (result)
		goto out;
	result = source_path_mark(NULL, "", &source_status, "tree", 0,
				  &marked_path);
	if (result)
		goto out;
	result = copy_directory(source_root_fd, destination_root_fd, "", 0,
				root_path, root_record);
	if (!result)
		result = source_paths_complete(0);
	if (!result)
		result = source_records_complete(0);
	if (!result && (copied_entries != captured_entries ||
			copied_bytes != captured_bytes))
		result = source_changed("source accounting changed during copy at",
					"tree");
	if (!result && fstat(source_root_fd, &source_status))
		result = fail_source_errno("cannot verify source tree", argv[1]);
	if (!result)
		result = require_source_mount(source_root_fd, "", AT_EMPTY_PATH,
					      argv[1], 0);
	if (!result)
		result = source_path_mark(NULL, "", &source_status, "tree", 1,
					  &marked_path);
	if (!result)
		result = verify_directory(source_root_fd, "", 0, root_path,
					  root_record);
	if (!result)
		result = source_paths_complete(1);
	if (!result)
		result = source_records_complete(1);
	if (!result)
		result = apply_fd_metadata(destination_root_fd, root_record, "tree");
	if (!result)
		printf("%" PRIu64 " %" PRIu64 "\n", copied_entries,
		       copied_bytes);

out:
	source_records_free_all();
	if (destination_root_fd >= 0 &&
	    destination_root_fd != destination_parent_fd)
		close(destination_root_fd);
	if (destination_parent_fd >= 0)
		close(destination_parent_fd);
	if (source_root_fd >= 0)
		close(source_root_fd);
	return result;
}
