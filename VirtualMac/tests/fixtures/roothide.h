#ifndef VZ_TEST_ROOTHIDE_H
#define VZ_TEST_ROOTHIDE_H

// Match the SDK's native/bootstrap path-conversion interface for host tests.
const char *jbroot(const char *path);
const char *rootfs(const char *path);
unsigned long long jbrand(void);

#endif
