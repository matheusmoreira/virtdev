#define _GNU_SOURCE

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

int unlinkat(int directory, const char *path, int flags)
{
	static int injected;
	const char *marker = getenv("REMOVE_TREE_STALL_MARKER");
	const char *name = getenv("REMOVE_TREE_STALL_NAME");
	int marker_fd;

	if (!injected && marker && name && !strcmp(path, name)) {
		injected = 1;
		marker_fd = open(marker, O_WRONLY | O_CREAT | O_TRUNC, 0600);
		if (marker_fd >= 0)
			close(marker_fd);
		for (;;)
			pause();
	}
	return syscall(SYS_unlinkat, directory, path, flags);
}
