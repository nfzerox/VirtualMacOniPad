#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Throwaway boundary experiment; supports only operation 52 and Exec3 payloads.
// Full usage/swizzle must be restored synchronously before the Metal creation.
typedef struct {
    uint32_t usage;
    uint8_t writeSwizzle;
    uint8_t swizzle[4];
    unsigned restoreCalls;
} ThinTextureExtras;

bool ThinTexture52To1(const void *input,size_t length,uint8_t output[44],
                     ThinTextureExtras *extras,const char **error);
bool ThinExec3To2(const void *input,size_t length,void *output,size_t capacity,
                 size_t *written,const char **error);

// Exact237 opcode68 fields. Decode metadata only, never dereference either
// table or imply that a nonempty placement table is implemented.
typedef struct {
    uint32_t task,objectBytes,placementBytes;
    uint64_t objectOffset,placementOffset;
} ThinObjectLists68;
bool ThinDecodeObjectLists68(const void *input,size_t length,ThinObjectLists68 *result);
// Pinned local-task policy only. Old wire51 uses a14-bit page offset;
// reject byte offsets it cannot represent, and validate BOTH table ranges.
bool ThinLocalObjectLists68To51(const void *input,size_t length,uint64_t taskBytes,
                              uint8_t output[12],const char **error);
