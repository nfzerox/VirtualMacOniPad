#if !defined(VZ_ROOTHIDE)
#error "This utility is only for RootHide packages"
#endif
#include "../host/VZPaths.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int directory_state(const char *path)
{
    struct stat info;
    if (lstat(path, &info) != 0) {
        if (errno == ENOENT) return 0;
        perror(path);
        return -1;
    }
    if (!S_ISDIR(info.st_mode)) {
        fprintf(stderr, "Refusing non-directory or symlink: %s\n", path);
        return -1;
    }
    return 1;
}

static int require_idle_runtime(void)
{
    int descriptors[2];
    if (pipe(descriptors) != 0) { perror("pipe"); return -1; }
    posix_spawn_file_actions_t actions;
    int result = posix_spawn_file_actions_init(&actions);
    if (result != 0) {
        close(descriptors[0]); close(descriptors[1]);
        return -1;
    }
    result = posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO);
    if (!result) result = posix_spawn_file_actions_addclose(&actions, descriptors[0]);
    if (!result) result = posix_spawn_file_actions_addclose(&actions, descriptors[1]);
    const char *helper = VZRuntimePath("install/runtime-processes");
    char *arguments[] = {(char *)helper, "--list-guests", NULL};
    pid_t child = 0;
    if (!result) result = posix_spawn(&child, helper, &actions, NULL, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(descriptors[1]);
    if (result) {
        close(descriptors[0]);
        fprintf(stderr, "Cannot verify stopped VMs: %s\n", strerror(result));
        return -1;
    }
    bool active = false;
    char buffer[256];
    ssize_t count;
    do {
        count = read(descriptors[0], buffer, sizeof(buffer));
        if (count > 0) active = true;
    } while (count > 0 || (count < 0 && errno == EINTR));
    close(descriptors[0]);
    int status = 0;
    pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    if (count < 0 || waited < 0 || !WIFEXITED(status) || WEXITSTATUS(status)) {
        fputs("Cannot verify stopped VMs; no data moved.\n", stderr);
        return -1;
    }
    if (active) {
        fputs("Stop all running Virtual Macs before consolidating or migrating.\n", stderr);
        return -1;
    }
    return 0;
}

// Move every *.bundle from the legacy library into the main library, appending
// " 2", " 3"... to the base name when the main library already has a bundle
// with that name. Each move is an exclusive same-volume rename, preserving
// sparse disks and metadata without copying. Non-bundle entries (such as the
// archived Settings.plist) are left in place.
static int merge_legacy_bundles(const char *legacy_dir, const char *library_dir)
{
    DIR *directory = opendir(legacy_dir);
    if (!directory) { perror(legacy_dir); return 1; }
    struct dirent *entry;
    int moved = 0, skipped = 0;
    while ((entry = readdir(directory)) != NULL) {
        const char *name = entry->d_name;
        if (name[0] == '.' && (name[1] == '\0' ||
                (name[1] == '.' && name[2] == '\0')))
            continue;
        const char *dot = strrchr(name, '.');
        if (!dot || strcmp(dot, ".bundle") != 0) {
            skipped++;
            continue;
        }
        size_t base_len = (size_t)(dot - name);
        char src[PATH_MAX];
        if (snprintf(src, sizeof(src), "%s/%s", legacy_dir, name) >= (int)sizeof(src)) {
            fprintf(stderr, "Skipping overlong entry: %s\n", name);
            closedir(directory);
            return 1;
        }
        for (unsigned suffix = 0; ; suffix++) {
            char dst_name[PATH_MAX];
            char base[NAME_MAX];
            if (base_len >= sizeof(base)) {
                fprintf(stderr, "Skipping overlong bundle name: %s\n", name);
                closedir(directory);
                return 1;
            }
            memcpy(base, name, base_len);
            base[base_len] = '\0';
            int written = suffix == 0
                ? snprintf(dst_name, sizeof(dst_name), "%s.bundle", base)
                : snprintf(dst_name, sizeof(dst_name), "%s %u.bundle", base, suffix + 1);
            if (written < 0 || (size_t)written >= sizeof(dst_name)) {
                fprintf(stderr, "Skipping overlong destination name: %s\n", name);
                closedir(directory);
                return 1;
            }
            char dst[PATH_MAX];
            if (snprintf(dst, sizeof(dst), "%s/%s", library_dir, dst_name) >= (int)sizeof(dst)) {
                fprintf(stderr, "Skipping overlong destination path: %s\n", name);
                closedir(directory);
                return 1;
            }
            if (renamex_np(src, dst, RENAME_EXCL) == 0) {
                printf("moved %s -> %s\n", name, dst_name);
                moved++;
                break;
            }
            if (errno != EEXIST) {
                perror(name);
                closedir(directory);
                return 1;
            }
            // Destination taken; try the next suffix.
        }
    }
    closedir(directory);
    printf("Merge complete. %d bundle%s moved, %d non-bundle entr%s left in place.\n",
           moved, moved == 1 ? "" : "s", skipped, skipped == 1 ? "y" : "ies");
    return 0;
}

int main(int argc, char **argv)
{
    bool migrate = argc == 2 && strcmp(argv[1], "--migrate") == 0;
    bool restore = argc == 2 && strcmp(argv[1], "--restore") == 0;
    bool merge = argc == 2 && strcmp(argv[1], "--merge") == 0;
    bool report = argc == 2 && strcmp(argv[1], "--status") == 0;
    if (!migrate && !restore && !merge && !report) {
        fputs("usage: legacy-storage --status|--migrate|--merge|--restore\n", stderr);
        return 2;
    }
    char host[PATH_MAX], private[PATH_MAX], library[PATH_MAX], lock[PATH_MAX];
    strlcpy(host, jbroot("/rootfs/var/mobile/Media/VirtualMac"), sizeof(host));
    strlcpy(private, VZStatePath("Legacy"), sizeof(private));
    strlcpy(library, VZLibraryRoot, sizeof(library));
    strlcpy(lock, VZRestorePath("legacy-storage.lock"), sizeof(lock));
    printf("Host library: %s\nPrivate legacy library: %s\nMain library: %s\n",
           host, private, library);
    if (report) {
        int host_state = directory_state(host), private_state = directory_state(private);
        if (host_state < 0 || private_state < 0) return 1;
        printf("host=%s private=%s\n", host_state ? "present" : "absent",
               private_state ? "present" : "absent");
        return 0;
    }
    if (geteuid() != 0) {
        fputs("Migration requires root; no data moved.\n", stderr);
        return 1;
    }
    if (merge) {
        if (directory_state(private) != 1) {
            fputs("Legacy library is absent; nothing to merge.\n", stderr);
            return 0;
        }
        if (directory_state(library) != 1) {
            fputs("Main library is missing; no data moved.\n", stderr);
            return 1;
        }
        int descriptor = open(lock, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (descriptor < 0) { perror("migration lock"); return 1; }
        if (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
            perror("another migration holds the lock");
            close(descriptor);
            return 1;
        }
        int outcome = 1;
        if (require_idle_runtime() != 0) goto merge_done;
        outcome = merge_legacy_bundles(private, library);
    merge_done:
        close(descriptor);
        return outcome;
    }
    int descriptor = open(lock, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0) { perror("migration lock"); return 1; }
    if (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        perror("another migration holds the lock");
        close(descriptor);
        return 1;
    }
    const char *source = migrate ? host : private;
    const char *destination = migrate ? private : host;
    int result = 1;
    if (directory_state(source) != 1 || directory_state(destination) != 0) {
        fputs("Source missing, target occupied, or unsafe path; no data moved.\n", stderr);
        goto done;
    }
    if (require_idle_runtime() != 0) goto done;
    // An exclusive rename preserves sparse files and metadata without merging
    // into or overwriting another library. Cross-volume moves fail.
    if (renamex_np(source, destination, RENAME_EXCL) != 0) {
        perror("atomic library move");
        goto done;
    }
    printf("%s complete. Contents preserved without copying or deleting files.\n",
           migrate ? "Migration" : "Restore");
    result = 0;
done:
    close(descriptor);
    return result;
}
