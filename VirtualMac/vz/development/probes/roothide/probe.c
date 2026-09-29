#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <poll.h>
#include <pwd.h>
#include <roothide.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
extern int csops(pid_t, unsigned int, void *, size_t);

#define PROBE_ROOT "/usr/libexec/VirtualMacProbe"
#define MESSAGE_ID 0x564d50

static int wait_child(pid_t pid)
{
    int status = 0;
    pid_t result;
    do { result = waitpid(pid, &status, 0); } while (result < 0 && errno == EINTR);
    if (result < 0) return 1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

static int spawn_and_wait(const char *executable, char *const arguments[])
{
    pid_t child = 0;
    int result = posix_spawn(&child, executable, NULL, NULL, arguments, environ);
    if (result != 0) {
        fprintf(stderr, "spawn %s: %s\n", executable, strerror(result));
        return 1;
    }
    return wait_child(child);
}

static int receive_message(void)
{
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t result = mach_port_allocate(mach_task_self(),
        MACH_PORT_RIGHT_RECEIVE, &port);
    if (result != KERN_SUCCESS) return 1;
    result = mach_port_insert_right(mach_task_self(), port, port,
                                   MACH_MSG_TYPE_MAKE_SEND);
    if (result != KERN_SUCCESS) return 1;
    printf("%u\n", port);
    fflush(stdout);
    struct {
        mach_msg_header_t header;
        mach_msg_max_trailer_t trailer;
    } message = {0};
    result = mach_msg(&message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
        0, sizeof(message), port, 8000, MACH_PORT_NULL);
    mach_port_deallocate(mach_task_self(), port);
    mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
    return result != KERN_SUCCESS || message.header.msgh_id != MESSAGE_ID;
}

static int test_task_port(void)
{
    char executable[4096];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) return 1;
    int descriptors[2];
    if (pipe(descriptors) != 0) return 1;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, descriptors[0]);
    posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, descriptors[1]);
    char *arguments[] = {executable, "--child", NULL};
    pid_t child = 0;
    int spawned = posix_spawn(&child, executable, &actions, NULL,
                             arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(descriptors[1]);
    if (spawned != 0) {
        close(descriptors[0]);
        fprintf(stderr, "child spawn: %s\n", strerror(spawned));
        return 1;
    }

    struct pollfd descriptor = {.fd = descriptors[0], .events = POLLIN};
    char line[64] = {0};
    ssize_t count = poll(&descriptor, 1, 8000) > 0
        ? read(descriptors[0], line, sizeof(line) - 1) : -1;
    close(descriptors[0]);
    mach_port_t childPort = count > 0 ? (mach_port_t)strtoul(line, NULL, 10) : 0;
    task_t childTask = MACH_PORT_NULL;
    kern_return_t result = task_for_pid(mach_task_self(), child, &childTask);
    printf("task_for_pid child=%d result=%d\n", child, result);
    int failed = result != KERN_SUCCESS || childPort == 0;
    mach_port_t sendRight = MACH_PORT_NULL;
    if (!failed) {
        mach_msg_type_name_t acquiredType = 0;
        result = mach_port_extract_right(childTask, childPort,
            MACH_MSG_TYPE_COPY_SEND, &sendRight, &acquiredType);
        printf("mach_port_extract_right result=%d type=%u\n", result, acquiredType);
        failed = result != KERN_SUCCESS;
    }
    if (!failed) {
        mach_msg_header_t message = {
            .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0),
            .msgh_size = sizeof(message),
            .msgh_remote_port = sendRight,
            .msgh_id = MESSAGE_ID,
        };
        result = mach_msg(&message, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
            sizeof(message), 0, MACH_PORT_NULL, 5000, MACH_PORT_NULL);
        printf("mach_msg result=%d\n", result);
        failed = result != KERN_SUCCESS;
    }
    if (MACH_PORT_VALID(sendRight))
        mach_port_deallocate(mach_task_self(), sendRight);
    if (MACH_PORT_VALID(childTask))
        mach_port_deallocate(mach_task_self(), childTask);
    if (failed) kill(child, SIGKILL);
    int childResult = wait_child(child);
    return failed || childResult != 0;
}

static int test_library(void)
{
    const char *path = jbroot(PROBE_ROOT "/ProbeLibrary.dylib");
    void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fprintf(stderr, "dlopen %s: %s\n", path, dlerror());
        return 1;
    }
    const char *(*libraryRoot)(void) = dlsym(library, "virtualmac_probe_library_root");
    const char *root = libraryRoot ? libraryRoot() : NULL;
    printf("library root=%s\n", root ?: "(unavailable)");
    int failed = !root || strcmp(root, jbroot("/")) != 0;
    dlclose(library);
    return failed;
}

static int test_bootstrap_file(void)
{
    char file[] = "/tmp/virtualmac-roothide-probe.XXXXXX";
    int descriptor = mkstemp(file);
    if (descriptor < 0) return 1;
    close(descriptor);
    const char *argument = rootfs(file);
    printf("host temporary file=%s bootstrap argument=%s\n", file, argument);
    char *arguments[] = {"sh", "-c", "test -f \"$1\"", "virtualmac-probe",
                         (char *)argument, NULL};
    int result = spawn_and_wait(jbroot("/bin/sh"), arguments);
    unlink(file);
    return result;
}

static void report_path(const char *label, const char *path)
{
    struct stat info;
    int result = stat(path, &info);
    int error = errno;
    printf("%s=%s", label, path);
    if (result == 0)
        printf(" mode=%04o uid=%u gid=%u\n", info.st_mode & 07777,
               info.st_uid, info.st_gid);
    else
        printf(" stat-error=%d (%s)\n", error, strerror(error));
}

int main(int argc, char **argv)
{
    setlinebuf(stdout);
    if (argc == 2 && strcmp(argv[1], "--child") == 0)
        return receive_message();
    if (argc == 2 && strcmp(argv[1], "--as-mobile") == 0) {
        struct passwd *mobile = getpwnam("mobile");
        if (!mobile || getuid() != 0 || initgroups("mobile", mobile->pw_gid) != 0 ||
            setgid(mobile->pw_gid) != 0 || setuid(mobile->pw_uid) != 0) {
            fprintf(stderr, "cannot drop to mobile: %s\n", strerror(errno));
            return 1;
        }
    } else if (argc != 1) {
        fprintf(stderr, "usage: virtualmac-roothide-probe [--as-mobile]\n");
        return 2;
    }
    uint32_t flags = 0;
    int csResult = csops(getpid(), 0, &flags, sizeof(flags));
    printf("identity uid=%u euid=%u gid=%u egid=%u csops=%d csflags=0x%x\n",
           getuid(), geteuid(), getgid(), getegid(), csResult, flags);
    printf("jbrand=%016llX\n", jbrand());
    report_path("bootstrap", jbroot("/"));
    report_path("native-code", jbroot(PROBE_ROOT));
    report_path("bootstrap-var", jbroot("/var/root"));
    report_path("host-storage", "/var/mobile/Media/VirtualMac");
    printf("host-storage bootstrap argument=%s\n",
           rootfs("/var/mobile/Media/VirtualMac"));

    int library = test_library();
    int bootstrapFile = test_bootstrap_file();
    int taskPort = test_task_port();
    const char *helper = jbroot(PROBE_ROOT "/root-helper");
    char *arguments[] = {(char *)helper, NULL};
    int root = spawn_and_wait(helper, arguments);
    printf("RESULT library=%s bootstrap-file=%s task-port=%s setuid=%s\n",
           library ? "FAIL" : "PASS", bootstrapFile ? "FAIL" : "PASS",
           taskPort ? "FAIL" : "PASS", root ? "FAIL" : "PASS");
    return library || bootstrapFile || taskPort || root;
}
