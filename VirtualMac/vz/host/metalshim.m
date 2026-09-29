#include "VZPaths.h"
// Metal shim for the iOS-ported VZ VMM service. macOS Metal exports MTLCopyAllDevices
// (multi-GPU enumeration); iOS Metal does not (single GPU). The extracted VMM binds it,
// so dyld fails the load. We build a tiny arm64e dylib that re-exports the device's real
// Metal (so every other Metal symbol the VMM needs resolves through us) and defines the
// few macOS-only entry points the VMM imports, backed by the iOS single-device API.
// Wire-up: change the VMM binary's Metal LC_LOAD_DYLIB to /var/root/metalshim.ios.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

#import "native_bc_texture_support.h"

static id (*gNewBufferWithLength)(id, SEL, NSUInteger, MTLResourceOptions);
static id (*gNewBufferWithBytes)(
    id, SEL, const void *, NSUInteger, MTLResourceOptions);
static id (*gNewBufferWithBytesNoCopy)(
    id, SEL, void *, NSUInteger, MTLResourceOptions,
    void (^)(void *, NSUInteger));
static id (*gNewTextureWithDescriptor)(
    id, SEL, MTLTextureDescriptor *);
static id (*gNewTextureWithDescriptorIOSurface)(
    id, SEL, MTLTextureDescriptor *, void *, NSUInteger);
static void (*gSetTextureStorageMode)(id, SEL, MTLStorageMode);
static void (*gSetTexturePixelFormat)(id, SEL, MTLPixelFormat);
static void (*gSetHeapStorageMode)(id, SEL, MTLStorageMode);
static BOOL (*gValidateTextureDescriptor)(id, SEL, id);
static void (*gTextureReplaceRegionSlice)(
    id, SEL, MTLRegion, NSUInteger, NSUInteger, const void *, NSUInteger,
    NSUInteger);
static void (*gTextureReplaceRegion)(
    id, SEL, MTLRegion, NSUInteger, const void *, NSUInteger);
static id (*gHeapNewTextureWithDescriptor)(
    id, SEL, MTLTextureDescriptor *);
static id (*gNewTextureView)(id, SEL, MTLPixelFormat);
static id (*gNewTextureViewWithRanges)(
    id, SEL, MTLPixelFormat, MTLTextureType, NSRange, NSRange);
static id (*gNewTextureViewWithRangesAndSwizzle)(
    id, SEL, MTLPixelFormat, MTLTextureType, NSRange, NSRange,
    MTLTextureSwizzleChannels);
typedef void (*ValidateTextureViewFn)(
    id, id<MTLTexture>, MTLPixelFormat, MTLTextureType,
    NSUInteger, NSUInteger, NSUInteger, NSUInteger, BOOL);
static ValidateTextureViewFn gValidateTextureView;

// Metal returns this private, 56-byte value indirectly on arm64.  Keeping the
// exact aggregate shape is important: declaring the hook as a pointer-return
// function would put the hidden result pointer in the wrong register.
typedef struct {
    uint64_t words[7];
} VZPixelFormatInfo;
typedef VZPixelFormatInfo (*PixelFormatGetInfoForDeviceFn)(
    id<MTLDevice>, MTLPixelFormat);
static PixelFormatGetInfoForDeviceFn gPixelFormatGetInfoForDevice;

typedef void (*MSHookFunctionFn)(void *, void *, void **);
static MSHookFunctionFn LoadMetalHookFunction(void) {
    MSHookFunctionFn hook =
        (MSHookFunctionFn)dlsym(RTLD_DEFAULT, "MSHookFunction");
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
    for (NSUInteger index = 0;
         index < sizeof(paths) / sizeof(paths[0]); ++index) {
        void *image = dlopen(paths[index], RTLD_NOW | RTLD_LOCAL);
        hook = image ? (MSHookFunctionFn)dlsym(image, "MSHookFunction") : NULL;
        if (hook) return hook;
    }
    return NULL;
}
static BOOL gInstalledSharedBufferCompatibility;
static unsigned long gMacCompressedTextureCount;
static id<MTLDevice> gMetalDevice;
static id<MTLCommandQueue> gBCUploadQueue;

static BOOL DebugLoggingEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value = getenv("VZ_DEBUG_LOGGING");
        enabled = value && value[0] && strcmp(value, "0") != 0;
    });
    return enabled;
}

// macOS: NSArray<id<MTLDevice>> *MTLCopyAllDevices(void)  — +1 (the "Copy" rule).
// iOS has exactly one GPU, so return the system default in a one-element array.
NSArray *MTLCopyAllDevices(void) {
    id dev = MTLCreateSystemDefaultDevice();
    NSArray *a = dev ? @[dev] : @[];
    return [a retain];  // built without ARC; "Copy" rule => return +1
}

// macOS-only; iOS logs "Ignoring call MTLSetShaderCachePath(...)" — so a no-op matches iOS behavior.
void MTLSetShaderCachePath(const char *path) { (void)path; }

// The macOS 13 VMM selects a Metal device by querying this macOS MTLDevice
// property. iOS has one integrated GPU and its concrete AGX device class does
// not implement the selector. Report the iPad GPU as integrated/non-low-power
// so the unmodified VMM can complete device selection.
static BOOL iPadMetalDeviceIsLowPower(id self, SEL selector) {
    (void)self;
    (void)selector;
    return NO;
}

static BOOL iPadMetalDeviceIsRemovable(id self, SEL selector) {
    (void)self;
    (void)selector;
    return NO;
}

static BOOL iPadMetalDeviceIsHeadless(id self, SEL selector) {
    (void)self;
    (void)selector;
    return NO;
}

static BOOL iPadMetalDeviceIsDepth24Stencil8PixelFormatSupported(
    id self, SEL selector) {
    (void)self;
    (void)selector;
    // Apple-family GPUs use 32-bit depth formats. This macOS compatibility
    // query is absent from iOS's MTLDevice surface, and reporting NO makes
    // PVG advertise the formats the iPad GPU actually supports.
    return NO;
}

static BOOL iPadMetalDeviceIsFramebufferReadSupported(id self, SEL selector) {
    (void)self;
    (void)selector;
    // Apple GPUs support framebuffer fetch. macOS exposes this private
    // capability query, while the iOS MTLDevice protocol omits the selector.
    return YES;
}

static BOOL iPadMetalDeviceReturnsYes(id self, SEL selector) {
    (void)self;
    (void)selector;
    return YES;
}

static NSUInteger iPadMetalDeviceMaxTextureDimension(id self, SEL selector) {
    (void)self;
    (void)selector;
    return 16384;
}

static NSUInteger iPadMetalDeviceMaxTotalThreads(id self, SEL selector) {
    (void)self;
    (void)selector;
    return 1024;
}

static void iPadSamplerSetReductionMode(id self, SEL selector,
                                        NSUInteger reductionMode) {
    (void)self;
    (void)selector;
    (void)reductionMode;
    // Sampler reduction mode is a macOS-only descriptor property.
    // The default weighted-average mode is value zero.
}

static NSUInteger iPadSamplerReductionMode(id self, SEL selector) {
    (void)self;
    (void)selector;
    return 0;
}

static void AddMetalMethodIfMissing(id device, NSString *name,
                                    IMP implementation,
                                    const char *types) {
    SEL selector = NSSelectorFromString(name);
    if (![device respondsToSelector:selector]) {
        class_addMethod([device class], selector, implementation, types);
    }
}

static MTLResourceOptions iPadMetalResourceOptions(
    MTLResourceOptions options) {
    // MTLStorageModeManaged is macOS-only. Apple Silicon has unified memory,
    // and current Metal headers explicitly direct Apple Silicon clients to
    // Shared instead.
    const MTLResourceOptions managed = 1UL << MTLResourceStorageModeShift;
    if ((options & MTLResourceStorageModeMask) == managed) {
        options &= ~MTLResourceStorageModeMask;
        options |= MTLResourceStorageModeShared;
    }
    return options;
}

static MTLStorageMode iPadMetalStorageMode(MTLStorageMode storageMode) {
    // Raw value 1 is MTLStorageModeManaged on macOS.
    return storageMode == (MTLStorageMode)1
        ? MTLStorageModeShared
        : storageMode;
}

static void iPadSetTextureStorageMode(id self, SEL selector,
                                     MTLStorageMode storageMode) {
    gSetTextureStorageMode(
        self, selector, iPadMetalStorageMode(storageMode));
}

static void iPadSetTexturePixelFormat(id self, SEL selector,
                                     MTLPixelFormat pixelFormat) {
    if (!VZIsBCPixelFormat(pixelFormat)) {
        gSetTexturePixelFormat(self, selector, pixelFormat);
        return;
    }
    if (VZNativeBCTextureSupportInstalled()) {
        void *descriptorPrivate = ((void *(*)(id, SEL))objc_msgSend)(
            self, sel_registerName("descriptorPrivate"));
        if (descriptorPrivate == NULL) return;
        ((NSUInteger *)descriptorPrivate)[1] = (NSUInteger)pixelFormat;
        if (DebugLoggingEnabled())
            fprintf(stderr,
                    "[metalshim] passing native Mac BC format=%lu to AGX\n",
                    (unsigned long)pixelFormat);
        return;
    }
    // Hosts without the exact, validated native AGX table retain the shipped
    // crash-prevention mapping. No conversion code runs in either path.
    MTLPixelFormat fallback = VZBCValidationSurrogate(pixelFormat);
    if (DebugLoggingEnabled()) {
        unsigned long count = __sync_add_and_fetch(
            &gMacCompressedTextureCount, 1);
        if (count <= 20 || count % 100 == 0)
            fprintf(stderr, "[metalshim] mapped Mac BC format=%lu to iPad format=%lu count=%lu\n",
                    (unsigned long)pixelFormat, (unsigned long)fallback, count);
    }
    gSetTexturePixelFormat(self, selector, fallback);
}

static void iPadSetHeapStorageMode(id self, SEL selector,
                                  MTLStorageMode storageMode) {
    gSetHeapStorageMode(
        self, selector, iPadMetalStorageMode(storageMode));
}

static BOOL iPadValidateTextureDescriptor(id self, SEL selector, id device) {
    if (!VZNativeBCTextureSupportInstalled())
        return gValidateTextureDescriptor(self, selector, device);
    NSUInteger *descriptorPrivate = ((NSUInteger *(*)(id, SEL))objc_msgSend)(
        self, sel_registerName("descriptorPrivate"));
    MTLPixelFormat format = descriptorPrivate
        ? (MTLPixelFormat)descriptorPrivate[1] : MTLPixelFormatInvalid;
    if (!VZIsBCPixelFormat(format))
        return gValidateTextureDescriptor(self, selector, device);
    descriptorPrivate[1] = (NSUInteger)VZBCValidationSurrogate(format);
    BOOL valid = gValidateTextureDescriptor(self, selector, device);
    descriptorPrivate[1] = (NSUInteger)format;
    return valid;
}

static void NormalizeTextureDescriptor(MTLTextureDescriptor *descriptor) {
    if ((NSUInteger)descriptor.storageMode == 1) {
        descriptor.storageMode = MTLStorageModeShared;
    }
}

// iPadOS 16.3.1's Metal framework predates the public BC pixel-format enum
// entries. AGX accepts the 16.4 format records installed above, but the common
// IOGPU texture object otherwise records the format as Invalid. That metadata
// is consulted when an engine creates a texture view, causing Metal's view
// compatibility validation to abort even though the underlying AGX resource
// is valid. Restore the metadata that iPadOS 16.4 records natively.
static void SetNativeBCTextureMetadata(id texture, MTLPixelFormat format) {
    if (!texture || !VZNativeBCTextureSupportInstalled() ||
        !VZIsBCPixelFormat(format)) return;
    Ivar pixelFormat = class_getInstanceVariable([texture class], "_pixelFormat");
    Ivar compressed = class_getInstanceVariable([texture class], "_isCompressed");
    if (pixelFormat)
        *(MTLPixelFormat *)((uint8_t *)(void *)texture +
                           ivar_getOffset(pixelFormat)) = format;
    if (compressed)
        *(BOOL *)((uint8_t *)(void *)texture + ivar_getOffset(compressed)) = YES;
}

static void ValidateNativeBCTextureView(
    id device, id<MTLTexture> texture, MTLPixelFormat format,
    MTLTextureType type, NSUInteger levelStart, NSUInteger levelCount,
    NSUInteger sliceStart, NSUInteger sliceCount, BOOL compressedView) {
    MTLPixelFormat sourceFormat = texture.pixelFormat;
    if (!VZIsBCPixelFormat(sourceFormat) || !VZIsBCPixelFormat(format)) {
        gValidateTextureView(device, texture, format, type,
                             levelStart, levelCount, sliceStart, sliceCount,
                             compressedView);
        return;
    }
    Ivar pixelFormat = class_getInstanceVariable([texture class], "_pixelFormat");
    if (!pixelFormat) {
        gValidateTextureView(device, texture, format, type,
                             levelStart, levelCount, sliceStart, sliceCount,
                             compressedView);
        return;
    }
    MTLPixelFormat *stored = (MTLPixelFormat *)((uint8_t *)(void *)texture +
                                                ivar_getOffset(pixelFormat));
    @try {
        *stored = VZBCValidationSurrogate(sourceFormat);
        gValidateTextureView(device, texture,
                             VZBCValidationSurrogate(format), type,
                             levelStart, levelCount, sliceStart, sliceCount,
                             compressedView);
    } @finally {
        *stored = sourceFormat;
    }
}

// Ventura's MetalSerializer asks the host Metal framework for block geometry
// when it replays guest uploads.  iPadOS 16.3.1's generic Metal table, unlike
// its AGX command path, has no BC records, so the replay can allocate a valid
// native texture and then copy zero or incorrectly-strided data into it.  The
// selected iPad formats have identical 4x4 block geometry, byte size, signed
// or sRGB character to their BC counterpart.  Use their generic metadata only
// for frontend sizing/validation; the descriptor and AGX resource retain the
// original BC pixel-format number.
static VZPixelFormatInfo NativeBCPixelFormatInfoForDevice(
    id<MTLDevice> device, MTLPixelFormat format) {
    if (VZNativeBCTextureSupportInstalled() && VZIsBCPixelFormat(format))
        format = VZBCValidationSurrogate(format);
    return gPixelFormatGetInfoForDevice(device, format);
}

static id iPadNewTextureWithDescriptor(
    id self, SEL selector, MTLTextureDescriptor *descriptor) {
    NormalizeTextureDescriptor(descriptor);
    id texture = gNewTextureWithDescriptor(self, selector, descriptor);
    SetNativeBCTextureMetadata(texture, descriptor.pixelFormat);
    if (DebugLoggingEnabled() && VZIsBCPixelFormat(descriptor.pixelFormat))
        fprintf(stderr, "[metalshim] native BC texture format=%lu %lux%lu -> %p\n",
                (unsigned long)descriptor.pixelFormat,
                (unsigned long)descriptor.width,
                (unsigned long)descriptor.height, texture);
    return texture;
}

static id iPadNewTextureWithDescriptorIOSurface(
    id self, SEL selector, MTLTextureDescriptor *descriptor,
    void *surface, NSUInteger plane) {
    NormalizeTextureDescriptor(descriptor);
    id texture = gNewTextureWithDescriptorIOSurface(
        self, selector, descriptor, surface, plane);
    SetNativeBCTextureMetadata(texture, descriptor.pixelFormat);
    return texture;
}

static id iPadHeapNewTextureWithDescriptor(
    id self, SEL selector, MTLTextureDescriptor *descriptor) {
    NormalizeTextureDescriptor(descriptor);
    id texture = gHeapNewTextureWithDescriptor(self, selector, descriptor);
    SetNativeBCTextureMetadata(texture, descriptor.pixelFormat);
    return texture;
}

static id iPadNewTextureView(id self, SEL selector,
                             MTLPixelFormat format) {
    id texture = gNewTextureView(self, selector, format);
    SetNativeBCTextureMetadata(texture, format);
    return texture;
}

static id iPadNewTextureViewWithRanges(
    id self, SEL selector, MTLPixelFormat format, MTLTextureType type,
    NSRange levels, NSRange slices) {
    id texture = gNewTextureViewWithRanges(
        self, selector, format, type, levels, slices);
    SetNativeBCTextureMetadata(texture, format);
    return texture;
}

static id iPadNewTextureViewWithRangesAndSwizzle(
    id self, SEL selector, MTLPixelFormat format, MTLTextureType type,
    NSRange levels, NSRange slices, MTLTextureSwizzleChannels swizzle) {
    id texture = gNewTextureViewWithRangesAndSwizzle(
        self, selector, format, type, levels, slices, swizzle);
    SetNativeBCTextureMetadata(texture, format);
    return texture;
}

static BOOL UploadNativeBCTexture(id<MTLTexture> texture, MTLRegion region,
                                  NSUInteger level, NSUInteger slice,
                                  const void *bytes, NSUInteger bytesPerRow,
                                  NSUInteger bytesPerImage) {
    if (!VZNativeBCTextureSupportInstalled() ||
        !VZIsBCPixelFormat(texture.pixelFormat) || !gBCUploadQueue) return NO;
    NSUInteger blockRows = MAX((region.size.height + 3) / 4, (NSUInteger)1);
    NSUInteger imageBytes = bytesPerImage ?: bytesPerRow * blockRows;
    NSUInteger totalBytes = imageBytes * MAX(region.size.depth, (NSUInteger)1);
    id<MTLBuffer> upload = [gMetalDevice newBufferWithBytes:bytes
                                                     length:totalBytes options:0];
    id<MTLCommandBuffer> command = [gBCUploadQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    [blit copyFromBuffer:upload sourceOffset:0 sourceBytesPerRow:bytesPerRow
     sourceBytesPerImage:imageBytes sourceSize:region.size toTexture:texture
        destinationSlice:slice destinationLevel:level
       destinationOrigin:region.origin];
    [blit endEncoding];
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) {
        fprintf(stderr, "[metalshim] native BC upload failed: %s\n",
                command.error.description.UTF8String ?: "unknown error");
    }
    [upload release];
    return YES;
}

static void iPadTextureReplaceRegionSlice(
    id self, SEL selector, MTLRegion region, NSUInteger level,
    NSUInteger slice, const void *bytes, NSUInteger bytesPerRow,
    NSUInteger bytesPerImage) {
    if (!UploadNativeBCTexture(self, region, level, slice, bytes, bytesPerRow,
                               bytesPerImage)) {
        gTextureReplaceRegionSlice(self, selector, region, level, slice, bytes,
                                   bytesPerRow, bytesPerImage);
    }
}

static void iPadTextureReplaceRegion(
    id self, SEL selector, MTLRegion region, NSUInteger level,
    const void *bytes, NSUInteger bytesPerRow) {
    if (!UploadNativeBCTexture(self, region, level, 0, bytes, bytesPerRow, 0)) {
        gTextureReplaceRegion(self, selector, region, level, bytes, bytesPerRow);
    }
}

static void iPadSharedBufferDidModifyRange(id self, SEL selector,
                                           NSRange range) {
    (void)self;
    (void)selector;
    (void)range;
    // Shared memory is coherent on Apple Silicon; this macOS managed-memory
    // flush has no work to perform on iOS.
}

static id InstallSharedBufferCompatibility(id buffer) {
    if (buffer != nil &&
        __sync_bool_compare_and_swap(
            &gInstalledSharedBufferCompatibility, NO, YES)) {
        Method method = class_getInstanceMethod(
            [buffer class], NSSelectorFromString(@"didModifyRange:"));
        if (method != NULL) {
            method_setImplementation(
                method, (IMP)iPadSharedBufferDidModifyRange);
        }
    }
    return buffer;
}

static id iPadNewBufferWithLength(id self, SEL selector, NSUInteger length,
                                  MTLResourceOptions options) {
    return InstallSharedBufferCompatibility(gNewBufferWithLength(
        self, selector, length, iPadMetalResourceOptions(options)));
}

static id iPadNewBufferWithBytes(id self, SEL selector, const void *bytes,
                                 NSUInteger length,
                                 MTLResourceOptions options) {
    return InstallSharedBufferCompatibility(gNewBufferWithBytes(
        self, selector, bytes, length, iPadMetalResourceOptions(options)));
}

static id iPadNewBufferWithBytesNoCopy(
    id self, SEL selector, void *bytes, NSUInteger length,
    MTLResourceOptions options, void (^deallocator)(void *, NSUInteger)) {
    return InstallSharedBufferCompatibility(gNewBufferWithBytesNoCopy(
        self, selector, bytes, length, iPadMetalResourceOptions(options),
        deallocator));
}

static IMP ReplaceMetalMethod(Class cls, NSString *name, IMP replacement) {
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        return NULL;
    }
    return method_setImplementation(method, replacement);
}

__attribute__((constructor))
static void InstallMacMetalDeviceCompatibility(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            return;
        }
        const char *bcSupport = getenv("VZ_METAL_BC_SUPPORT");
        BOOL nativeBC = (!bcSupport || strcmp(bcSupport, "0")) &&
            VZInstallNativeBCTextureSupport();
        if (nativeBC) {
            gMetalDevice = [device retain];
            gBCUploadQueue = [device newCommandQueue];
            MSHookFunctionFn hook = LoadMetalHookFunction();
            void *validator = dlsym(
                RTLD_DEFAULT,
                "_mtlValidateArgumentsForTextureViewOnDevice");
            if (hook && validator) {
                hook(validator, (void *)ValidateNativeBCTextureView,
                     (void **)&gValidateTextureView);
            }
            void *pixelFormatInfo = dlsym(
                RTLD_DEFAULT, "MTLPixelFormatGetInfoForDevice");
            if (hook && pixelFormatInfo) {
                hook(pixelFormatInfo,
                     (void *)NativeBCPixelFormatInfoForDevice,
                     (void **)&gPixelFormatGetInfoForDevice);
            }
            Class descriptorClass =
                NSClassFromString(@"MTLTextureDescriptorInternal");
            Method validationMethod = class_getInstanceMethod(
                descriptorClass, sel_registerName("validateWithDevice:"));
            if (validationMethod != NULL) {
                gValidateTextureDescriptor =
                    (BOOL (*)(id, SEL, id))method_setImplementation(
                        validationMethod,
                        (IMP)iPadValidateTextureDescriptor);
            }
        }
        class_addMethod([device class],
                        NSSelectorFromString(@"isLowPower"),
                        (IMP)iPadMetalDeviceIsLowPower,
                        "B@:");
        class_addMethod([device class],
                        NSSelectorFromString(@"isRemovable"),
                        (IMP)iPadMetalDeviceIsRemovable,
                        "B@:");
        class_addMethod([device class],
                        NSSelectorFromString(@"isHeadless"),
                        (IMP)iPadMetalDeviceIsHeadless,
                        "B@:");
        class_addMethod(
            [device class],
            NSSelectorFromString(
                @"isDepth24Stencil8PixelFormatSupported"),
            (IMP)iPadMetalDeviceIsDepth24Stencil8PixelFormatSupported,
            "B@:");
        class_addMethod(
            [device class],
            NSSelectorFromString(@"isFramebufferReadSupported"),
            (IMP)iPadMetalDeviceIsFramebufferReadSupported,
            "B@:");
        AddMetalMethodIfMissing(
            device, @"isRGB10A2GammaSupported",
            (IMP)iPadMetalDeviceReturnsYes, "B@:");
        AddMetalMethodIfMissing(
            device, @"supportsExtendedXR10Formats",
            (IMP)iPadMetalDeviceReturnsYes, "B@:");
        AddMetalMethodIfMissing(
            device, @"supportsNativeHardwareFP16",
            (IMP)iPadMetalDeviceReturnsYes, "B@:");
        AddMetalMethodIfMissing(
            device, @"maxTextureWidth2D",
            (IMP)iPadMetalDeviceMaxTextureDimension, "Q@:");
        AddMetalMethodIfMissing(
            device, @"maxTextureHeight2D",
            (IMP)iPadMetalDeviceMaxTextureDimension, "Q@:");
        AddMetalMethodIfMissing(
            device, @"maxTotalThreadsPerThreadgroup",
            (IMP)iPadMetalDeviceMaxTotalThreads, "Q@:");
        gNewBufferWithLength =
            (id (*)(id, SEL, NSUInteger, MTLResourceOptions))
                ReplaceMetalMethod(
                    [device class],
                    @"newBufferWithLength:options:",
                    (IMP)iPadNewBufferWithLength);
        gNewBufferWithBytes =
            (id (*)(id, SEL, const void *, NSUInteger, MTLResourceOptions))
                ReplaceMetalMethod(
                    [device class],
                    @"newBufferWithBytes:length:options:",
                    (IMP)iPadNewBufferWithBytes);
        gNewBufferWithBytesNoCopy =
            (id (*)(id, SEL, void *, NSUInteger, MTLResourceOptions,
                    void (^)(void *, NSUInteger)))
                ReplaceMetalMethod(
                    [device class],
                    @"newBufferWithBytesNoCopy:length:options:deallocator:",
                    (IMP)iPadNewBufferWithBytesNoCopy);
        gNewTextureWithDescriptor =
            (id (*)(id, SEL, MTLTextureDescriptor *))ReplaceMetalMethod(
                [device class],
                @"newTextureWithDescriptor:",
                (IMP)iPadNewTextureWithDescriptor);
        gNewTextureWithDescriptorIOSurface =
            (id (*)(id, SEL, MTLTextureDescriptor *, void *, NSUInteger))
                ReplaceMetalMethod(
                    [device class],
                    @"newTextureWithDescriptor:iosurface:plane:",
                    (IMP)iPadNewTextureWithDescriptorIOSurface);

        MTLTextureDescriptor *textureDescriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                                      MTLPixelFormatBGRA8Unorm
                                                             width:1
                                                            height:1
                                                         mipmapped:NO];
        gSetTextureStorageMode =
            (void (*)(id, SEL, MTLStorageMode))ReplaceMetalMethod(
                [textureDescriptor class],
                @"setStorageMode:",
                (IMP)iPadSetTextureStorageMode);
        gSetTexturePixelFormat =
            (void (*)(id, SEL, MTLPixelFormat))ReplaceMetalMethod(
                [textureDescriptor class], @"setPixelFormat:",
                (IMP)iPadSetTexturePixelFormat);

        if (nativeBC) {
            id<MTLTexture> sampleTexture =
                [device newTextureWithDescriptor:textureDescriptor];
            if (sampleTexture != nil) {
                gTextureReplaceRegionSlice =
                    (void (*)(id, SEL, MTLRegion, NSUInteger, NSUInteger,
                              const void *, NSUInteger, NSUInteger))
                        ReplaceMetalMethod(
                            [sampleTexture class],
                            @"replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:",
                            (IMP)iPadTextureReplaceRegionSlice);
                gTextureReplaceRegion =
                    (void (*)(id, SEL, MTLRegion, NSUInteger, const void *,
                              NSUInteger))ReplaceMetalMethod(
                            [sampleTexture class],
                            @"replaceRegion:mipmapLevel:withBytes:bytesPerRow:",
                            (IMP)iPadTextureReplaceRegion);
                gNewTextureView =
                    (id (*)(id, SEL, MTLPixelFormat))ReplaceMetalMethod(
                        [sampleTexture class],
                        @"newTextureViewWithPixelFormat:",
                        (IMP)iPadNewTextureView);
                gNewTextureViewWithRanges =
                    (id (*)(id, SEL, MTLPixelFormat, MTLTextureType,
                            NSRange, NSRange))ReplaceMetalMethod(
                        [sampleTexture class],
                        @"newTextureViewWithPixelFormat:textureType:levels:slices:",
                        (IMP)iPadNewTextureViewWithRanges);
                gNewTextureViewWithRangesAndSwizzle =
                    (id (*)(id, SEL, MTLPixelFormat, MTLTextureType,
                            NSRange, NSRange, MTLTextureSwizzleChannels))
                        ReplaceMetalMethod(
                            [sampleTexture class],
                            @"newTextureViewWithPixelFormat:textureType:levels:slices:swizzle:",
                            (IMP)iPadNewTextureViewWithRangesAndSwizzle);
            }
        }

        MTLHeapDescriptor *heapDescriptor = [[MTLHeapDescriptor alloc] init];
        gSetHeapStorageMode =
            (void (*)(id, SEL, MTLStorageMode))ReplaceMetalMethod(
                [heapDescriptor class],
                @"setStorageMode:",
                (IMP)iPadSetHeapStorageMode);
        if (nativeBC) {
            heapDescriptor.storageMode = MTLStorageModePrivate;
            heapDescriptor.size = 64 * 1024;
            id<MTLHeap> sampleHeap = [device newHeapWithDescriptor:heapDescriptor];
            if (sampleHeap) {
                gHeapNewTextureWithDescriptor =
                    (id (*)(id, SEL, MTLTextureDescriptor *))ReplaceMetalMethod(
                        [sampleHeap class], @"newTextureWithDescriptor:",
                        (IMP)iPadHeapNewTextureWithDescriptor);
            }
            [sampleHeap release];
        }

        MTLSamplerDescriptor *samplerDescriptor =
            [[MTLSamplerDescriptor alloc] init];
        AddMetalMethodIfMissing(
            samplerDescriptor, @"setReductionMode:",
            (IMP)iPadSamplerSetReductionMode, "v@:Q");
        AddMetalMethodIfMissing(
            samplerDescriptor, @"reductionMode",
            (IMP)iPadSamplerReductionMode, "Q@:");
    }
}
