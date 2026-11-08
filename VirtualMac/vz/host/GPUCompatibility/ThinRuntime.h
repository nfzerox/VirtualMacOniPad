#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __OBJC__
#import <Metal/Metal.h>
#endif
#ifdef __cplusplus
extern "C" {
#endif
enum { VMM_THIN_RUNTIME_ABI=1 };
typedef void (*VMMThinLogSink)(const char *message,void *context);
typedef struct {
    uint32_t abiVersion;
    uint32_t advertisedVersion; // Legacy ceiling43 or verified graphics compatibility237.
    bool enabled;              // Startup-only. No implicit constructor/install.
    const char *pvgPath;
    const char *serializerPath;
} VMMThinConfiguration;
// Set once before initialization/worker threads; caller owns context lifetime.
void VMMThinRuntimeSetLogSink(VMMThinLogSink sink,void *context);
bool VMMThinRuntimeInitialize(const VMMThinConfiguration *configuration,char *error,size_t capacity);
// Explicit startup-only opt-in for the owned backend; requires preview237.
// Install before any PGDevice creation/workers. No factory interposition.
bool VMMThinRuntimeInstallBackendHooks(char *error,size_t capacity);
// Optional exclusive first-error JSON file; configure once before Initialize.
bool VMMThinRuntimeConfigureFirstUnknownFile(const char *path,char *error,size_t capacity);
char *VMMThinRuntimeCopyFirstUnknownJSON(void);
char *VMMThinRuntimeCopyStatusJSON(void);
void VMMThinRuntimeFree(void *pointer);
#ifdef __OBJC__
id VMMThinRuntimeWrapDevice(id<MTLDevice> device);
// Compatibility237 only: call before exposing this exact PGDevice to any guest.
bool VMMThinRuntimeAttachDevice(id pvgDevice,char *error,size_t capacity);
char *VMMThinRuntimeCopyDeviceStatusJSON(id pvgDevice);
#endif
#ifdef __cplusplus
}
#endif
