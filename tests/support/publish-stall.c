// SPDX-License-Identifier: AGPL-3.0-or-later

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <stdlib.h>
#include <string.h>
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

static int mark_ready(void)
{
	const char *marker = getenv("PUBLISH_STALL_MARKER");
	int descriptor;

	if (!marker)
		return 0;
	descriptor = (int)syscall(SYS_openat, AT_FDCWD, marker,
				  O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
	if (descriptor < 0)
		return errno == EEXIST ? 0 : -1;
	return close(descriptor);
}

int renameat2(int old_directory, const char *old_path, int new_directory,
	      const char *new_path, unsigned int flags)
{
	const char *mode = getenv("PUBLISH_STALL_MODE");
	int result;

	if (!mode || !is_publisher())
		return (int)syscall(SYS_renameat2, old_directory, old_path,
				    new_directory, new_path, flags);
	if (!strcmp(mode, "before")) {
		if (mark_ready())
			return -1;
		sleep(30);
	}
	result = (int)syscall(SYS_renameat2, old_directory, old_path,
			      new_directory, new_path, flags);
	if (!result && !strcmp(mode, "after")) {
		if (mark_ready())
			return -1;
		sleep(30);
	}
	return result;
}
