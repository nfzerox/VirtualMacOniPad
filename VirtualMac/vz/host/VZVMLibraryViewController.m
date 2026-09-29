#import "VZPaths.h"
#import "VZVMLibraryViewController.h"
#import "VZAppSettings.h"
#import "VZSettingsViewController.h"
#import "VZNewVMViewController.h"
#import "VZProgressViewController.h"
#import "VZRestoreCatalog.h"
#import "VZLocalization.h"
#import "VZSupport.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <ifaddrs.h>
#include <errno.h>
#include <netinet/in.h>
#include <net/if.h>
#include <limits.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <sys/wait.h>

extern char **environ;

NSString * const VZVMConfigurationFileName = @"VirtualMac.plist";
NSString * const VZApplePencilPressureTiltEnabledKey =
    @"ApplePencilPressureTiltEnabled";
NSString * const VZVirtualMacGuestToolsEnabledKey =
    @"VirtualMacGuestToolsEnabled";
NSString * const VZMetalBCSupportEnabledKey = @"MetalBCSupportEnabled";
NSString * const VZOpenGLAccelerationEnabledKey = @"OpenGLAccelerationEnabled";
NSString * const VZGuestToolsRemovalPendingKey = @"GuestToolsRemovalPending";

static NSString * const VZCPUCountKey = @"CPUCount";
static NSString * const VZMemorySizeKey = @"MemorySize";
static NSString * const VZStorageSizeKey = @"StorageSize";
static NSString * const VZNetworkModeKey = @"NetworkMode";
static NSString * const VZBridgeInterfaceKey = @"BridgeInterface";
static NSString * const VZBootRecoveryKey = @"BootRecovery";
static NSString * const VZSharedDirectoriesKey = @"SharedDirectories";
static NSString * const VZPointingDeviceKey = @"PointingDevice";
static NSString * const VZKeyboardDeviceKey = @"KeyboardDevice";
static NSString * const VZAudioOutputEnabledKey = @"AudioOutputEnabled";
static NSString * const VZAudioInputEnabledKey = @"AudioInputEnabled";
static NSString * const VZVideoToolboxEnabledKey = @"VideoToolboxEnabled";
static NSString * const VZDisplayModeKey = @"DisplayMode";
static NSString * const VZDisplayWidthKey = @"DisplayWidth";
static NSString * const VZDisplayHeightKey = @"DisplayHeight";
static NSString * const VZDisplayPPIKey = @"DisplayPixelsPerInch";
static NSString * const VZMACAddressKey = @"MACAddress";
static NSString * const VZVMNameKey = @"VMName";

static NSArray<NSDictionary *> *VZFixedDisplayPresets(void)
{
    static NSArray *presets;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        presets = [@[
            @{@"mode": @"1080p", @"title": VZL(@"1080p"),
              @"width": @1920, @"height": @1080, @"ppi": @72},
            @{@"mode": @"4KRetina", @"title": VZL(@"4K Retina"),
              @"width": @3840, @"height": @2160, @"ppi": @218},
            @{@"mode": @"5KRetina", @"title": VZL(@"5K Retina"),
              @"width": @5120, @"height": @2880, @"ppi": @218},
            @{@"mode": @"6KRetina", @"title": VZL(@"6K Retina"),
              @"width": @6016, @"height": @3384, @"ppi": @218},
        ] retain];
    });
    return presets;
}

static NSDictionary *VZFixedDisplayPresetForOptions(NSDictionary *options)
{
    NSInteger width = [options[VZDisplayWidthKey] integerValue];
    NSInteger height = [options[VZDisplayHeightKey] integerValue];
    NSInteger ppi = [options[VZDisplayPPIKey] integerValue];
    for (NSDictionary *preset in VZFixedDisplayPresets())
        if (width == [preset[@"width"] integerValue] &&
            height == [preset[@"height"] integerValue] &&
            ppi == [preset[@"ppi"] integerValue])
            return preset;
    return nil;
}

static NSString *VZDisplaySelectionForOptions(NSDictionary *options)
{
    NSString *mode = options[VZDisplayModeKey];
    if ([mode isEqualToString:@"NativeRetina"] ||
        [mode isEqualToString:@"FullScreen"] ||
        [mode isEqualToString:@"LandscapeNativeRetina"] ||
        [mode isEqualToString:@"PortraitNativeRetina"] ||
        [mode isEqualToString:@"ExternalDisplay"] ||
        [mode isEqualToString:@"WindowSizeAtStartup"])
        return mode;
    NSDictionary *preset = VZFixedDisplayPresetForOptions(options);
    return preset ? preset[@"mode"] : @"Custom";
}

static NSString *VZDisplaySelectionTitle(NSDictionary *options)
{
    NSString *selection = VZDisplaySelectionForOptions(options);
    if ([selection isEqualToString:@"NativeRetina"] ||
        [selection isEqualToString:@"FullScreen"])
        return VZL(@"Full Screen");
    if ([selection isEqualToString:@"LandscapeNativeRetina"])
        return VZDeviceString(VZL(@"Landscape iPad"),
                              VZL(@"Landscape iPhone"));
    if ([selection isEqualToString:@"PortraitNativeRetina"])
        return VZDeviceString(VZL(@"Portrait iPad"),
                              VZL(@"Portrait iPhone"));
    if ([selection isEqualToString:@"ExternalDisplay"])
        return VZL(@"External Display");
    if ([selection isEqualToString:@"WindowSizeAtStartup"])
        return VZL(@"Window Size");
    for (NSDictionary *preset in VZFixedDisplayPresets())
        if ([selection isEqualToString:preset[@"mode"]])
            return preset[@"title"];
    return VZL(@"Custom");
}

static uint64_t GiB(uint64_t value)
{
    return value << 30;
}

NSString *VZVMLibraryPath(void)
{
#if defined(VZ_ROOTHIDE)
    return @(VZLibraryRoot);
#else
    return VZVMSupportPath();
#endif
}

NSString *VZVMSupportPath(void)
{
    return @"/var/mobile/Media/VirtualMac";
}

NSString *VZRestoreImagesPath(void)
{
#if defined(VZ_ROOTHIDE)
    return @(VZRestoreImagesRoot);
#else
    return [VZVMSupportPath() stringByAppendingPathComponent:@"Restore Images"];
#endif
}

NSString *VZInstallationsPath(void)
{
#if defined(VZ_ROOTHIDE)
    return @(VZInstallationsRoot);
#else
    return [VZVMSupportPath() stringByAppendingPathComponent:@"Installations"];
#endif
}

static uint64_t VZDeviceMemoryLimit(void)
{
    uint64_t physical = NSProcessInfo.processInfo.physicalMemory;
    // The marketed capacity is larger than the memory iPadOS exposes to this
    // process.
    // VZ rejects a rounded-up 16/8 GiB value as greater than its host limit.
    return MAX(GiB(2), (physical >> 30) << 30);
}

static uint64_t VZDefaultMemorySize(void)
{
    uint64_t physical = NSProcessInfo.processInfo.physicalMemory;
    return physical >= GiB(12) ? GiB(8) : GiB(4);
}

static uint64_t VZDefaultStorageSize(void)
{
    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfFileSystemForPath:VZVMLibraryPath() error:nil];
    uint64_t total = [attributes[NSFileSystemSize] unsignedLongLongValue];
    uint64_t available =
        [attributes[NSFileSystemFreeSize] unsignedLongLongValue];

    // Disk.img is sparse, so its logical capacity is not allocated up front.
    // Still require enough real headroom for an IPSW, restore working files,
    // and meaningful guest growth before offering a larger default.
    if (total >= GiB(512) && available >= GiB(160))
        return GiB(256);
    if (total >= GiB(256) && available >= GiB(96))
        return GiB(128);
    return GiB(64);
}

static uint64_t VZAvailableStorageSize(void)
{
    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfFileSystemForPath:VZVMLibraryPath() error:nil];
    return [attributes[NSFileSystemFreeSize] unsignedLongLongValue];
}

static uint64_t VZVMStorageCapacity(NSString *bundlePath,
                                    NSDictionary *options)
{
    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfItemAtPath:[bundlePath stringByAppendingPathComponent:
            @"Disk.img"] error:nil];
    uint64_t capacity = [attributes[NSFileSize] unsignedLongLongValue];
    return capacity ?: [options[VZStorageSizeKey] unsignedLongLongValue];
}

static NSString *VZMACStringFromBytes(const uint8_t bytes[6])
{
    return [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]];
}

static NSString *VZRandomMACAddress(void)
{
    uint8_t bytes[6];
    arc4random_buf(bytes, sizeof(bytes));
    bytes[0] = (bytes[0] | 0x02) & 0xfe;
    return VZMACStringFromBytes(bytes);
}

static NSString *VZMACAddressForBundle(NSString *bundlePath)
{
    NSData *identifier = [NSData dataWithContentsOfFile:
        [bundlePath stringByAppendingPathComponent:@"MachineIdentifier"]];
    const uint8_t *contents = identifier.bytes;
    uint64_t hash = UINT64_C(1469598103934665603);
    for (NSUInteger index = 0; index < identifier.length; index++) {
        hash ^= contents[index];
        hash *= UINT64_C(1099511628211);
    }
    if (!identifier.length) {
        const char *path = bundlePath.fileSystemRepresentation;
        for (; path && *path; path++) {
            hash ^= (uint8_t)*path;
            hash *= UINT64_C(1099511628211);
        }
    }
    uint8_t bytes[6];
    for (NSUInteger index = 0; index < sizeof(bytes); index++)
        bytes[index] = (uint8_t)(hash >> (index * 8));
    bytes[0] = (bytes[0] | 0x02) & 0xfe;
    return VZMACStringFromBytes(bytes);
}

static BOOL VZHostSupportsBridgedNetworking(void)
{
    // iPadOS 14 lacks the private Wi-Fi virtualization integration that lets
    // a macOS host bridge a guest MAC through a Wi-Fi station. NAT is the
    // supported network attachment on that host release. Keep the existing
    // bridged-network UI and behavior unchanged on iPadOS 15 and 16.
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion > 14;
}

static NSString *VZEffectiveNetworkMode(NSDictionary *options)
{
    NSString *mode = options[VZNetworkModeKey] ?: @"NAT";
    return !VZHostSupportsBridgedNetworking() &&
        [mode isEqualToString:@"Bridge"] ? @"NAT" : mode;
}

static NSString *VZNetworkModeDisplayName(NSDictionary *options)
{
    NSString *mode = VZEffectiveNetworkMode(options);
    if ([mode isEqualToString:@"Bridge"])
        return VZL(@"Bridge");
    if ([mode isEqualToString:@"Disabled"])
        return VZL(@"Disabled");
    return mode;
}

static NSArray *VZBridgeInterfaceNames(void)
{
    if (!VZHostSupportsBridgedNetworking())
        return @[];
    NSMutableSet *names = [NSMutableSet set];
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
            if (!item->ifa_name || !(item->ifa_flags & IFF_UP) ||
                (item->ifa_flags & IFF_LOOPBACK))
                continue;
            NSString *name = [NSString stringWithUTF8String:item->ifa_name];
            if ([name hasPrefix:@"en"] || [name hasPrefix:@"bridge"])
                [names addObject:name];
        }
        freeifaddrs(interfaces);
    }
    if (!names.count)
        [names addObject:@"en0"];
    return [names.allObjects sortedArrayUsingSelector:
        @selector(localizedStandardCompare:)];
}

static NSString *VZInterfaceDisplayName(NSString *interface)
{
    if ([interface isEqualToString:@"en0"])
        return VZL(@"Wi-Fi");
    if ([interface hasPrefix:@"pdp_ip"])
        return VZL(@"Cellular");
    if ([interface hasPrefix:@"bridge"])
        return [NSString stringWithFormat:VZL(@"Network Bridge (%@)"), interface];
    if ([interface hasPrefix:@"en"])
        return [NSString stringWithFormat:VZL(@"Ethernet (%@)"), interface];
    return interface;
}

static NSString *VZActiveInternetDisplayName(void)
{
    NSString *candidate = nil;
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
            if (!item->ifa_name || !item->ifa_addr ||
                item->ifa_addr->sa_family != AF_INET ||
                !(item->ifa_flags & IFF_UP) ||
                (item->ifa_flags & IFF_LOOPBACK))
                continue;
            NSString *name = [NSString stringWithUTF8String:item->ifa_name];
            if ([name isEqualToString:@"en0"]) {
                candidate = name;
                break;
            }
            if (!candidate && ([name hasPrefix:@"pdp_ip"] ||
                               [name hasPrefix:@"utun"]))
                candidate = name;
        }
        freeifaddrs(interfaces);
    }
    if ([candidate hasPrefix:@"utun"])
        return VZL(@"VPN");
    return candidate ? VZInterfaceDisplayName(candidate)
                     : VZDeviceString(VZL(@"iPad Internet Connection"),
                                      VZL(@"iPhone Internet Connection"));
}

BOOL VZRestoreImageUsesMontereyProfile(NSString *path)
{
    NSDictionary *image = @{ @"name": path.lastPathComponent ?: @"" };
    return [VZRestoreCatalog majorVersionForImage:image] == 12;
}

static BOOL VZDefaultOpenGLAccelerationForRestoreImage(NSString *path)
{
    return [VZRestoreCatalog enablesOpenGLByDefaultForImage:
        @{ @"name": path.lastPathComponent ?: @"" }];
}

static NSString *VZDefaultPointingDeviceForPath(NSString *path)
{
    return VZRestoreImageUsesMontereyProfile(path) ? @"USBMouse" : @"MacTrackpad";
}

static NSString *VZDefaultKeyboardDeviceForPath(NSString *path)
{
    return VZRestoreImageUsesMontereyProfile(path) ? @"USBKeyboard" : @"MacKeyboard";
}

NSDictionary *VZVMDefaultOptions(void)
{
    NSUInteger processors = MAX((NSUInteger)2,
        MIN((NSUInteger)4, NSProcessInfo.processInfo.activeProcessorCount));
    return @{
        VZCPUCountKey: @(processors),
        VZMemorySizeKey: @(VZDefaultMemorySize()),
        VZStorageSizeKey: @(VZDefaultStorageSize()),
        VZNetworkModeKey: @"NAT",
        VZBridgeInterfaceKey: @"en0",
        VZBootRecoveryKey: @NO,
        VZSharedDirectoriesKey: @[],
        VZPointingDeviceKey: @"MacTrackpad",
        VZKeyboardDeviceKey: @"MacKeyboard",
        VZApplePencilPressureTiltEnabledKey: @NO,
        VZVirtualMacGuestToolsEnabledKey: @YES,
        VZMetalBCSupportEnabledKey: @YES,
        VZOpenGLAccelerationEnabledKey: @YES,
        VZGuestToolsRemovalPendingKey: @NO,
        VZAudioOutputEnabledKey: @YES,
        VZAudioInputEnabledKey: @YES,
        VZVideoToolboxEnabledKey: @YES,
        VZDisplayModeKey: @"NativeRetina",
        VZDisplayWidthKey: @1920,
        VZDisplayHeightKey: @1080,
        VZDisplayPPIKey: @264,
        VZMACAddressKey: VZRandomMACAddress(),
    };
}

NSDictionary *VZVMOptionsForBundle(NSString *bundlePath)
{
    NSMutableDictionary *options =
        [NSMutableDictionary dictionaryWithDictionary:VZVMDefaultOptions()];
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:
        [bundlePath stringByAppendingPathComponent:VZVMConfigurationFileName]];
    if ([saved isKindOfClass:NSDictionary.class])
        [options addEntriesFromDictionary:saved];
#if defined(VZ_ROOTHIDE)
    NSMutableArray *shares = [NSMutableArray array];
    for (NSDictionary *share in options[VZSharedDirectoriesKey]) {
        NSMutableDictionary *resolved = [[share mutableCopy] autorelease];
        if ([share[@"Path"] isKindOfClass:NSString.class])
            resolved[@"Path"] = VZResolvedStoredPath(share[@"Path"]);
        [shares addObject:resolved];
    }
    options[VZSharedDirectoriesKey] = shares;
#endif
    [options removeObjectForKey:@"EnhancedMetalOpenGLEnabled"];
    if (![saved[VZPointingDeviceKey] isKindOfClass:NSString.class])
        options[VZPointingDeviceKey] =
            VZDefaultPointingDeviceForPath(bundlePath);
    if (![saved[VZKeyboardDeviceKey] isKindOfClass:NSString.class])
        options[VZKeyboardDeviceKey] =
            VZDefaultKeyboardDeviceForPath(bundlePath);
    if (![saved[VZOpenGLAccelerationEnabledKey]
            isKindOfClass:NSNumber.class])
        options[VZOpenGLAccelerationEnabledKey] =
            @(VZDefaultOpenGLAccelerationForRestoreImage(bundlePath));
    NSString *savedMAC = saved[VZMACAddressKey];
    if (![savedMAC isKindOfClass:NSString.class] ||
        [savedMAC isEqualToString:@"d6:a7:58:8e:78:d5"])
        options[VZMACAddressKey] = VZMACAddressForBundle(bundlePath);
    return options;
}

BOOL VZWriteVMOptions(NSDictionary *options, NSString *bundlePath,
                      NSError **error)
{
#if defined(VZ_ROOTHIDE)
    NSMutableDictionary *stored = [[options mutableCopy] autorelease];
    NSMutableArray *shares = [NSMutableArray array];
    NSString *portableBundle = VZStoredPath(bundlePath);
    BOOL legacyBundle = [portableBundle hasPrefix:@"/var/mobile/Media/VirtualMac/"] ||
        [portableBundle hasPrefix:@"/rootfs/var/mobile/Media/VirtualMac/"];
    for (NSDictionary *share in options[VZSharedDirectoriesKey]) {
        NSMutableDictionary *entry = [[share mutableCopy] autorelease];
        if ([share[@"Path"] isKindOfClass:NSString.class]) {
            NSString *path = VZStoredPath(share[@"Path"]);
            if (legacyBundle && [path hasPrefix:@"/rootfs/"])
                path = [path substringFromIndex:7];
            entry[@"Path"] = path;
        }
        [shares addObject:entry];
    }
    stored[VZSharedDirectoriesKey] = shares;
    options = stored;
#endif
    NSString *path =
        [bundlePath stringByAppendingPathComponent:VZVMConfigurationFileName];
    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:options format:NSPropertyListXMLFormat_v1_0
                     options:0 error:error];
    return data && [data writeToFile:path options:NSDataWritingAtomic error:error];
}

BOOL VZIsValidVMBundle(NSString *path)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    BOOL directory = NO;
    if (![manager fileExistsAtPath:path isDirectory:&directory] || !directory)
        return NO;
    for (NSString *name in @[@"Disk.img", @"AuxiliaryStorage",
                              @"HardwareModel", @"MachineIdentifier"]) {
        BOOL itemDirectory = NO;
        if (![manager fileExistsAtPath:[path stringByAppendingPathComponent:name]
                           isDirectory:&itemDirectory] || itemDirectory)
            return NO;
    }
    return YES;
}

NSString *VZVMStableIdentifier(NSString *path)
{
    NSData *identifier = [NSData dataWithContentsOfFile:
        [path stringByAppendingPathComponent:@"MachineIdentifier"]];
    return identifier.length ? [identifier base64EncodedStringWithOptions:0] : nil;
}

NSArray<NSDictionary *> *VZDiscoverVirtualMachines(void)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *library = VZVMLibraryPath();
    [manager createDirectoryAtPath:library withIntermediateDirectories:YES
                        attributes:nil error:nil];
    [manager createDirectoryAtPath:VZRestoreImagesPath()
       withIntermediateDirectories:YES attributes:nil error:nil];
    [manager createDirectoryAtPath:VZInstallationsPath()
       withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *readme = [library stringByAppendingPathComponent:@"README.md"];
    if (![manager fileExistsAtPath:readme]) {
        NSString *text =
            @"# Virtual Mac\n\n"
             "Use Add in Virtual Mac to install a restore image, or copy a "
             "complete `.bundle` here. A bundle contains `Disk.img`, "
             "`AuxiliaryStorage`, `HardwareModel`, and `MachineIdentifier`.\n";
        [text writeToFile:readme atomically:YES
                 encoding:NSUTF8StringEncoding error:nil];
    }

    NSMutableArray *machines = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^append)(NSString *, NSString *) =
        ^(NSString *path, NSString *name) {
        if (!VZIsValidVMBundle(path))
            return;
        NSString *manifest = [path stringByAppendingPathComponent:
            VZVMConfigurationFileName];
        if (![manager fileExistsAtPath:manifest]) {
            NSError *manifestError = nil;
            NSDictionary *defaults = VZVMOptionsForBundle(path);
            if (!VZWriteVMOptions(defaults, path, &manifestError))
                NSLog(@"Virtual Mac could not synthesize settings for %@: %@",
                      path, manifestError);
        }
        NSString *identity = path.stringByResolvingSymlinksInPath;
        if ([seen containsObject:identity])
            return;
        [seen addObject:identity];
        [machines addObject:@{@"name": name, @"path": path}];
    };
    for (NSString *name in [manager contentsOfDirectoryAtPath:library
                                                        error:nil]) {
        if ([name.pathExtension caseInsensitiveCompare:@"bundle"] !=
                NSOrderedSame)
            continue;
        NSString *path = [library stringByAppendingPathComponent:name];
        NSString *display = name.stringByDeletingPathExtension;
        append(path, display);
    }
#if defined(VZ_ROOTHIDE)
    NSString *legacy = VZLegacyLibraryPath();
    for (NSString *name in [manager contentsOfDirectoryAtPath:legacy error:nil]) {
        if ([name.pathExtension caseInsensitiveCompare:@"bundle"] == NSOrderedSame) {
            NSString *path = [legacy stringByAppendingPathComponent:name];
            if (VZIsValidVMBundle(path) &&
                ![seen containsObject:path.stringByResolvingSymlinksInPath])
                [machines addObject:@{@"name": name.stringByDeletingPathExtension,
                                      @"path": path, @"legacy": @YES}];
        }
    }
#endif
    [machines sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                       NSDictionary *right) {
        return [left[@"name"] localizedStandardCompare:right[@"name"]];
    }];
    return machines;
}

static UIImage *VZInstallerArtworkForImage(NSDictionary *image)
{
    NSString *name = [VZRestoreCatalog artworkNameForImage:image];
    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png"
                                               inDirectory:@"Installers"];
    return [UIImage imageWithContentsOfFile:path];
}

static BOOL VZVMNameIsOccupied(NSString *name)
{
    NSString *bundleName = [name stringByAppendingPathExtension:@"bundle"];
    NSString *installingName = [bundleName
        stringByAppendingPathExtension:@"installing"];
    NSArray *directories = @[VZVMLibraryPath()];
#if defined(VZ_ROOTHIDE)
    directories = [directories arrayByAddingObject:VZLegacyLibraryPath()];
#endif
    for (NSString *directory in directories) {
        for (NSString *entry in [NSFileManager.defaultManager
                contentsOfDirectoryAtPath:directory error:nil]) {
            if ([entry caseInsensitiveCompare:bundleName] == NSOrderedSame ||
                [entry caseInsensitiveCompare:installingName] == NSOrderedSame)
                return YES;
        }
    }
    return NO;
}

static NSString *VZUniqueVMName(NSString *requested)
{
    NSString *base = requested.length ? requested : @"macOS";
    if (!VZVMNameIsOccupied(base))
        return base;
    for (NSUInteger suffix = 2; suffix < NSUIntegerMax; suffix++) {
        NSString *candidate = [NSString stringWithFormat:@"%@ %lu", base,
            (unsigned long)suffix];
        if (!VZVMNameIsOccupied(candidate))
            return candidate;
    }
    return [base stringByAppendingFormat:@" %@", NSUUID.UUID.UUIDString];
}

static NSString *VZSanitizedVMName(NSString *requested)
{
    NSCharacterSet *invalid = [NSCharacterSet
        characterSetWithCharactersInString:@"/:\n\r"];
    NSString *name = [[[requested ?: @"" componentsSeparatedByCharactersInSet:
        invalid] componentsJoinedByString:@"-"]
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return name.length ? name : @"macOS";
}

static NSString *VZUniqueVMNameExcludingPath(NSString *requested,
                                              NSString *excludedPath)
{
    NSString *base = VZSanitizedVMName(requested);
    NSString *excluded = excludedPath.stringByStandardizingPath;
    for (NSUInteger suffix = 1; suffix < NSUIntegerMax; suffix++) {
        NSString *candidate = suffix == 1 ? base :
            [NSString stringWithFormat:@"%@ %lu", base,
             (unsigned long)suffix];
        NSString *path = [VZVMLibraryPath() stringByAppendingPathComponent:
            [candidate stringByAppendingPathExtension:@"bundle"]];
        if ([path.stringByStandardizingPath isEqualToString:excluded] ||
            ![NSFileManager.defaultManager fileExistsAtPath:path])
            return candidate;
    }
    return [base stringByAppendingFormat:@" %@", NSUUID.UUID.UUIDString];
}

NSArray<NSString *> *VZInstallationArtifactPaths(void)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *name in [manager
            contentsOfDirectoryAtPath:VZInstallationsPath() error:nil])
        [paths addObject:[VZInstallationsPath()
            stringByAppendingPathComponent:name]];

    return paths;
}

NSArray<NSString *> *VZCachedRestoreImagePaths(void)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray *paths = [NSMutableArray array];
    NSString *directory = VZRestoreImagesPath();
    for (NSString *name in [manager
            contentsOfDirectoryAtPath:directory error:nil])
        [paths addObject:[directory stringByAppendingPathComponent:name]];
    return paths;
}

void VZRemovePaths(NSArray<NSString *> *paths)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *path in paths) {
        NSError *error = nil;
        if ([manager removeItemAtPath:path error:&error])
            continue;
        // Restore helpers run as root and can leave diagnostics or staging
        // files that the UIKit process cannot unlink. The setuid launcher
        // accepts only descendants of the two artifact directories.
        const char *launcher =
            VZRuntimePath("install/install-launcher");
        char *arguments[] = {(char *)launcher, "--delete-artifact",
            (char *)path.fileSystemRepresentation, NULL};
        pid_t child = 0;
        int spawned = posix_spawn(&child, launcher, NULL, NULL,
                                  arguments, environ);
        int status = 0;
        if (spawned == 0)
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
        if (spawned != 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
            NSLog(@"Virtual Mac cleanup could not remove %@: %@", path, error);
    }
}

@interface VZVMConfigurationViewController : UITableViewController
    <UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate>
@property(nonatomic, copy) NSString *bundlePath;
@property(nonatomic, copy) NSString *vmName;
@property(nonatomic, assign) BOOL running;
@property(nonatomic, retain) NSMutableDictionary *options;
@property(nonatomic, retain) NSDictionary *originalOptions;
@property(nonatomic, copy) NSString *originalVMName;
@property(nonatomic, copy) void (^completion)(NSDictionary *options);
@property(nonatomic, copy) void (^deletion)(void);
@property(nonatomic, assign) BOOL showsExperimentalInstallWarning;
@property(nonatomic, assign) BOOL showsUnsupportedInstallWarning;
@property(nonatomic, copy) NSString *experimentalMacOSName;
@property(nonatomic, copy) void (^chooseDifferentVersionHandler)(void);
@property(nonatomic, retain) UIView *experimentalWarningHeader;
@property(nonatomic, assign) CGFloat lastConfigurationWidth;
@end

@implementation VZVMConfigurationViewController

- (instancetype)initWithBundlePath:(NSString *)bundlePath
                            options:(NSDictionary *)options
                         completion:(void (^)(NSDictionary *))completion
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.bundlePath = bundlePath;
        self.vmName = bundlePath.lastPathComponent.stringByDeletingPathExtension;
        self.options = [NSMutableDictionary dictionaryWithDictionary:options];
        self.completion = completion;
        self.title = bundlePath ? VZL(@"Virtual Mac") : VZL(@"New Virtual Mac");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.originalOptions = [NSDictionary dictionaryWithDictionary:self.options];
    self.originalVMName = self.vmName ?: @"";
    // A newly created VM is pushed from the version picker, so preserve the
    // navigation controller's normal Back button. Existing VM settings are
    // presented as the sheet root and retain Cancel.
    if (self.bundlePath) {
        self.navigationItem.leftBarButtonItem = [[[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self
            action:@selector(cancel:)] autorelease];
    }
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
        initWithTitle:self.bundlePath ? VZL(@"Save") : VZL(@"Continue")
        style:UIBarButtonItemStyleDone target:self action:@selector(done:)]
        autorelease];
    if (!self.bundlePath && self.showsExperimentalInstallWarning)
        [self installExperimentalWarningHeader];
}

- (void)installExperimentalWarningHeader
{
    UIView *header = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    header.backgroundColor = UIColor.clearColor;

    UIView *card = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 12.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    [header addSubview:card];

    UIImageView *icon = [[[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"exclamationmark.triangle.fill"]] autorelease];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = self.showsUnsupportedInstallWarning
        ? UIColor.systemRedColor : UIColor.systemYellowColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [card addSubview:icon];

    UILabel *title = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.textColor = UIColor.labelColor;
    title.numberOfLines = 0;
    NSString *macOSName = self.experimentalMacOSName ?: @"macOS";
    title.text = self.showsUnsupportedInstallWarning
        ? [NSString stringWithFormat:VZL(@"%@ is not supported"), macOSName]
        : [NSString stringWithFormat:
            VZL(@"Support for %@ is experimental"), macOSName];
    [card addSubview:title];

    UILabel *message = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    message.translatesAutoresizingMaskIntoConstraints = NO;
    message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    message.textColor = UIColor.secondaryLabelColor;
    message.numberOfLines = 0;
    if (self.showsUnsupportedInstallWarning) {
        NSString *appVersion = NSBundle.mainBundle.infoDictionary[
            @"CFBundleShortVersionString"] ?: @"";
        message.text = [NSString stringWithFormat:
            VZL(@"Virtual Mac %@ does not support %@. Check for updates in Sileo."),
            appVersion, macOSName];
    } else {
        message.text = [NSString stringWithFormat:
            VZL(@"%@ may encounter performance or graphical issues. For the best experience, use macOS Ventura, macOS Sonoma, or macOS Sequoia.\n\nIf transparency effects cause visual problems, turn on Reduce Transparency in System Settings > Accessibility > Display."),
            macOSName];
    }
    [card addSubview:message];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [button setTitle:VZL(@"Choose a Different Version")
             forState:UIControlStateNormal];
    [button addTarget:self action:@selector(chooseDifferentVersion:)
        forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:button];

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20.0],
        [card.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20.0],
        [card.topAnchor constraintEqualToAnchor:header.topAnchor constant:16.0],
        [card.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-8.0],
        [icon.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
        [icon.topAnchor constraintEqualToAnchor:card.topAnchor constant:16.0],
        [icon.widthAnchor constraintEqualToConstant:22.0],
        [icon.heightAnchor constraintEqualToConstant:22.0],
        [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10.0],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],
        [title.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
        [message.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
        [message.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],
        [message.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10.0],
        [button.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
        [button.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],
        [button.topAnchor constraintEqualToAnchor:message.bottomAnchor constant:8.0],
        [button.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-6.0],
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:44.0]
    ]];
    self.experimentalWarningHeader = header;
    self.tableView.tableHeaderView = header;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat tableWidth = CGRectGetWidth(self.tableView.bounds);
    BOOL widthChanged = self.lastConfigurationWidth > 0 &&
        fabs(tableWidth - self.lastConfigurationWidth) > 0.5;
    self.lastConfigurationWidth = tableWidth;
    if (widthChanged)
        [self.tableView reloadData];
    UIView *header = self.experimentalWarningHeader;
    if (!header)
        return;
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    if (width <= 0)
        return;
    header.bounds = CGRectMake(0, 0, width, CGRectGetHeight(header.bounds));
    CGFloat height = [header systemLayoutSizeFittingSize:
        CGSizeMake(width, UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired
        verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    if (fabs(CGRectGetHeight(header.frame) - height) > 0.5) {
        header.frame = CGRectMake(0, 0, width, height);
        self.tableView.tableHeaderView = header;
    }
}

- (void)chooseDifferentVersion:(id)sender
{
    (void)sender;
    if (self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    void (^handler)(void) = [[self.chooseDifferentVersionHandler copy]
        autorelease];
    [self dismissViewControllerAnimated:YES completion:handler];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    // The configuration can either be the sheet root or be pushed from the
    // creation flow. In both cases it owns the unsaved-change decision.
    self.navigationController.presentationController.delegate = self;
}

- (BOOL)hasUnsavedChanges
{
    return ![self.options isEqualToDictionary:self.originalOptions] ||
        ![(self.vmName ?: @"") isEqualToString:(self.originalVMName ?: @"")];
}

- (void)confirmDiscardChanges
{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:VZL(@"Discard Changes?")
        message:VZL(@"Your changes to this Virtual Mac will not be saved.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Keep Editing")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Discard Changes")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        self.navigationController.presentationController.delegate = nil;
        [self dismissViewControllerAnimated:YES completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)presentationControllerShouldDismiss:(UIPresentationController *)controller
{
    (void)controller;
    return ![self hasUnsavedChanges];
}

- (void)presentationControllerDidAttemptToDismiss:
    (UIPresentationController *)controller
{
    (void)controller;
    [self confirmDiscardChanges];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 7;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section
{
    if (section == 0)
        return 1 + (self.bundlePath ? 2 : 3);
    if (section == 1)
        return 1 + [self.options[VZSharedDirectoriesKey] count];
    if (section == 2)
        return self.bundlePath ? 4 : 3;
    if (section == 3)
        return 3;
    if (section == 4)
        return [VZDisplaySelectionForOptions(self.options)
                   isEqualToString:@"Custom"]
            ? 4 : 1;
    if (section == 5)
        return 5;
    return self.bundlePath && self.running ? 0 : 1;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section
{
    if (section == 6)
        return nil;
    return @[VZL(@"Resources"), VZL(@"Shared Folders"),
             self.bundlePath ? VZL(@"Boot and Network") : VZL(@"Network"),
             VZL(@"Input"), VZL(@"Display"),
             VZL(@"Audio and Acceleration")][section];
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 0 && !self.bundlePath)
        return VZL(@"Storage size can’t be changed later. If you need additional storage in the future, set a larger size now.");
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"v"];
    if (!cell)
        cell = [[[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"v"]
            autorelease];
    // Every section shares this reuse identifier. Clear all state that a
    // switch-backed row can leave behind before configuring the new row.
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.textLabel.textAlignment = NSTextAlignmentNatural;
    cell.imageView.image = nil;
    cell.userInteractionEnabled = YES;
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = VZL(@"Name");
            cell.detailTextLabel.text = self.vmName;
            if (self.running) {
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                cell.textLabel.textColor = UIColor.secondaryLabelColor;
            }
            return cell;
        }
        NSInteger resourceIndex = indexPath.row - 1;
        NSArray *names = self.bundlePath ? @[VZL(@"Processors"), VZL(@"Memory")]
                                         : @[VZL(@"Processors"), VZL(@"Memory"), VZL(@"Storage")];
        NSString *key = @[VZCPUCountKey, VZMemorySizeKey,
                           VZStorageSizeKey][resourceIndex];
        cell.textLabel.text = names[resourceIndex];
        uint64_t value = [self.options[key] unsignedLongLongValue];
        cell.detailTextLabel.text = resourceIndex == 0
            ? [NSString stringWithFormat:@"%llu", value]
            : [NSString stringWithFormat:@"%llu GB", value >> 30];
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = VZL(@"Add Shared Folder");
            cell.detailTextLabel.text = nil;
        } else {
            NSDictionary *share = self.options[VZSharedDirectoriesKey]
                [indexPath.row - 1];
            NSString *path = share[@"Path"];
            NSString *name = path.lastPathComponent;
            NSArray<NSString *> *components = path.pathComponents;
            if (components.count >= 2 &&
                [components.lastObject isEqualToString:@"Downloads"] &&
                [components[components.count - 2]
                    isEqualToString:@"File Provider Storage"])
                name = VZL(@"Downloads");
            else if ([name isEqualToString:@"File Provider Storage"])
                name = VZDeviceString(VZL(@"On My iPad"),
                                      VZL(@"On My iPhone"));
            cell.textLabel.text = name;
            cell.detailTextLabel.text = [share[@"ReadOnly"] boolValue]
                ? VZL(@"Read Only") : VZL(@"Read & Write");
        }
    } else if (indexPath.section == 2 && self.bundlePath &&
               indexPath.row == 0) {
        cell.textLabel.text = VZL(@"Start in Recovery");
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        toggle.on = [self.options[VZBootRecoveryKey] boolValue];
        [toggle addTarget:self action:@selector(recoveryChanged:)
         forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.detailTextLabel.text = nil;
    } else if (indexPath.section == 2 &&
               indexPath.row == (self.bundlePath ? 1 : 0)) {
        cell.textLabel.text = VZL(@"Virtual Mac Guest Tools");
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        toggle.on = [self.options[VZVirtualMacGuestToolsEnabledKey] boolValue];
        [toggle addTarget:self action:@selector(guestToolsChanged:)
           forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.detailTextLabel.text = nil;
    } else if (indexPath.section == 2 &&
               indexPath.row == (self.bundlePath ? 2 : 1)) {
        cell.textLabel.text = VZL(@"Network");
        NSString *mode = VZEffectiveNetworkMode(self.options);
        NSString *interface = self.options[VZBridgeInterfaceKey];
        cell.detailTextLabel.text = [mode isEqualToString:@"Bridge"]
            ? [NSString stringWithFormat:VZL(@"Bridge via %@"),
                VZInterfaceDisplayName(interface)]
            : [mode isEqualToString:@"NAT"]
                ? [NSString stringWithFormat:VZL(@"Shared via %@"),
                    VZActiveInternetDisplayName()]
                : [mode isEqualToString:@"Disabled"] ? VZL(@"Disabled")
                                                      : mode;
    } else if (indexPath.section == 2) {
        cell.textLabel.text = VZL(@"MAC Address");
        cell.detailTextLabel.text = self.options[VZMACAddressKey];
    } else if (indexPath.section == 3 && indexPath.row == 0) {
        cell.textLabel.text = VZL(@"Keyboard");
        cell.detailTextLabel.text =
            [self.options[VZKeyboardDeviceKey] isEqualToString:@"USBKeyboard"]
            ? VZL(@"USB Keyboard") : VZL(@"Mac Keyboard");
    } else if (indexPath.section == 3 && indexPath.row == 1) {
        cell.textLabel.text = VZL(@"Pointing Device");
        cell.detailTextLabel.text =
            [self.options[VZPointingDeviceKey] isEqualToString:@"USBMouse"]
            ? VZL(@"USB Mouse") : VZL(@"Mac Trackpad");
    } else if (indexPath.section == 3) {
        NSString *fullTitle = VZL(@"Apple Pencil Pressure and Tilt");
        CGFloat available = MAX(CGRectGetWidth(tableView.bounds) - 147.0,
                                80.0);
        CGFloat needed = [fullTitle sizeWithAttributes:@{
            NSFontAttributeName: cell.textLabel.font}].width;
        cell.textLabel.text = needed <= available
            ? fullTitle : VZL(@"Apple Pencil Pressure");
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        toggle.on = [self.options[VZApplePencilPressureTiltEnabledKey]
            boolValue];
        [toggle addTarget:self action:@selector(pencilRelayChanged:)
           forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.detailTextLabel.text = nil;
    } else if (indexPath.section == 4 && indexPath.row == 0) {
        cell.textLabel.text = VZL(@"Resolution");
        cell.detailTextLabel.text = VZDisplaySelectionTitle(self.options);
    } else if (indexPath.section == 4) {
        NSArray *names = @[VZL(@"Width"), VZL(@"Height"), VZL(@"Pixels Per Inch")];
        NSArray *keys = @[VZDisplayWidthKey, VZDisplayHeightKey,
                          VZDisplayPPIKey];
        cell.textLabel.text = names[indexPath.row - 1];
        cell.detailTextLabel.text = [self.options[keys[indexPath.row - 1]]
            stringValue];
    } else if (indexPath.section == 5) {
        NSArray *names = @[VZL(@"Audio Output"), VZL(@"Microphone Input"),
                           VZL(@"Metal BC Support"),
                           VZL(@"OpenGL Acceleration"),
                           VZL(@"Video Encoding and Decoding Acceleration")];
        NSArray *keys = @[VZAudioOutputEnabledKey, VZAudioInputEnabledKey,
                          VZMetalBCSupportEnabledKey,
                          VZOpenGLAccelerationEnabledKey,
                          VZVideoToolboxEnabledKey];
        cell.textLabel.text = names[indexPath.row];
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        BOOL guestTools = [self.options[VZVirtualMacGuestToolsEnabledKey]
            boolValue];
        BOOL isOpenGL = indexPath.row == 3;
        toggle.on = [self.options[keys[indexPath.row]] boolValue] &&
            (!isOpenGL || guestTools);
        toggle.enabled = YES;
        toggle.tag = indexPath.row;
        [toggle addTarget:self action:@selector(deviceToggleChanged:)
           forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.detailTextLabel.text = nil;
    } else if (!self.bundlePath) {
        cell.textLabel.text = VZL(@"Continue");
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = UIColor.systemBlueColor;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        cell.textLabel.text = VZL(@"Delete Virtual Mac");
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = UIColor.systemRedColor;
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    return cell;
}

- (void)chooseTitle:(NSString *)title message:(NSString *)message
            choices:(NSArray<NSDictionary *> *)choices key:(NSString *)key
           fromCell:(UITableViewCell *)cell
{
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:title message:message
                  preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *choice in choices) {
        [sheet addAction:[UIAlertAction actionWithTitle:choice[@"title"]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            self.options[key] = choice[@"value"];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = cell;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)chooseDisplayResolutionFromCell:(UITableViewCell *)cell
{
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:VZL(@"Display Resolution") message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *dynamicChoices = @[
        @{@"title": VZL(@"Full Screen"), @"mode": @"FullScreen"},
        @{@"title": VZL(@"Window Size"),
          @"mode": @"WindowSizeAtStartup"},
        @{@"title": VZDeviceString(VZL(@"Landscape iPad"),
                                    VZL(@"Landscape iPhone")),
          @"mode": @"LandscapeNativeRetina"},
        @{@"title": VZDeviceString(VZL(@"Portrait iPad"),
                                    VZL(@"Portrait iPhone")),
          @"mode": @"PortraitNativeRetina"},
        @{@"title": VZL(@"External Display"),
          @"mode": @"ExternalDisplay"},
    ];
    for (NSDictionary *choice in dynamicChoices) {
        [sheet addAction:[UIAlertAction actionWithTitle:choice[@"title"]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            self.options[VZDisplayModeKey] = choice[@"mode"];
            [self.tableView reloadData];
        }]];
    }
    for (NSDictionary *preset in VZFixedDisplayPresets()) {
        [sheet addAction:[UIAlertAction actionWithTitle:preset[@"title"]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            self.options[VZDisplayModeKey] = @"Fixed";
            self.options[VZDisplayWidthKey] = preset[@"width"];
            self.options[VZDisplayHeightKey] = preset[@"height"];
            self.options[VZDisplayPPIKey] = preset[@"ppi"];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:VZL(@"Custom")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        // If the stored tuple exactly identifies a preset, change only its
        // density to the established custom default so the editable fields
        // become visible. Otherwise preserve the user's custom dimensions.
        if (VZFixedDisplayPresetForOptions(self.options))
            self.options[VZDisplayPPIKey] = @264;
        self.options[VZDisplayModeKey] = @"Custom";
        [self.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)editMACAddress
{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:VZL(@"MAC Address")
                         message:VZL(@"Enter six hexadecimal octets separated by colons.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = self.options[VZMACAddressKey];
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSString *value = alert.textFields.firstObject.text.lowercaseString;
        NSRegularExpression *pattern = [NSRegularExpression
            regularExpressionWithPattern:@"^([0-9a-f]{2}:){5}[0-9a-f]{2}$"
                                  options:0 error:nil];
        if ([pattern numberOfMatchesInString:value options:0
                                       range:NSMakeRange(0, value.length)] == 1)
            self.options[VZMACAddressKey] = value;
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editNumberForKey:(NSString *)key title:(NSString *)title
                      min:(uint64_t)minimum max:(uint64_t)maximum
                    bytes:(BOOL)bytes
{
    NSString *range;
    if ([key isEqualToString:VZCPUCountKey]) {
        NSUInteger recommendation = MIN((uint64_t)4, maximum);
        range = [NSString stringWithFormat:VZDeviceString(
            VZL(@"You can assign between %llu and %llu processor cores to this Virtual Mac, with %lu processor cores as the recommendation.\n\nMaxing out processor core assignment does not guarantee improved performance in Virtual Mac, as iPadOS also needs processor power to coordinate underlying tasks."),
            VZL(@"You can assign between %llu and %llu processor cores to this Virtual Mac, with %lu processor cores as the recommendation.\n\nMaxing out processor core assignment does not guarantee improved performance in Virtual Mac, as iOS also needs processor power to coordinate underlying tasks.")),
            minimum, maximum, (unsigned long)recommendation];
    } else if ([key isEqualToString:VZMemorySizeKey]) {
        uint64_t recommendation = MIN(VZDefaultMemorySize(), maximum) >> 30;
        range = [NSString stringWithFormat:VZDeviceString(
            VZL(@"You can assign between %llu and %llu GB of memory to this Virtual Mac, with %llu GB as the recommendation. The remaining memory is used for graphics processing and iPadOS.\n\nMaxing out memory assignment does not guarantee improved performance in Virtual Mac, and may degrade graphics performance and system stability."),
            VZL(@"You can assign between %llu and %llu GB of memory to this Virtual Mac, with %llu GB as the recommendation. The remaining memory is used for graphics processing and iOS.\n\nMaxing out memory assignment does not guarantee improved performance in Virtual Mac, and may degrade graphics performance and system stability.")),
            minimum >> 30, maximum >> 30, recommendation];
    } else {
        range = maximum
            ? [NSString stringWithFormat:VZL(@"Allowed: %llu–%llu%@"),
                bytes ? minimum >> 30 : minimum,
                bytes ? maximum >> 30 : maximum, bytes ? @" GB" : @""]
            : [NSString stringWithFormat:
                VZL(@"Minimum: %llu GB. The upper limit is determined by the filesystem."),
                minimum >> 30];
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:range
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        uint64_t value = [self.options[key] unsignedLongLongValue];
        field.text = [NSString stringWithFormat:@"%llu",
                      bytes ? value >> 30 : value];
        field.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        uint64_t entered = strtoull(
            alert.textFields.firstObject.text.UTF8String, NULL, 10);
        uint64_t value = entered;
        if (bytes) {
            uint64_t maximumGiB = (uint64_t)LLONG_MAX >> 30;
            value = entered > maximumGiB ? (uint64_t)LLONG_MAX : GiB(entered);
        }
        value = MAX(minimum, maximum ? MIN(maximum, value) : value);
        self.options[key] = @(value);
        [self.tableView reloadData];
        if ([key isEqualToString:VZStorageSizeKey] &&
            value > VZAvailableStorageSize()) {
            uint64_t available = VZAvailableStorageSize() >> 30;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         250 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                UIAlertController *warning = [UIAlertController
                    alertControllerWithTitle:VZL(@"Disk Exceeds Available Storage")
                    message:[NSString stringWithFormat:
                        VZL(@"Only about %llu GB is currently available. The disk image is sparse, but installation or later use can fail when storage fills up."),
                        available]
                    preferredStyle:UIAlertControllerStyleAlert];
                [warning addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
                    style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:warning animated:YES completion:nil];
            });
        }
    }]];
    [self presentViewController:alert animated:YES completion:^{
        UITextField *field = alert.textFields.firstObject;
        [field selectAll:nil];
        [field becomeFirstResponder];
    }];
}

- (void)editVMName
{
    if (self.running)
        return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:VZL(@"Name")
                         message:VZL(@"Choose a name for this Virtual Mac.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = self.vmName;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        self.vmName = VZUniqueVMNameExcludingPath(
            alert.textFields.firstObject.text, self.bundlePath);
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:^{
        [alert.textFields.firstObject selectAll:nil];
        [alert.textFields.firstObject becomeFirstResponder];
    }];
}

- (void)confirmDeleteVirtualMac
{
    if (!self.bundlePath.length || self.running)
        return;
    NSString *name = self.vmName.length ? self.vmName : VZL(@"this Virtual Mac");
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:VZL(@"Delete Virtual Mac?")
                         message:[NSString stringWithFormat:
                            VZL(@"“%@” and all files stored in it will be permanently deleted."),
                            name]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Delete")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        NSString *path = [[self.bundlePath copy] autorelease];
        VZRemovePaths(@[path]);
        if ([[VZAppSettings.sharedSettings stringForKey:VZAutoBootVMPathKey]
                isEqualToString:path]) {
            [VZAppSettings.sharedSettings setString:nil
                forKey:VZAutoBootVMPathKey];
            [VZAppSettings.sharedSettings setString:nil
                forKey:VZAutoBootVMIdentifierKey];
        }
        void (^deletion)(void) = [[self.deletion copy] autorelease];
        [self dismissViewControllerAnimated:YES completion:^{
            if (deletion) deletion();
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            [self editVMName];
            return;
        }
        NSInteger resourceIndex = indexPath.row - 1;
        if (resourceIndex == 0) {
            NSUInteger maxCPU = MAX((NSUInteger)2,
                MIN((NSUInteger)8, NSProcessInfo.processInfo.activeProcessorCount));
            [self editNumberForKey:VZCPUCountKey title:VZL(@"Processors")
                              min:2 max:maxCPU bytes:NO];
        } else if (resourceIndex == 1) {
            [self editNumberForKey:VZMemorySizeKey title:VZL(@"Memory")
                              min:GiB(2) max:VZDeviceMemoryLimit() bytes:YES];
        } else if (resourceIndex == 2) {
            [self editNumberForKey:VZStorageSizeKey title:VZL(@"Storage")
                              min:GiB(32) max:0 bytes:YES];
        }
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            UIDocumentPickerViewController *picker =
                [[[UIDocumentPickerViewController alloc]
                    initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO]
                    autorelease];
            picker.delegate = self;
            [self presentViewController:picker animated:YES completion:nil];
        } else {
            NSInteger shareIndex = indexPath.row - 1;
            NSDictionary *saved =
                self.options[VZSharedDirectoriesKey][shareIndex];
            NSString *path = saved[@"Path"];
            UIAlertController *sheet = [UIAlertController
                alertControllerWithTitle:path.lastPathComponent message:path
                    preferredStyle:UIAlertControllerStyleActionSheet];
            for (NSNumber *readOnly in @[@NO, @YES]) {
                NSString *title = readOnly.boolValue
                    ? VZL(@"Read Only") : VZL(@"Read & Write");
                [sheet addAction:[UIAlertAction actionWithTitle:title
                    style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *action) {
                    (void)action;
                    NSMutableArray *shares = [NSMutableArray arrayWithArray:
                        self.options[VZSharedDirectoriesKey]];
                    shares[shareIndex] =
                        @{@"Path": path, @"ReadOnly": readOnly};
                    self.options[VZSharedDirectoriesKey] = shares;
                    [self.tableView reloadData];
                }]];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:VZL(@"Remove")
                style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *action) {
                (void)action;
                NSMutableArray *shares = [NSMutableArray arrayWithArray:
                    self.options[VZSharedDirectoriesKey]];
                [shares removeObjectAtIndex:shareIndex];
                self.options[VZSharedDirectoriesKey] = shares;
                [self.tableView reloadData];
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
                style:UIAlertActionStyleCancel handler:nil]];
            sheet.popoverPresentationController.sourceView =
                [tableView cellForRowAtIndexPath:indexPath];
            [self presentViewController:sheet animated:YES completion:nil];
        }
    } else if (indexPath.section == 2 &&
               indexPath.row == (self.bundlePath ? 2 : 1)) {
        UIAlertController *sheet = [UIAlertController
            alertControllerWithTitle:VZL(@"Network Attachment") message:nil
                      preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSString *mode in @[@"NAT", @"Disabled"]) {
            NSString *title = [mode isEqualToString:@"NAT"]
                ? [NSString stringWithFormat:VZL(@"NAT: Share %@"),
                    VZActiveInternetDisplayName()] : VZL(@"Disabled");
            [sheet addAction:[UIAlertAction actionWithTitle:title
                style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                (void)action;
                self.options[VZNetworkModeKey] = mode;
                [self.tableView reloadData];
            }]];
        }
        for (NSString *interface in VZBridgeInterfaceNames()) {
            NSString *title = [NSString stringWithFormat:VZL(@"Bridge: %@"),
                VZInterfaceDisplayName(interface)];
            [sheet addAction:[UIAlertAction actionWithTitle:title
                style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                (void)action;
                self.options[VZNetworkModeKey] = @"Bridge";
                self.options[VZBridgeInterfaceKey] = interface;
                [self.tableView reloadData];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
            style:UIAlertActionStyleCancel handler:nil]];
        sheet.popoverPresentationController.sourceView =
            [tableView cellForRowAtIndexPath:indexPath];
        [self presentViewController:sheet animated:YES completion:nil];
    } else if (indexPath.section == 2 &&
               indexPath.row == (self.bundlePath ? 3 : 2)) {
        [self editMACAddress];
    } else if (indexPath.section == 3 && indexPath.row == 0) {
        [self chooseTitle:VZL(@"Keyboard") message:
            VZL(@"Use USB Keyboard for macOS Monterey. Newer guests support the Mac keyboard device.")
            choices:@[
                @{@"title": VZL(@"Mac Keyboard"), @"value": @"MacKeyboard"},
                @{@"title": VZL(@"USB Keyboard"), @"value": @"USBKeyboard"},
            ] key:VZKeyboardDeviceKey
            fromCell:[tableView cellForRowAtIndexPath:indexPath]];
    } else if (indexPath.section == 3 && indexPath.row == 1) {
        [self chooseTitle:VZL(@"Pointing Device") message:
            VZL(@"Use USB Mouse for macOS Monterey. Newer guests support the Mac trackpad device.")
            choices:@[
            @{@"title": VZL(@"Mac Trackpad"), @"value": @"MacTrackpad"},
            @{@"title": VZL(@"USB Mouse"), @"value": @"USBMouse"},
            ] key:VZPointingDeviceKey
            fromCell:[tableView cellForRowAtIndexPath:indexPath]];
    } else if (indexPath.section == 4 && indexPath.row == 0) {
        [self chooseDisplayResolutionFromCell:
            [tableView cellForRowAtIndexPath:indexPath]];
    } else if (indexPath.section == 4 && indexPath.row > 0) {
        NSArray *keys = @[VZDisplayWidthKey, VZDisplayHeightKey,
                          VZDisplayPPIKey];
        NSArray *titles = @[VZL(@"Display Width"), VZL(@"Display Height"),
                            VZL(@"Pixels Per Inch")];
        uint64_t minimum = indexPath.row == 3 ? 72 : 800;
        uint64_t maximum = indexPath.row == 3 ? 600 : 7680;
        [self editNumberForKey:keys[indexPath.row - 1]
                         title:titles[indexPath.row - 1]
                           min:minimum max:maximum bytes:NO];
    } else if (indexPath.section == 6) {
        if (self.bundlePath)
            [self confirmDeleteVirtualMac];
        else
            [self done:nil];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (!url)
        return;
    [url startAccessingSecurityScopedResource];
    NSMutableArray *shares = [NSMutableArray arrayWithArray:
        self.options[VZSharedDirectoriesKey]];
    [shares addObject:@{@"Path": url.path, @"ReadOnly": @NO}];
    self.options[VZSharedDirectoriesKey] = shares;
    [self.tableView reloadData];
}

- (void)recoveryChanged:(UISwitch *)sender
{
    self.options[VZBootRecoveryKey] = @(sender.on);
}

- (UISwitch *)switchForSection:(NSInteger)section row:(NSInteger)row
{
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row
                                                inSection:section];
    UIView *accessory = [self.tableView cellForRowAtIndexPath:indexPath]
        .accessoryView;
    return [accessory isKindOfClass:UISwitch.class]
        ? (UISwitch *)accessory : nil;
}

- (void)setGuestToolsSwitchOn:(BOOL)guestToolsOn
                    openGLOn:(BOOL)openGLOn
                     animated:(BOOL)animated
{
    NSInteger guestToolsRow = self.bundlePath ? 1 : 0;
    [[self switchForSection:2 row:guestToolsRow]
        setOn:guestToolsOn animated:animated];
    [[self switchForSection:5 row:3]
        setOn:openGLOn animated:animated];
}

- (void)guestToolsChanged:(UISwitch *)sender
{
    if (sender.on || ![self.options[VZOpenGLAccelerationEnabledKey] boolValue]) {
        self.options[VZVirtualMacGuestToolsEnabledKey] = @(sender.on);
        self.options[VZGuestToolsRemovalPendingKey] = @(!sender.on);
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:5]
                      withRowAnimation:UITableViewRowAnimationNone];
        return;
    }
    // Keep the model unchanged until the dependency change is confirmed, but
    // leave both controls in the state the user requested while the alert is
    // visible. Cancel animates the pair back together.
    [self setGuestToolsSwitchOn:NO openGLOn:NO animated:YES];
    NSString *dependencyMessage = VZL(@"Because OpenGL acceleration requires Virtual Mac guest tools, turning off Virtual Mac guest tools will also turn off OpenGL acceleration. Apps such as Final Cut Pro mostly use Metal, but they check for OpenGL capabilities in order to launch.");
    for (NSString *boundary in @[@". ", @"。", @"।"]) {
        NSRange range = [dependencyMessage rangeOfString:boundary];
        if (range.location == NSNotFound)
            continue;
        NSString *prefix = [dependencyMessage substringToIndex:
            NSMaxRange(range) - ([boundary hasSuffix:@" "] ? 1 : 0)];
        NSString *suffix = [dependencyMessage substringFromIndex:
            NSMaxRange(range)];
        dependencyMessage = [NSString stringWithFormat:@"%@\n\n%@",
            prefix, suffix];
        break;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:VZL(@"Turn Off Virtual Mac Guest Tools?")
        message:dependencyMessage
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        (void)action;
        [self setGuestToolsSwitchOn:YES openGLOn:YES animated:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        self.options[VZVirtualMacGuestToolsEnabledKey] = @NO;
        self.options[VZGuestToolsRemovalPendingKey] = @YES;
        [self setGuestToolsSwitchOn:NO openGLOn:NO animated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)deviceToggleChanged:(UISwitch *)sender
{
    NSArray *keys = @[VZAudioOutputEnabledKey, VZAudioInputEnabledKey,
                      VZMetalBCSupportEnabledKey,
                      VZOpenGLAccelerationEnabledKey,
                      VZVideoToolboxEnabledKey];
    if (sender.tag >= (NSInteger)keys.count)
        return;
    if (sender.tag == 3 && sender.on &&
        ![self.options[VZVirtualMacGuestToolsEnabledKey] boolValue]) {
        self.options[VZVirtualMacGuestToolsEnabledKey] = @YES;
        self.options[VZGuestToolsRemovalPendingKey] = @NO;
        [self setGuestToolsSwitchOn:YES openGLOn:YES animated:YES];
    }
    self.options[keys[sender.tag]] = @(sender.on);
}

- (void)pencilRelayChanged:(UISwitch *)sender
{
    self.options[VZApplePencilPressureTiltEnabledKey] = @(sender.on);
    if (!sender.on)
        return;

    NSString *name = VZSanitizedVMName(self.vmName);
    NSString *message = [NSString stringWithFormat:
        VZL(@"To use Apple Pencil pressure and tilt, download pencil-probe in %@ Virtual Mac."),
        name];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:VZL(@"Apple Pencil Pressure and Tilt")
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Learn More")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSURL *url = [NSURL URLWithString:
            @"https://github.com/ma-syu/pencil-probe"];
        [UIApplication.sharedApplication openURL:url options:@{}
            completionHandler:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)done:(id)sender
{
    (void)sender;
    if (!VZHostSupportsBridgedNetworking() &&
        [self.options[VZNetworkModeKey] isEqualToString:@"Bridge"])
        self.options[VZNetworkModeKey] = @"NAT";
    if (self.bundlePath) {
        NSError *error = nil;
        NSString *newName = VZUniqueVMNameExcludingPath(
            self.vmName, self.bundlePath);
        NSString *oldName = self.bundlePath.lastPathComponent
            .stringByDeletingPathExtension;
        if (!self.running && ![newName isEqualToString:oldName]) {
            NSString *destination = [VZVMLibraryPath()
                stringByAppendingPathComponent:
                    [newName stringByAppendingPathExtension:@"bundle"]];
            if (![NSFileManager.defaultManager moveItemAtPath:self.bundlePath
                toPath:destination error:&error]) {
                VZPresentFailureReport(self,
                    VZL(@"Could Not Rename Virtual Mac"),
                    error.localizedDescription, error.debugDescription,
                    VZFailureSupportOptionNone);
                return;
            }
            NSString *autoBoot = [VZAppSettings.sharedSettings
                stringForKey:VZAutoBootVMPathKey];
            if ([autoBoot isEqualToString:self.bundlePath])
                [VZAppSettings.sharedSettings setString:destination
                    forKey:VZAutoBootVMPathKey];
            self.bundlePath = destination;
            self.vmName = newName;
        }
        if (!VZWriteVMOptions(self.options, self.bundlePath, &error)) {
            VZPresentFailureReport(self, VZL(@"Could Not Save"),
                error.localizedDescription, error.debugDescription,
                VZFailureSupportOptionNone);
            return;
        }
    }
    void (^completion)(NSDictionary *) = [[self.completion copy] autorelease];
    NSMutableDictionary *result = [NSMutableDictionary
        dictionaryWithDictionary:self.options];
    result[VZVMNameKey] = VZSanitizedVMName(self.vmName);
    NSDictionary *options = [[result copy] autorelease];
    [self dismissViewControllerAnimated:YES completion:^{
        if (completion)
            completion(options);
    }];
}

- (void)cancel:(id)sender
{
    (void)sender;
    if (![self hasUnsavedChanges]) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    [self confirmDiscardChanges];
}

- (void)dealloc
{
    [_bundlePath release];
    [_vmName release];
    [_options release];
    [_originalOptions release];
    [_originalVMName release];
    [_completion release];
    [_deletion release];
    [_experimentalMacOSName release];
    [_chooseDifferentVersionHandler release];
    [_experimentalWarningHeader release];
    [super dealloc];
}
@end

static const CGFloat VZLibraryHorizontalInset = 24.0;

@interface VZLibraryControlsView : UIView
@property(nonatomic, retain) UISearchBar *searchBar;
@property(nonatomic, retain) UISegmentedControl *layoutControl;
@property(nonatomic, retain) NSLayoutConstraint *searchLeadingConstraint;
@property(nonatomic, assign) BOOL alignmentPassScheduled;
@end

@implementation VZLibraryControlsView
- (void)scheduleAlignmentPass
{
    if (!self.window || self.alignmentPassScheduled)
        return;
    self.alignmentPassScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.alignmentPassScheduled = NO;
        [self setNeedsLayout];
    });
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    // Perform one settled-frame pass after the controls join the window.
    [self scheduleAlignmentPass];
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.searchBar = [[[UISearchBar alloc] initWithFrame:CGRectZero]
            autorelease];
        self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
        self.searchBar.placeholder = VZL(@"Search Virtual Mac");
        self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
        [self addSubview:self.searchBar];
        self.layoutControl = [[[UISegmentedControl alloc] initWithItems:@[
            [UIImage systemImageNamed:@"square.grid.2x2"],
            [UIImage systemImageNamed:@"list.bullet"]]] autorelease];
        self.layoutControl.translatesAutoresizingMaskIntoConstraints = NO;
        self.layoutControl.accessibilityLabel = VZL(@"Library Appearance");
        [self addSubview:self.layoutControl];
        self.searchLeadingConstraint = [self.searchBar.leadingAnchor
            constraintEqualToAnchor:self.leadingAnchor
            constant:VZLibraryHorizontalInset];
        [NSLayoutConstraint activateConstraints:@[
            self.searchLeadingConstraint,
            [self.searchBar.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
            [self.searchBar.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
            [self.layoutControl.leadingAnchor constraintEqualToAnchor:
                self.searchBar.trailingAnchor constant:12],
            [self.layoutControl.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                constant:-VZLibraryHorizontalInset],
            [self.layoutControl.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.layoutControl.widthAnchor constraintEqualToConstant:112],
        ]];
    }
    return self;
}
- (void)layoutSubviews
{
    [super layoutSubviews];
    self.searchBar.placeholder = CGRectGetWidth(self.bounds) < 500
        ? VZL(@"Search") : VZL(@"Search Virtual Mac");
    UITextField *field = self.searchBar.searchTextField;
    CGRect fieldFrame = [field convertRect:field.bounds toView:self];
    if (fieldFrame.size.width > 0) {
        // Align the rendered field, rather than UISearchBar's outer bounds,
        // with the first library card.
        CGFloat targetX = VZLibraryHorizontalInset;
        CGFloat adjustment = targetX - CGRectGetMinX(fieldFrame);
        if (ABS(adjustment) > 0.5) {
            self.searchLeadingConstraint.constant += adjustment;
            [self scheduleAlignmentPass];
        }
    }
}
- (void)dealloc
{
    [_searchBar release];
    [_layoutControl release];
    [_searchLeadingConstraint release];
    [super dealloc];
}
@end

@interface VZVMLibraryViewController () <UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout, UISearchBarDelegate,
    VZNewVMViewControllerDelegate>
@property(nonatomic, retain) NSArray *machines;
@property(nonatomic, retain) NSArray *filteredMachines;
@property(nonatomic, copy) NSString *searchText;
@property(nonatomic, retain) NSURL *pendingIPSWURL;
@property(nonatomic, retain) VZLibraryControlsView *controlsView;
@property(nonatomic, retain) UICollectionView *collectionView;
@property(nonatomic, retain) UIView *emptyView;
@property(nonatomic, retain) UIView *noResultsView;
@property(nonatomic, retain) NSLayoutConstraint *noResultsBottomConstraint;
@property(nonatomic, assign) CGFloat lastCollectionWidth;
@property(nonatomic, retain) NSURLSessionDownloadTask *downloadTask;
@property(nonatomic, retain) NSTimer *downloadTimer;
@property(nonatomic, retain) VZProgressViewController *downloadController;
@property(nonatomic, retain) VZProgressViewController *restoreCopyController;
@property(nonatomic, copy) NSString *downloadDestination;
@property(nonatomic, copy) NSString *downloadMarkerPath;
@property(nonatomic, assign) int64_t downloadLastBytes;
@property(nonatomic, retain) NSDate *downloadLastSample;
@property(nonatomic, retain) NSDate *downloadStartedAt;
@property(nonatomic, assign) BOOL downloadCancelled;
@property(nonatomic, assign) BOOL didCheckInterruptedDownloads;
@end

@implementation VZVMLibraryViewController

- (void)showSettings:(UIBarButtonItem *)sender
{
    (void)sender;
    VZSettingsViewController *settings = [[[VZSettingsViewController alloc]
        initWithMachines:self.machines] autorelease];
    UINavigationController *navigation = [[[UINavigationController alloc]
        initWithRootViewController:settings] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    navigation.preferredContentSize = CGSizeMake(620, 720);
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)presentSettings
{
    [self showSettings:nil];
}

- (void)presentConfiguration:(VZVMConfigurationViewController *)configuration
{
    UINavigationController *navigation = [[[UINavigationController alloc]
        initWithRootViewController:configuration] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.preferredContentSize = CGSizeMake(620, 760);
    [self presentViewController:navigation animated:YES completion:nil];
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.title = VZL(@"Virtual Mac");
        self.navigationItem.leftBarButtonItem = [[[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"gearshape"]
            style:UIBarButtonItemStylePlain target:self
            action:@selector(showSettings:)] autorelease];
        self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self
            action:@selector(addVM:)] autorelease];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UICollectionViewFlowLayout *layout = [[[UICollectionViewFlowLayout alloc] init] autorelease];
    layout.sectionInset = UIEdgeInsetsMake(22, VZLibraryHorizontalInset,
                                           30, VZLibraryHorizontalInset);
    layout.minimumInteritemSpacing = 18;
    layout.minimumLineSpacing = 18;
    self.collectionView = [[[UICollectionView alloc] initWithFrame:self.view.bounds
        collectionViewLayout:layout] autorelease];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.backgroundColor = UIColor.systemBackgroundColor;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:UICollectionViewCell.class
        forCellWithReuseIdentifier:@"item"];
    UIRefreshControl *refresh = [[[UIRefreshControl alloc] init] autorelease];
    [refresh addTarget:self action:@selector(reloadLibrary)
        forControlEvents:UIControlEventValueChanged];
    self.collectionView.refreshControl = refresh;
    [self.view addSubview:self.collectionView];
    self.controlsView = [[[VZLibraryControlsView alloc] initWithFrame:CGRectZero]
        autorelease];
    self.controlsView.translatesAutoresizingMaskIntoConstraints = NO;
    self.controlsView.searchBar.delegate = self;
    self.controlsView.searchBar.text = self.searchText;
    self.controlsView.layoutControl.selectedSegmentIndex =
        [[VZAppSettings.sharedSettings stringForKey:VZLibraryLayoutKey]
            isEqualToString:@"list"] ? 1 : 0;
    [self.controlsView.layoutControl addTarget:self
        action:@selector(libraryLayoutChanged:)
        forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.controlsView];
    [NSLayoutConstraint activateConstraints:@[
        [self.controlsView.topAnchor constraintEqualToAnchor:
            self.view.safeAreaLayoutGuide.topAnchor],
        [self.controlsView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.controlsView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.controlsView.heightAnchor constraintEqualToConstant:58.0],
        [self.collectionView.topAnchor constraintEqualToAnchor:
            self.controlsView.bottomAnchor],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    UIView *empty = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    empty.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *onboardingImagePath = [NSBundle.mainBundle
        pathForResource:@"VirtualMacTemplate" ofType:@"png"];
    UIImage *onboardingImage = [[UIImage
        imageWithContentsOfFile:onboardingImagePath]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIImageView *icon = [[[UIImageView alloc] initWithImage:
        onboardingImage] autorelease];
    icon.tintColor = UIColor.secondaryLabelColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *title = [[[UILabel alloc] init] autorelease];
    title.text = VZL(@"Welcome to Virtual Mac");
    UIFont *preferredTitleFont =
        [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    UIFontDescriptor *boldTitleDescriptor = [preferredTitleFont.fontDescriptor
        fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    title.font = boldTitleDescriptor
        ? [UIFont fontWithDescriptor:boldTitleDescriptor size:0]
        : preferredTitleFont;
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *message = [[[UILabel alloc] init] autorelease];
    message.text = VZDeviceString(
        VZL(@"People have dreamed of running macOS on iPad for more than a decade. Today, that dream comes true. Create a Virtual Mac to get started."),
        VZL(@"People have dreamed of taking macOS wherever they go for more than a decade. Today, that dream comes true. Create a Virtual Mac to get started."));
    message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    message.textColor = UIColor.secondaryLabelColor;
    message.textAlignment = NSTextAlignmentCenter;
    message.numberOfLines = 0;
    message.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *create = [UIButton buttonWithType:UIButtonTypeSystem];
    [create setTitle:VZL(@"Create Virtual Mac") forState:UIControlStateNormal];
    create.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *createConfiguration =
            [UIButtonConfiguration filledButtonConfiguration];
        createConfiguration.contentInsets =
            NSDirectionalEdgeInsetsMake(10, 28, 10, 28);
        create.configuration = createConfiguration;
    } else {
        create.backgroundColor = UIColor.systemBlueColor;
        create.tintColor = UIColor.whiteColor;
        create.layer.cornerRadius = 10;
        create.layer.cornerCurve = kCACornerCurveContinuous;
        create.contentEdgeInsets = UIEdgeInsetsMake(10, 28, 10, 28);
    }
    [create addTarget:self action:@selector(addVM:) forControlEvents:UIControlEventTouchUpInside];
    create.translatesAutoresizingMaskIntoConstraints = NO;
    for (UIView *view in @[icon, title, message, create]) [empty addSubview:view];
    [self.view addSubview:empty];
    [NSLayoutConstraint activateConstraints:@[
        [empty.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [empty.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-24],
        [empty.widthAnchor constraintLessThanOrEqualToConstant:430],
        [icon.topAnchor constraintEqualToAnchor:empty.topAnchor],
        [icon.centerXAnchor constraintEqualToAnchor:empty.centerXAnchor],
        [icon.widthAnchor constraintEqualToConstant:160],
        [icon.heightAnchor constraintEqualToConstant:118],
        [title.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:10],
        [title.leadingAnchor constraintEqualToAnchor:empty.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:empty.trailingAnchor],
        [message.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [message.leadingAnchor constraintEqualToAnchor:empty.leadingAnchor],
        [message.trailingAnchor constraintEqualToAnchor:empty.trailingAnchor],
        [create.topAnchor constraintEqualToAnchor:message.bottomAnchor constant:22],
        [create.centerXAnchor constraintEqualToAnchor:empty.centerXAnchor],
        [create.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [create.bottomAnchor constraintEqualToAnchor:empty.bottomAnchor],
    ]];
    self.emptyView = empty;

    UIView *noResults = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    noResults.translatesAutoresizingMaskIntoConstraints = NO;
    noResults.userInteractionEnabled = NO;
    noResults.hidden = YES;
    UIImageView *noResultsIcon = [[[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"magnifyingglass"]] autorelease];
    noResultsIcon.tintColor = UIColor.secondaryLabelColor;
    noResultsIcon.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *noResultsTitle = [[[UILabel alloc] init] autorelease];
    noResultsTitle.text = VZL(@"No Results");
    UIFont *preferredNoResultsFont =
        [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    UIFontDescriptor *boldNoResultsDescriptor =
        [preferredNoResultsFont.fontDescriptor
            fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    noResultsTitle.font = boldNoResultsDescriptor
        ? [UIFont fontWithDescriptor:boldNoResultsDescriptor size:0]
        : preferredNoResultsFont;
    noResultsTitle.textAlignment = NSTextAlignmentCenter;
    noResultsTitle.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *noResultsMessage = [[[UILabel alloc] init] autorelease];
    noResultsMessage.text = VZL(@"No Virtual Macs match your search.");
    noResultsMessage.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    noResultsMessage.textColor = UIColor.secondaryLabelColor;
    noResultsMessage.textAlignment = NSTextAlignmentCenter;
    noResultsMessage.translatesAutoresizingMaskIntoConstraints = NO;
    [noResults addSubview:noResultsIcon];
    [noResults addSubview:noResultsTitle];
    [noResults addSubview:noResultsMessage];
    [self.view addSubview:noResults];
    self.noResultsBottomConstraint = [noResults.bottomAnchor
        constraintEqualToAnchor:self.view.bottomAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [noResults.topAnchor constraintEqualToAnchor:
            self.controlsView.bottomAnchor],
        [noResults.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [noResults.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.noResultsBottomConstraint,
        [noResultsIcon.centerXAnchor constraintEqualToAnchor:noResults.centerXAnchor],
        [noResultsIcon.centerYAnchor constraintEqualToAnchor:noResults.centerYAnchor constant:-42],
        [noResultsIcon.widthAnchor constraintEqualToConstant:44],
        [noResultsIcon.heightAnchor constraintEqualToConstant:44],
        [noResultsTitle.topAnchor constraintEqualToAnchor:noResultsIcon.bottomAnchor constant:14],
        [noResultsTitle.leadingAnchor constraintEqualToAnchor:noResults.leadingAnchor constant:24],
        [noResultsTitle.trailingAnchor constraintEqualToAnchor:noResults.trailingAnchor constant:-24],
        [noResultsMessage.topAnchor constraintEqualToAnchor:noResultsTitle.bottomAnchor constant:6],
        [noResultsMessage.leadingAnchor constraintEqualToAnchor:noResults.leadingAnchor constant:24],
        [noResultsMessage.trailingAnchor constraintEqualToAnchor:noResults.trailingAnchor constant:-24],
    ]];
    self.noResultsView = noResults;
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(settingsChanged:) name:VZSettingsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(libraryDidChange:) name:VZLibraryDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(keyboardFrameChanged:)
        name:UIKeyboardWillChangeFrameNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(applicationDidBecomeActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)refreshCollectionLayout
{
    // UIKit may restore a scene snapshot while a form sheet covers this view
    // without laying out the underlying collection at the intermediate size.
    // Resolve our constraints first, then discard every cached item size. Do
    // not reload data here: that would replace cells and can end an active
    // search session.
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    self.lastCollectionWidth = self.collectionView.bounds.size.width;
    [self.controlsView setNeedsLayout];
    [self.collectionView.collectionViewLayout invalidateLayout];
    [self.collectionView setNeedsLayout];
    [self.collectionView layoutIfNeeded];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    (void)notification;
    // The first active notification can arrive before UIKit has restored the
    // final scene geometry. Run after that transaction has drained.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.view.window)
            [self refreshCollectionLayout];
    });
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:nil completion:
        ^(id<UIViewControllerTransitionCoordinatorContext> context) {
            (void)context;
            [self refreshCollectionLayout];
        }];
}

- (void)keyboardFrameChanged:(NSNotification *)notification
{
    CGRect screenFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey]
        CGRectValue];
    CGRect keyboardFrame = [self.view convertRect:screenFrame fromView:nil];
    CGRect overlap = CGRectIntersection(self.view.bounds, keyboardFrame);
    CGFloat coveredHeight = CGRectIsNull(overlap) ? 0.0 :
        MAX(0.0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(overlap));
    CGFloat bottomConstant = -coveredHeight;
    // Reloading the search header can produce duplicate keyboard-frame
    // notifications even though the keyboard did not move. Reanimating the
    // same constraint makes the No Results content appear to enter again on
    // every character.
    if (ABS(self.noResultsBottomConstraint.constant - bottomConstant) < 0.5)
        return;
    self.noResultsBottomConstraint.constant = bottomConstant;

    NSTimeInterval duration =
        [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey]
            doubleValue];
    UIViewAnimationCurve curve =
        [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey]
            integerValue];
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState |
        ((UIViewAnimationOptions)curve << 16);
    [UIView animateWithDuration:duration delay:0 options:options animations:^{
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat width = self.collectionView.bounds.size.width;
    if (ABS(width - self.lastCollectionWidth) > 0.5) {
        self.lastCollectionWidth = width;
        [self.collectionView.collectionViewLayout invalidateLayout];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadLibrary];
    if (!self.didCheckInterruptedDownloads) {
        self.didCheckInterruptedDownloads = YES;
        NSFileManager *manager = NSFileManager.defaultManager;
        NSString *restoreDirectory =
            VZRestoreImagesPath().stringByStandardizingPath;
        NSString *restorePrefix = [restoreDirectory stringByAppendingString:@"/"];
        for (NSString *name in [manager
                contentsOfDirectoryAtPath:restoreDirectory error:nil]) {
            if (![name hasSuffix:@".download.plist"])
                continue;
            NSString *marker = [restoreDirectory
                stringByAppendingPathComponent:name];
            NSDictionary *metadata = [NSDictionary
                dictionaryWithContentsOfFile:marker];
            NSString *destination = [metadata[@"Destination"]
                isKindOfClass:NSString.class]
                ? [VZResolvedStoredPath(metadata[@"Destination"]) stringByStandardizingPath] : nil;
            unsigned long long expected =
                [metadata[@"ExpectedSize"] unsignedLongLongValue];
            unsigned long long actual = destination.length ? [[manager
                attributesOfItemAtPath:destination error:nil][NSFileSize]
                unsignedLongLongValue] : 0;
            BOOL complete = expected > 0 && actual == expected;
            NSMutableArray *cleanup = [NSMutableArray arrayWithObject:marker];
            if (!complete && [destination hasPrefix:restorePrefix])
                [cleanup addObject:destination];
            VZRemovePaths(cleanup);
        }
    }
}

- (void)reloadLibrary
{
    self.machines = VZDiscoverVirtualMachines();
    [self applySearchFilter];
    self.emptyView.hidden = self.machines.count > 0;
    self.collectionView.hidden = self.machines.count == 0;
    self.controlsView.hidden = self.machines.count == 0;
    [self.collectionView.collectionViewLayout invalidateLayout];
    [self.collectionView reloadData];
    [self updateSearchBackground];
    [self.collectionView.refreshControl endRefreshing];
}

- (void)applySearchFilter
{
    if (!self.searchText.length) {
        self.filteredMachines = self.machines;
        return;
    }
    NSString *query = self.searchText;
    self.filteredMachines = [self.machines filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSDictionary *machine,
                                               NSDictionary *bindings) {
        (void)bindings;
        return [machine[@"name"] localizedCaseInsensitiveContainsString:query];
    }]];
}

- (BOOL)showsCreateCard
{
    return self.searchText.length == 0;
}

- (NSArray *)searchItemIdentifiers
{
    NSMutableArray *identifiers = [NSMutableArray array];
    if ([self showsCreateCard])
        [identifiers addObject:@"__VirtualMacCreateCard__"];
    for (NSDictionary *machine in self.filteredMachines)
        [identifiers addObject:machine[@"path"] ?: machine];
    return identifiers;
}

- (NSUInteger)machineIndexForItem:(NSInteger)item
{
    NSInteger index = item - ([self showsCreateCard] ? 1 : 0);
    return index >= 0 && index < (NSInteger)self.filteredMachines.count
        ? (NSUInteger)index : NSNotFound;
}

- (void)updateSearchBackground
{
    BOOL visible = self.searchText.length && !self.filteredMachines.count;
    if (self.noResultsView.hidden == !visible)
        return;
    self.noResultsView.hidden = !visible;
    if (visible)
        [self.view bringSubviewToFront:self.noResultsView];
}

- (void)libraryDidChange:(NSNotification *)notification
{
    (void)notification;
    [self reloadLibrary];
}

- (void)settingsChanged:(NSNotification *)notification
{
    (void)notification;
    self.controlsView.layoutControl.selectedSegmentIndex =
        [[VZAppSettings.sharedSettings stringForKey:VZLibraryLayoutKey]
            isEqualToString:@"list"] ? 1 : 0;
    [self.collectionView.collectionViewLayout invalidateLayout];
    [self.collectionView reloadData];
}

- (void)searchBar:(UISearchBar *)searchBar
    textDidChange:(NSString *)searchText
{
    (void)searchBar;
    NSArray *oldIdentifiers = [self searchItemIdentifiers];
    self.searchText = searchText;
    [self applySearchFilter];
    NSArray *newIdentifiers = [self searchItemIdentifiers];
    NSSet *oldSet = [NSSet setWithArray:oldIdentifiers];
    NSSet *newSet = [NSSet setWithArray:newIdentifiers];
    NSMutableArray *deletions = [NSMutableArray array];
    NSMutableArray *insertions = [NSMutableArray array];
    [oldIdentifiers enumerateObjectsUsingBlock:
        ^(id identifier, NSUInteger index, BOOL *stop) {
        (void)stop;
        if (![newSet containsObject:identifier])
            [deletions addObject:[NSIndexPath indexPathForItem:index
                                                     inSection:0]];
    }];
    [newIdentifiers enumerateObjectsUsingBlock:
        ^(id identifier, NSUInteger index, BOOL *stop) {
        (void)stop;
        if (![oldSet containsObject:identifier])
            [insertions addObject:[NSIndexPath indexPathForItem:index
                                                      inSection:0]];
    }];
    [self updateSearchBackground];
    if (!deletions.count && !insertions.count)
        return;
    // Filtering preserves machine order, so unchanged cells naturally shift
    // around the small set of inserted/deleted identities. Search controls
    // live outside the collection, so these updates cannot replace or resign
    // the active text field.
    [UIView performWithoutAnimation:^{
        [self.collectionView performBatchUpdates:^{
            if (deletions.count)
                [self.collectionView deleteItemsAtIndexPaths:deletions];
            if (insertions.count)
                [self.collectionView insertItemsAtIndexPaths:insertions];
        } completion:nil];
    }];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
}

- (void)libraryLayoutChanged:(UISegmentedControl *)sender
{
    [VZAppSettings.sharedSettings setString:
        sender.selectedSegmentIndex == 1 ? @"list" : @"grid"
        forKey:VZLibraryLayoutKey];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    (void)collectionView; (void)section;
    return self.filteredMachines.count + ([self showsCreateCard] ? 1 : 0);
}

- (NSString *)activeVMBundlePath
{
    if ([self.delegate respondsToSelector:
            @selector(activeVMBundlePathForLibrary:)])
        return [self.delegate activeVMBundlePathForLibrary:self];
    return nil;
}

- (BOOL)isMachineActive:(NSDictionary *)machine
{
    return [[[self activeVMBundlePath] stringByStandardizingPath]
        isEqualToString:[machine[@"path"] stringByStandardizingPath]];
}

- (void)startMachine:(NSDictionary *)machine
{
    NSString *activePath = [self activeVMBundlePath];
    if (activePath.length) {
        if ([self isMachineActive:machine]) {
            if ([self.delegate respondsToSelector:
                    @selector(vmLibraryResumeActiveVM:)])
                [self.delegate vmLibraryResumeActiveVM:self];
            return;
        }
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:VZL(@"Another Virtual Mac Is Running")
            message:VZL(@"Switch to the running Virtual Mac and shut it down before starting another one.")
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
            style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction
            actionWithTitle:VZL(@"Switch to Running Virtual Mac")
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            if ([self.delegate respondsToSelector:
                    @selector(vmLibraryResumeActiveVM:)])
                [self.delegate vmLibraryResumeActiveVM:self];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:VZStoredPath(machine[@"path"])
        forKey:@"VZSelectedVMPath"];
    [self.delegate vmLibrary:self bootBundleAtPath:machine[@"path"]
        options:VZVMOptionsForBundle(machine[@"path"])];
}

- (void)confirmDeleteMachine:(NSDictionary *)machine
{
    if ([self isMachineActive:machine])
        return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:VZL(@"Delete Virtual Mac?")
        message:[NSString stringWithFormat:
            VZL(@"“%@” and all files stored in it will be permanently deleted."),
            machine[@"name"]]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Delete")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        VZRemovePaths(@[machine[@"path"]]);
        if ([[VZAppSettings.sharedSettings stringForKey:VZAutoBootVMPathKey]
                isEqualToString:machine[@"path"]]) {
            [VZAppSettings.sharedSettings setString:nil
                forKey:VZAutoBootVMPathKey];
            [VZAppSettings.sharedSettings setString:nil
                forKey:VZAutoBootVMIdentifierKey];
        }
        [self reloadLibrary];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)configureMachineAtIndex:(NSUInteger)index
{
    if (index >= self.filteredMachines.count)
        return;
    NSDictionary *machine = self.filteredMachines[index];
    BOOL running = [self isMachineActive:machine];
    VZVMConfigurationViewController *configuration =
        [[[VZVMConfigurationViewController alloc]
          initWithBundlePath:machine[@"path"]
                     options:VZVMOptionsForBundle(machine[@"path"])
                  completion:^(NSDictionary *options) {
            (void)options;
            [self reloadLibrary];
        }] autorelease];
    configuration.title = machine[@"name"];
    configuration.vmName = machine[@"name"];
    configuration.running = running;
    configuration.deletion = ^{ [self reloadLibrary]; };
    [self presentConfiguration:configuration];
}

- (void)forceShutdownMachine:(NSDictionary *)machine
{
    if (![self isMachineActive:machine] ||
        ![self.delegate respondsToSelector:
            @selector(vmLibraryForceShutdownActiveVM:)])
        return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:VZL(@"Force Shut Down Virtual Mac?")
        message:VZL(@"Unsaved changes in macOS may be lost.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Force Shut Down")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        [self.delegate vmLibraryForceShutdownActiveVM:self];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentActionsForMachine:(NSDictionary *)machine
                        fromView:(UIView *)source
{
    BOOL active = [self isMachineActive:machine];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:machine[@"name"] message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:active ? VZL(@"Resume") : VZL(@"Start")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; [self startMachine:machine];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:VZL(@"Options")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSUInteger index = [self.filteredMachines indexOfObject:machine];
        if (index != NSNotFound) [self configureMachineAtIndex:index];
    }]];
    if (active)
        [sheet addAction:[UIAlertAction actionWithTitle:VZL(@"Force Shut Down")
            style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            (void)action; [self forceShutdownMachine:machine];
        }]];
    else
        [sheet addAction:[UIAlertAction actionWithTitle:VZL(@"Delete")
            style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            (void)action; [self confirmDeleteMachine:machine];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source ?: self.view;
    sheet.popoverPresentationController.sourceRect = source ? source.bounds :
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
    cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    UICollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"item"
        forIndexPath:indexPath];
    for (UIView *view in cell.contentView.subviews) [view removeFromSuperview];
    for (UIGestureRecognizer *gesture in
            [[[cell gestureRecognizers] copy] autorelease])
        if ([gesture isKindOfClass:UISwipeGestureRecognizer.class])
            [cell removeGestureRecognizer:gesture];
    cell.contentView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    cell.contentView.layer.cornerRadius = 14;
    cell.contentView.layer.cornerCurve = kCACornerCurveContinuous;
    cell.contentView.layer.borderWidth = 0.5;
    cell.contentView.layer.borderColor = UIColor.separatorColor.CGColor;
    cell.contentView.clipsToBounds = YES;
    BOOL list = [[VZAppSettings.sharedSettings stringForKey:VZLibraryLayoutKey] isEqualToString:@"list"];
    BOOL narrow = CGRectGetWidth(collectionView.bounds) < 500;
    UIView *selected = [[[UIView alloc] initWithFrame:cell.bounds] autorelease];
    selected.backgroundColor = UIColor.tertiarySystemFillColor;
    selected.layer.cornerRadius = 14;
    selected.layer.cornerCurve = kCACornerCurveContinuous;
    cell.selectedBackgroundView = selected;
    UIImageView *image = [[[UIImageView alloc] init] autorelease];
    image.translatesAutoresizingMaskIntoConstraints = NO;
    image.contentMode = UIViewContentModeScaleAspectFill;
    image.clipsToBounds = YES;
    // The grid card already clips to its rounded outer edge. A second rounded
    // image mask leaves a visible seam above solid-color artwork such as the
    // Create card; only standalone list thumbnails need their own rounding.
    image.layer.cornerRadius = list ? 10 : 0;
    image.layer.cornerCurve = kCACornerCurveContinuous;
    image.layer.maskedCorners = list ?
        (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
         kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner) :
        (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner);
    image.backgroundColor = UIColor.tertiarySystemFillColor;
    [cell.contentView addSubview:image];
    UILabel *title = [[[UILabel alloc] init] autorelease];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont preferredFontForTextStyle:list ? UIFontTextStyleHeadline : UIFontTextStyleTitle3];
    title.numberOfLines = 1;
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    [cell.contentView addSubview:title];
    UILabel *detail = [[[UILabel alloc] init] autorelease];
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    detail.textColor = UIColor.secondaryLabelColor;
    [cell.contentView addSubview:detail];
    UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
    more.translatesAutoresizingMaskIntoConstraints = NO;
    NSUInteger machineIndex = [self machineIndexForItem:indexPath.item];
    BOOL createCard = machineIndex == NSNotFound && [self showsCreateCard] && indexPath.item == 0;
    more.tag = machineIndex == NSNotFound ? 0 : machineIndex + 1;
    [more addTarget:self action:@selector(moreButton:)
        forControlEvents:UIControlEventTouchUpInside];
    [cell.contentView addSubview:more];
    if (createCard) {
        NSString *art = [[NSBundle mainBundle] pathForResource:@"new"
            ofType:@"png" inDirectory:@"Wallpapers"];
        image.image = [UIImage imageWithContentsOfFile:art];
        title.text = VZL(@"Create Virtual Mac");
        detail.text = VZL(@"Install macOS");
        more.hidden = YES;
    } else {
        NSDictionary *machine = self.filteredMachines[machineIndex];
        NSDictionary *options = VZVMOptionsForBundle(machine[@"path"]);
        title.text = machine[@"name"];
        uint64_t storage = VZVMStorageCapacity(machine[@"path"], options);
        detail.text = [NSString stringWithFormat:
            VZL(@"%@ CPU · %@ GB RAM · %llu GB · %@%@"),
            options[VZCPUCountKey], @([options[VZMemorySizeKey] unsignedLongLongValue] >> 30),
            (unsigned long long)(storage >> 30), VZNetworkModeDisplayName(options),
            [machine[@"legacy"] boolValue] ? VZL(@" · Legacy") : @""];
        NSString *wallpaperName = [VZRestoreCatalog
            artworkNameForMachineName:machine[@"name"]];
        NSString *art = [[NSBundle mainBundle] pathForResource:wallpaperName
            ofType:@"jpg" inDirectory:@"Wallpapers"];
        image.image = [UIImage imageWithContentsOfFile:art];
        image.tag = machineIndex + 1;
        image.userInteractionEnabled = YES;
        UITapGestureRecognizer *start = [[[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(machineArtworkTapped:)] autorelease];
        [image addGestureRecognizer:start];
        image.isAccessibilityElement = YES;
        image.accessibilityLabel = [NSString stringWithFormat:VZL(@"Start %@"), machine[@"name"]];
        image.accessibilityTraits = UIAccessibilityTraitButton;
        [more setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
        more.accessibilityLabel = [NSString stringWithFormat:VZL(@"Configure %@"), machine[@"name"]];
        more.hidden = narrow;
        {
            UIVisualEffectView *playBackground = [[[UIVisualEffectView alloc]
                initWithEffect:[UIBlurEffect effectWithStyle:
                    UIBlurEffectStyleSystemUltraThinMaterialDark]] autorelease];
            playBackground.translatesAutoresizingMaskIntoConstraints = NO;
            playBackground.userInteractionEnabled = YES;
            CGFloat playDiameter = list ? (narrow ? 32 : 36)
                                        : (narrow ? 52 : 72);
            playBackground.layer.cornerRadius = playDiameter / 2.0;
            playBackground.clipsToBounds = YES;
            UIButton *play = [UIButton buttonWithType:UIButtonTypeSystem];
            play.translatesAutoresizingMaskIntoConstraints = NO;
            play.tag = machineIndex + 1;
            play.tintColor = UIColor.whiteColor;
            NSString *symbolName = [self isMachineActive:machine]
                ? @"arrow.right" : @"play.fill";
            UIImage *playImage = [[UIImage systemImageNamed:symbolName]
                imageByApplyingSymbolConfiguration:[UIImageSymbolConfiguration
                    configurationWithPointSize:list ? 14 : 24
                    weight:UIImageSymbolWeightSemibold]];
            [play setImage:playImage forState:UIControlStateNormal];
            [play addTarget:self action:@selector(startButton:)
                forControlEvents:UIControlEventTouchUpInside];
            [playBackground.contentView addSubview:play];
            [cell.contentView addSubview:playBackground];
            [NSLayoutConstraint activateConstraints:@[
                [playBackground.centerXAnchor constraintEqualToAnchor:image.centerXAnchor],
                [playBackground.centerYAnchor constraintEqualToAnchor:image.centerYAnchor],
                [playBackground.widthAnchor constraintEqualToConstant:playDiameter],
                [playBackground.heightAnchor constraintEqualToConstant:playDiameter],
                [play.centerXAnchor constraintEqualToAnchor:playBackground.contentView.centerXAnchor],
                [play.centerYAnchor constraintEqualToAnchor:playBackground.contentView.centerYAnchor],
                [play.widthAnchor constraintEqualToAnchor:playBackground.widthAnchor],
                [play.heightAnchor constraintEqualToAnchor:playBackground.heightAnchor],
            ]];
        }
    }
    if (list) {
        cell.tag = machineIndex == NSNotFound ? 0 : machineIndex + 1;
        UISwipeGestureRecognizer *swipe = [[[UISwipeGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleMachineSwipe:)] autorelease];
        swipe.direction = UISwipeGestureRecognizerDirectionRight;
        [cell addGestureRecognizer:swipe];
        [NSLayoutConstraint activateConstraints:@[
            [image.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:10],
            [image.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [image.widthAnchor constraintEqualToConstant:104], [image.heightAnchor constraintEqualToConstant:62],
            [title.leadingAnchor constraintEqualToAnchor:image.trailingAnchor constant:14],
            [title.trailingAnchor constraintLessThanOrEqualToAnchor:
                (narrow ? cell.contentView.trailingAnchor : more.leadingAnchor)
                constant:(narrow ? -12 : -8)],
            [title.bottomAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor constant:-2],
            [detail.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
            [detail.trailingAnchor constraintLessThanOrEqualToAnchor:
                (narrow ? cell.contentView.trailingAnchor : more.leadingAnchor)
                constant:(narrow ? -12 : -8)],
            [detail.topAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor constant:3],
            [more.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-14],
            [more.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [more.widthAnchor constraintEqualToConstant:48],
            [more.heightAnchor constraintEqualToConstant:48],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [image.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
            [image.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
            [image.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
            [image.heightAnchor constraintEqualToAnchor:cell.contentView.widthAnchor multiplier:0.56],
            [title.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:14],
            [title.trailingAnchor constraintLessThanOrEqualToAnchor:
                (narrow ? cell.contentView.trailingAnchor : more.leadingAnchor)
                constant:(narrow ? -14 : -6)],
            [title.topAnchor constraintEqualToAnchor:image.bottomAnchor constant:12],
            [detail.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
            [detail.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-14],
            [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:3],
            [more.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-12],
            [more.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
            [more.widthAnchor constraintEqualToConstant:48],
            [more.heightAnchor constraintEqualToConstant:48],
        ]];
    }
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", title.text, detail.text];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout
    sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    (void)layout; (void)indexPath;
    CGFloat width = collectionView.bounds.size.width - 48;
    if ([[VZAppSettings.sharedSettings stringForKey:VZLibraryLayoutKey] isEqualToString:@"list"])
        return CGSizeMake(width, 82);
    NSUInteger columns = width >= 900 ? 3 : (width >= 520 ? 2 : 1);
    CGFloat itemWidth = floor((width - 18 * (columns - 1)) / columns);
    return CGSizeMake(itemWidth, itemWidth * 0.56 + 76);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    NSUInteger index = [self machineIndexForItem:indexPath.item];
    if (index == NSNotFound) {
        if ([self showsCreateCard] && indexPath.item == 0) [self presentNewVMFlow];
        return;
    }
    NSDictionary *machine = self.filteredMachines[index];
    UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:indexPath];
    [self presentActionsForMachine:machine fromView:cell];
}

- (void)machineArtworkTapped:(UITapGestureRecognizer *)recognizer
{
    NSInteger item = recognizer.view.tag;
    if (item <= 0 || item > (NSInteger)self.filteredMachines.count) return;
    [self startMachine:self.filteredMachines[item - 1]];
}

- (void)startButton:(UIButton *)sender
{
    if (sender.tag == 0 || sender.tag > self.filteredMachines.count) return;
    [self startMachine:self.filteredMachines[sender.tag - 1]];
}

- (void)moreButton:(UIButton *)sender
{
    if (sender.tag == 0 || sender.tag > self.filteredMachines.count) return;
    [self configureMachineAtIndex:sender.tag - 1];
}

- (void)handleMachineSwipe:(UISwipeGestureRecognizer *)recognizer
{
    UICollectionViewCell *cell = (id)recognizer.view;
    if (cell.tag == 0 || cell.tag > (NSInteger)self.filteredMachines.count)
        return;
    NSDictionary *machine = self.filteredMachines[cell.tag - 1];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:machine[@"name"] message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:VZL(@"Options")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; [self configureMachineAtIndex:cell.tag - 1];
    }]];
    if (![self isMachineActive:machine])
        [sheet addAction:[UIAlertAction actionWithTitle:VZL(@"Delete")
            style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            (void)action; [self confirmDeleteMachine:machine];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView
    contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath
    point:(CGPoint)point
{
    (void)collectionView; (void)point;
    NSUInteger index = [self machineIndexForItem:indexPath.item];
    if (index == NSNotFound) return nil;
    NSDictionary *machine = self.filteredMachines[index];
    BOOL active = [self isMachineActive:machine];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
        previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        (void)suggested;
        UIImage *resumeImage = [UIImage systemImageNamed:@"arrow.right"];
        UIAction *start = [UIAction actionWithTitle:active ? VZL(@"Resume") : VZL(@"Start")
            image:active ? resumeImage : [UIImage systemImageNamed:@"play.fill"]
            identifier:nil handler:^(__kindof UIAction *action) {
            (void)action; [self startMachine:machine];
        }];
        UIAction *options = [UIAction actionWithTitle:VZL(@"Options")
            image:[UIImage systemImageNamed:@"gearshape"] identifier:nil
            handler:^(__kindof UIAction *action) {
            (void)action;
            NSUInteger index = [self.filteredMachines indexOfObject:machine];
            if (index != NSNotFound) [self configureMachineAtIndex:index];
        }];
        UIAction *power = [UIAction actionWithTitle:
            active ? VZL(@"Force Shut Down") : VZL(@"Delete")
            image:[UIImage systemImageNamed:active ? @"power" : @"trash"]
            identifier:nil handler:^(__kindof UIAction *action) {
            (void)action;
            if (active) [self forceShutdownMachine:machine];
            else [self confirmDeleteMachine:machine];
        }];
        power.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:@"" children:@[start, options, power]];
    }];
}

- (void)addVM:(id)sender
{
    (void)sender;
    [self presentNewVMFlow];
}

- (void)presentNewVMFlow
{
    VZNewVMViewController *controller = [[[VZNewVMViewController alloc] init] autorelease];
    controller.delegate = self;
    UINavigationController *navigation = [[[UINavigationController alloc]
        initWithRootViewController:controller] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.preferredContentSize = CGSizeMake(650, 700);
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)presentRestoreImagePicker
{
    UIDocumentPickerViewController *picker = [[[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeItem] asCopy:YES] autorelease];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)configureRestoreImageAtURL:(NSURL *)url
{
    self.pendingIPSWURL = url;
    NSString *suggested = VZUniqueVMName(
        [VZRestoreCatalog defaultVirtualMachineNameForRestoreImagePath:url.path]);
    NSMutableDictionary *defaults = [NSMutableDictionary
        dictionaryWithDictionary:VZVMDefaultOptions()];
    defaults[VZOpenGLAccelerationEnabledKey] =
        @(VZDefaultOpenGLAccelerationForRestoreImage(url.path));
    defaults[VZPointingDeviceKey] = VZDefaultPointingDeviceForPath(url.path);
    defaults[VZKeyboardDeviceKey] = VZDefaultKeyboardDeviceForPath(url.path);
    VZVMConfigurationViewController *configuration =
        [[[VZVMConfigurationViewController alloc]
          initWithBundlePath:nil options:defaults
          completion:^(NSDictionary *result) {
            NSMutableDictionary *options = [NSMutableDictionary
                dictionaryWithDictionary:result];
            NSString *name = VZUniqueVMName(options[VZVMNameKey]);
            [options removeObjectForKey:VZVMNameKey];
            [self.delegate vmLibrary:self installRestoreImageAtURL:url
                name:name options:options];
        }] autorelease];
    configuration.vmName = suggested;
    NSDictionary *localImage = @{ @"name": url.lastPathComponent ?: @"" };
    configuration.showsExperimentalInstallWarning =
        [VZRestoreCatalog isExperimentalImage:localImage];
    configuration.showsUnsupportedInstallWarning =
        [VZRestoreCatalog isUnsupportedImage:localImage];
    if (configuration.showsExperimentalInstallWarning) {
        configuration.experimentalMacOSName =
            [VZRestoreCatalog macOSNameForImage:localImage];
        configuration.chooseDifferentVersionHandler = ^{
            [self presentNewVMFlow];
        };
    }
    [self presentConfiguration:configuration];
}

- (void)copySelectedRestoreImageAtURL:(NSURL *)source
{
    NSString *restoreDirectory = VZRestoreImagesPath();
    NSString *standardSource = source.path.stringByStandardizingPath;
    if ([standardSource.stringByDeletingLastPathComponent
            isEqualToString:restoreDirectory.stringByStandardizingPath]) {
        [source stopAccessingSecurityScopedResource];
        [self configureRestoreImageAtURL:[NSURL fileURLWithPath:standardSource]];
        return;
    }
    [NSFileManager.defaultManager createDirectoryAtPath:restoreDirectory
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *base = source.lastPathComponent.stringByDeletingPathExtension;
    NSString *extension = source.pathExtension.lowercaseString;
    NSString *destination = [restoreDirectory stringByAppendingPathComponent:
        [base stringByAppendingPathExtension:extension]];
    for (NSUInteger suffix = 2;
         [NSFileManager.defaultManager fileExistsAtPath:destination]; suffix++)
        destination = [restoreDirectory stringByAppendingPathComponent:
            [[NSString stringWithFormat:@"%@ %lu", base, (unsigned long)suffix]
                stringByAppendingPathExtension:extension]];

    UIApplication.sharedApplication.idleTimerDisabled = YES;
    self.restoreCopyController = [[[VZProgressViewController alloc]
        initWithTitle:VZL(@"Copying Restore Image")] autorelease];
    self.restoreCopyController.statusText = source.lastPathComponent;
    self.restoreCopyController.detailText =
        VZDeviceString(
            VZL(@"Preparing the IPSW for installation. Your iPad will remain awake."),
            VZL(@"Preparing the IPSW for installation. Your iPhone will remain awake."));
    self.restoreCopyController.consoleHidden = YES;
    self.restoreCopyController.indeterminate = YES;
    UINavigationController *navigation = [[[UINavigationController alloc]
        initWithRootViewController:self.restoreCopyController] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.modalInPresentation = YES;
    navigation.preferredContentSize = CGSizeMake(620, 280);
    // A security-scoped file selected with asCopy:YES is commonly an APFS
    // clone on the same data volume, so this second durable copy completes
    // almost immediately. Presenting and then immediately dismissing a modal
    // progress sheet causes a distracting flash between the document picker
    // and configuration screen. Delay the progress UI; genuinely slow copies
    // still receive feedback without adding latency to the normal path.
    __block BOOL copyFinished = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!copyFinished && self.restoreCopyController &&
            !navigation.presentingViewController &&
            !self.presentedViewController)
            [self presentViewController:navigation animated:YES completion:nil];
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *copyError = nil;
        BOOL copied = [NSFileManager.defaultManager copyItemAtPath:source.path
            toPath:destination error:&copyError];
        [source stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            copyFinished = YES;
            UIApplication.sharedApplication.idleTimerDisabled = NO;
            void (^finished)(void) = ^{
                self.restoreCopyController = nil;
                if (copied) {
                    [self configureRestoreImageAtURL:
                        [NSURL fileURLWithPath:destination]];
                } else {
                    VZPresentFailureReport(self, VZL(@"Could Not Copy IPSW"),
                        copyError.localizedDescription,
                        copyError.debugDescription,
                        VZFailureSupportOptionNone);
                }
            };
            if (navigation.presentingViewController)
                [navigation dismissViewControllerAnimated:YES
                                                completion:finished];
            else
                finished();
        });
    });
}

- (void)newVMControllerChooseLocalRestoreImage:(VZNewVMViewController *)controller
{
    [controller dismissViewControllerAnimated:YES completion:^{
        [self presentRestoreImagePicker];
    }];
}

- (void)cancelDownload
{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:VZL(@"Cancel Download?")
                         message:VZL(@"The partial restore image will be deleted.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Keep Downloading")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel Download")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        self.downloadCancelled = YES;
        [self.downloadTask cancel];
        [self.downloadTimer invalidate];
        self.downloadTimer = nil;
        if (self.downloadDestination.length)
            [NSFileManager.defaultManager removeItemAtPath:self.downloadDestination error:nil];
        if (self.downloadMarkerPath.length)
            [NSFileManager.defaultManager removeItemAtPath:self.downloadMarkerPath error:nil];
        UIApplication.sharedApplication.idleTimerDisabled = NO;
        [self.downloadController.navigationController dismissViewControllerAnimated:YES
            completion:^{
                self.downloadController.cancellationHandler = nil;
                self.downloadController = nil;
                self.downloadTask = nil;
                self.downloadDestination = nil;
                self.downloadMarkerPath = nil;
            }];
    }]];
    [self.downloadController presentViewController:alert animated:YES completion:nil];
}

- (void)newVMController:(VZNewVMViewController *)controller
    downloadRestoreImage:(NSDictionary *)image
{
    NSURL *remoteURL = [NSURL URLWithString:image[@"url"]];
    if (!remoteURL)
        return;
    NSMutableDictionary *defaults = [NSMutableDictionary
        dictionaryWithDictionary:VZVMDefaultOptions()];
    defaults[VZPointingDeviceKey] =
        VZDefaultPointingDeviceForPath(remoteURL.path);
    defaults[VZKeyboardDeviceKey] =
        VZDefaultKeyboardDeviceForPath(remoteURL.path);
    defaults[VZOpenGLAccelerationEnabledKey] =
        @([VZRestoreCatalog enablesOpenGLByDefaultForImage:image]);
    VZVMConfigurationViewController *configuration =
        [[[VZVMConfigurationViewController alloc]
          initWithBundlePath:nil options:defaults
          completion:^(NSDictionary *result) {
            NSMutableDictionary *options = [NSMutableDictionary
                dictionaryWithDictionary:result];
            NSString *name = VZUniqueVMName(options[VZVMNameKey]);
            [options removeObjectForKey:VZVMNameKey];
            [controller.navigationController
                dismissViewControllerAnimated:YES completion:^{
                [self beginDownloadRestoreImage:image name:name
                                         options:options];
            }];
        }] autorelease];
    // Show both the marketing name and any uniqueness suffix while the user
    // configures the Virtual Mac, before its bundle is created.
    configuration.vmName = VZUniqueVMName(
        [VZRestoreCatalog defaultVirtualMachineNameForRestoreImagePath:
            remoteURL.path] ?: image[@"name"]);
    configuration.showsExperimentalInstallWarning =
        [VZRestoreCatalog isExperimentalImage:image];
    configuration.showsUnsupportedInstallWarning =
        [VZRestoreCatalog isUnsupportedImage:image];
    configuration.experimentalMacOSName =
        [VZRestoreCatalog macOSNameForImage:image];
    [controller.navigationController pushViewController:configuration
        animated:YES];
}

- (void)beginDownloadRestoreImage:(NSDictionary *)image
                             name:(NSString *)name
                          options:(NSDictionary *)options
{
    NSURL *remoteURL = [NSURL URLWithString:image[@"url"]];
    if (!remoteURL)
        return;
    NSString *destination = [VZRestoreImagesPath()
        stringByAppendingPathComponent:remoteURL.lastPathComponent ?: @"Restore.ipsw"];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:destination
                                                                              error:nil];
    uint64_t expected = [image[@"downloadSize"] unsignedLongLongValue];
    if (attributes && (!expected || [attributes[NSFileSize] unsignedLongLongValue] == expected)) {
        [self.delegate vmLibrary:self
            installRestoreImageAtURL:[NSURL fileURLWithPath:destination]
                                name:name
                             options:options];
        return;
    }
    [NSFileManager.defaultManager createDirectoryAtPath:VZRestoreImagesPath()
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    self.downloadCancelled = NO;
    self.downloadDestination = destination;
    self.downloadMarkerPath = [VZRestoreImagesPath()
        stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.download.plist",
                                                                  destination.lastPathComponent]];
    [@{
        @"Name" : image[@"name"] ?: destination.lastPathComponent,
        @"URL" : remoteURL.absoluteString ?: @"",
        @"Destination" : VZStoredPath(destination),
        @"ExpectedSize" : @(expected),
        @"StartedAt" : NSDate.date
    } writeToFile:self.downloadMarkerPath
        atomically:YES];
    self.downloadController =
        [[[VZProgressViewController alloc] initWithTitle:VZL(@"Downloading macOS")] autorelease];
    self.downloadController.heroImage = VZInstallerArtworkForImage(image);
    NSString *macOSName = [VZRestoreCatalog macOSNameForImage:image];
    NSString *version = [VZRestoreCatalog versionForImage:image];
    if ([version hasSuffix:@".0"])
        version = [version substringToIndex:version.length - 2];
    BOOL hasKnownArtwork = ![[VZRestoreCatalog artworkNameForImage:image]
        isEqualToString:@"ipsw"];
    self.downloadController.heroTitleText = hasKnownArtwork && version.length
        ? [NSString stringWithFormat:@"%@ %@", macOSName, version]
        : ([image[@"name"] isKindOfClass:NSString.class]
            ? image[@"name"] : macOSName);
    NSByteCountFormatter *initialFormatter =
        [[[NSByteCountFormatter alloc] init] autorelease];
    initialFormatter.countStyle = NSByteCountFormatterCountStyleFile;
    initialFormatter.zeroPadsFractionDigits = YES;
    self.downloadController.detailText = [NSString stringWithFormat:
        @"%@ / %@ · — · —",
        [initialFormatter stringFromByteCount:0],
        expected > 0 ? [initialFormatter stringFromByteCount:expected] : @"—"];
    self.downloadController.tipText =
        VZDeviceString(
            VZL(@"Keep Virtual Mac open. Your iPad will remain awake until the download finishes."),
            VZL(@"Keep Virtual Mac open. Your iPhone will remain awake until the download finishes."));
    self.downloadController.consoleHidden = YES;
    self.downloadController.indeterminate = expected == 0;
    self.downloadController.cancellationHandler = ^{
        [self cancelDownload];
    };
    UINavigationController *navigation = [[[UINavigationController alloc]
        initWithRootViewController:self.downloadController] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.modalInPresentation = YES;
    navigation.preferredContentSize = CGSizeMake(620, 560);
    [self presentViewController:navigation animated:YES completion:nil];
    self.downloadTask = [NSURLSession.sharedSession
        downloadTaskWithURL:remoteURL
          completionHandler:^(NSURL *temporaryURL, NSURLResponse *response, NSError *error) {
              (void)response;
              NSError *moveError = nil;
              if (temporaryURL && !self.downloadCancelled) {
                  [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
                  [NSFileManager.defaultManager moveItemAtURL:temporaryURL
                                                        toURL:[NSURL fileURLWithPath:destination]
                                                        error:&moveError];
              }
              dispatch_async(dispatch_get_main_queue(), ^{
                  [self.downloadTimer invalidate];
                  self.downloadTimer = nil;
                  self.downloadTask = nil;
                  UIApplication.sharedApplication.idleTimerDisabled = NO;
                  NSError *failure = error ?: moveError;
                  BOOL cancelled = self.downloadCancelled;
                  if (!failure) {
                      [NSFileManager.defaultManager removeItemAtPath:self.downloadMarkerPath
                                                               error:nil];
                  } else if (!cancelled) {
                      // Downloads cannot be resumed. Avoid retaining a stale
                      // IPSW or marker after an ordinary network failure;
                      // launch-time cleanup covers abrupt process exits.
                      [NSFileManager.defaultManager removeItemAtPath:destination
                                                               error:nil];
                      [NSFileManager.defaultManager removeItemAtPath:self.downloadMarkerPath
                                                               error:nil];
                  }
                  if (!self.downloadController)
                      return;
                  [self.downloadController.navigationController
                      dismissViewControllerAnimated:YES
                                         completion:^{
                                             self.downloadController.cancellationHandler = nil;
                                             self.downloadController = nil;
                                             self.downloadDestination = nil;
                                             self.downloadMarkerPath = nil;
                                             if (cancelled) {
                                                 // Cancellation is terminal.
                                                 // NSURLSession normally
                                                 // completes with
                                                 // NSURLErrorCancelled, but
                                                 // the completion can race
                                                 // the confirmation UI. Never
                                                 // turn either outcome into a
                                                 // restore request.
                                                 return;
                                             } else if (failure) {
                                                 VZPresentFailureReport(self,
                                                     VZL(@"Download Failed"),
                                                     failure.localizedDescription,
                                                     failure.debugDescription,
                                                     VZFailureSupportOptionNone);
                                             } else {
                                                 [self.delegate vmLibrary:self
                                                     installRestoreImageAtURL:
                                                         [NSURL fileURLWithPath:destination]
                                                                         name:name
                                                                      options:options];
                                             }
                                         }];
              });
          }];
    [self.downloadTask resume];
    self.downloadLastBytes = 0;
    self.downloadLastSample = NSDate.date;
    self.downloadStartedAt = self.downloadLastSample;
    self.downloadTimer = [NSTimer
        scheduledTimerWithTimeInterval:0.5
                               repeats:YES
                                 block:^(NSTimer *timer) {
                                     (void)timer;
                                     int64_t total =
                                         self.downloadTask.countOfBytesExpectedToReceive;
                                     int64_t received = self.downloadTask.countOfBytesReceived;
                                     if (total > 0) {
                                         float progress = (float)received / (float)total;
                                         self.downloadController.indeterminate = NO;
                                         self.downloadController.progress = progress;
                                         NSByteCountFormatter *formatter =
                                             [[[NSByteCountFormatter alloc] init] autorelease];
                                         formatter.countStyle = NSByteCountFormatterCountStyleFile;
                                         formatter.zeroPadsFractionDigits = YES;
                                         NSTimeInterval elapsed =
                                             -[self.downloadLastSample timeIntervalSinceNow];
                                         int64_t delta = received - self.downloadLastBytes;
                                         NSString *speed =
                                             elapsed > 0.05 && delta >= 0
                                                 ? [NSString
                                                       stringWithFormat:@"%@/s",
                                                                        [formatter
                                                                            stringFromByteCount:
                                                                                (int64_t)(delta /
                                                                                          elapsed)]]
                                                 : VZL(@"Calculating speed…");
                                         NSTimeInterval averageElapsed =
                                             -[self.downloadStartedAt timeIntervalSinceNow];
                                         double averageSpeed = averageElapsed > 1.0
                                             ? received / averageElapsed : 0.0;
                                         NSString *remaining = nil;
                                         if (averageSpeed > 0.0 && received < total) {
                                             NSTimeInterval seconds =
                                                 (total - received) / averageSpeed;
                                             seconds = MAX(60.0,
                                                 ceil(seconds / 60.0) * 60.0);
                                             NSDateComponentsFormatter *duration =
                                                 [[[NSDateComponentsFormatter alloc] init]
                                                     autorelease];
                                             duration.allowedUnits =
                                                 NSCalendarUnitHour | NSCalendarUnitMinute;
                                             duration.unitsStyle =
                                                 NSDateComponentsFormatterUnitsStyleFull;
                                             duration.maximumUnitCount = 2;
                                             remaining = [duration
                                                 stringFromTimeInterval:seconds];
                                             if (remaining.length)
                                                 remaining = [NSString stringWithFormat:
                                                     VZL(@"%@ remaining"), remaining];
                                         }
                                         self.downloadController.detailText = [NSString
                                             stringWithFormat:remaining.length
                                                 ? @"%@ / %@ · %@ · %@"
                                                 : @"%@ / %@ · %@",
                                                              [formatter
                                                                  stringFromByteCount:received],
                                                              [formatter stringFromByteCount:total],
                                                              speed, remaining];
                                         self.downloadLastBytes = received;
                                         self.downloadLastSample = NSDate.date;
                                     }
                                 }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  NSURL *url = urls.firstObject;
  if (!url)
    return;
  NSString *extension = url.pathExtension.lowercaseString;
  if (![extension isEqualToString:@"ipsw"]) {
    UIAlertController *invalid = [UIAlertController
        alertControllerWithTitle:VZL(@"Unsupported Restore Image")
                         message:VZL(@"Choose a macOS IPSW restore image.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [invalid addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
                                                style:UIAlertActionStyleDefault
                                              handler:nil]];
    [self presentViewController:invalid animated:YES completion:nil];
    return;
  }
  [url startAccessingSecurityScopedResource];
  [self copySelectedRestoreImageAtURL:url];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_machines release];
    [_filteredMachines release];
    [_searchText release];
    [_pendingIPSWURL release];
    [_controlsView release];
    [_collectionView release];
    [_emptyView release];
    [_noResultsView release];
    [_noResultsBottomConstraint release];
    [_downloadTask cancel];
    [_downloadTask release];
    [_downloadTimer invalidate];
    [_downloadTimer release];
    _downloadController.cancellationHandler = nil;
    [_downloadController release];
    [_restoreCopyController release];
    [_downloadDestination release];
    [_downloadMarkerPath release];
    [_downloadLastSample release];
    [_downloadStartedAt release];
    [super dealloc];
}
@end
