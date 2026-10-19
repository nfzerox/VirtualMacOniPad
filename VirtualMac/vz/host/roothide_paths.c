#if !defined(VZ_ROOTHIDE)
#error "This compatibility library is only for RootHide packages"
#endif

#include "VZPaths.h"
#include <copyfile.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <removefile.h>
#include <spawn.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>

struct pidfh;
extern struct pidfh *pidfile_open(const char *, mode_t, pid_t *);

static const char *redirect_path(const char *path, char buffer[PATH_MAX])
{
    if (!path) return path;
    const char *source = strncmp(path, "/private/", 9) == 0 ? path + 8 : path;
    const struct { const char *path; const char *name; } network[] = {
        {"/tmp/bootpd.plist", "bootpd.plist"},
        {"/tmp/com.apple.mis.rtadvd.conf", "com.apple.mis.rtadvd.conf"},
        {"/var/db/dhcpd_leases", "dhcpd_leases"},
        {"/var/db/bsdpd_clients", "bsdpd_clients"},
        {"/var/run/bootpd.pid", "bootpd.pid"},
        {"/var/run/rtadvd.pid", "rtadvd.pid"},
        {"/var/run/rtadvd.dump", "rtadvd.dump"},
        {"/Library/Preferences/SystemConfiguration/com.apple.vmnet.plist", "com.apple.vmnet.plist"},
        {"/Library/Preferences/SystemConfiguration/com.apple.dhcp6d.plist", "com.apple.dhcp6d.plist"},
    };
    for (size_t i = 0; i < sizeof(network) / sizeof(network[0]); i++) {
        size_t length = strlen(network[i].path);
        if (strncmp(source, network[i].path, length) == 0 &&
            (source[length] == '\0' || source[length] == '.' || source[length] == '-')) {
            snprintf(buffer, PATH_MAX, "%s%s%s", VZNetworkPath(""),
                     network[i].name, source + length);
            return buffer;
        }
    }
    if (strcmp(source, "/var/run/usbmuxd") == 0)
        return VZSocketPath("usbmuxd");
    if (strcmp(source, "/tmp/vzusbmuxd") == 0)
        return VZSocketPath("vzusbmuxd");
    const char *pairing = "/var/db/lockdown";
    size_t pairing_length = strlen(pairing);
    if (strncmp(source, pairing, pairing_length) == 0 &&
        (source[pairing_length] == '\0' || source[pairing_length] == '/')) {
        snprintf(buffer, PATH_MAX, "%s%s", VZRestorePath("Pairing"),
                 source + pairing_length);
        return buffer;
    }
    if (strcmp(source, "/tmp/") == 0 ||
        strncmp(source, "/tmp/bootImg", 12) == 0 ||
        strncmp(source, "/tmp/unified_cache.", 19) == 0) {
        snprintf(buffer, PATH_MAX, "%s%s", VZRestorePath(""), source + 5);
        return buffer;
    }
    return path;
}

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static const struct { const void *new; const void *old; } \
    interpose_##original __attribute__((section("__DATA,__interpose"))) = \
        {(const void *)&replacement, (const void *)&original}

static size_t redirected_confstr(int name, char *buffer, size_t size)
{
    if (name != _CS_DARWIN_USER_TEMP_DIR) return confstr(name, buffer, size);
    const char *path = VZRestorePath("");
    size_t required = strlen(path) + 1;
    if (size) strlcpy(buffer, path, size);
    return required;
}
INTERPOSE(redirected_confstr, confstr);

static int redirected_open(const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    char buffer[PATH_MAX];
    return open(redirect_path(path, buffer), flags, mode);
}
INTERPOSE(redirected_open, open);

static FILE *redirected_fopen(const char *path, const char *mode)
{
    char buffer[PATH_MAX];
    return fopen(redirect_path(path, buffer), mode);
}
INTERPOSE(redirected_fopen, fopen);

static int redirected_mkstemp(char *template)
{
    char buffer[PATH_MAX];
    const char *mapped = redirect_path(template, buffer);
    if (mapped == template) return mkstemp(template);
    int result = mkstemp(buffer);
    if (result >= 0) {
        size_t length = strlen(template);
        size_t mappedLength = strlen(buffer);
        if (length >= 6 && mappedLength >= 6)
            memcpy(template + length - 6, buffer + mappedLength - 6, 6);
    }
    return result;
}
INTERPOSE(redirected_mkstemp, mkstemp);

static char *redirected_mkdtemp(char *template)
{
    char buffer[PATH_MAX];
    const char *mapped = redirect_path(template, buffer);
    if (mapped == template) return mkdtemp(template);
    if (!mkdtemp(buffer)) return NULL;
    size_t length = strlen(template);
    size_t mappedLength = strlen(buffer);
    if (length >= 6 && mappedLength >= 6)
        memcpy(template + length - 6, buffer + mappedLength - 6, 6);
    return template;
}
INTERPOSE(redirected_mkdtemp, mkdtemp);

static int redirected_stat(const char *path, struct stat *info)
{
    char buffer[PATH_MAX];
    return stat(redirect_path(path, buffer), info);
}
INTERPOSE(redirected_stat, stat);

static int redirected_lstat(const char *path, struct stat *info)
{
    char buffer[PATH_MAX];
    return lstat(redirect_path(path, buffer), info);
}
INTERPOSE(redirected_lstat, lstat);

static DIR *redirected_opendir(const char *path)
{
    char buffer[PATH_MAX];
    return opendir(redirect_path(path, buffer));
}
INTERPOSE(redirected_opendir, opendir);

static char *redirected_realpath(const char *path, char *resolved)
{
    char buffer[PATH_MAX];
    return realpath(redirect_path(path, buffer), resolved);
}
INTERPOSE(redirected_realpath, realpath);

static int redirected_access(const char *path, int mode)
{
    char buffer[PATH_MAX];
    return access(redirect_path(path, buffer), mode);
}
INTERPOSE(redirected_access, access);

static int redirected_unlink(const char *path)
{
    char buffer[PATH_MAX];
    return unlink(redirect_path(path, buffer));
}
INTERPOSE(redirected_unlink, unlink);

static int redirected_remove(const char *path)
{
    char buffer[PATH_MAX];
    return remove(redirect_path(path, buffer));
}
INTERPOSE(redirected_remove, remove);

static int redirected_removefile(const char *path, removefile_state_t state,
                                 removefile_flags_t flags)
{
    char buffer[PATH_MAX];
    return removefile(redirect_path(path, buffer), state, flags);
}
INTERPOSE(redirected_removefile, removefile);

static int redirected_mkdir(const char *path, mode_t mode)
{
    char buffer[PATH_MAX];
    return mkdir(redirect_path(path, buffer), mode);
}
INTERPOSE(redirected_mkdir, mkdir);

static int redirected_rmdir(const char *path)
{
    char buffer[PATH_MAX];
    return rmdir(redirect_path(path, buffer));
}
INTERPOSE(redirected_rmdir, rmdir);

static int redirected_rename(const char *from, const char *to)
{
    char source[PATH_MAX], destination[PATH_MAX];
    return rename(redirect_path(from, source), redirect_path(to, destination));
}
INTERPOSE(redirected_rename, rename);

static int redirected_renamex_np(const char *from, const char *to,
                                 unsigned flags)
{
    char source[PATH_MAX], destination[PATH_MAX];
    return renamex_np(redirect_path(from, source),
                      redirect_path(to, destination), flags);
}
INTERPOSE(redirected_renamex_np, renamex_np);

static int redirected_copyfile(const char *from, const char *to,
                               copyfile_state_t state, copyfile_flags_t flags)
{
    char source[PATH_MAX], destination[PATH_MAX];
    return copyfile(redirect_path(from, source),
                    redirect_path(to, destination), state, flags);
}
INTERPOSE(redirected_copyfile, copyfile);

static int redirected_link(const char *from, const char *to)
{
    char source[PATH_MAX], destination[PATH_MAX];
    return link(redirect_path(from, source), redirect_path(to, destination));
}
INTERPOSE(redirected_link, link);

static int redirected_symlink(const char *target, const char *path)
{
    char source[PATH_MAX], destination[PATH_MAX];
    return symlink(redirect_path(target, source), redirect_path(path, destination));
}
INTERPOSE(redirected_symlink, symlink);

static ssize_t redirected_readlink(const char *path, char *output, size_t size)
{
    char buffer[PATH_MAX];
    return readlink(redirect_path(path, buffer), output, size);
}
INTERPOSE(redirected_readlink, readlink);

static int redirected_chmod(const char *path, mode_t mode)
{
    char buffer[PATH_MAX];
    return chmod(redirect_path(path, buffer), mode);
}
INTERPOSE(redirected_chmod, chmod);

static int redirected_lchmod(const char *path, mode_t mode)
{
    char buffer[PATH_MAX];
    return lchmod(redirect_path(path, buffer), mode);
}
INTERPOSE(redirected_lchmod, lchmod);

static int redirected_chown(const char *path, uid_t owner, gid_t group)
{
    char buffer[PATH_MAX];
    const char *mapped = redirect_path(path, buffer);
    return chown(mapped, owner, mapped == path ? group : 501);
}
INTERPOSE(redirected_chown, chown);

extern int open_dprotected_np(const char *, int, int, int, ...);
static int redirected_open_dprotected_np(const char *path, int flags,
                                         int protection, int dpflags, ...)
{
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, dpflags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    char buffer[PATH_MAX];
    return open_dprotected_np(redirect_path(path, buffer), flags,
                             protection, dpflags, mode);
}
INTERPOSE(redirected_open_dprotected_np, open_dprotected_np);

static struct pidfh *redirected_pidfile_open(const char *path, mode_t mode, pid_t *pid)
{
    char buffer[PATH_MAX];
    if (!path && strcmp(getprogname(), "rtadvd") == 0)
        path = "/var/run/rtadvd.pid";
    return pidfile_open(redirect_path(path, buffer), mode, pid);
}
INTERPOSE(redirected_pidfile_open, pidfile_open);

static int redirected_posix_spawn(pid_t *pid, const char *path,
    const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attributes,
    char *const arguments[], char *const environment[])
{
    if (path && strcmp(path, "/usr/sbin/rtadvd") == 0)
        path = VZBootstrapPath("/usr/sbin/rtadvd");
    return posix_spawn(pid, path, actions, attributes, arguments, environment);
}
INTERPOSE(redirected_posix_spawn, posix_spawn);

static int redirected_spawn_addopen(posix_spawn_file_actions_t *actions,
                                    int fd, const char *path, int flags,
                                    mode_t mode)
{
    char buffer[PATH_MAX];
    return posix_spawn_file_actions_addopen(actions, fd,
        redirect_path(path, buffer), flags, mode);
}
INTERPOSE(redirected_spawn_addopen, posix_spawn_file_actions_addopen);

static const struct sockaddr *redirect_socket(const struct sockaddr *address,
    socklen_t *length, struct sockaddr_un *storage)
{
    if (!address || address->sa_family != AF_UNIX ||
        *length <= offsetof(struct sockaddr_un, sun_path) ||
        *length > sizeof(*storage)) return address;
    const struct sockaddr_un *original = (const struct sockaddr_un *)address;
    size_t available = *length - offsetof(struct sockaddr_un, sun_path);
    if (strnlen(original->sun_path, available) == available) return address;
    char buffer[PATH_MAX];
    const char *path = redirect_path(original->sun_path, buffer);
    if (path == original->sun_path) return address;
    if (strlen(path) >= sizeof(storage->sun_path)) {
        errno = ENAMETOOLONG;
        return NULL;
    }
    memset(storage, 0, sizeof(*storage));
    storage->sun_family = AF_UNIX;
    strlcpy(storage->sun_path, path, sizeof(storage->sun_path));
    *length = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + strlen(path) + 1);
    storage->sun_len = (unsigned char)*length;
    return (const struct sockaddr *)storage;
}

static int redirected_bind(int socket, const struct sockaddr *address, socklen_t length)
{
    struct sockaddr_un storage;
    const struct sockaddr *mapped = redirect_socket(address, &length, &storage);
    return mapped ? bind(socket, mapped, length) : -1;
}
INTERPOSE(redirected_bind, bind);

static int redirected_connect(int socket, const struct sockaddr *address, socklen_t length)
{
    struct sockaddr_un storage;
    const struct sockaddr *mapped = redirect_socket(address, &length, &storage);
    int result = mapped ? connect(socket, mapped, length) : -1;
#if defined(VZ_DEVELOPMENT)
    if (address && address->sa_family == AF_UNIX) {
        int error = errno;
        static unsigned count;
        if (__sync_fetch_and_add(&count, 1) < 64) {
            FILE *log = fopen(VZRestorePath("socket-connect.log"), "a");
            if (log) {
                fprintf(log, "pid=%d source=%s target=%s length=%u result=%d errno=%d\n",
                    getpid(), ((const struct sockaddr_un *)address)->sun_path,
                    mapped ? ((const struct sockaddr_un *)mapped)->sun_path : "(invalid)",
                    length, result, error);
                fclose(log);
            }
        }
        errno = error;
    }
#endif
    return result;
}
INTERPOSE(redirected_connect, connect);

__attribute__((constructor)) static void configure_private_files(void)
{
    umask(0027);
}
