// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Private helper: copy a tree while enforcing logical-byte, entry, and
// destination-capacity bounds. The destination parent must already exist;
// this program creates a child named "tree".

#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/fs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
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
	USAGE_ERROR = 64,
};

enum { HARDLINK_BUCKETS = 4096, COPY_BUFFER_SIZE = 131072 };

struct hardlink {
	dev_t device;
	ino_t inode;
	off_t size;
	struct timespec ctime;
	char *destination_path;
	struct hardlink *next;
};

static struct hardlink *hardlinks[HARDLINK_BUCKETS];
static uint64_t maximum_bytes;
static uint64_t maximum_entries;
static uint64_t reserve_bytes;
static uint64_t reserve_inodes;
static uint64_t copied_bytes;
static uint64_t copied_entries;
static dev_t source_device;
static int source_root_fd = -1;
static int destination_root_fd = -1;

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

static int fail_errno(const char *operation, const char *path)
{
	fprintf(stderr, "%s '%s': %s\n", operation, path, strerror(errno));
	return COPY_ERROR;
}

static int timespec_equal(struct timespec left, struct timespec right)
{
	return left.tv_sec == right.tv_sec && left.tv_nsec == right.tv_nsec;
}

static int same_inode(const struct stat *left, const struct stat *right)
{
	return left->st_dev == right->st_dev && left->st_ino == right->st_ino &&
	       (left->st_mode & S_IFMT) == (right->st_mode & S_IFMT);
}

static size_t hardlink_bucket(dev_t device, ino_t inode)
{
	uint64_t value = (uint64_t)(uintmax_t)device;

	value ^= (uint64_t)(uintmax_t)inode + UINT64_C(0x9e3779b97f4a7c15) +
		 (value << 6) + (value >> 2);
	return (size_t)(value % HARDLINK_BUCKETS);
}

static struct hardlink *hardlink_find(dev_t device, ino_t inode)
{
	struct hardlink *entry;

	for (entry = hardlinks[hardlink_bucket(device, inode)]; entry;
	     entry = entry->next) {
		if (entry->device == device && entry->inode == inode)
			return entry;
	}
	return NULL;
}

static int hardlink_remember(const struct stat *status, const char *path)
{
	size_t bucket = hardlink_bucket(status->st_dev, status->st_ino);
	struct hardlink *entry = calloc(1, sizeof(*entry));

	if (!entry)
		return fail_errno("cannot allocate hard-link record for", path);
	entry->destination_path = strdup(path);
	if (!entry->destination_path) {
		free(entry);
		return fail_errno("cannot allocate hard-link path for", path);
	}
	entry->device = status->st_dev;
	entry->inode = status->st_ino;
	entry->size = status->st_size;
	entry->ctime = status->st_ctim;
	entry->next = hardlinks[bucket];
	hardlinks[bucket] = entry;
	return 0;
}

static void hardlink_free_all(void)
{
	size_t bucket;

	for (bucket = 0; bucket < HARDLINK_BUCKETS; bucket++) {
		struct hardlink *entry = hardlinks[bucket];

		while (entry) {
			struct hardlink *next = entry->next;

			free(entry->destination_path);
			free(entry);
			entry = next;
		}
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

static uint64_t available_bytes(const struct statvfs *space)
{
	uint64_t blocks = (uint64_t)space->f_bavail;
	uint64_t size = (uint64_t)space->f_frsize;

	if (size && blocks > UINT64_MAX / size)
		return UINT64_MAX;
	return blocks * size;
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

static int reserve_entry(const char *path)
{
	if (copied_entries >= maximum_entries) {
		fprintf(stderr, "entry limit exceeded at '%s'\n", path);
		return ENTRY_LIMIT;
	}
	copied_entries++;
	return 0;
}

static int reserve_regular_bytes(const struct stat *status, const char *path)
{
	uint64_t size;

	if (status->st_size < 0) {
		fprintf(stderr, "negative regular-file size at '%s'\n", path);
		return COPY_ERROR;
	}
	size = (uint64_t)status->st_size;
	if (size > maximum_bytes || copied_bytes > maximum_bytes - size) {
		fprintf(stderr, "logical-byte limit exceeded at '%s'\n", path);
		return BYTE_LIMIT;
	}
	copied_bytes += size;
	return 0;
}

static int apply_fd_metadata(int fd, const struct stat *status,
			     const char *path)
{
	struct timespec times[2] = { status->st_atim, status->st_mtim };

	if (fchown(fd, status->st_uid, status->st_gid))
		return fail_errno("cannot preserve ownership on", path);
	if (fchmod(fd, status->st_mode & 07777))
		return fail_errno("cannot preserve mode on", path);
	if (futimens(fd, times))
		return fail_errno("cannot preserve timestamps on", path);
	return 0;
}

static int apply_symlink_metadata(int directory_fd, const char *name,
				  const struct stat *status, const char *path)
{
	struct timespec times[2] = { status->st_atim, status->st_mtim };

	if (fchownat(directory_fd, name, status->st_uid, status->st_gid,
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
			return fail_errno("cannot read", path);
		}
		if (!count) {
			errno = EIO;
			return fail_errno("source changed while copying", path);
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
			return fail_errno("cannot read", path);
		}
		if (!count) {
			errno = EIO;
			return fail_errno("source changed while copying", path);
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
		return fail_errno("cannot inspect sparse extents in", path);
	}
	offset = first_data;
	while (offset < size) {
		off_t hole = lseek(source_fd, offset, SEEK_HOLE);
		off_t next;
		int result;

		if (hole < 0)
			return fail_errno("cannot inspect sparse extent in", path);
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
			return fail_errno("cannot inspect sparse extents in", path);
		}
		offset = next;
	}
	if (ftruncate(destination_fd, size))
		return fail_errno("cannot size", path);
	return 0;
}

static int copy_directory(int source_fd, int destination_fd,
			  const char *relative);

static int copy_regular(int source_directory_fd, int destination_directory_fd,
			const char *name, const char *path,
			const struct stat *initial)
{
	struct hardlink *existing = hardlink_find(initial->st_dev, initial->st_ino);
	struct stat opened;
	int source_fd;
	int destination_fd;
	int result;

	if (existing) {
		if (existing->size != initial->st_size ||
		    !timespec_equal(existing->ctime, initial->st_ctim)) {
			fprintf(stderr, "hard-linked source changed at '%s'\n", path);
			return COPY_ERROR;
		}
		result = require_capacity(4096, 1);
		if (result)
			return result;
		if (linkat(destination_root_fd, existing->destination_path,
			   destination_directory_fd, name, 0))
			return fail_errno("cannot preserve hard link at", path);
		return 0;
	}

	source_fd = openat(source_directory_fd, name,
			   O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (source_fd < 0)
		return fail_errno("cannot open regular file", path);
	if (fstat(source_fd, &opened) || !same_inode(initial, &opened)) {
		if (!errno)
			errno = ESTALE;
		result = fail_errno("source changed before copy at", path);
		close(source_fd);
		return result;
	}
	result = reserve_regular_bytes(&opened, path);
	if (result) {
		close(source_fd);
		return result;
	}
	result = require_capacity(4096, 1);
	if (result) {
		close(source_fd);
		return result;
	}
	destination_fd = openat(destination_directory_fd, name,
				O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC |
					O_NOFOLLOW,
				0600);
	if (destination_fd < 0) {
		result = fail_errno("cannot create regular file", path);
		close(source_fd);
		return result;
	}
	result = copy_file_data(source_fd, destination_fd, opened.st_size, path);
	if (!result) {
		struct stat after;

		if (fstat(source_fd, &after) || !same_inode(&opened, &after) ||
		    opened.st_size != after.st_size ||
		    !timespec_equal(opened.st_ctim, after.st_ctim)) {
			if (!errno)
				errno = ESTALE;
			result = fail_errno("source changed during copy at", path);
		}
	}
	if (!result)
		result = apply_fd_metadata(destination_fd, &opened, path);
	if (close(destination_fd) && !result)
		result = fail_errno("cannot close destination file", path);
	if (close(source_fd) && !result)
		result = fail_errno("cannot close source file", path);
	if (!result && opened.st_nlink > 1)
		result = hardlink_remember(&opened, path);
	return result;
}

static int copy_symlink(int source_directory_fd, int destination_directory_fd,
			const char *name, const char *path,
			const struct stat *initial)
{
	size_t capacity = initial->st_size > 0 ? (size_t)initial->st_size + 1 : 4096;
	char *target;
	ssize_t length;
	struct stat after;
	int result;

	if (capacity > 65536) {
		errno = ENAMETOOLONG;
		return fail_errno("symlink target is too long at", path);
	}
	target = malloc(capacity + 1);
	if (!target)
		return fail_errno("cannot allocate symlink target for", path);
	length = readlinkat(source_directory_fd, name, target, capacity);
	if (length < 0) {
		result = fail_errno("cannot read symlink", path);
		free(target);
		return result;
	}
	if ((size_t)length == capacity) {
		free(target);
		errno = ENAMETOOLONG;
		return fail_errno("symlink target changed at", path);
	}
	target[length] = '\0';
	if (fstatat(source_directory_fd, name, &after, AT_SYMLINK_NOFOLLOW) ||
	    !same_inode(initial, &after) ||
	    !timespec_equal(initial->st_ctim, after.st_ctim)) {
		if (!errno)
			errno = ESTALE;
		result = fail_errno("symlink changed during copy at", path);
		free(target);
		return result;
	}
	result = require_capacity(4096, 1);
	if (!result && symlinkat(target, destination_directory_fd, name))
		result = fail_errno("cannot create symlink", path);
	if (!result)
		result = apply_symlink_metadata(destination_directory_fd, name,
						&after, path);
	free(target);
	return result;
}

static int copy_entry(int source_directory_fd, int destination_directory_fd,
		      const char *name, const char *relative)
{
	struct stat status;
	char *path = relative_join(relative, name);
	int result;

	if (!path)
		return fail_errno("cannot allocate path below", relative);
	result = reserve_entry(path);
	if (result)
		goto out;
	if (fstatat(source_directory_fd, name, &status, AT_SYMLINK_NOFOLLOW)) {
		result = fail_errno("cannot inspect", path);
		goto out;
	}
	if (status.st_dev != source_device) {
		fprintf(stderr, "source crosses a filesystem boundary at '%s'\n", path);
		result = COPY_ERROR;
		goto out;
	}

	if (S_ISREG(status.st_mode)) {
		result = copy_regular(source_directory_fd, destination_directory_fd,
				      name, path, &status);
	} else if (S_ISLNK(status.st_mode)) {
		result = copy_symlink(source_directory_fd, destination_directory_fd,
				      name, path, &status);
	} else if (S_ISDIR(status.st_mode)) {
		struct stat opened;
		int child_source_fd;
		int child_destination_fd;

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
			result = fail_errno("cannot open source directory", path);
			goto out;
		}
		child_destination_fd = openat(destination_directory_fd, name,
					      O_RDONLY | O_CLOEXEC | O_DIRECTORY |
						      O_NOFOLLOW);
		if (child_destination_fd < 0) {
			result = fail_errno("cannot open destination directory", path);
			close(child_source_fd);
			goto out;
		}
		if (fstat(child_source_fd, &opened) || !same_inode(&status, &opened)) {
			if (!errno)
				errno = ESTALE;
			result = fail_errno("source directory changed at", path);
		} else {
			result = copy_directory(child_source_fd, child_destination_fd,
						path);
			if (!result)
				result = apply_fd_metadata(child_destination_fd, &opened,
							   path);
		}
		if (close(child_destination_fd) && !result)
			result = fail_errno("cannot close destination directory", path);
		if (close(child_source_fd) && !result)
			result = fail_errno("cannot close source directory", path);
	} else {
		fprintf(stderr, "unsupported source type at '%s'\n", path);
		result = COPY_ERROR;
	}

out:
	free(path);
	return result;
}

static int copy_directory(int source_fd, int destination_fd,
			  const char *relative)
{
	DIR *directory;
	struct dirent *entry;
	int scan_fd = dup(source_fd);
	int result = 0;

	if (scan_fd < 0)
		return fail_errno("cannot duplicate source directory", relative);
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
				    relative);
		if (result)
			break;
		errno = 0;
	}
	if (!result && errno)
		result = fail_errno("cannot continue scanning", relative);
	if (closedir(directory) && !result)
		result = fail_errno("cannot close source scan", relative);
	return result;
}

int main(int argc, char *argv[])
{
	struct stat source_status;
	int destination_parent_fd = -1;
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
	result = copy_directory(source_root_fd, destination_root_fd, "");
	if (!result)
		result = apply_fd_metadata(destination_root_fd, &source_status, "tree");
	if (!result)
		printf("%" PRIu64 " %" PRIu64 "\n", copied_entries,
		       copied_bytes);

out:
	hardlink_free_all();
	if (destination_root_fd >= 0 &&
	    destination_root_fd != destination_parent_fd)
		close(destination_root_fd);
	if (destination_parent_fd >= 0)
		close(destination_parent_fd);
	if (source_root_fd >= 0)
		close(source_root_fd);
	return result;
}
