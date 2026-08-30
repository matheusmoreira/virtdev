// SPDX-License-Identifier: AGPL-3.0-or-later

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

static int helper_active(void)
{
	char executable[4096];
	const char suffix[] = "/virtdev-file-state";
	static int active = -1;
	ssize_t length;

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

static int create_marker(const char *path)
{
	int descriptor = (int)syscall(SYS_openat, AT_FDCWD, path,
				      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
				      0600);

	if (descriptor < 0)
		return -1;
	return close(descriptor);
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
		if (errno != ENOENT || clock_gettime(CLOCK_MONOTONIC, &now))
			return -1;
		if (now.tv_sec - start.tv_sec >= 30) {
			errno = ETIMEDOUT;
			return -1;
		}
		nanosleep(&delay, NULL);
	}
}

ssize_t pread(int descriptor, void *buffer, size_t count, off_t offset)
{
	static uint64_t calls;

	if (helper_active()) {
		const char *ready = getenv("FILE_STATE_GATE_READY");
		const char *release = getenv("FILE_STATE_GATE_RELEASE");
		const char *skip_text = getenv("FILE_STATE_GATE_SKIP");
		char *end = NULL;
		unsigned long long skip;

		errno = 0;
		skip = skip_text ? strtoull(skip_text, &end, 10) : 0;
		if (errno || (skip_text && (!skip_text[0] || !end || *end))) {
			errno = EINVAL;
			return -1;
		}
		calls++;
		if (calls == skip + 1 &&
		    (!ready || !release || create_marker(ready) ||
		     wait_for_release(release)))
			return -1;
	}
	return syscall(SYS_pread64, descriptor, buffer, count, offset);
}
