#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

const char *jbroot(const char *path)
{
    static char paths[32][PATH_MAX];
    static unsigned next;
    char *result = paths[next++ % 32];
    const char *root = getenv("VZ_TEST_ROOT");
    if (!root || snprintf(result, PATH_MAX, "%s%s", root, path) >= PATH_MAX)
        abort();
    return result;
}
