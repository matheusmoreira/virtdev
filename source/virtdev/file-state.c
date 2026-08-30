// SPDX-License-Identifier: AGPL-3.0-or-later

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <unistd.h>

enum {
	FILE_STATE_OK = 0,
	FILE_STATE_ERROR = 1,
	FILE_STATE_LIMIT = 44,
	FILE_STATE_CHANGED = 47,
	FILE_STATE_METADATA_UNSUPPORTED = 49,
	FILE_STATE_USAGE = 64,
};

enum {
	SHA256_BLOCK_SIZE = 64,
	SHA256_DIGEST_SIZE = 32,
	READ_BUFFER_SIZE = 131072,
};

struct sha256_state {
	uint32_t words[8];
	uint64_t bytes;
	unsigned char block[SHA256_BLOCK_SIZE];
	size_t used;
};

static int parse_u64(const char *text, uint64_t *result)
{
	const unsigned char *cursor = (const unsigned char *)text;
	uint64_t value = 0;

	if (!cursor[0])
		return -1;
	while (*cursor) {
		unsigned int digit;

		if (*cursor < '0' || *cursor > '9')
			return -1;
		digit = (unsigned int)(*cursor - '0');
		if (value > (UINT64_MAX - digit) / 10)
			return -1;
		value = value * 10 + digit;
		cursor++;
	}
	*result = value;
	return 0;
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
			  unsigned char digest[SHA256_DIGEST_SIZE])
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

static int metadata_equal(const struct stat *left, const struct stat *right)
{
	return left->st_dev == right->st_dev && left->st_ino == right->st_ino &&
	       left->st_mode == right->st_mode && left->st_uid == right->st_uid &&
	       left->st_gid == right->st_gid && left->st_nlink == right->st_nlink &&
	       left->st_size == right->st_size &&
	       left->st_mtim.tv_sec == right->st_mtim.tv_sec &&
	       left->st_mtim.tv_nsec == right->st_mtim.tv_nsec &&
	       left->st_ctim.tv_sec == right->st_ctim.tv_sec &&
	       left->st_ctim.tv_nsec == right->st_ctim.tv_nsec;
}

static int file_changed(const char *path)
{
	fprintf(stderr, "regular file changed while being inspected: '%s'\n", path);
	return FILE_STATE_CHANGED;
}

static int file_error(const char *operation, const char *path)
{
	fprintf(stderr, "%s '%s': %s\n", operation, path, strerror(errno));
	return FILE_STATE_ERROR;
}

static int require_no_xattrs(int descriptor, const char *path)
{
	ssize_t size;

	do {
		size = flistxattr(descriptor, NULL, 0);
	} while (size < 0 && errno == EINTR);
	if (size < 0)
		return file_error("cannot inspect regular-file attributes at", path);
	if (size) {
		fprintf(stderr,
			"extended attributes or ACLs are unsupported at '%s'\n",
			path);
		return FILE_STATE_METADATA_UNSUPPORTED;
	}
	return FILE_STATE_OK;
}

static int digest_fd(int descriptor, off_t size, const char *path,
		     unsigned char digest[SHA256_DIGEST_SIZE])
{
	unsigned char buffer[READ_BUFFER_SIZE];
	unsigned char extra;
	struct sha256_state state;
	off_t offset = 0;

	sha256_initialize(&state);
	while (offset < size) {
		size_t wanted = (uint64_t)(size - offset) > sizeof(buffer) ?
				    sizeof(buffer) : (size_t)(size - offset);
		ssize_t count = pread(descriptor, buffer, wanted, offset);

		if (count < 0) {
			if (errno == EINTR)
				continue;
			return file_error("cannot read regular file", path);
		}
		if (!count)
			return file_changed(path);
		if (sha256_update(&state, buffer, (size_t)count))
			return file_changed(path);
		offset += count;
	}
	for (;;) {
		ssize_t count = pread(descriptor, &extra, 1, size);

		if (count < 0 && errno == EINTR)
			continue;
		if (count < 0)
			return file_error("cannot verify regular-file length", path);
		if (count)
			return file_changed(path);
		break;
	}
	sha256_finish(&state, digest);
	return FILE_STATE_OK;
}

static void digest_hex(const unsigned char digest[SHA256_DIGEST_SIZE],
		       char output[SHA256_DIGEST_SIZE * 2 + 1])
{
	static const char digits[] = "0123456789abcdef";
	size_t index;

	for (index = 0; index < SHA256_DIGEST_SIZE; index++) {
		output[index * 2] = digits[digest[index] >> 4];
		output[index * 2 + 1] = digits[digest[index] & 0x0f];
	}
	output[SHA256_DIGEST_SIZE * 2] = '\0';
}

int main(int argc, char *argv[])
{
	unsigned char digest[SHA256_DIGEST_SIZE];
	char hexadecimal[SHA256_DIGEST_SIZE * 2 + 1];
	struct stat before;
	struct stat after;
	uint64_t maximum_bytes;
	uint64_t size;
	int descriptor = -1;
	int result = FILE_STATE_ERROR;

	if (argc != 3 || parse_u64(argv[2], &maximum_bytes)) {
		fprintf(stderr, "usage: %s path max-bytes\n", argv[0]);
		return FILE_STATE_USAGE;
	}
	descriptor = open(argv[1], O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
	if (descriptor < 0) {
		result = file_error("cannot open regular file", argv[1]);
		goto out;
	}
	if (fstat(descriptor, &before)) {
		result = file_error("cannot inspect regular file", argv[1]);
		goto out;
	}
	if (!S_ISREG(before.st_mode)) {
		errno = EINVAL;
		result = file_error("path is not a regular file", argv[1]);
		goto out;
	}
	if (before.st_size < 0) {
		errno = EOVERFLOW;
		result = file_error("regular file has a negative size", argv[1]);
		goto out;
	}
	size = (uint64_t)before.st_size;
	if (size > maximum_bytes || size > UINT64_MAX / 8) {
		fprintf(stderr, "regular file exceeds byte limit: '%s'\n", argv[1]);
		result = FILE_STATE_LIMIT;
		goto out;
	}
	result = require_no_xattrs(descriptor, argv[1]);
	if (result)
		goto out;
	result = digest_fd(descriptor, before.st_size, argv[1], digest);
	if (result)
		goto out;
	if (fstat(descriptor, &after)) {
		result = file_error("cannot reinspect regular file", argv[1]);
		goto out;
	}
	if (!metadata_equal(&before, &after)) {
		result = file_changed(argv[1]);
		goto out;
	}
	if (close(descriptor)) {
		descriptor = -1;
		result = file_error("cannot close regular file", argv[1]);
		goto out;
	}
	descriptor = -1;
	digest_hex(digest, hexadecimal);
	if (printf("%" PRIuMAX " %" PRIuMAX " %" PRIxMAX
		   " %" PRIuMAX " %" PRIuMAX " %" PRIuMAX " %" PRIu64
		   " %" PRIdMAX " %ld %" PRIdMAX " %ld %s\n",
		   (uintmax_t)before.st_dev, (uintmax_t)before.st_ino,
		   (uintmax_t)before.st_mode, (uintmax_t)before.st_uid,
		   (uintmax_t)before.st_gid, (uintmax_t)before.st_nlink, size,
		   (intmax_t)before.st_mtim.tv_sec, before.st_mtim.tv_nsec,
		   (intmax_t)before.st_ctim.tv_sec, before.st_ctim.tv_nsec,
		   hexadecimal) < 0 || fflush(stdout)) {
		errno = EIO;
		result = file_error("cannot emit regular-file state for", argv[1]);
		goto out;
	}
	result = FILE_STATE_OK;

out:
	if (descriptor >= 0)
		close(descriptor);
	return result;
}
