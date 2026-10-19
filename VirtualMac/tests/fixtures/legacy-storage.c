#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

uid_t test_geteuid(void) { return getenv("VZ_TEST_NONROOT") ? 501 : 0; }

const char *jbroot(const char *path)
{
    static char result[PATH_MAX];
    const char *root = getenv("VZ_TEST_ROOT");
    if (!root) abort();
    int count = snprintf(result, sizeof(result), "%s%s", root, path);
    if (count < 0 || (size_t)count >= sizeof(result)) abort();
    return result;
}
