#ifndef VZ_PATHS_H
#define VZ_PATHS_H

#include <unistd.h>

#if defined(VZ_ROOTHIDE)
#include <roothide.h>
#define VZRuntimePath(suffix) jbroot("/usr/libexec/VirtualMac/" suffix)
#define VZBootstrapPath(path) jbroot(path)
#define VZBootstrapArgument(path) rootfs(path)
#define VZStatePath(suffix) jbroot("/var/mobile/Library/VirtualMac/User/" suffix)
#define VZTemporaryPath(suffix) \
    jbroot(geteuid() == 0 ? "/var/mobile/Library/VirtualMac/Root/" suffix \
                         : "/var/mobile/Library/VirtualMac/User/Run/" suffix)
#define VZRestorePath(suffix) jbroot("/var/mobile/Library/VirtualMac/Root/" suffix)
#define VZNetworkPath(suffix) jbroot("/var/mobile/Library/VirtualMac/Network/" suffix)
#define VZSocketPath(suffix) jbroot("/var/run/vm/" suffix)
#define VZLogMode 0640
#define VZSocketMode 0660
#define VZInstallationsRoot VZStatePath("Installations")
#define VZLibraryRoot VZStatePath("Library")
#define VZRestoreImagesRoot VZStatePath("Restore Images")
#define VZDHCPLeasesPath VZNetworkPath("dhcpd_leases")
#define VZUSBMuxSocket VZSocketPath("usbmuxd")
#else
#define VZRuntimePath(suffix) ("/var/root/VirtualMac/" suffix)
#define VZBootstrapPath(path) \
    (access("/var/jb" path, X_OK) == 0 ? "/var/jb" path : path)
#define VZBootstrapArgument(path) (path)
#define VZStatePath(suffix) ("/var/mobile/Media/VirtualMac/" suffix)
#define VZTemporaryPath(suffix) ("/tmp/" suffix)
#define VZRestorePath(suffix) ("/tmp/" suffix)
#define VZNetworkPath(suffix) ("/tmp/" suffix)
#define VZSocketPath(suffix) ("/tmp/" suffix)
#define VZLogMode 0666
#define VZSocketMode 0666
#define VZInstallationsRoot "/var/mobile/Media/VirtualMac/Installations"
#define VZLibraryRoot "/var/mobile/Media/VirtualMac"
#define VZRestoreImagesRoot "/var/mobile/Media/VirtualMac/Restore Images"
#define VZDHCPLeasesPath "/var/db/dhcpd_leases"
#define VZUSBMuxSocket "/var/run/usbmuxd"
#endif

#if defined(__OBJC__)
#import <Foundation/NSString.h>
#import <Foundation/NSPathUtilities.h>
#if defined(VZ_ROOTHIDE)
#include <CommonCrypto/CommonDigest.h>
#endif

static inline NSString *VZNotificationName(NSString *name)
{
#if defined(VZ_ROOTHIDE)
    // Share a per-jailbreak namespace without publishing jbrand itself.
    NSString *seed = [NSString stringWithFormat:
        @"VirtualMac.notifications.%016llx", jbrand()];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(seed.UTF8String, (CC_LONG)strlen(seed.UTF8String), digest);
    char prefix[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < sizeof(digest); i++) {
        prefix[i * 2] = hex[digest[i] >> 4];
        prefix[i * 2 + 1] = hex[digest[i] & 15];
    }
    prefix[sizeof(prefix) - 1] = '\0';
    return [NSString stringWithFormat:@"%s.%@", prefix, name];
#else
    return name;
#endif
}

static inline NSString *VZStoredPath(NSString *path)
{
#if defined(VZ_ROOTHIDE)
    if (!path.length) return path;
    NSString *stored = @(rootfs(path.fileSystemRepresentation));
    NSString *legacy = @"/var/mobile/Library/VirtualMac/User/Legacy";
    if ([stored isEqualToString:legacy] ||
        [stored hasPrefix:[legacy stringByAppendingString:@"/"]])
        return [@"/var/mobile/Media/VirtualMac"
            stringByAppendingString:[stored substringFromIndex:legacy.length]];
    if ([stored hasPrefix:@"/rootfs/"] ||
        [stored hasPrefix:@"/var/mobile/Library/VirtualMac/"])
        return stored;
    // Shared folders may live elsewhere in the bootstrap. Distinguish those
    // logical paths from legacy configurations containing native host paths.
    return [@"jbroot:" stringByAppendingString:stored];
#else
    return path;
#endif
}

static inline NSString *VZLegacyLibraryPath(void)
{
#if defined(VZ_ROOTHIDE)
    NSString *private = @(VZStatePath("Legacy"));
    if (access(private.fileSystemRepresentation, F_OK) == 0)
        return private;
#endif
    return @"/var/mobile/Media/VirtualMac";
}

static inline NSString *VZResolvedStoredPath(NSString *path)
{
#if defined(VZ_ROOTHIDE)
    if ([path hasPrefix:@"jbroot:/"])
        path = @(jbroot([path substringFromIndex:7].fileSystemRepresentation));
    else if ([path hasPrefix:@"/rootfs/"] ||
        [path hasPrefix:@"/var/mobile/Library/VirtualMac/"])
        path = @(jbroot(path.fileSystemRepresentation));
    NSString *host = @"/var/mobile/Media/VirtualMac";
    NSString *normalized = [path hasPrefix:@"/private/var/"]
        ? [path substringFromIndex:8] : path;
    if ([normalized isEqualToString:host] ||
        [normalized hasPrefix:[host stringByAppendingString:@"/"]])
        return [VZLegacyLibraryPath() stringByAppendingString:
            [normalized substringFromIndex:host.length]];
#endif
    return path;
}
#endif

#endif
