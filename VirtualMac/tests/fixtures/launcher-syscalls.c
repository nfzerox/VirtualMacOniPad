#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

int test_open(const char *path, int flags, ...)
{
    va_list args;
    va_start(args, flags);
    int mode = va_arg(args, int);
    va_end(args);
    printf("open(%s,%d,%o)\n", path, flags, mode);
    return 10;
}

int test_stat(const char *path, struct stat *info)
{
    memset(info, 0, sizeof(*info));
    info->st_mode = S_IFREG | 0755;
    printf("stat(%s)\n", path);
    return 0;
}

int test_access(const char *path, int mode)
{
    (void)mode;
    if (strncmp(path, "/var/jb/", 8) == 0)
        return getenv("TEST_ROOTLESS") ? 0 : -1;
    return 0;
}

int test_setgid(gid_t value)
{
    printf("setgid(%u)\n", value);
    if (getenv("TEST_DENY_ROOT")) { errno = EPERM; return -1; }
    return 0;
}

int test_setuid(uid_t value)
{
    printf("setuid(%u)\n", value);
    return 0;
}

int test_kill(pid_t value, int number)
{
    printf("kill(%d,%d)\n", value, number);
    return 0;
}

int test_usleep(useconds_t value)
{
    printf("usleep(%u)\n", value);
    return 0;
}

int test_dup2(int source, int target) { (void)source; return target; }
int test_close(int descriptor) { (void)descriptor; return 0; }

int test_setenv(const char *name, const char *value, int overwrite)
{
    printf("setenv(%s,%s,%d)\n", name, value, overwrite);
    return 0;
}

int test_execl(const char *path, const char *argument, ...)
{
    printf("execl(%s)", path);
    va_list args;
    va_start(args, argument);
    while (argument) {
        printf(" <%s>", argument);
        argument = va_arg(args, const char *);
    }
    va_end(args);
    putchar('\n');
    errno = ENOENT;
    return -1;
}
