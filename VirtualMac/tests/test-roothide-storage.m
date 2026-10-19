#import <Foundation/Foundation.h>
#import "../vz/host/VZAppSettings.h"
#import "../vz/host/VZPaths.h"
#include <stdlib.h>
#include <string.h>

#include "installation-attempt.inc"
static NSString * const VZSharedDirectoriesKey = @"SharedDirectories";
static NSString * const VZVMConfigurationFileName = @"VirtualMac.plist";
#include "write-vm-options.inc"

#if defined(VZ_ROOTHIDE)
static NSString *testRoot;
static NSString *testRootAlias;

unsigned long long jbrand(void)
{
    return [testRoot hasSuffix:@"root-before"]
        ? 0x0123456789abcdefULL : 0xfedcba9876543210ULL;
}

const char *jbroot(const char *path)
{
    NSString *value = @(path);
    if ([value hasPrefix:@"/rootfs/"])
        return [value substringFromIndex:7].UTF8String;
    return [testRoot stringByAppendingString:value].UTF8String;
}

const char *rootfs(const char *path)
{
    NSString *value = @(path);
    if ([value hasPrefix:[testRoot stringByAppendingString:@"/"]])
        return [value substringFromIndex:testRoot.length].UTF8String;
    if (testRootAlias && [value hasPrefix:[testRootAlias stringByAppendingString:@"/"]])
        return [value substringFromIndex:testRootAlias.length].UTF8String;
    return [@"/rootfs" stringByAppendingString:value].UTF8String;
}
#endif

static NSDictionary *readAttempt(NSString *attempt)
{
    NSDictionary *record = [NSDictionary dictionaryWithContentsOfFile:
        [attempt stringByAppendingPathComponent:@"Attempt.plist"]];
    NSCAssert(record != nil, @"installation record was not written");
    return record;
}

static void checkPaths(NSDictionary *record, NSString *image,
                       NSString *destination)
{
    NSCAssert([record[@"RestoreImage"] isEqualToString:image],
              @"restore image changed while updating status: %@", record);
    NSCAssert([record[@"Destination"] isEqualToString:destination],
              @"destination changed while updating status: %@", record);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSCAssert(argc == 2, @"expected a writable test directory");
        NSString *pattern = [@(argv[1]) stringByAppendingPathComponent:
            @"storage.XXXXXX"];
        char *temporary = strdup(pattern.fileSystemRepresentation);
        NSCAssert(temporary && mkdtemp(temporary), @"mkdtemp failed");
        NSString *directory = @(temporary);
        free(temporary);
        NSFileManager *manager = NSFileManager.defaultManager;
#if defined(VZ_ROOTHIDE)
        testRoot = [directory stringByAppendingPathComponent:@"root-before"];
        NSString *attempt = @(VZStatePath("Installations/Test.installation"));
#else
        NSString *attempt = [directory stringByAppendingPathComponent:
            @"Test.installation"];
#endif
        NSCAssert([manager createDirectoryAtPath:attempt
            withIntermediateDirectories:YES attributes:nil error:nil],
            @"cannot create test storage");
        NSString *image = [@(VZRestoreImagesRoot)
            stringByAppendingPathComponent:@"Restore Image.ipsw"];
        NSString *destination = [@(VZLibraryRoot)
            stringByAppendingPathComponent:@"Test VM.bundle"];
        NSString *storedImage = VZStoredPath(image);
        NSString *storedDestination = VZStoredPath(destination);
        VZWriteInstallationAttempt(attempt, @"installing", @{
            @"RestoreImage": image, @"Destination": destination});
        checkPaths(readAttempt(attempt), storedImage, storedDestination);
        for (NSString *state in @[@"failed", @"installing", @"complete"])
            VZWriteInstallationAttempt(attempt, state, @{@"Progress": @1});
        VZWriteInstallationAttempt(attempt, @"complete", nil);
        checkPaths(readAttempt(attempt), storedImage, storedDestination);
#if defined(VZ_ROOTHIDE)
        NSCAssert([storedDestination isEqualToString:
            @"/var/mobile/Library/VirtualMac/User/Library/Test VM.bundle"],
            @"private path retained a randomized root");
        NSString *host = @"/var/mobile/Media/External/Shared Folder";
        NSString *storedHost = VZStoredPath(host);
        NSCAssert([storedHost isEqualToString:
            @"/rootfs/var/mobile/Media/External/Shared Folder"],
            @"host share lost its host namespace");
        NSCAssert([VZResolvedStoredPath(storedHost) isEqualToString:host],
            @"host share no longer resolves to the original path");
        VZAppSettings *settings = [[VZAppSettings alloc] init];
        [settings setString:destination forKey:VZAutoBootVMPathKey];
        [settings release];
        NSString *oldRoot = testRoot;
        NSString *shared = @(jbroot("/var/mobile/Documents/Shared Folder"));
        NSString *storedShared = VZStoredPath(shared);
        NSCAssert([storedShared isEqualToString:
            @"jbroot:/var/mobile/Documents/Shared Folder"],
            @"bootstrap share was indistinguishable from a legacy host path");
        NSCAssert([VZResolvedStoredPath(storedShared) isEqualToString:shared],
            @"bootstrap share did not resolve before relocation");
        NSCAssert([VZResolvedStoredPath(host) isEqualToString:host],
            @"legacy shared folder was relocated into the bootstrap");
        NSString *oldVM = @"/var/mobile/Media/VirtualMac/Original VM.bundle";
        NSCAssert([VZResolvedStoredPath(oldVM) isEqualToString:oldVM],
            @"unmigrated legacy VM changed location");
        NSString *legacy = @(VZStatePath("Legacy"));
        NSCAssert([manager createDirectoryAtPath:legacy
            withIntermediateDirectories:YES attributes:nil error:nil],
            @"cannot create migrated legacy fixture");
        NSString *legacyVM = [legacy stringByAppendingPathComponent:@"Original VM.bundle"];
        NSCAssert([VZLegacyLibraryPath() isEqualToString:legacy],
            @"migrated library is not discoverable");
        for (NSString *spelling in @[oldVM, [@"/rootfs" stringByAppendingString:oldVM],
                                    [@"/private" stringByAppendingString:oldVM]])
            NSCAssert([VZResolvedStoredPath(spelling) isEqualToString:legacyVM],
                @"legacy reference did not follow migration: %@", spelling);
        NSString *storedLegacy = VZStoredPath(legacyVM);
        NSCAssert([storedLegacy isEqualToString:oldVM],
            @"standard builds cannot read tagged legacy paths after rollback");
        NSCAssert([VZResolvedStoredPath(storedLegacy) isEqualToString:legacyVM],
            @"portable legacy path did not resolve into the migrated directory");
        NSCAssert([manager createDirectoryAtPath:legacyVM
            withIntermediateDirectories:YES attributes:nil error:nil], @"cannot create legacy VM fixture");
        NSDictionary *legacyOptions = @{VZSharedDirectoriesKey: @[
            @{@"Path": [legacy stringByAppendingPathComponent:@"Shared"], @"ReadOnly": @YES},
            @{@"Path": host, @"ReadOnly": @NO}]};
        NSCAssert(VZWriteVMOptions(legacyOptions, legacyVM, nil), @"cannot save legacy options");
        NSDictionary *savedLegacyOptions = [NSDictionary dictionaryWithContentsOfFile:
            [legacyVM stringByAppendingPathComponent:VZVMConfigurationFileName]];
        NSArray *savedShares = savedLegacyOptions[VZSharedDirectoriesKey];
        NSCAssert([savedShares[0][@"Path"] isEqualToString:@"/var/mobile/Media/VirtualMac/Shared"] &&
            [savedShares[1][@"Path"] isEqualToString:host],
            @"legacy VM options cannot be read by standard builds after rollback");
        NSCAssert([legacyOptions[VZSharedDirectoriesKey][0][@"Path"] hasPrefix:legacy],
            @"saving options mutated the caller's paths");
        testRootAlias = [directory stringByAppendingPathComponent:@"root-alias"];
        NSString *aliasedLegacyVM = [testRootAlias stringByAppendingString:
            @"/var/mobile/Library/VirtualMac/User/Legacy/Original VM.bundle"];
        NSCAssert([VZStoredPath(aliasedLegacyVM) isEqualToString:storedLegacy],
            @"SDK-recognized root alias lost legacy rollback mapping");
        NSString *neighbor = @"/var/mobile/Media/VirtualMac-other/Shared";
        NSCAssert([VZResolvedStoredPath(neighbor) isEqualToString:neighbor],
            @"similarly named external folder was remapped");
        NSString *notification = VZNotificationName(@"com.mac.virtual.command-space.down");
        NSCAssert([notification isEqualToString:
            VZNotificationName(@"com.mac.virtual.command-space.down")],
            @"app and tweak must agree on the notification name");
        NSCAssert(![notification hasPrefix:@"com.mac.virtual."] &&
            ![notification containsString:@"0123456789abcdef"] &&
            [notification hasSuffix:@".command-space.down"],
            @"notification exposes a fixed channel or the raw jailbreak id");
        testRoot = [directory stringByAppendingPathComponent:@"root-after"];
        NSCAssert(![notification isEqualToString:
            VZNotificationName(@"com.mac.virtual.command-space.down")],
            @"notification channel survived jailbreak re-randomization");
        NSCAssert([manager moveItemAtPath:oldRoot toPath:testRoot error:nil],
            @"cannot simulate RootHide re-randomization");
        NSString *movedDestination = [@(VZLibraryRoot)
            stringByAppendingPathComponent:@"Test VM.bundle"];
        settings = [[VZAppSettings alloc] init];
        NSCAssert([[settings stringForKey:VZAutoBootVMPathKey]
            isEqualToString:movedDestination],
            @"auto-boot retained the previous randomized root");
        NSCAssert([VZResolvedStoredPath(storedDestination)
            isEqualToString:movedDestination],
            @"shared-folder or download path retained the previous root");
        NSCAssert([VZResolvedStoredPath(storedShared) isEqualToString:
            @(jbroot("/var/mobile/Documents/Shared Folder"))],
            @"arbitrary bootstrap share retained the previous root");
        NSString *movedLegacy = @(VZStatePath("Legacy"));
        NSCAssert([VZResolvedStoredPath(storedLegacy) isEqualToString:
            [movedLegacy stringByAppendingPathComponent:@"Original VM.bundle"]],
            @"migrated legacy reference retained the previous root");
        NSCAssert([manager removeItemAtPath:movedLegacy error:nil],
            @"cannot simulate legacy rollback");
        NSCAssert([VZResolvedStoredPath(storedLegacy) isEqualToString:oldVM],
            @"legacy reference failed after rollback");
        attempt = @(VZStatePath("Installations/Test.installation"));
        VZWriteInstallationAttempt(attempt, @"complete", @{@"Reloaded": @YES});
        checkPaths(readAttempt(attempt), storedImage, storedDestination);
        [settings setString:host forKey:VZAutoBootVMPathKey];
        [settings release];
        settings = [[VZAppSettings alloc] init];
        NSCAssert([[settings stringForKey:VZAutoBootVMPathKey]
            isEqualToString:host], @"legacy host auto-boot path changed");
        [settings release];
        puts("RootHide storage: repeated updates and root relocation passed");
#else
        NSDictionary *standardOptions = @{VZSharedDirectoriesKey: @[
            @{@"Path": @"/var/mobile/Media/Shared", @"ReadOnly": @YES}]};
        NSCAssert(VZWriteVMOptions(standardOptions, attempt, nil), @"standard options save failed");
        NSDictionary *savedStandardOptions = [NSDictionary dictionaryWithContentsOfFile:
            [attempt stringByAppendingPathComponent:VZVMConfigurationFileName]];
        NSCAssert([savedStandardOptions isEqualToDictionary:standardOptions],
            @"standard option serialization changed");
        NSCAssert([VZNotificationName(@"com.mac.virtual.settings-changed")
            isEqualToString:@"com.mac.virtual.settings-changed"],
            @"standard notification channel changed");
        NSCAssert([storedImage isEqualToString:image] &&
            [storedDestination isEqualToString:destination],
            @"standard paths changed during serialization");
        NSCAssert([VZResolvedStoredPath(destination)
            isEqualToString:destination], @"standard path was relocated");
        NSCAssert([VZLegacyLibraryPath() isEqualToString:@"/var/mobile/Media/VirtualMac"],
            @"standard library path changed");
        puts("Standard storage: existing paths and repeated updates passed");
#endif
        NSCAssert([manager removeItemAtPath:directory error:nil],
                  @"cannot remove test storage");
    }
    return 0;
}
