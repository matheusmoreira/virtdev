// SPDX-License-Identifier: AGPL-3.0-or-later
// Atomically publish a staged filesystem entry.

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum {
	PUBLISH_OK = 0,
	PUBLISH_UNCHANGED = 1,
	PUBLISH_COMMITTED_UNSYNCED = 2,
	PUBLISH_CONFLICT = 3,
	PUBLISH_USAGE = 64,
};

static char *parent_path(const char *path)
{
	char *copy;
	char *slash;
	size_t length;

	if (!path || !path[0])
		return NULL;
	length = strlen(path);
	if (length > 1 && path[length - 1] == '/')
		return NULL;
	copy = strdup(path);
	if (!copy)
		return NULL;
	slash = strrchr(copy, '/');
	if (!slash) {
		free(copy);
		return strdup(".");
	}
	if (!slash[1]) {
		free(copy);
		return NULL;
	}
	if (slash == copy)
		slash[1] = '\0';
	else
		*slash = '\0';
	return copy;
}

static int open_parent(const char *path, char **parent)
{
	int descriptor;

	*parent = parent_path(path);
	if (!*parent) {
		errno = EINVAL;
		return -1;
	}
	descriptor = open(*parent,
			  O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
	if (descriptor < 0)
		fprintf(stderr, "cannot open publication parent '%s': %s\n",
			*parent, strerror(errno));
	return descriptor;
}

static int sync_parent(int descriptor, const char *phase, const char *path)
{
	if (!syncfs(descriptor))
		return 0;
	fprintf(stderr, "%s sync failed for '%s': %s\n", phase, path,
		strerror(errno));
	return -1;
}

int main(int argc, char **argv)
{
	const char *mode;
	const char *source;
	const char *target;
	char *source_parent = NULL;
	char *target_parent = NULL;
	struct stat status;
	unsigned int rename_flags;
	int source_parent_fd = -1;
	int target_parent_fd = -1;
	int result = PUBLISH_UNCHANGED;

	if (argc != 4 || !strcmp(argv[2], argv[3])) {
		fprintf(stderr, "usage: %s noreplace|exchange source target\n",
			argv[0]);
		return PUBLISH_USAGE;
	}
	mode = argv[1];
	source = argv[2];
	target = argv[3];
	if (!strcmp(mode, "noreplace"))
		rename_flags = RENAME_NOREPLACE;
	else if (!strcmp(mode, "exchange"))
		rename_flags = RENAME_EXCHANGE;
	else {
		fprintf(stderr, "usage: %s noreplace|exchange source target\n",
			argv[0]);
		return PUBLISH_USAGE;
	}

	source_parent_fd = open_parent(source, &source_parent);
	if (source_parent_fd < 0)
		goto out;
	target_parent_fd = open_parent(target, &target_parent);
	if (target_parent_fd < 0)
		goto out;
	if (lstat(source, &status)) {
		fprintf(stderr, "cannot inspect staged publication '%s': %s\n",
			source, strerror(errno));
		goto out;
	}
	if (rename_flags == RENAME_NOREPLACE) {
		if (!lstat(target, &status)) {
			result = PUBLISH_CONFLICT;
			goto out;
		}
		if (errno != ENOENT) {
			fprintf(stderr, "cannot inspect publication target '%s': %s\n",
				target, strerror(errno));
			goto out;
		}
	} else if (lstat(target, &status)) {
		fprintf(stderr, "cannot inspect exchange target '%s': %s\n",
			target, strerror(errno));
		goto out;
	}
	if (sync_parent(source_parent_fd, "pre-publication", source) ||
	    sync_parent(target_parent_fd, "pre-publication", target))
		goto out;
	if (renameat2(AT_FDCWD, source, AT_FDCWD, target, rename_flags)) {
		if (rename_flags == RENAME_NOREPLACE && errno == EEXIST) {
			result = PUBLISH_CONFLICT;
			goto out;
		}
		fprintf(stderr, "cannot publish '%s' as '%s': %s\n", source,
			target, strerror(errno));
		goto out;
	}
	result = PUBLISH_COMMITTED_UNSYNCED;
	if (sync_parent(source_parent_fd, "post-publication", source) ||
	    sync_parent(target_parent_fd, "post-publication", target))
		goto out;
	result = PUBLISH_OK;

out:
	if (target_parent_fd >= 0)
		close(target_parent_fd);
	if (source_parent_fd >= 0)
		close(source_parent_fd);
	free(target_parent);
	free(source_parent);
	return result;
}
