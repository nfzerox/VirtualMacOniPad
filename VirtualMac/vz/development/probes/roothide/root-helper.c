#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(void)
{
    printf("root-helper before uid=%u euid=%u gid=%u egid=%u\n",
           getuid(), geteuid(), getgid(), getegid());
    if (setgid(0) != 0 || setuid(0) != 0) {
        fprintf(stderr, "root-helper setuid failed: %s\n", strerror(errno));
        return 1;
    }
    printf("root-helper after uid=%u euid=%u gid=%u egid=%u\n",
           getuid(), geteuid(), getgid(), getegid());
    return getuid() != 0 || geteuid() != 0 || getgid() != 0 || getegid() != 0;
}
