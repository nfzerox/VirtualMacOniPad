#include "../host/VZPaths.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

static int has_prefix(const char *value, const char *prefix)
{
    return strncmp(value, prefix, strlen(prefix)) == 0;
}

static int is_decimal(const char *value)
{
    if (!*value)
        return 0;
    for (; *value; value++) {
        if (*value < '0' || *value > '9')
            return 0;
    }
    return 1;
}

static int has_suffix(const char *value, const char *suffix)
{
    size_t value_length = strlen(value);
    size_t suffix_length = strlen(suffix);
    return value_length >= suffix_length &&
        strcasecmp(value + value_length - suffix_length, suffix) == 0;
}

static int is_direct_child(const char *value, const char *parent)
{
    size_t parent_length = strlen(parent);
    return strncmp(value, parent, parent_length) == 0 &&
        value[parent_length] == '/' && value[parent_length + 1] != '\0' &&
        strchr(value + parent_length + 1, '/') == NULL;
}

static int is_child_path(const char *value, const char *parent)
{
    size_t length = strlen(parent);
    return strncmp(value, parent, length) == 0 && value[length] == '/' &&
        value[length + 1] != '\0';
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--diagnose") == 0) {
        const char *script =
            VZRuntimePath("install/start-install.sh");
        struct stat info;
        printf("launcher uid=%u euid=%u gid=%u egid=%u\n",
               getuid(), geteuid(), getgid(), getegid());
        if (stat(script, &info) == 0) {
            printf("start-install mode=%04o uid=%u gid=%u executable=%d\n",
                   info.st_mode & 07777, info.st_uid, info.st_gid,
                   access(script, X_OK) == 0);
        } else {
            printf("start-install stat failed: errno=%d %s\n",
                   errno, strerror(errno));
        }
        if (setgid(0) != 0 || setuid(0) != 0) {
            printf("setuid failed: errno=%d %s\n", errno, strerror(errno));
            return 1;
        }
        printf("after-setuid uid=%u euid=%u gid=%u egid=%u\n",
               getuid(), geteuid(), getgid(), getegid());
        return 0;
    }
    if (argc == 4 && strcmp(argv[1], "--cancel-install") == 0) {
        const char *attempt = argv[3];
        if (!is_decimal(argv[2]) || !has_prefix(attempt,
                VZStatePath("Installations/")) ||
            !has_suffix(attempt, ".installation") ||
            strchr(attempt, '\n') || strchr(attempt, '\r') ||
            strstr(attempt, "/../") || has_suffix(attempt, "/..")) {
            fprintf(stderr, "install-launcher: invalid cancellation request\n");
            return 2;
        }
        if (setgid(0) != 0 || setuid(0) != 0) {
            fprintf(stderr, "install-launcher: cannot become root: %s\n",
                    strerror(errno));
            return 1;
        }
        pid_t process = (pid_t)strtol(argv[2], NULL, 10);
        if (process > 1)
            kill(-process, SIGTERM);
        usleep(500000);
        execl(VZBootstrapPath("/bin/rm"),
              "rm", "-rf", "--", VZBootstrapArgument(attempt),
              (char *)NULL);
        return 1;
    }
    if (argc == 3 && strcmp(argv[1], "--delete-artifact") == 0) {
        const char *path = argv[2];
        const char *installations =
            VZStatePath("Installations/");
        const char *images = VZRestoreImagesRoot;
        int allowed =
            (has_prefix(path, installations) &&
             strlen(path) > strlen(installations)) ||
            is_child_path(path, images);
        if (!allowed || strchr(path, '\n') || strchr(path, '\r') ||
            strstr(path, "/../") || has_suffix(path, "/..")) {
            fprintf(stderr, "install-launcher: invalid artifact path\n");
            return 2;
        }
        if (setgid(0) != 0 || setuid(0) != 0) {
            fprintf(stderr, "install-launcher: cannot become root: %s\n",
                    strerror(errno));
            return 1;
        }
        execl(VZBootstrapPath("/bin/rm"),
              "rm", "-rf", "--", VZBootstrapArgument(path),
              (char *)NULL);
        fprintf(stderr, "install-launcher: cleanup exec failed: %s\n",
                strerror(errno));
        return 1;
    }
    if (argc != 8) {
        fprintf(stderr, "install-launcher: expected seven arguments\n");
        return 2;
    }
    if (!is_child_path(argv[1], VZRestoreImagesRoot) ||
        !(has_suffix(argv[1], ".ipsw") || has_suffix(argv[1], ".zip")) ||
        !has_prefix(argv[2],
            VZStatePath("Installations/")) ||
        !has_suffix(argv[2], ".bundle.installing") ||
        !is_direct_child(argv[3], VZLibraryRoot) ||
        !has_suffix(argv[3], ".bundle") ||
        !has_prefix(argv[4],
            VZStatePath("Installations/")) ||
        !has_suffix(argv[4], ".install.log") ||
        !is_decimal(argv[5]) || !is_decimal(argv[6]) ||
        !is_decimal(argv[7])) {
        fprintf(stderr, "install-launcher: invalid output path\n");
        return 2;
    }
    for (int index = 1; index < argc; index++) {
        if (strchr(argv[index], '\n') || strchr(argv[index], '\r')) {
            fprintf(stderr, "install-launcher: newline in argument\n");
            return 2;
        }
        if (strstr(argv[index], "/../") ||
            has_suffix(argv[index], "/..")) {
            fprintf(stderr, "install-launcher: parent traversal in argument\n");
            return 2;
        }
    }
    int log_fd = open(argv[4], O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (log_fd < 0)
        return 2;
    dup2(log_fd, STDOUT_FILENO);
    dup2(log_fd, STDERR_FILENO);
    close(log_fd);
    setlinebuf(stdout);
    setlinebuf(stderr);
    printf("INSTALL_LAUNCHER_BEGIN\tipsw=%s\n", argv[1]);

    struct stat info;
    if (stat(argv[1], &info) != 0 || !S_ISREG(info.st_mode)) {
        fprintf(stderr,
                "INSTALL_FAILED\tlauncher IPSW is not a regular file: %s\n",
                strerror(errno));
        return 2;
    }
    if (setgid(0) != 0 || setuid(0) != 0) {
        fprintf(stderr, "INSTALL_FAILED\tlauncher cannot become root: %s\n",
                strerror(errno));
        return 1;
    }
    if (setenv("PATH",
#if defined(VZ_ROOTHIDE)
               "/usr/bin:/bin:/usr/sbin:/sbin:/rootfs/usr/bin:/rootfs/bin",
#else
               "/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin",
#endif
               1) != 0) {
        fprintf(stderr, "INSTALL_FAILED\tlauncher cannot set PATH: %s\n",
                strerror(errno));
        return 1;
    }
    execl(VZBootstrapPath("/bin/sh"), "sh",
          VZBootstrapArgument(VZRuntimePath("install/start-install.sh")), argv[1],
          argv[2], argv[3], argv[4], argv[5], argv[6], argv[7],
          (char *)NULL);
    fprintf(stderr, "INSTALL_FAILED\tlauncher exec failed: %s\n",
            strerror(errno));
    return 1;
}
