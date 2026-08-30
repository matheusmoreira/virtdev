#define _GNU_SOURCE

#include <errno.h>

int syncfs(int descriptor)
{
	static int calls;

	(void)descriptor;
	if (++calls >= 3) {
		errno = EIO;
		return -1;
	}
	return 0;
}
