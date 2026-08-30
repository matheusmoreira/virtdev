#define _GNU_SOURCE

#include <linux/stat.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/syscall.h>
#include <unistd.h>

int statx(int directory, const char *path, int flags, unsigned int mask,
	  struct statx *status)
{
	static int injected;
	const char *name = getenv("REMOVE_TREE_GATE_NAME");
	const char *source = getenv("REMOVE_TREE_GATE_SOURCE");
	const char *target = getenv("REMOVE_TREE_GATE_TARGET");
	int result;

	result = syscall(SYS_statx, directory, path, flags, mask, status);
	if (!result && !injected && name && source && target &&
	    !strcmp(path, name)) {
		injected = 1;
		if (mount(source, target, NULL, MS_BIND, NULL))
			_exit(120);
	}
	return result;
}
