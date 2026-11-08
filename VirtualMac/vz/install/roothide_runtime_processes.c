#if !defined(VZ_ROOTHIDE)
#error "This helper is only for RootHide packages"
#endif

#include "../host/VZPaths.h"
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern int proc_listallpids(void *, int);
extern int proc_pidpath(int, void *, uint32_t);

static const char *const executables[] = {
    "/Applications/VirtualMac.app/VirtualMac",
    "/usr/libexec/VirtualMac/install/install-macos",
    "/usr/libexec/VirtualMac/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine",
    "/usr/libexec/VirtualMac/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation",
    "/usr/libexec/VirtualMac/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/Resources/usbmuxd",
    "/usr/libexec/InternetSharing", "/usr/libexec/bootpd", "/usr/sbin/rtadvd",
};
static char package_paths[sizeof(executables) / sizeof(executables[0])][PATH_MAX];
static size_t executable_count = sizeof(executables) / sizeof(executables[0]);

static bool package_process(pid_t pid)
{
    char path[4 * PATH_MAX] = {0};
    if (pid <= 1 || pid == getpid() || proc_pidpath(pid, path, sizeof(path)) <= 0)
        return false;
    for (size_t i = 0; i < executable_count; i++)
        if (package_paths[i][0] && strcmp(path, package_paths[i]) == 0)
            return true;
    return false;
}

int main(int argc, char **argv)
{
    bool stop = argc == 2 && strcmp(argv[1], "--stop") == 0;
    bool vms_only = argc == 2 && strcmp(argv[1], "--list-vms") == 0;
    bool guests_only = argc == 2 && strcmp(argv[1], "--list-guests") == 0;
    if (argc != 2 || (!stop && !vms_only && !guests_only &&
            strcmp(argv[1], "--list") != 0)) {
        fputs("usage: runtime-processes --list|--list-vms|--list-guests|--stop\n", stderr);
        return 2;
    }
    // --list-vms includes the app and usbmuxd so the install flow can
    // refuse while the app is mid-restore. --list-guests checks only the
    // processes that actually run a guest (installer, VMM, installation
    // service), so library consolidation is allowed while the app itself
    // or the resident usbmuxd helper is up.
    if (vms_only) executable_count = 5;
    if (guests_only)
        executable_count = 4; // indices 1..3: install-macos, VMM, Installation
    if (geteuid() != 0) {
        fputs("runtime-processes requires root\n", stderr);
        return 1;
    }
    size_t start = guests_only ? 1 : 0;
    for (size_t i = start; i < executable_count; i++) {
        if (!realpath(jbroot(executables[i]), package_paths[i - start]))
            package_paths[i - start][0] = '\0';
    }
    if (guests_only) executable_count -= start; // only the shifted set is live
    int count = proc_listallpids(NULL, 0);
    if (count <= 0 || count > INT_MAX / (int)sizeof(pid_t) - 128) {
        fputs("cannot enumerate runtime processes\n", stderr);
        return 1;
    }
    size_t capacity = (size_t)count + 128;
    pid_t *pids = calloc(capacity, sizeof(*pids));
    if (!pids) return 1;
    count = proc_listallpids(pids, (int)(capacity * sizeof(*pids)));
    if (count < 0 || (size_t)count >= capacity) {
        free(pids);
        fputs("runtime process list changed; retry\n", stderr);
        return 1;
    }
    for (int i = 0; i < count; i++) {
        if (!package_process(pids[i])) {
            pids[i] = 0;
            continue;
        }
        if (!stop) {
            printf("%d\n", pids[i]);
        } else if (kill(pids[i], SIGTERM) != 0 && errno != ESRCH) {
            perror("stop package process");
            free(pids);
            return 1;
        }
    }
    if (stop) {
        for (unsigned attempt = 0; attempt < 30; attempt++) {
            bool pending = false;
            for (int i = 0; i < count; i++) pending |= package_process(pids[i]);
            if (!pending) { free(pids); return 0; }
            usleep(100000);
        }
        fputs("Virtual Mac is still stopping; retry the package operation.\n", stderr);
        free(pids);
        return 1;
    }
    free(pids);
    return 0;
}
