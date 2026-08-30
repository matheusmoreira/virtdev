// SPDX-License-Identifier: AGPL-3.0-or-later

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

int renameat2(int old_directory, const char *old_path, int new_directory,
	      const char *new_path, unsigned int flags)
{
	const char *target = getenv("TRANSFER_EXIT_AFTER_EXCHANGE_TARGET");
	const char *marker = getenv("TRANSFER_EXIT_AFTER_EXCHANGE_MARKER");
	int result = (int)syscall(SYS_renameat2, old_directory, old_path,
				  new_directory, new_path, flags);

	if (!result && flags == RENAME_EXCHANGE && target && marker &&
	    !strcmp(new_path, target)) {
		int descriptor = (int)syscall(SYS_openat, AT_FDCWD, marker,
					      O_WRONLY | O_CREAT | O_EXCL |
						      O_CLOEXEC,
					      0600);

		if (descriptor >= 0) {
			close(descriptor);
			_exit(137);
		}
		if (errno != EEXIST)
			return -1;
	}
	return result;
}
