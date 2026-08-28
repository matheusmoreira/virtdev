// SPDX-License-Identifier: AGPL-3.0-or-later

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int write_text(const char *path, const char *text)
{
	int fd;
	ssize_t length = (ssize_t)strlen(text);

	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0 || write(fd, text, (size_t)length) != length) {
		if (fd >= 0)
			close(fd);
		return -1;
	}
	return close(fd);
}

static int touch(const char *path)
{
	return write_text(path, "");
}

int main(int argc, char *argv[])
{
	char pid_text[32];
	char *end;
	long generations;
	struct timespec delay = { .tv_nsec = 1000000 };

	if (argc != 6)
		return 64;
	errno = 0;
	generations = strtol(argv[5], &end, 10);
	if (errno || *end || generations < 1 || generations > 10000)
		return 64;

	signal(SIGINT, SIG_IGN);
	signal(SIGTERM, SIG_IGN);
	signal(SIGHUP, SIG_IGN);
	close(STDIN_FILENO);
	close(STDOUT_FILENO);
	close(STDERR_FILENO);

	for (long generation = 0; generation < generations; ++generation) {
		pid_t child;

		if (setpgid(0, 0))
			break;
		if (!access(argv[2], F_OK))
			touch(argv[3]);
		snprintf(pid_text, sizeof(pid_text), "%ld\n", (long)getpid());
		if (write_text(argv[1], pid_text))
			break;
		nanosleep(&delay, NULL);
		if (generation + 1 == generations)
			break;
		child = fork();
		if (child < 0)
			break;
		if (child > 0)
			_exit(0);
	}

	touch(argv[4]);
	return 0;
}
