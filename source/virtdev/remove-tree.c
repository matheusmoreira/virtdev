// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Private helper for descriptor-relative recursive removal. Every opened
// directory must remain on the target root's mount.

#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/openat2.h>
#include <linux/stat.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <unistd.h>

enum {
	REMOVE_OK = 0,
	MOUNT_BOUNDARY = 1,
	UNSAFE_TARGET = 2,
	REMOVE_FAILED = 3,
	USAGE_ERROR = 64,
};

struct identity {
	uint64_t mount_id;
	uint64_t inode;
	mode_t mode;
	dev_t device;
};

static const char *program_name;
static const char *root_path;

static int stat_identity(int directory, const char *name, int flags,
			 struct identity *identity)
{
	struct statx status;

	memset(&status, 0, sizeof(status));
	if (statx(directory, name, flags | AT_NO_AUTOMOUNT,
		  STATX_TYPE | STATX_INO | STATX_MNT_ID, &status))
		return -1;
	if (!(status.stx_mask & STATX_TYPE) ||
	    !(status.stx_mask & STATX_INO) ||
	    !(status.stx_mask & STATX_MNT_ID)) {
		errno = ENOTSUP;
		return -1;
	}
	identity->mount_id = status.stx_mnt_id;
	identity->inode = status.stx_ino;
	identity->mode = status.stx_mode;
	identity->device = makedev(status.stx_dev_major, status.stx_dev_minor);
	return 0;
}

static int identity_matches(const struct identity *left,
			    const struct identity *right)
{
	return left->mount_id == right->mount_id &&
	       left->inode == right->inode && left->mode == right->mode &&
	       left->device == right->device;
}

static void report_error(const char *path)
{
	fprintf(stderr, "%s: cannot remove '%s': %s\n", program_name, path,
		strerror(errno));
}

static void report_boundary(const char *path)
{
	printf("%s\n", path);
}

static char *child_path(const char *parent, const char *name)
{
	size_t parent_length = strlen(parent);
	size_t name_length = strlen(name);
	char *path;

	if (parent_length > SIZE_MAX - name_length - 2) {
		errno = ENAMETOOLONG;
		return NULL;
	}
	path = malloc(parent_length + name_length + 2);
	if (!path)
		return NULL;
	memcpy(path, parent, parent_length);
	path[parent_length] = '/';
	memcpy(path + parent_length + 1, name, name_length + 1);
	return path;
}

static int remove_directory_contents(int directory, uint64_t root_mount,
				     const char *path)
{
	DIR *stream;
	struct dirent *entry;
	int stream_descriptor;
	int result = REMOVE_OK;

	stream_descriptor = dup(directory);
	if (stream_descriptor < 0) {
		report_error(path);
		return REMOVE_FAILED;
	}
	stream = fdopendir(stream_descriptor);
	if (!stream) {
		close(stream_descriptor);
		report_error(path);
		return REMOVE_FAILED;
	}

	errno = 0;
	while ((entry = readdir(stream))) {
		struct identity before;
		char *entry_path;

		if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
			continue;
		entry_path = child_path(path, entry->d_name);
		if (!entry_path) {
			report_error(path);
			result = REMOVE_FAILED;
			break;
		}
		if (stat_identity(directory, entry->d_name,
				  AT_SYMLINK_NOFOLLOW, &before)) {
			if (errno == ENOENT) {
				free(entry_path);
				errno = 0;
				continue;
			}
			report_error(entry_path);
			free(entry_path);
			result = REMOVE_FAILED;
			break;
		}
		if (before.mount_id != root_mount) {
			report_boundary(entry_path);
			free(entry_path);
			result = MOUNT_BOUNDARY;
			break;
		}

		if (S_ISDIR(before.mode)) {
			struct identity opened, current;
			int child;

			child = openat(directory, entry->d_name,
				       O_RDONLY | O_CLOEXEC | O_DIRECTORY |
				       O_NOFOLLOW | O_NONBLOCK);
			if (child < 0) {
				if (errno == ENOENT) {
					free(entry_path);
					errno = 0;
					continue;
				}
				if (errno == ELOOP || errno == ENOTDIR) {
					errno = ESTALE;
				}
				report_error(entry_path);
				free(entry_path);
				result = REMOVE_FAILED;
				break;
			}
			if (stat_identity(child, "", AT_EMPTY_PATH, &opened)) {
				report_error(entry_path);
				close(child);
				free(entry_path);
				result = REMOVE_FAILED;
				break;
			}
			if (opened.mount_id != root_mount) {
				report_boundary(entry_path);
				close(child);
				free(entry_path);
				result = MOUNT_BOUNDARY;
				break;
			}
			if (!identity_matches(&before, &opened)) {
				errno = ESTALE;
				report_error(entry_path);
				close(child);
				free(entry_path);
				result = REMOVE_FAILED;
				break;
			}
			result = remove_directory_contents(child, root_mount,
						   entry_path);
			if (result != REMOVE_OK) {
				close(child);
				free(entry_path);
				break;
			}
			if (stat_identity(directory, entry->d_name,
					  AT_SYMLINK_NOFOLLOW, &current) ||
			    !identity_matches(&opened, &current)) {
				if (!errno)
					errno = ESTALE;
				report_error(entry_path);
				close(child);
				free(entry_path);
				result = REMOVE_FAILED;
				break;
			}
			if (unlinkat(directory, entry->d_name, AT_REMOVEDIR)) {
				if (errno == EBUSY) {
					report_boundary(entry_path);
					result = MOUNT_BOUNDARY;
				} else {
					report_error(entry_path);
					result = REMOVE_FAILED;
				}
				close(child);
				free(entry_path);
				break;
			}
			close(child);
		} else if (unlinkat(directory, entry->d_name, 0)) {
			if (errno == ENOENT) {
				free(entry_path);
				errno = 0;
				continue;
			}
			if (errno == EBUSY) {
				report_boundary(entry_path);
				result = MOUNT_BOUNDARY;
			} else {
				report_error(entry_path);
				result = REMOVE_FAILED;
			}
			free(entry_path);
			break;
		}
		free(entry_path);
		errno = 0;
	}
	if (result == REMOVE_OK && errno) {
		report_error(path);
		result = REMOVE_FAILED;
	}
	if (closedir(stream) && result == REMOVE_OK) {
		report_error(path);
		result = REMOVE_FAILED;
	}
	return result;
}

static int open_parent(const char *path, char **leaf)
{
	struct open_how how = {
		.flags = O_RDONLY | O_CLOEXEC | O_DIRECTORY,
		.resolve = RESOLVE_NO_MAGICLINKS | RESOLVE_NO_SYMLINKS,
	};
	char *copy, *slash;
	int descriptor;

	copy = strdup(path);
	if (!copy)
		return -1;
	slash = strrchr(copy, '/');
	if (!slash || !slash[1]) {
		free(copy);
		errno = EINVAL;
		return -1;
	}
	*leaf = strdup(slash + 1);
	if (!*leaf) {
		free(copy);
		return -1;
	}
	if (slash == copy)
		slash[1] = '\0';
	else
		*slash = '\0';
	descriptor = syscall(SYS_openat2, AT_FDCWD, copy, &how, sizeof(how));
	free(copy);
	if (descriptor < 0) {
		free(*leaf);
		*leaf = NULL;
	}
	return descriptor;
}

int main(int argc, char *argv[])
{
	struct identity parent_identity, root_identity, current;
	char *leaf = NULL;
	int parent, root, result;

	program_name = argv[0];
	if (argc != 2 || argv[1][0] != '/' || !strcmp(argv[1], "/")) {
		fprintf(stderr, "usage: %s /absolute/directory\n", argv[0]);
		return USAGE_ERROR;
	}
	root_path = argv[1];
	parent = open_parent(root_path, &leaf);
	if (parent < 0) {
		report_error(root_path);
		return UNSAFE_TARGET;
	}
	if (stat_identity(parent, "", AT_EMPTY_PATH, &parent_identity)) {
		report_error(root_path);
		close(parent);
		free(leaf);
		return UNSAFE_TARGET;
	}
	if (stat_identity(parent, leaf, AT_SYMLINK_NOFOLLOW, &root_identity)) {
		if (errno == ENOENT) {
			close(parent);
			free(leaf);
			return REMOVE_OK;
		}
		report_error(root_path);
		close(parent);
		free(leaf);
		return UNSAFE_TARGET;
	}
	if (root_identity.mount_id != parent_identity.mount_id) {
		report_boundary(root_path);
		close(parent);
		free(leaf);
		return MOUNT_BOUNDARY;
	}
	if (!S_ISDIR(root_identity.mode)) {
		if (unlinkat(parent, leaf, 0)) {
			report_error(root_path);
			close(parent);
			free(leaf);
			return REMOVE_FAILED;
		}
		if (close(parent)) {
			report_error(root_path);
			free(leaf);
			return REMOVE_FAILED;
		}
		free(leaf);
		return REMOVE_OK;
	}
	root = openat(parent, leaf, O_RDONLY | O_CLOEXEC | O_DIRECTORY |
		      O_NOFOLLOW | O_NONBLOCK);
	if (root < 0) {
		report_error(root_path);
		close(parent);
		free(leaf);
		return UNSAFE_TARGET;
	}
	if (stat_identity(root, "", AT_EMPTY_PATH, &current) ||
	    !identity_matches(&root_identity, &current)) {
		if (!errno)
			errno = ESTALE;
		report_error(root_path);
		close(root);
		close(parent);
		free(leaf);
		return UNSAFE_TARGET;
	}

	result = remove_directory_contents(root, root_identity.mount_id,
					   root_path);
	if (result == REMOVE_OK) {
		if (stat_identity(parent, leaf, AT_SYMLINK_NOFOLLOW, &current) ||
		    !identity_matches(&root_identity, &current)) {
			if (!errno)
				errno = ESTALE;
			report_error(root_path);
			result = REMOVE_FAILED;
		} else if (unlinkat(parent, leaf, AT_REMOVEDIR)) {
			if (errno == EBUSY) {
				report_boundary(root_path);
				result = MOUNT_BOUNDARY;
			} else {
				report_error(root_path);
				result = REMOVE_FAILED;
			}
		}
	}
	if (close(root) && result == REMOVE_OK) {
		report_error(root_path);
		result = REMOVE_FAILED;
	}
	if (close(parent) && result == REMOVE_OK) {
		report_error(root_path);
		result = REMOVE_FAILED;
	}
	free(leaf);
	return result;
}
