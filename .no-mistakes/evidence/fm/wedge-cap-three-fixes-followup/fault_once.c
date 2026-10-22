/* fault_once.c - a one-shot filesystem fault injector for the wedge-cap live
 * scenarios, built INSIDE the disposable test workspace and preloaded into the
 * real bin/fm-watch.sh process.
 *
 * It fails exactly ONE open(2)/openat(2)/creat(2) whose resolved path ends with
 * $FM_FAULT_MATCH, with $FM_FAULT_ERRNO (default EACCES). Once-only is global
 * across processes: the fault fires only for whoever wins an O_CREAT|O_EXCL
 * create of $FM_FAULT_MARKER, so a later write to the same path (the rollback
 * that follows the failed one) succeeds. That models a transient write failure
 * (EIO/ENOSPC/a read-only remount that clears), which is the only way the
 * watcher's own three-tier contract reaches its "rollback succeeded" tier.
 *
 * Nothing here knows anything about the watcher: it only fails a write the
 * operator asked to be failed, once.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Only a WRITE open is a candidate: a reader (the watcher's own `cat` of the
 * counter) must keep working, or the fault would silently rewrite what the
 * watcher believes it read instead of failing the write under test. */
static int fault_should_fire(const char *path, int flags)
{
	static long seen = 0;
	const char *match = getenv("FM_FAULT_MATCH");
	const char *marker = getenv("FM_FAULT_MARKER");
	const char *nth_env = getenv("FM_FAULT_NTH");
	char resolved[PATH_MAX];
	const char *name;
	size_t mlen, plen;
	long nth = 1;
	int fd;

	if (match == NULL || marker == NULL || path == NULL || *path == '\0')
		return 0;
	if ((flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND)) == 0)
		return 0;
	if (nth_env != NULL && *nth_env != '\0') {
		nth = strtol(nth_env, NULL, 10);
		if (nth < 1)
			nth = 1;
	}
	if (realpath(path, resolved) != NULL)
		name = resolved;
	else
		name = path;
	mlen = strlen(match);
	plen = strlen(name);
	if (plen < mlen || strcmp(name + plen - mlen, match) != 0)
		return 0;

	/* $FM_FAULT_NTH selects WHICH write of this path fails, so a caller can let
	 * an earlier write of the same cap-state file succeed and refuse a later
	 * one. Counting is per process; the watcher does its own cap-state writes
	 * in one shell. */
	seen++;
	if (seen != nth)
		return 0;

	/* O_EXCL create is the atomic winner election: exactly one process ever
	 * fires the fault, whatever the call ordering is across processes. */
	fd = open(marker, O_CREAT | O_EXCL | O_WRONLY, 0600);
	if (fd < 0)
		return 0;
	close(fd);
	return 1;
}

static int fault_errno(void)
{
	const char *name = getenv("FM_FAULT_ERRNO");
	if (name != NULL && strcmp(name, "EIO") == 0)
		return EIO;
	if (name != NULL && strcmp(name, "ENOSPC") == 0)
		return ENOSPC;
	if (name != NULL && strcmp(name, "EROFS") == 0)
		return EROFS;
	return EACCES;
}

#define REAL(sym) \
	static int (*real_##sym)(void) = NULL; \
	if (real_##sym == NULL) \
		real_##sym = (int (*)(void))dlsym(RTLD_NEXT, #sym)

int open(const char *path, int flags, ...)
{
	mode_t mode = 0;
	va_list ap;
	static int (*real_open)(const char *, int, ...) = NULL;

	if (flags & (O_CREAT | O_TMPFILE)) {
		va_start(ap, flags);
		mode = va_arg(ap, mode_t);
		va_end(ap);
	}
	if (real_open == NULL)
		real_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
	if (real_open == NULL) {
		errno = ENOSYS;
		return -1;
	}
	if (fault_should_fire(path, flags)) {
		errno = fault_errno();
		return -1;
	}
	return real_open(path, flags, mode);
}

int open64(const char *path, int flags, ...)
{
	mode_t mode = 0;
	va_list ap;
	static int (*real_open64)(const char *, int, ...) = NULL;

	if (flags & (O_CREAT | O_TMPFILE)) {
		va_start(ap, flags);
		mode = va_arg(ap, mode_t);
		va_end(ap);
	}
	if (real_open64 == NULL)
		real_open64 = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open64");
	if (real_open64 == NULL)
		return open(path, flags, mode);
	if (fault_should_fire(path, flags)) {
		errno = fault_errno();
		return -1;
	}
	return real_open64(path, flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...)
{
	mode_t mode = 0;
	va_list ap;
	static int (*real_openat)(int, const char *, int, ...) = NULL;

	if (flags & (O_CREAT | O_TMPFILE)) {
		va_start(ap, flags);
		mode = va_arg(ap, mode_t);
		va_end(ap);
	}
	if (real_openat == NULL)
		real_openat = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat");
	if (real_openat == NULL) {
		errno = ENOSYS;
		return -1;
	}
	/* Every state-dir write the watcher makes is absolute, so a relative path
	 * is passed through untouched rather than guessed at. */
	return real_openat(dirfd, path, flags, mode);
}

int openat64(int dirfd, const char *path, int flags, ...)
{
	mode_t mode = 0;
	va_list ap;
	static int (*real_openat64)(int, const char *, int, ...) = NULL;

	if (flags & (O_CREAT | O_TMPFILE)) {
		va_start(ap, flags);
		mode = va_arg(ap, mode_t);
		va_end(ap);
	}
	if (real_openat64 == NULL)
		real_openat64 = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat64");
	if (real_openat64 == NULL) {
		errno = ENOSYS;
		return -1;
	}
	if (path != NULL && path[0] == '/')
		return real_openat64(dirfd, path, flags, mode);
	return openat(dirfd, path, flags, mode);
}

int creat(const char *path, mode_t mode)
{
	static int (*real_creat)(const char *, mode_t) = NULL;

	if (real_creat == NULL)
		real_creat = (int (*)(const char *, mode_t))dlsym(RTLD_NEXT, "creat");
	if (real_creat == NULL) {
		errno = ENOSYS;
		return -1;
	}
	if (fault_should_fire(path, O_WRONLY | O_CREAT | O_TRUNC)) {
		errno = fault_errno();
		return -1;
	}
	return real_creat(path, mode);
}
/* Fortified glibc call sites (Ubuntu's default -D_FORTIFY_SOURCE) redirect the
 * plain names to the __*_2 variants, so the injector has to own those too. */
int __open_2(const char *path, int flags)
{
	static int (*real)(const char *, int) = NULL;

	if (real == NULL)
		real = (int (*)(const char *, int))dlsym(RTLD_NEXT, "__open_2");
	if (real == NULL) {
		errno = ENOSYS;
		return -1;
	}
	if (fault_should_fire(path, flags)) {
		errno = fault_errno();
		return -1;
	}
	return real(path, flags);
}

int __open64_2(const char *path, int flags)
{
	static int (*real)(const char *, int) = NULL;

	if (real == NULL)
		real = (int (*)(const char *, int))dlsym(RTLD_NEXT, "__open64_2");
	if (real == NULL)
		return __open_2(path, flags);
	if (fault_should_fire(path, flags)) {
		errno = fault_errno();
		return -1;
	}
	return real(path, flags);
}

int __openat_2(int dirfd, const char *path, int flags)
{
	static int (*real)(int, const char *, int) = NULL;

	if (real == NULL)
		real = (int (*)(int, const char *, int))dlsym(RTLD_NEXT, "__openat_2");
	if (real == NULL) {
		errno = ENOSYS;
		return -1;
	}
	if (fault_should_fire(path, flags)) {
		errno = fault_errno();
		return -1;
	}
	return real(dirfd, path, flags);
}

int __openat64_2(int dirfd, const char *path, int flags)
{
	static int (*real)(int, const char *, int) = NULL;

	if (real == NULL)
		real = (int (*)(int, const char *, int))dlsym(RTLD_NEXT, "__openat64_2");
	if (real == NULL)
		return __openat_2(dirfd, path, flags);
	if (fault_should_fire(path, flags)) {
		errno = fault_errno();
		return -1;
	}
	return real(dirfd, path, flags);
}
