#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

static const char *paths[] = {
    "/sbin/launchd",
    "/private/test-jb/Applications/VirtualMac.app/VirtualMac",
    "/usr/libexec/InternetSharing",
    "/private/test-jb/usr/libexec/InternetSharing",
    "/private/test-jb/usr/sbin/rtadvd",
    "/private/other-jb/usr/libexec/InternetSharing",
    "/private/test-jb/usr/libexec/VirtualMac/install/install-macos",
    "/private/test-jb/usr/libexec/bootpd",
    "/private/test-jb-evil/usr/libexec/bootpd",
    "/private/test-jb/Applications/VirtualMac.app/VirtualMac-other",
};
static int stopped[sizeof(paths) / sizeof(paths[0])];

uid_t test_geteuid(void) { return getenv("TEST_NOT_ROOT") ? 501 : 0; }
pid_t test_getpid(void) { return 999; }
int test_usleep(useconds_t duration) { (void)duration; return 0; }

const char *jbroot(const char *path)
{
    static char result[4096];
    snprintf(result, sizeof(result), "/private/test-jb%s", path);
    return result;
}

char *test_realpath(const char *path, char *resolved)
{
    if (getenv("TEST_MISSING_FILES")) { errno = ENOENT; return NULL; }
    strcpy(resolved, path);
    return resolved;
}

int proc_listallpids(void *buffer, int size)
{
    if (getenv("TEST_LIST_ERROR")) { errno = EPERM; return -1; }
    int count = sizeof(paths) / sizeof(paths[0]);
    if (buffer) {
        assert(size >= count * (int)sizeof(pid_t));
        for (int i = 0; i < count; i++) ((pid_t *)buffer)[i] = 100 + i;
    }
    return count;
}

int proc_pidpath(int pid, void *buffer, uint32_t size)
{
    int index = pid - 100;
    assert(index >= 0 && (size_t)index < sizeof(paths) / sizeof(paths[0]));
    if (stopped[index]) { errno = ESRCH; return 0; }
    assert(strlen(paths[index]) + 1 <= size);
    strcpy(buffer, paths[index]);
    return (int)strlen(buffer);
}

int test_kill(pid_t pid, int number)
{
    int index = pid - 100;
    assert(index == 1 || index == 3 || index == 4 || index == 6 || index == 7);
    assert(number == SIGTERM);
    printf("stop %d\n", pid);
    if (!getenv("TEST_STILL_RUNNING")) stopped[index] = 1;
    return 0;
}
