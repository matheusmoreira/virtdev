// SPDX-License-Identifier: AGPL-3.0-or-later

#define _GNU_SOURCE

#include <errno.h>
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

int syncfs(int descriptor)
{
	if (is_publisher()) {
		errno = EIO;
		return -1;
	}
	return (int)syscall(SYS_syncfs, descriptor);
}
