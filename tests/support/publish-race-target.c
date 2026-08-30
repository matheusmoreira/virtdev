// SPDX-License-Identifier: AGPL-3.0-or-later

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

static int is_publisher(void)
{
	char path[4096];
	ssize_t length = readlink("/proc/self/exe", path, sizeof(path) - 1);
	const char *name;

	if (length < 0 || (size_t)length >= sizeof(path))
		return 0;
	path[length] = '\0';
	name = strrchr(path, '/');
	name = name ? name + 1 : path;
	return !strcmp(name, "virtdev-publish");
}

int renameat2(int old_directory, const char *old_path, int new_directory,
	      const char *new_path, unsigned int flags)
{
	const char *mode = getenv("PUBLISH_RACE_TARGET");

	if (mode && (flags & RENAME_NOREPLACE) && is_publisher()) {
		if (mkdir(new_path, 0700) && errno != EEXIST)
			return -1;
		if (!strcmp(mode, "nonempty")) {
			size_t length = strlen(new_path) + sizeof("/intruder");
			char *path = malloc(length);
			int descriptor;

			if (!path) {
				errno = ENOMEM;
				return -1;
			}
			if (snprintf(path, length, "%s/intruder", new_path) < 0) {
				free(path);
				errno = EIO;
				return -1;
			}
			descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
					  0600);
			free(path);
			if (descriptor < 0 && errno != EEXIST)
				return -1;
			if (descriptor >= 0 && close(descriptor))
				return -1;
		}
	}
	return (int)syscall(SYS_renameat2, old_directory, old_path,
			    new_directory, new_path, flags);
}
