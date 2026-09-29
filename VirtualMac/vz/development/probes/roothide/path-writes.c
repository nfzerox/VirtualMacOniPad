#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include "../../../host/VZPaths.h"

static int exists(const char *path)
{
    struct stat info;
    return stat(path, &info) == 0;
}

int main(void)
{
    char file[] = "/tmp/unified_cache.XXXXXX";
    int fd = mkstemp(file);
    assert(fd >= 0);
    assert(write(fd, "probe", 5) == 5);
    close(fd);
    assert(exists(file));
    char physical[1024];
    snprintf(physical, sizeof(physical), "%s%s", VZRestorePath(""), file + 5);
    assert(exists(physical));
    fd = open(file, O_RDONLY);
    char content[6] = {0};
    assert(fd >= 0 && read(fd, content, 5) == 5);
    close(fd);
    assert(strcmp(content, "probe") == 0);
    assert(unlink(file) == 0 && !exists(physical));

    char directory[] = "/tmp/unified_cache.XXXXXX";
    assert(mkdtemp(directory));
    snprintf(physical, sizeof(physical), "%s%s", VZRestorePath(""), directory + 5);
    assert(exists(physical));
    assert(rmdir(directory) == 0 && !exists(physical));

    char staging[128], final[128];
    snprintf(final, sizeof(final), "/tmp/bootpd.plist.probe.%d", getpid());
    snprintf(staging, sizeof(staging), "%s-", final);
    fd = open(staging, O_WRONLY | O_CREAT | O_EXCL, 0600);
    assert(fd >= 0);
    close(fd);
    snprintf(physical, sizeof(physical), "%s%s", VZNetworkPath(""), staging + 5);
    assert(exists(physical));
    assert(rename(staging, final) == 0);
    assert(unlink(final) == 0);
    snprintf(final, sizeof(final), "/Library/Preferences/SystemConfiguration/com.apple.vmnet.plist.probe.%d", getpid());
    snprintf(staging, sizeof(staging), "%s-", final);
    fd = open(staging, O_WRONLY | O_CREAT | O_EXCL, 0600);
    assert(fd >= 0);
    close(fd);
    snprintf(physical, sizeof(physical), "%scom.apple.vmnet.plist.probe.%d-", VZNetworkPath(""), getpid());
    assert(exists(physical));
    assert(rename(staging, final) == 0);
    assert(unlink(final) == 0);
    assert(strlen(VZSocketPath("vz-usb-restore.sock")) < sizeof(((struct sockaddr_un *)0)->sun_path));
    puts("PASS private mkstemp/mkdtemp/open/rename/unlink/socket-length");
    return 0;
}
