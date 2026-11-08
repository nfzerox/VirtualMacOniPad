#import "../host/VZPaths.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pwd.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#import "../host/NSViewShim.h"

static id gVirtualMachine;
static id gInstaller;
static dispatch_source_t gProgressTimer;
static NSString *gStagingBundlePath;
static NSString *gFinalBundlePath;

static SEL S(const char *name) { return sel_registerName(name); }
static Class C(const char *name) { return objc_getClass(name); }
static id New(const char *name)
{
    return ((id (*)(id, SEL))objc_msgSend)(C(name), S("new"));
}
static id Alloc(const char *name)
{
    return ((id (*)(id, SEL))objc_msgSend)(C(name), S("alloc"));
}
static void SetObject(id object, const char *selector, id value)
{
    ((void (*)(id, SEL, id))objc_msgSend)(object, S(selector), value);
}
static NSURL *FileURL(NSString *path)
{
    return [NSURL fileURLWithPath:path];
}

static void MakeFailedBundleAccessible(void)
{
    if (!gStagingBundlePath.length || ![[NSFileManager defaultManager]
            fileExistsAtPath:gStagingBundlePath])
        return;
    // The installer runs as root, while UIKit deliberately remains mobile.
    // Hand the complete partial tree back before reporting the error so the
    // app can archive or delete it. Restore may add files that this launcher
    // does not know by name, so enumerating is safer than a fixed file list.
    struct passwd *mobile = getpwnam("mobile");
    uid_t uid = mobile ? mobile->pw_uid : 501;
    gid_t gid = mobile ? mobile->pw_gid : 501;
    NSMutableArray<NSString *> *paths = [NSMutableArray
        arrayWithObject:gStagingBundlePath];
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager]
        enumeratorAtPath:gStagingBundlePath];
    for (NSString *relativePath in enumerator)
        [paths addObject:[gStagingBundlePath
            stringByAppendingPathComponent:relativePath]];
    for (NSString *path in paths) {
        struct stat status;
        if (lstat(path.fileSystemRepresentation, &status) != 0)
            continue;
        lchown(path.fileSystemRepresentation, uid, gid);
        if (S_ISLNK(status.st_mode))
            continue;
        mode_t accessibleMode = status.st_mode & 0777;
        accessibleMode |= S_ISDIR(status.st_mode) ? 0700 : 0600;
        chmod(path.fileSystemRepresentation, accessibleMode);
    }
}

static uint64_t EnvironmentUInt64(const char *name, uint64_t fallback,
                                  uint64_t minimum, uint64_t maximum)
{
    const char *text = getenv(name);
    if (!text || !*text)
        return fallback;
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno || !end || *end || value < minimum || value > maximum)
        return fallback;
    return value;
}

static void FinishWithError(NSString *stage, NSError *error)
{
    MakeFailedBundleAccessible();
    fprintf(stderr, "INSTALL_FAILED\tstage=%s\terror=%s\n",
            stage.UTF8String ?: "(unknown)",
            error.description.UTF8String ?: "(unknown)");
    fflush(NULL);
    exit(1);
}

static BOOL LoadImage(NSString *path)
{
    void *image = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!image) {
        fprintf(stderr, "DLOPEN_FAILED\t%s\t%s\n",
                path.fileSystemRepresentation, dlerror());
        return NO;
    }
    printf("DLOPEN_OK\t%s\n", path.fileSystemRepresentation);
    return YES;
}

static BOOL WriteData(id object, const char *selector, NSString *path)
{
    NSData *data = ((id (*)(id, SEL))objc_msgSend)(object, S(selector));
    NSError *error = nil;
    BOOL result = [data writeToURL:FileURL(path)
                           options:NSDataWritingAtomic error:&error];
    if (!result)
        FinishWithError(@"write-metadata", error);
    return result;
}

static BOOL SetBundleFileAccess(NSString *path, mode_t mode, NSError **error)
{
    const char *fileSystemPath = path.fileSystemRepresentation;
    if (chown(fileSystemPath, 501, 501) == 0 &&
        chmod(fileSystemPath, mode) == 0)
        return YES;
    int savedError = errno;
    if (error)
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:savedError
                                 userInfo:nil];
    return NO;
}

static BOOL PrepareBundleForMobile(NSError **error)
{
    if (!SetBundleFileAccess(gStagingBundlePath, 0755, error))
        return NO;
    for (NSString *name in @[@"Disk.img", @"AuxiliaryStorage"]) {
        if (!SetBundleFileAccess(
                [gStagingBundlePath stringByAppendingPathComponent:name],
                0600, error))
            return NO;
    }
    for (NSString *name in @[@"HardwareModel", @"MachineIdentifier"]) {
        if (!SetBundleFileAccess(
                [gStagingBundlePath stringByAppendingPathComponent:name],
                0644, error))
            return NO;
    }
    return YES;
}

static id CreateConfiguration(id requirements, NSError **error)
{
    NSString *auxiliaryPath =
        [gStagingBundlePath stringByAppendingPathComponent:@"AuxiliaryStorage"];
    NSString *diskPath =
        [gStagingBundlePath stringByAppendingPathComponent:@"Disk.img"];
    NSString *hardwarePath =
        [gStagingBundlePath stringByAppendingPathComponent:@"HardwareModel"];
    NSString *identifierPath =
        [gStagingBundlePath stringByAppendingPathComponent:@"MachineIdentifier"];

    id hardwareModel = [requirements valueForKey:@"hardwareModel"];
    id platform = New("VZMacPlatformConfiguration");
    id auxiliary = ((id (*)(id, SEL, id, id, NSUInteger, NSError **))objc_msgSend)(
        Alloc("VZMacAuxiliaryStorage"),
        S("initCreatingStorageAtURL:hardwareModel:options:error:"),
        FileURL(auxiliaryPath), hardwareModel, (NSUInteger)1, error);
    if (!auxiliary)
        return nil;
    id machineIdentifier = New("VZMacMachineIdentifier");
    SetObject(platform, "setHardwareModel:", hardwareModel);
    SetObject(platform, "setAuxiliaryStorage:", auxiliary);
    SetObject(platform, "setMachineIdentifier:", machineIdentifier);
    WriteData(hardwareModel, "dataRepresentation", hardwarePath);
    WriteData(machineIdentifier, "dataRepresentation", identifierPath);

    uint64_t cpuCount = EnvironmentUInt64(
        "VZ_INSTALL_CPU_COUNT", 4, 2,
        MAX((NSUInteger)2, NSProcessInfo.processInfo.activeProcessorCount));
    uint64_t memorySize = EnvironmentUInt64(
        "VZ_INSTALL_MEMORY_SIZE", 4ULL << 30, 2ULL << 30, 8ULL << 30);
    uint64_t storageSize = EnvironmentUInt64(
        "VZ_INSTALL_STORAGE_SIZE", 64ULL << 30, 32ULL << 30,
        (uint64_t)LLONG_MAX);

    int disk = open(diskPath.fileSystemRepresentation,
                    O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
    if (disk == -1) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                                 userInfo:nil];
        return nil;
    }
    if (ftruncate(disk, (off_t)storageSize) != 0) {
        int savedError = errno;
        close(disk);
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:savedError
                                 userInfo:nil];
        return nil;
    }
    close(disk);

    id attachment = ((id (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(
        Alloc("VZDiskImageStorageDeviceAttachment"),
        S("initWithURL:readOnly:error:"), FileURL(diskPath), NO, error);
    if (!attachment)
        return nil;
    id blockDevice = ((id (*)(id, SEL, id))objc_msgSend)(
        Alloc("VZVirtioBlockDeviceConfiguration"),
        S("initWithAttachment:"), attachment);

    id configuration = New("VZVirtualMachineConfiguration");
    SetObject(configuration, "setPlatform:", platform);
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(
        configuration, S("setCPUCount:"), (NSUInteger)cpuCount);
    ((void (*)(id, SEL, uint64_t))objc_msgSend)(
        configuration, S("setMemorySize:"), memorySize);
    SetObject(configuration, "setBootLoader:", New("VZMacOSBootLoader"));
    SetObject(configuration, "setStorageDevices:", @[blockDevice]);

    // The display is install-time only; the user's configured native-resolution
    // display remains the runtime device. RestoreOS builds may still require a
    // graphics device, so every supported host configures the same display.
    id display = ((id (*)(id, SEL, NSInteger, NSInteger, NSInteger))
        objc_msgSend)(Alloc("VZMacGraphicsDisplayConfiguration"),
            S("initWithWidthInPixels:heightInPixels:pixelsPerInch:"),
            1920, 1200, 80);
    id graphics = New("VZMacGraphicsDeviceConfiguration");
    SetObject(graphics, "setDisplays:", @[display]);
    SetObject(configuration, "setGraphicsDevices:", @[graphics]);
    printf("INSTALL_GRAPHICS\t1920x1200@80\n");

    BOOL valid = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(
        configuration, S("validateWithError:"), error);
    if (!valid)
        return nil;
    printf("INSTALL_CONFIGURATION_OK\tcpu=%llu\tmemory=%llu\t"
           "disk-bytes=%llu\n", cpuCount, memorySize, storageSize);
    return configuration;
}

static void StartInstall(id restoreImage, NSURL *ipswURL)
{
    id requirements =
        [restoreImage valueForKey:@"mostFeaturefulSupportedConfiguration"];
    id hardwareModel = [requirements valueForKey:@"hardwareModel"];
    BOOL modelSupported = ((BOOL (*)(id, SEL))objc_msgSend)(
        hardwareModel, S("isSupported"));
    if (!requirements || !hardwareModel || !modelSupported) {
        FinishWithError(@"requirements",
            [NSError errorWithDomain:@"VirtualMac" code:1 userInfo:nil]);
    }

    NSError *error = nil;
    if (![[NSFileManager defaultManager]
            createDirectoryAtPath:gStagingBundlePath
      withIntermediateDirectories:NO attributes:nil error:&error])
        FinishWithError(@"create-bundle", error);

    id configuration = CreateConfiguration(requirements, &error);
    if (!configuration)
        FinishWithError(@"create-configuration", error);

    gVirtualMachine = ((id (*)(id, SEL, id))objc_msgSend)(
        Alloc("VZVirtualMachine"), S("initWithConfiguration:"), configuration);
    if (!gVirtualMachine) {
        FinishWithError(@"create-virtual-machine",
            [NSError errorWithDomain:@"VirtualMac" code:2 userInfo:nil]);
    }
    gInstaller = ((id (*)(id, SEL, id, id))objc_msgSend)(
        Alloc("VZMacOSInstaller"),
        S("initWithVirtualMachine:restoreImageURL:"),
        gVirtualMachine, ipswURL);
    if (!gInstaller) {
        FinishWithError(@"create-installer",
            [NSError errorWithDomain:@"VirtualMac" code:3 userInfo:nil]);
    }

    id progress = [gInstaller valueForKey:@"progress"];
    gProgressTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(
        gProgressTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
        NSEC_PER_SEC, NSEC_PER_MSEC * 100);
    dispatch_source_set_event_handler(gProgressTimer, ^{
        double fraction = [[progress valueForKey:@"fractionCompleted"] doubleValue];
        printf("INSTALL_PROGRESS\t%.6f\n", fraction);
        fflush(NULL);
    });
    dispatch_resume(gProgressTimer);

    printf("INSTALL_BEGIN\t%s\n", ipswURL.path.UTF8String);
    ((void (*)(id, SEL, id))objc_msgSend)(
        gInstaller, S("installWithCompletionHandler:"), ^(NSError *installError) {
        dispatch_source_cancel(gProgressTimer);
        if (installError)
            FinishWithError(@"install", installError);

        NSError *moveError = nil;
        if (!PrepareBundleForMobile(&moveError))
            FinishWithError(@"prepare-bundle-access", moveError);
        if (![[NSFileManager defaultManager]
                moveItemAtPath:gStagingBundlePath
                        toPath:gFinalBundlePath error:&moveError])
            FinishWithError(@"finalize-bundle", moveError);
        printf("INSTALL_SUCCEEDED\tbundle=%s\n",
               gFinalBundlePath.UTF8String);
        fflush(NULL);
        exit(0);
    });
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        setlinebuf(stdout);
        setlinebuf(stderr);
        if (argc != 4) {
            fprintf(stderr,
                    "usage: install-macos <restore.ipsw> <staging.bundle.installing> <final.bundle>\n");
            return 2;
        }
        NSString *ipswPath = [[NSString alloc] initWithUTF8String:argv[1]];
        gStagingBundlePath =
            [[NSString alloc] initWithUTF8String:argv[2]];
        gFinalBundlePath = [[NSString alloc] initWithUTF8String:argv[3]];
        if (![gStagingBundlePath hasSuffix:@".bundle.installing"] ||
            ![gStagingBundlePath hasPrefix:
                @(VZStatePath("Installations/"))] ||
            ![gFinalBundlePath.stringByDeletingLastPathComponent
                isEqualToString:@(VZLibraryRoot)] ||
            ![gFinalBundlePath hasSuffix:@".bundle"] ||
            [[NSFileManager defaultManager]
                fileExistsAtPath:gStagingBundlePath] ||
            [[NSFileManager defaultManager]
                fileExistsAtPath:gFinalBundlePath]) {
            fprintf(stderr, "INVALID_INSTALL_PATHS\t%s\t%s\n",
                    gStagingBundlePath.UTF8String,
                    gFinalBundlePath.UTF8String);
            return 2;
        }

        printf("FAKE_CLASS\tNSView\tsuperclass=%s\tinstance-size=%zu\n",
               class_getName(class_getSuperclass([NSView class])),
               class_getInstanceSize([NSView class]));

        NSString *root = @(VZRuntimePath(""));
        setenv("VZ_INSTALLATION_BIN", [[root stringByAppendingPathComponent:
            @"payload/Installation.xpc/Contents/MacOS/"
             "com.apple.Virtualization.Installation"] fileSystemRepresentation], 1);
        setenv("VZ_VMM_BIN", [[root stringByAppendingPathComponent:
            @"payload/VirtualMachine.xpc/Contents/MacOS/"
             "com.apple.Virtualization.VirtualMachine"] fileSystemRepresentation], 1);
        setenv("VZ_AVP_BOOTER", [[root stringByAppendingPathComponent:
            @"payload/Frameworks/Virtualization.framework/Resources/"
             "AVPBooter.vmapple2.bin"] fileSystemRepresentation], 1);
        setenv("VMM_FACTORY_SETTLE_USEC", "100000", 1);
        setenv("VMM_FACTORY_LONG_STOP", "6", 1);
        setenv("VMM_FACTORY_LONG_SETTLE_USEC", "5000000", 1);

        NSArray<NSString *> *images = @[
            [root stringByAppendingPathComponent:
                @"install/VZHostCompat.dylib"],
            [root stringByAppendingPathComponent:
                @"payload/Frameworks/Hypervisor.framework/Hypervisor"],
            [root stringByAppendingPathComponent:
                @"payload/Frameworks/ParavirtualizedGraphics.framework/"
                 "ParavirtualizedGraphics"],
            [root stringByAppendingPathComponent:
                @"payload/Frameworks/Virtualization.framework/Virtualization"],
        ];
        for (NSString *image in images)
            if (!LoadImage(image))
                return 1;

        Method startMethod = class_getInstanceMethod(
            C("VZVirtualMachine"), S("startWithCompletionHandler:"));
        Dl_info info = {0};
        if (!startMethod ||
            !dladdr((const void *)method_getImplementation(startMethod), &info) ||
            !info.dli_fbase)
            return 1;
        int (*rebind)(void *) =
            (int (*)(void *))dlsym(RTLD_DEFAULT, "vz_rebind_virtualization");
        int rebindResult = rebind ? rebind(info.dli_fbase) : -1;
        printf("VZ_REBIND\tbase=%p\tresult=%d\n", info.dli_fbase,
               rebindResult);
        if (rebindResult != 0)
            return 1;

        NSURL *ipswURL = FileURL(ipswPath);
        Class restoreClass = C("VZMacOSRestoreImage");
        printf("RESTORE_LOAD_BEGIN\t%s\n", ipswPath.UTF8String);
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            restoreClass, S("loadFileURL:completionHandler:"), ipswURL,
            ^(id restoreImage, NSError *loadError) {
            if (!restoreImage)
                FinishWithError(@"load-restore-image", loadError);
            printf("RESTORE_LOAD_OK\tbuild=%s\n",
                   [[[restoreImage valueForKey:@"buildVersion"] description]
                       UTF8String]);
            dispatch_async(dispatch_get_main_queue(), ^{
                StartInstall(restoreImage, ipswURL);
            });
        });
        dispatch_main();
    }
}
