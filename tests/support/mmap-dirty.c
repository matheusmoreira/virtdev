// SPDX-License-Identifier: AGPL-3.0-or-later

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int create_marker(const char *path)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);

	if (fd < 0)
		return -1;
	return close(fd);
}

static int wait_for_marker(const char *path)
{
	struct timespec delay = { .tv_nsec = 1000000 };
	struct timespec start;
	struct timespec now;
	struct stat status;

	if (clock_gettime(CLOCK_MONOTONIC, &start))
		return -1;
	for (;;) {
		if (!stat(path, &status))
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

int main(int argc, char *argv[])
{
	int descriptors[2] = { -1, -1 };
	void *mappings[2] = { MAP_FAILED, MAP_FAILED };
	struct stat status[2];
	size_t length;
	size_t file_index;
	size_t byte_index;
	int result = 1;

	if (argc != 8) {
		fprintf(stderr,
			"usage: %s first second mapped trigger mutated release replacement\n",
			argv[0]);
		return 64;
	}
	length = strlen(argv[7]);
	for (file_index = 0; file_index < 2; file_index++) {
		descriptors[file_index] = open(argv[file_index + 1],
					       O_RDWR | O_CLOEXEC);
		if (descriptors[file_index] < 0 ||
		    fstat(descriptors[file_index], &status[file_index])) {
			fprintf(stderr, "cannot map '%s': %s\n", argv[file_index + 1],
				strerror(errno));
			goto out;
		}
		if (status[file_index].st_size < 0 ||
		    (uint64_t)status[file_index].st_size != (uint64_t)length) {
			fprintf(stderr, "cannot map '%s': %s\n", argv[file_index + 1],
				strerror(EINVAL));
			goto out;
		}
		mappings[file_index] = mmap(NULL, length, PROT_READ | PROT_WRITE,
					    MAP_SHARED, descriptors[file_index], 0);
		if (mappings[file_index] == MAP_FAILED) {
			fprintf(stderr, "cannot map '%s': %s\n", argv[file_index + 1],
				strerror(errno));
			goto out;
		}
		for (byte_index = 0; byte_index < length; byte_index++) {
			volatile unsigned char *bytes = mappings[file_index];

			bytes[byte_index] = bytes[byte_index];
		}
	}
	if (create_marker(argv[3]) || wait_for_marker(argv[4])) {
		fprintf(stderr, "mmap synchronization failed: %s\n", strerror(errno));
		goto out;
	}
	for (file_index = 0; file_index < 2; file_index++) {
		volatile unsigned char *bytes = mappings[file_index];

		for (byte_index = 0; byte_index < length; byte_index++)
			bytes[byte_index] = (unsigned char)argv[7][byte_index];
	}
	if (create_marker(argv[5]) || wait_for_marker(argv[6])) {
		fprintf(stderr, "mmap synchronization failed: %s\n", strerror(errno));
		goto out;
	}
	result = 0;

out:
	for (file_index = 0; file_index < 2; file_index++) {
		if (mappings[file_index] != MAP_FAILED)
			munmap(mappings[file_index], length);
		if (descriptors[file_index] >= 0)
			close(descriptors[file_index]);
	}
	return result;
}
