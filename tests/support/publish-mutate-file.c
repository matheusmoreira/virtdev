// SPDX-License-Identifier: AGPL-3.0-or-later

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

static int write_all(int descriptor, const char *text)
{
	size_t remaining = strlen(text);

	while (remaining) {
		ssize_t written = write(descriptor, text, remaining);

		if (written < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		text += written;
		remaining -= (size_t)written;
	}
	return 0;
}

int renameat2(int old_directory, const char *old_path, int new_directory,
	      const char *new_path, unsigned int flags)
{
	const char *target = getenv("TRANSFER_MUTATION_TARGET");
	const char *marker = getenv("TRANSFER_MUTATION_MARKER");
	const char *mode = getenv("TRANSFER_MUTATION_MODE");
	int marker_fd;

	if ((flags & RENAME_EXCHANGE) && target && marker &&
	    !strcmp(new_path, target)) {
		marker_fd = (int)syscall(SYS_openat, AT_FDCWD, marker,
					 O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
					 0600);
		if (marker_fd >= 0) {
			if (close(marker_fd))
				return -1;
			if (mode && !strcmp(mode, "xattr")) {
				if (setxattr(target, "user.virtdev-race", "writer", 6, 0))
					return -1;
			} else if (mode && !strcmp(mode, "hardlink")) {
				char first[PATH_MAX];
				char second[PATH_MAX];
				struct stat directory_status;
				struct timespec times[2];
				int first_length;
				int second_length;

				first_length = snprintf(first, sizeof(first), "%s/one", target);
				second_length = snprintf(second, sizeof(second), "%s/two", target);
				if (first_length < 0 || (size_t)first_length >= sizeof(first) ||
				    second_length < 0 || (size_t)second_length >= sizeof(second) ||
				    stat(target, &directory_status))
					return -1;
				times[0] = directory_status.st_atim;
				times[1] = directory_status.st_mtim;
				if (unlink(second) || link(first, second) ||
				    utimensat(AT_FDCWD, target, times, 0))
					return -1;
			} else {
				int target_fd = (int)syscall(SYS_openat, AT_FDCWD,
							 target, O_WRONLY | O_TRUNC |
							 O_CLOEXEC, 0);

				if (target_fd < 0)
					return -1;
				if (write_all(target_fd, "writer-update\n") ||
				    fsync(target_fd) || close(target_fd))
					return -1;
			}
		} else if (errno != EEXIST) {
			return -1;
		}
	}
	return (int)syscall(SYS_renameat2, old_directory, old_path,
			    new_directory, new_path, flags);
}
