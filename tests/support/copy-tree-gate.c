// SPDX-License-Identifier: AGPL-3.0-or-later

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static int helper_active(void)
{
	char executable[4096];
	static int active = -1;
	ssize_t length;
	const char suffix[] = "/virtdev-copy-tree";

	if (active >= 0)
		return active;
	length = readlink("/proc/self/exe", executable, sizeof(executable) - 1);
	if (length < 0 || (size_t)length >= sizeof(executable))
		return active = 0;
	executable[length] = '\0';
	active = (size_t)length >= sizeof(suffix) - 1 &&
		 !strcmp(executable + length - (sizeof(suffix) - 1), suffix);
	return active;
}

static int create_marker(const char *path, const char *content)
{
	size_t length = strlen(content);
	int fd = (int)syscall(SYS_openat, AT_FDCWD, path,
			      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);

	if (fd < 0)
		return -1;
	while (length) {
		ssize_t written = write(fd, content, length);

		if (written < 0) {
			if (errno == EINTR)
				continue;
			close(fd);
			return -1;
		}
		content += written;
		length -= (size_t)written;
	}
	return close(fd);
}

static int wait_for_release(const char *path)
{
	struct timespec delay = { .tv_nsec = 1000000 };
	struct timespec start;
	struct timespec now;
	struct stat status;

	if (clock_gettime(CLOCK_MONOTONIC, &start))
		return -1;
	for (;;) {
		if (!syscall(SYS_newfstatat, AT_FDCWD, path, &status, 0))
			return 0;
		if (errno != ENOENT)
			return -1;
		if (clock_gettime(CLOCK_MONOTONIC, &now))
			return -1;
		if (now.tv_sec - start.tv_sec >= 30) {
			errno = ETIMEDOUT;
			return -1;
		}
		nanosleep(&delay, NULL);
	}
}

int openat(int directory_fd, const char *path, int flags, ...)
{
	static unsigned int regular_source_opens;
	mode_t mode = 0;
	int has_mode = (flags & O_CREAT) || ((flags & O_TMPFILE) == O_TMPFILE);

	if (has_mode) {
		va_list arguments;

		va_start(arguments, flags);
		mode = (mode_t)va_arg(arguments, int);
		va_end(arguments);
	}
	if (helper_active() && (flags & O_ACCMODE) == O_RDONLY &&
	    !(flags & (O_DIRECTORY | O_CREAT | O_PATH))) {
		const char *first = getenv("COPY_TREE_GATE_FIRST");
		const char *ready = getenv("COPY_TREE_GATE_READY");
		const char *release = getenv("COPY_TREE_GATE_RELEASE");
		const char *skip_text = getenv("COPY_TREE_GATE_SKIP");
		char *end = NULL;
		unsigned long skip;

		errno = 0;
		skip = skip_text ? strtoul(skip_text, &end, 10) : 0;
		if (errno || (skip_text && (!skip_text[0] || !end || *end)) ||
		    skip > UINT32_MAX - 2) {
			errno = EINVAL;
			return -1;
		}
		regular_source_opens++;
		if (!first || !ready || !release) {
			errno = EINVAL;
			return -1;
		}
		if (regular_source_opens == skip + 1 && create_marker(first, path))
			return -1;
		if (regular_source_opens == skip + 2 &&
		    (create_marker(ready, "ready\n") || wait_for_release(release)))
			return -1;
	}
	return (int)syscall(SYS_openat, directory_fd, path, flags, mode);
}
