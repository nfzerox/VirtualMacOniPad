#include <assert.h>
#include <copyfile.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <limits.h>
#include <removefile.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static void raw_exists(const char *path, int expected)
{
    struct stat info;
    int result = fstatat(AT_FDCWD, path, &info, AT_SYMLINK_NOFOLLOW);
    assert((result == 0) == expected);
    if (result != 0) assert(errno == ENOENT);
}

static void make_file(const char *path)
{
    int fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0600);
    assert(fd >= 0 && write(fd, "private", 7) == 7);
    assert(close(fd) == 0);
}

static void check_content(const char *path)
{
    char contents[8] = {0};
    int fd = open(path, O_RDONLY);
    assert(fd >= 0 && read(fd, contents, sizeof(contents)) == 7);
    assert(close(fd) == 0 && strcmp(contents, "private") == 0);
}

static void check_traversal(FTS *stream, const char *root)
{
    assert(stream);
    unsigned files = 0;
    FTSENT *entry;
    while ((entry = fts_read(stream))) {
        assert(entry->fts_info != FTS_ERR && entry->fts_info != FTS_NS &&
               entry->fts_info != FTS_DNR);
        if (entry->fts_info == FTS_F) {
            files++;
            assert(strcmp(entry->fts_path + strlen(root), "/input") == 0);
            check_content(entry->fts_accpath);
        }
    }
    assert(files == 1 && fts_close(stream) == 0);
}

static void check_directory_access(void)
{
    char directory[] = "/tmp/unified_cache.XXXXXX";
    assert(mkdtemp(directory) == directory);
    raw_exists(directory, 0);
    struct stat info;
    assert(lstat(directory, &info) == 0 && S_ISDIR(info.st_mode));
    char path[PATH_MAX], copied[PATH_MAX], alias[PATH_MAX];
    snprintf(path, sizeof(path), "%s/input", directory);
    snprintf(copied, sizeof(copied), "%s/copy", directory);
    snprintf(alias, sizeof(alias), "%s/alias", directory);
    make_file(path);
    DIR *stream = opendir(directory);
    assert(stream);
    int found = 0;
    struct dirent *entry;
    while ((entry = readdir(stream)))
        found |= strcmp(entry->d_name, "input") == 0;
    assert(found && closedir(stream) == 0);
    char nativeDirectory[PATH_MAX];
    assert(realpath(directory, nativeDirectory));
    char *roots[] = {nativeDirectory, NULL};
    check_traversal(fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR, NULL), nativeDirectory);
    check_traversal(fts_open_b(roots, FTS_PHYSICAL | FTS_NOCHDIR,
        ^int(const FTSENT **left, const FTSENT **right) {
            return strcmp((*left)->fts_name, (*right)->fts_name);
        }), nativeDirectory);
    assert(copyfile(path, copied, NULL, COPYFILE_DATA) == 0);
    check_content(copied);
    assert(link(copied, alias) == 0);
    assert(remove(copied) == 0);
    assert(renamex_np(alias, copied, RENAME_EXCL) == 0);
    assert(symlink("copy", alias) == 0);
    assert(lstat(alias, &info) == 0 && S_ISLNK(info.st_mode));
    char target[PATH_MAX] = {0};
    assert(readlink(alias, target, sizeof(target) - 1) == 4);
    assert(strcmp(target, "copy") == 0);
    check_content(alias);
    assert(unlink(alias) == 0 && symlink(copied, alias) == 0);
    check_content(alias);
    char physical[PATH_MAX];
    assert(realpath(copied, physical) == physical);
    assert(strncmp(physical, getenv("VZ_TEST_ROOT"),
                   strlen(getenv("VZ_TEST_ROOT"))) == 0);
    raw_exists(physical, 1);
    assert(removefile(directory, NULL, REMOVEFILE_RECURSIVE) == 0);
    raw_exists(physical, 0);
}

static void check_restore_temporary_root(void)
{
    char directory[PATH_MAX], expected[PATH_MAX];
    snprintf(expected, sizeof(expected),
        "%s/var/mobile/Library/VirtualMac/Root/", getenv("VZ_TEST_ROOT"));
    size_t required = confstr(_CS_DARWIN_USER_TEMP_DIR, NULL, 0);
    assert(required == strlen(expected) + 1);
    assert(confstr(_CS_DARWIN_USER_TEMP_DIR, directory, sizeof(directory)) == required);
    assert(strcmp(directory, expected) == 0);
    char small[5];
    assert(confstr(_CS_DARWIN_USER_TEMP_DIR, small, sizeof(small)) == required);
    assert(strncmp(small, expected, sizeof(small) - 1) == 0 && small[4] == '\0');
    strlcat(directory, "bootability-bundle-XXXXXX", sizeof(directory));
    assert(mkdtemp(directory));
    raw_exists(directory, 1);
    assert(rmdir(directory) == 0);
}

static void check_private_pairing(void)
{
    char path[PATH_MAX], physical[PATH_MAX];
    snprintf(path, sizeof(path), "/var/db/lockdown/virtualmac-test-%d.plist", getpid());
    snprintf(physical, sizeof(physical),
        "%s/var/mobile/Library/VirtualMac/Root/Pairing/virtualmac-test-%d.plist",
        getenv("VZ_TEST_ROOT"), getpid());
    assert(lchmod("/var/db/lockdown/", 0701) == 0);
    make_file(path);
    raw_exists(path, 0);
    raw_exists(physical, 1);
    assert(unlink(path) == 0);
    assert(lchmod("/var/db/lockdown/", 0700) == 0);
}

static void check_atomic_network_file(void)
{
    char final[PATH_MAX], staging[PATH_MAX], physical[PATH_MAX];
    snprintf(final, sizeof(final), "/private/Library/Preferences/SystemConfiguration/com.apple.vmnet.plist.probe.%d", getpid());
    assert(snprintf(staging, sizeof(staging), "%s-", final) < (int)sizeof(staging));
    snprintf(physical, sizeof(physical), "%s/var/mobile/Library/VirtualMac/Network/com.apple.vmnet.plist.probe.%d", getenv("VZ_TEST_ROOT"), getpid());
    make_file(staging);
    assert(rename(staging, final) == 0);
    raw_exists(final, 0);
    raw_exists(physical, 1);
    check_content(final);
    assert(unlink(final) == 0);
    raw_exists(physical, 0);
}

static void check_spawn_file_actions(void)
{
    char path[] = "/tmp/unified_cache.XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0 && close(fd) == 0);
    posix_spawn_file_actions_t actions;
    assert(posix_spawn_file_actions_init(&actions) == 0);
    assert(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO,
        path, O_WRONLY | O_TRUNC, 0600) == 0);
    pid_t child;
    char *arguments[] = {"sh", "-c", "printf private", NULL};
    assert(posix_spawn(&child, "/bin/sh", &actions, NULL,
        arguments, environ) == 0);
    assert(posix_spawn_file_actions_destroy(&actions) == 0);
    int status;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) &&
        WEXITSTATUS(status) == 0);
    check_content(path);
    raw_exists(path, 0);
    assert(unlink(path) == 0);
}

static void check_private_socket(void)
{
    const char *canonical = "/tmp/vzusbmuxd";
    char physical[PATH_MAX];
    snprintf(physical, sizeof(physical), "%s/var/run/vm/vzusbmuxd",
             getenv("VZ_TEST_ROOT"));
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    strlcpy(address.sun_path, canonical, sizeof(address.sun_path));
    address.sun_len = sizeof(address);
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(server >= 0);
    int result = bind(server, (struct sockaddr *)&address, sizeof(address));
    if (result != 0) perror("private restore socket bind");
    assert(result == 0 && listen(server, 1) == 0);
    raw_exists(physical, 1);
    assert(symlink("vzusbmuxd", "/var/run/usbmuxd") == 0);
    strlcpy(address.sun_path, "/var/run/usbmuxd", sizeof(address.sun_path));
    int client = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(client >= 0 && connect(client, (struct sockaddr *)&address,
        sizeof(address)) == 0);
    assert(close(client) == 0 && close(server) == 0);
    assert(unlink("/var/run/usbmuxd") == 0 && unlink(canonical) == 0);
    raw_exists(physical, 0);
}

int main(int argc, char **argv)
{
    assert(argc == 1 || (argc == 2 && strcmp(argv[1], "--files-only") == 0));
    assert(getenv("VZ_TEST_ROOT"));
    check_directory_access();
    check_restore_temporary_root();
    check_private_pairing();
    check_atomic_network_file();
    check_spawn_file_actions();
    if (argc == 1)
        check_private_socket();
    char untouched[PATH_MAX];
    snprintf(untouched, sizeof(untouched), "%s/outside-mapped-paths",
             getenv("VZ_TEST_ROOT"));
    make_file(untouched);
    raw_exists(untouched, 1);
    check_content(untouched);
    assert(unlink(untouched) == 0);
    puts("RootHide interposition: private directory I/O, atomic writes and spawn passed");
    puts(argc == 1 ? "Private socket routing passed" : "Socket test explicitly skipped (--files-only)");
    return 0;
}
