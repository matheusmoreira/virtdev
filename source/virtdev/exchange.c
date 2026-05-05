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
//   1    exchange failed (see stderr for errno)
//   64   usage error

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>

#ifndef RENAME_EXCHANGE
#define RENAME_EXCHANGE 2
#endif

int main(int argc, char *argv[])
{
	if (argc != 3) {
		fprintf(stderr, "usage: %s path1 path2\n", argv[0]);
		return 64;
	}

	if (renameat2(AT_FDCWD, argv[1], AT_FDCWD, argv[2], RENAME_EXCHANGE)) {
		fprintf(stderr, "%s: cannot exchange '%s' and '%s': %s\n",
			argv[0], argv[1], argv[2], strerror(errno));
		return 1;
	}

	return 0;
}
