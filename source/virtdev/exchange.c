// SPDX-License-Identifier: AGPL-3.0-or-later
//
// virtdev-exchange — atomically exchange two paths
//
// Wraps renameat2(2) with RENAME_EXCHANGE: a single syscall that
// atomically swaps the names of two filesystem entries.  Both paths
// must exist.  They may be of different types (regular file, directory,
// symlink, etc.) and need not be on the same parent directory, but
// they must be on the same mounted filesystem.
//
// Exit codes:
//
//   0    success
//   1    pre-exchange sync/open or exchange failed; names were not exchanged
//   2    names were exchanged, but the post-exchange durability sync failed
//   64   usage error

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifndef RENAME_EXCHANGE
#define RENAME_EXCHANGE 2
#endif

static int open_directory(const char *path)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);

	if (fd < 0)
		fprintf(stderr, "cannot open directory '%s': %s\n", path,
			strerror(errno));
	return fd;
}

static int sync_filesystem(int fd, const char *phase)
{
	if (!syncfs(fd))
		return 0;
	fprintf(stderr, "%s sync failed: %s\n", phase, strerror(errno));
	return -1;
}

int main(int argc, char *argv[])
{
	int fd1, fd2;

	if (argc != 3) {
		fprintf(stderr, "usage: %s path1 path2\n", argv[0]);
		return 64;
	}

	fd1 = open_directory(argv[1]);
	if (fd1 < 0)
		return 1;
	fd2 = open_directory(argv[2]);
	if (fd2 < 0) {
		close(fd1);
		return 1;
	}

	/*
	 * The staged image bytes, modes, and generation must reach stable storage
	 * before their names become authoritative. syncfs is intentionally used
	 * instead of fsync(directory): fsync on a directory does not flush the
	 * regular-file contents below it. The expected case is one filesystem;
	 * syncing both fds also handles the preflight cleanly before EXDEV.
	 */
	if (sync_filesystem(fd1, "pre-exchange") ||
	    sync_filesystem(fd2, "pre-exchange")) {
		close(fd2);
		close(fd1);
		return 1;
	}

	if (renameat2(AT_FDCWD, argv[1], AT_FDCWD, argv[2], RENAME_EXCHANGE)) {
		fprintf(stderr, "%s: cannot exchange '%s' and '%s': %s\n",
			argv[0], argv[1], argv[2], strerror(errno));
		close(fd2);
		close(fd1);
		return 1;
	}

	/*
	 * The descriptors still name the exchanged directory inodes. syncfs on
	 * either descriptor commits the rename and its parent-directory metadata;
	 * both calls keep error reporting symmetric. Exit 2 tells the caller the
	 * namespace changed, so it must preserve both trees for inspection.
	 */
	if (sync_filesystem(fd1, "post-exchange") ||
	    sync_filesystem(fd2, "post-exchange")) {
		close(fd2);
		close(fd1);
		return 2;
	}

	close(fd2);
	close(fd1);

	return 0;
}
