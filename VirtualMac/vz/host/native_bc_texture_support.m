#include "VZPaths.h"
#import "native_bc_texture_support.h"

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <ptrauth.h>

typedef const void *(*ChooseTextureFormatFn)(uint32_t);
typedef void (*MSHookFunctionFn)(void *, void *, void **);

static ChooseTextureFormatFn gChooseTextureFormatTrampoline;
static const void *gFormatDescriptors[1024];
static const void *gInvalidFormatDescriptor;
static uint32_t gFormatDescriptorCount;
static BOOL gNativeBCInstalled;

// These fourteen 0x60-byte AGX TextureFormat records are the exact new table
// entries added in iOS/iPadOS 16.4 for MTLPixelFormat 130...135, 140...143,
// and 150...153. The surrounding A16 G15 and M2 G14G table layouts and GPU
// command paths are already present in 16.3.1 (20D67).
// See vz/development/research/BC_TEXTURE_SUPPORT.md for the reproducible
// binary-diff addresses and validation probe.
static const uint32_t kBCFormatDescriptors[14][24]
    __attribute__((aligned(16))) = {
    {0x74,0,0,0,0,0,1,4,0,0,0x74,0,0x800,0,2,3,
     0x2c680,0x2c680,0,0,0,0,8,0},
    {0x74,0,0,0,0,0,1,4,0,0,0x74,0,0x800,0,2,3,
     0x2c680,0x2c680,0,0,0,3,8,0},
    {0x75,0,0,0,0,0,1,4,0,0,0x75,0,0x1000,0,2,3,
     0x2c680,0x2c680,0,0,0,0,0x10,0},
    {0x75,0,0,0,0,0,1,4,0,0,0x75,0,0x1000,0,2,3,
     0x2c680,0x2c680,0,0,0,3,0x10,0},
    {0x76,0,0,0,0,0,1,4,0,0,0x76,0,0x1000,0,2,3,
     0x2c680,0x2c680,0,0,0,0,0x10,0},
    {0x76,0,0,0,0,0,1,4,0,0,0x76,0,0x1000,0,2,3,
     0x2c680,0x2c680,0,0,0,3,0x10,0},
    {0x77,0,0,0,0,0,1,1,0,0,0x77,0,0x800,0,2,3,
     0x8080,0x12480,0,0,0,0,8,0},
    {0x77,0,1,0,1,0,1,1,0,0,0x77,0,0x800,1,2,3,
     0x8080,0x12480,0,0,0,0,8,0},
    {0x78,0,0,0,0,0,1,2,0,0,0x78,0,0x1000,0,2,3,
     0x8680,0x12680,0,0,0,0,0x10,0},
    {0x78,0,1,0,1,0,1,2,0,0,0x78,0,0x1000,1,2,3,
     0x8680,0x12680,0,0,0,0,0x10,0},
    {0x79,0,4,0,4,0,1,3,0,0,0x79,0,0x1000,4,2,3,
     0xc680,0x14680,0,0,0,0,0x10,0},
    {0x7a,0,4,0,4,0,1,3,0,0,0x7a,0,0x1000,4,2,3,
     0xc680,0x14680,0,0,0,0,0x10,0},
    {0x7b,0,0,0,0,0,1,4,0,0,0x7b,0,0x1000,0,2,3,
     0x2c680,0x2c680,0,0,0,0,0x10,0},
    {0x7b,0,0,0,0,0,1,4,0,0,0x7b,0,0x1000,0,2,3,
     0x2c680,0x2c680,0,0,0,3,0x10,0},
};

_Static_assert(sizeof(kBCFormatDescriptors[0]) == 0x60,
               "AGX texture-format records must remain 0x60 bytes");

static const uint16_t kBCFormats[] = {
    130, 131, 132, 133, 134, 135, 140,
    141, 142, 143, 150, 151, 152, 153,
};

BOOL VZIsBCPixelFormat(MTLPixelFormat format) {
    switch ((NSUInteger)format) {
        case 130: case 131: case 132: case 133: case 134: case 135:
        case 140: case 141: case 142: case 143:
        case 150: case 151: case 152: case 153:
            return YES;
        default:
            return NO;
    }
}

MTLPixelFormat VZBCValidationSurrogate(MTLPixelFormat format) {
    switch ((NSUInteger)format) {
        case 130: return (MTLPixelFormat)180; // ETC2 RGB8
        case 131: return (MTLPixelFormat)181; // ETC2 RGB8 sRGB
        case 140: return (MTLPixelFormat)170; // EAC R11 unorm
        case 141: return (MTLPixelFormat)172; // EAC R11 snorm
        case 142: return (MTLPixelFormat)174; // EAC RG11 unorm
        case 143: return (MTLPixelFormat)176; // EAC RG11 snorm
        case 133: case 135: case 153:
            return (MTLPixelFormat)186;       // ASTC 4x4 sRGB
        case 150: case 151:
            return (MTLPixelFormat)222;       // ASTC 4x4 HDR
        default:
            return (MTLPixelFormat)204;       // ASTC 4x4 LDR
    }
}

static const void *ChooseTextureFormat(uint32_t format) {
    return format < gFormatDescriptorCount
        ? gFormatDescriptors[format] : gInvalidFormatDescriptor;
}

typedef struct {
    const struct mach_header_64 *header;
    const uint32_t *text;
    size_t textInstructionCount;
    intptr_t slide;
    const char *name;
} AGXImage;

static BOOL RuntimeAddressIsInImage(const AGXImage *image,
                                    const void *address, size_t length) {
    uintptr_t start = (uintptr_t)address;
    if (start + length < start) return NO;
    const uint8_t *loadCommand = (const uint8_t *)(image->header + 1);
    for (uint32_t index = 0; index < image->header->ncmds; ++index) {
        const struct load_command *command =
            (const struct load_command *)loadCommand;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            if (strcmp(segment->segname, SEG_LINKEDIT) != 0) {
                uintptr_t segmentStart = segment->vmaddr + image->slide;
                uintptr_t segmentEnd = segmentStart + segment->vmsize;
                if (start >= segmentStart && start + length <= segmentEnd)
                    return YES;
            }
        }
        if (command->cmdsize < sizeof(*command)) return NO;
        loadCommand += command->cmdsize;
    }
    return NO;
}

static BOOL ReadAGXImage(uint32_t imageIndex, AGXImage *result) {
    const char *name = _dyld_get_image_name(imageIndex);
    // Apple uses generation-specific names such as AGXMetal13_3,
    // AGXMetalG14G, and AGXMetalG15. Match the extension location, not a GPU,
    // product model, or OS-generation substring.
    if (!name || !strstr(name, "/System/Library/Extensions/AGXMetal"))
        return NO;
    const struct mach_header *rawHeader = _dyld_get_image_header(imageIndex);
    if (!rawHeader || rawHeader->magic != MH_MAGIC_64) return NO;
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)rawHeader;
    intptr_t slide = _dyld_get_image_vmaddr_slide(imageIndex);
    const uint8_t *loadCommand = (const uint8_t *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; ++index) {
        const struct load_command *command =
            (const struct load_command *)loadCommand;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            const struct section_64 *section =
                (const struct section_64 *)(segment + 1);
            for (uint32_t sectionIndex = 0;
                 sectionIndex < segment->nsects; ++sectionIndex) {
                if (!strcmp(section[sectionIndex].segname, SEG_TEXT) &&
                    !strcmp(section[sectionIndex].sectname, SECT_TEXT) &&
                    !(section[sectionIndex].size & 3)) {
                    result->header = header;
                    result->text = (const uint32_t *)(
                        section[sectionIndex].addr + slide);
                    result->textInstructionCount =
                        section[sectionIndex].size / sizeof(uint32_t);
                    result->slide = slide;
                    result->name = name;
                    return YES;
                }
            }
        }
        if (command->cmdsize < sizeof(*command)) return NO;
        loadCommand += command->cmdsize;
    }
    return NO;
}

static BOOL IsADRP(uint32_t instruction, uint32_t destinationRegister) {
    return (instruction & 0x9f00001fU) ==
        (0x90000000U | destinationRegister);
}

static BOOL IsADDImmediate(uint32_t instruction, uint32_t destinationRegister,
                           uint32_t sourceRegister) {
    const uint32_t registerBits = destinationRegister | (sourceRegister << 5);
    return (instruction & 0xffc003ffU) == (0x91000000U | registerBits);
}

// AGX implements its private pixel-format chooser as a bounded switch over
// `format - 1`. Find that semantic dispatcher rather than using a VM address,
// image UUID, OS version, or device-generation name. The immediates containing
// table addresses are deliberately ignored. Requiring the complete dispatcher
// makes this substantially narrower than a three-instruction fingerprint.
static BOOL MatchTextureFormatChooser(const uint32_t *code,
                                      uint32_t *formatCount) {
    // iPadOS 14 receives MTLPixelFormat as x0; later compilers narrow it to
    // w0. Both implement the same unsigned enum switch and callable ABI.
    BOOL wideInput = code[0] == 0xd1000410U;
    if (!wideInput && code[0] != 0x51000410U) return NO;
    if ((code[1] & 0xffc003ffU) !=
        (wideInput ? 0xf100021fU : 0x7100021fU)) return NO;
    if ((code[2] & 0xff00001fU) != 0x54000008U) return NO; // b.hi
    if (!IsADRP(code[3], 0) || !IsADDImmediate(code[4], 0, 0)) return NO;
    if ((code[5] & 0xffc003ffU) != 0xf100021fU) return NO;
    if (code[6] != 0x9a9f9210U || !IsADRP(code[7], 17) ||
        !IsADDImmediate(code[8], 17, 17) || code[9] != 0xb8b07a30U ||
        code[10] != 0x10000011U || code[11] != 0x8b100230U ||
        code[12] != 0xd61f0200U) return NO;
    uint32_t firstLimit = (code[1] >> 10) & 0xfffU;
    uint32_t secondLimit = (code[5] >> 10) & 0xfffU;
    if (!firstLimit || firstLimit != secondLimit) return NO;
    uint32_t count = firstLimit + 2; // valid enum values are 0...limit+1
    if (count > sizeof(gFormatDescriptors) /
                    sizeof(gFormatDescriptors[0])) return NO;
    *formatCount = count;
    return YES;
}

static BOOL FindTextureFormatChooser(AGXImage *foundImage,
                                     void **foundAddress,
                                     uint32_t *foundFormatCount) {
    NSUInteger matches = 0;
    for (uint32_t imageIndex = 0; imageIndex < _dyld_image_count();
         ++imageIndex) {
        AGXImage image = {};
        if (!ReadAGXImage(imageIndex, &image)) continue;
        for (size_t instructionIndex = 0;
             instructionIndex + 17 < image.textInstructionCount;
             ++instructionIndex) {
            uint32_t formatCount = 0;
            const uint32_t *candidate = image.text + instructionIndex;
            if (!MatchTextureFormatChooser(candidate, &formatCount)) continue;
            // The out-of-range branch must land on an adrp/add/ret record
            // return, as it does independently in the old and new drivers.
            int32_t branchWords =
                ((int32_t)(candidate[2] << 8) >> 13);
            const uint32_t *target = candidate + 2 + branchWords;
            if (target < image.text ||
                target + 3 > image.text + image.textInstructionCount ||
                !IsADRP(target[0], 0) ||
                !IsADDImmediate(target[1], 0, 0) ||
                target[2] != 0xd65f03c0U) continue;
            ++matches;
            *foundImage = image;
            *foundAddress = (void *)candidate;
            *foundFormatCount = formatCount;
        }
    }
    return matches == 1;
}

static uint64_t DescriptorABIHash(const void *record) {
    const uint8_t *bytes = record;
    uint64_t hash = 14695981039346656037ULL;
    for (NSUInteger index = 0; index < 0x60; ++index) {
        hash ^= bytes[index];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static BOOL ValidateTextureFormatABI(const AGXImage *image,
                                     ChooseTextureFormatFn chooser,
                                     uint32_t formatCount,
                                     const void **invalidResult,
                                     BOOL *alreadyNative) {
    if (formatCount <= 204) return NO;
    const void *invalid = chooser(UINT32_MAX);
    if (!invalid || chooser(0) != invalid ||
        chooser(formatCount) != invalid ||
        !RuntimeAddressIsInImage(image, invalid, 0x60)) return NO;

    // Prove that the dispatcher returns records owned by this AGX image and
    // that the image uses the 0x60-byte record ABI copied below. This avoids
    // applying those records to a future driver that merely has a similar
    // switch implementation.
    const uint32_t probes[] = {1, 10, 30, 70, 80, 115, 170, 180, 204};
    const void *records[sizeof(probes) / sizeof(probes[0])] = {};
    NSUInteger adjacentPairs = 0;
    for (NSUInteger index = 0;
         index < sizeof(probes) / sizeof(probes[0]); ++index) {
        records[index] = chooser(probes[index]);
        if (!records[index] || records[index] == invalid ||
            !RuntimeAddressIsInImage(image, records[index], 0x60)) return NO;
        for (NSUInteger previous = 0; previous < index; ++previous) {
            uintptr_t a = (uintptr_t)records[index];
            uintptr_t b = (uintptr_t)records[previous];
            uintptr_t distance = a > b ? a - b : b - a;
            if (distance == 0x60) ++adjacentPairs;
        }
    }
    if (adjacentPairs < 2) return NO;

    // These are format records, not an image/build fingerprint. EAC R11,
    // ETC2 RGB8, and ASTC 4x4 have byte-identical records in the first and
    // last qualified iOS/iPadOS 14/15/16 M1, M2, and A16 firmwares. They prove
    // the field encoding consumed by the static BC records.
    if (DescriptorABIHash(chooser(170)) != 0x96c7f2141f60b4c2ULL ||
        DescriptorABIHash(chooser(180)) != 0xe095d5cb46537e57ULL ||
        DescriptorABIHash(chooser(204)) != 0xd0cb277563853582ULL)
        return NO;

    NSUInteger nativeCount = 0;
    NSUInteger invalidCount = 0;
    for (NSUInteger index = 0;
         index < sizeof(kBCFormats) / sizeof(kBCFormats[0]); ++index) {
        const void *record = chooser(kBCFormats[index]);
        if (record == invalid) {
            ++invalidCount;
        } else if (record && RuntimeAddressIsInImage(image, record, 0x60)) {
            ++nativeCount;
        } else {
            return NO;
        }
    }
    if (nativeCount && invalidCount) return NO;
    *invalidResult = invalid;
    *alreadyNative = nativeCount ==
        sizeof(kBCFormats) / sizeof(kBCFormats[0]);
    return nativeCount || invalidCount;
}

static MSHookFunctionFn LoadHookFunction(void) {
    MSHookFunctionFn hook = dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (hook) return hook;
#if defined(VZ_ROOTHIDE)
    const char *paths[] = {
        jbroot("/usr/lib/libellekit.dylib"),
        jbroot("/usr/lib/libhooker.dylib"),
    };
#else
    static const char *paths[] = {
        "/var/jb/usr/lib/libellekit.dylib",
        "/var/jb/usr/lib/libhooker.dylib",
        "/usr/lib/libhooker.dylib",
    };
#endif
    for (NSUInteger index = 0; index < sizeof(paths) / sizeof(paths[0]); ++index) {
        void *image = dlopen(paths[index], RTLD_NOW | RTLD_LOCAL);
        hook = image ? dlsym(image, "MSHookFunction") : NULL;
        if (hook) return hook;
    }
    return NULL;
}

BOOL VZInstallNativeBCTextureSupport(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AGXImage image = {};
        void *unhookedAddress = NULL;
        uint32_t formatCount = 0;
        if (!FindTextureFormatChooser(&image, &unhookedAddress,
                                      &formatCount)) return;
        ChooseTextureFormatFn unhooked =
            ptrauth_sign_unauthenticated(
                unhookedAddress, ptrauth_key_function_pointer, 0);
        BOOL alreadyNative = NO;
        if (!ValidateTextureFormatABI(&image, unhooked, formatCount,
                                      &gInvalidFormatDescriptor,
                                      &alreadyNative)) return;
        if (alreadyNative) {
            gNativeBCInstalled = YES;
            fprintf(stderr,
                    "[metalshim] AGX driver already provides native BC "
                    "texture formats\n");
            return;
        }
        MSHookFunctionFn hook = LoadHookFunction();
        if (!hook) return;

        gFormatDescriptorCount = formatCount;
        for (uint32_t format = 0; format < formatCount; ++format)
            gFormatDescriptors[format] = unhooked(format);
        for (NSUInteger index = 0;
             index < sizeof(kBCFormats) / sizeof(kBCFormats[0]); ++index) {
            gFormatDescriptors[kBCFormats[index]] = kBCFormatDescriptors[index];
        }
        hook(unhookedAddress, (void *)ChooseTextureFormat,
             (void **)&gChooseTextureFormatTrampoline);
        gNativeBCInstalled = gChooseTextureFormatTrampoline != NULL;
        if (gNativeBCInstalled) {
            fprintf(stderr,
                    "[metalshim] enabled native BC texture formats in %s "
                    "after runtime ABI validation\n", image.name);
        }
    });
    return gNativeBCInstalled;
}

BOOL VZNativeBCTextureSupportInstalled(void) {
    return gNativeBCInstalled;
}
