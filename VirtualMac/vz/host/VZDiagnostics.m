#import "VZPaths.h"
#import "VZDiagnostics.h"
#import "VZAppSettings.h"
#import <UIKit/UIKit.h>
#import <errno.h>
#import <ifaddrs.h>
#import <limits.h>
#import <net/if.h>
#import <netdb.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <sys/sysctl.h>
#import <sys/wait.h>
#import <sys/utsname.h>
#import <pwd.h>
#import <string.h>
#import <unistd.h>

extern char **environ;

static uint32_t VZCRC32(NSData *data)
{
    uint32_t crc = UINT32_MAX;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger index = 0; index < data.length; index++) {
        crc ^= bytes[index];
        for (NSUInteger bit = 0; bit < 8; bit++)
            crc = (crc >> 1) ^ (0xedb88320U & -(int32_t)(crc & 1));
    }
    return ~crc;
}

static NSString *VZDiagnosticsLibraryPath(void)
{
    return @(VZLibraryRoot);
}

static NSArray *VZDiagnosticsInstallationPaths(void)
{
    NSString *directory = @(VZInstallationsRoot);
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:directory error:nil])
        [paths addObject:[directory stringByAppendingPathComponent:name]];
    return paths;
}

static void VZAppend16(NSMutableData *data, uint16_t value)
{
    [data appendBytes:&value length:sizeof(value)];
}

static void VZAppend32(NSMutableData *data, uint32_t value)
{
    [data appendBytes:&value length:sizeof(value)];
}

static NSData *VZBoundedFileData(NSString *path)
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle)
        return nil;
    unsigned long long size = [handle seekToEndOfFile];
    const unsigned long long limit = 8ULL << 20;
    [handle seekToFileOffset:size > limit ? size - limit : 0];
    NSData *data = [handle readDataToEndOfFile];
    [handle closeFile];
    return data;
}

typedef void (^VZDiagnosticEntryHandler)(NSString *name, NSData *data);

static void VZAddEntry(VZDiagnosticEntryHandler handler,
                       NSString *name, NSData *data)
{
    if (!name.length || !data.length)
        return;
    handler(name, data);
}

static void VZAppendPathStatus(NSMutableString *report, NSString *path)
{
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        int error = errno;
        [report appendFormat:@"%@ lstat-error=%d (%s)\n", path, error,
                             strerror(error)];
        return;
    }
    [report appendFormat:
        @"%@ mode=%04o uid=%u gid=%u size=%lld access=%c%c%c\n",
        path, info.st_mode & 07777, info.st_uid, info.st_gid,
        (long long)info.st_size,
        access(path.fileSystemRepresentation, R_OK) == 0 ? 'r' : '-',
        access(path.fileSystemRepresentation, W_OK) == 0 ? 'w' : '-',
        access(path.fileSystemRepresentation, X_OK) == 0 ? 'x' : '-'];
}

static NSData *VZInstallerPreflightData(void)
{
    NSMutableString *report = [NSMutableString stringWithFormat:
        @"caller uid=%u euid=%u gid=%u egid=%u\n",
        getuid(), geteuid(), getgid(), getegid()];
    NSArray *paths = @[@"/var", @"/var/root", @"/var/root/VirtualMac",
        @"/var/root/VirtualMac/install",
        @"/var/root/VirtualMac/install/install-launcher",
        @"/var/root/VirtualMac/install/start-install.sh"];
    for (NSString *path in paths)
        VZAppendPathStatus(report, path);
    NSString *rootHideRoot = VZRootHideJailbreakRootPath();
    if (rootHideRoot.length) {
        [report appendFormat:@"RootHide jailbreak root=%@\n", rootHideRoot];
        for (NSString *suffix in @[@"var/root/VirtualMac",
                                    @"rootfs/var/root/VirtualMac",
                                    @"usr/libexec/VirtualMac"])
            VZAppendPathStatus(report,
                [rootHideRoot stringByAppendingPathComponent:suffix]);
    }

    struct statfs fileSystem = {0};
    if (statfs("/var/root", &fileSystem) == 0) {
        [report appendFormat:@"/var/root filesystem=%s flags=0x%lx\n",
            fileSystem.f_fstypename, (unsigned long)fileSystem.f_flags];
    } else {
        int error = errno;
        [report appendFormat:@"/var/root statfs-error=%d (%s)\n",
                             error, strerror(error)];
    }

    int descriptors[2] = {-1, -1};
    if (pipe(descriptors) != 0) {
        int error = errno;
        [report appendFormat:@"preflight pipe-error=%d (%s)\n",
                             error, strerror(error)];
        return [report dataUsingEncoding:NSUTF8StringEncoding];
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, descriptors[0]);
    posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, descriptors[1]);
    const char *launcher =
        VZRuntimePath("install/install-launcher");
    // A spawn error diagnoses the parent-directory/execute-permission failure
    // that prevents the launcher from running at all. Output from the
    // diagnostics-only mode covers the later privilege/script boundary.
    char *arguments[] = {(char *)launcher, "--diagnose", NULL};
    pid_t process = 0;
    int spawned = posix_spawn(&process, launcher, &actions, NULL,
                              arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(descriptors[1]);
    if (spawned != 0) {
        close(descriptors[0]);
        [report appendFormat:@"preflight posix_spawn=%d (%s)\n",
                             spawned, strerror(spawned)];
        return [report dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSMutableData *output = [NSMutableData data];
    uint8_t buffer[1024];
    for (;;) {
        ssize_t count = read(descriptors[0], buffer, sizeof(buffer));
        if (count > 0) {
            [output appendBytes:buffer length:(NSUInteger)count];
            continue;
        }
        if (count < 0 && errno == EINTR)
            continue;
        break;
    }
    close(descriptors[0]);
    int status = 0;
    pid_t waited;
    do {
        waited = waitpid(process, &status, 0);
    } while (waited < 0 && errno == EINTR);
    NSString *text = [[[NSString alloc] initWithData:output
        encoding:NSUTF8StringEncoding] autorelease];
    if (text.length)
        [report appendString:text];
    [report appendFormat:@"preflight wait=%d exited=%d status=%d signal=%d\n",
        waited, WIFEXITED(status), WIFEXITED(status) ? WEXITSTATUS(status) : -1,
        WIFSIGNALED(status) ? WTERMSIG(status) : 0];
    return [report dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *VZCommandOutput(NSString *executable,
                               NSArray<NSString *> *arguments)
{
    int descriptors[2] = {-1, -1};
    if (pipe(descriptors) != 0)
        return [[NSString stringWithFormat:@"pipe failed: %s\n", strerror(errno)]
            dataUsingEncoding:NSUTF8StringEncoding];
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, descriptors[0]);
    posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, descriptors[1]);
    NSUInteger count = arguments.count + 1;
    char **argv = calloc(count + 1, sizeof(char *));
    argv[0] = (char *)executable.fileSystemRepresentation;
    for (NSUInteger index = 0; index < arguments.count; index++)
        argv[index + 1] = (char *)arguments[index].UTF8String;
    pid_t process = 0;
    int spawned = posix_spawn(&process, executable.fileSystemRepresentation,
        &actions, NULL, argv, environ);
    free(argv);
    posix_spawn_file_actions_destroy(&actions);
    close(descriptors[1]);
    if (spawned != 0) {
        close(descriptors[0]);
        return [[NSString stringWithFormat:@"%@ failed to start: %s\n",
            executable, strerror(spawned)]
            dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSMutableData *output = [NSMutableData data];
    uint8_t buffer[4096];
    const NSUInteger limit = 4U << 20;
    for (;;) {
        ssize_t bytes = read(descriptors[0], buffer, sizeof(buffer));
        if (bytes > 0) {
            NSUInteger remaining = limit > output.length
                ? limit - output.length : 0;
            if (remaining)
                [output appendBytes:buffer length:MIN((NSUInteger)bytes,
                                                      remaining)];
            continue;
        }
        if (bytes < 0 && errno == EINTR)
            continue;
        break;
    }
    close(descriptors[0]);
    int status = 0;
    while (waitpid(process, &status, 0) < 0 && errno == EINTR) {}
    NSString *footer = [NSString stringWithFormat:
        @"\n[exit=%d signal=%d]\n",
        WIFEXITED(status) ? WEXITSTATUS(status) : -1,
        WIFSIGNALED(status) ? WTERMSIG(status) : 0];
    [output appendData:[footer dataUsingEncoding:NSUTF8StringEncoding]];
    return output;
}

static NSString *VZFirstExecutablePath(NSArray<NSString *> *paths)
{
    for (NSString *path in paths) {
        if (access(path.fileSystemRepresentation, X_OK) == 0)
            return path;
    }
    return nil;
}

static NSData *VZBootstrapData(void)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *rootHideRoot = VZRootHideJailbreakRootPath();
    BOOL rootless = [manager fileExistsAtPath:@"/var/jb"] ||
        rootHideRoot.length;
    NSString *brand = @"Unknown";
    NSString *versionPath = nil;
    if (rootHideRoot.length) {
        brand = @"Dopamine RootHide";
        versionPath = [rootHideRoot stringByAppendingPathComponent:
            @"basebin/.version"];
    } else if ([manager fileExistsAtPath:@"/var/jb/basebin/dopamine"]) {
        brand = @"Dopamine";
        versionPath = @"/var/jb/basebin/.version";
    } else if ([manager fileExistsAtPath:@"/taurine"]) {
        brand = @"Taurine";
    }
    NSString *version = @"unknown";
    NSData *versionData = versionPath ? VZBoundedFileData(versionPath) : nil;
    if (versionData.length) {
        NSString *candidate = [[[NSString alloc] initWithData:versionData
            encoding:NSUTF8StringEncoding] autorelease];
        candidate = [candidate stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (candidate.length) version = candidate;
    }
    NSMutableString *report = [NSMutableString stringWithFormat:
        @"Detected jailbreak: %@\nVersion: %@\nBootstrap variant: %@\n"
         "uid=%u euid=%u gid=%u egid=%u\n",
        brand, version, rootless ? @"rootless" : @"rootful",
        getuid(), geteuid(), getgid(), getegid()];
    [report appendFormat:@"Bundle path=%@\nExecutable path=%@\n",
        NSBundle.mainBundle.bundlePath,
        NSBundle.mainBundle.executablePath ?: @"(unknown)"];
    if (rootHideRoot.length)
        [report appendFormat:@"RootHide jailbreak root=%@\n", rootHideRoot];
    for (NSString *name in @[@"JB_ROOT_PATH", @"PATH",
                              @"DYLD_INSERT_LIBRARIES"]) {
        const char *value = getenv(name.UTF8String);
        [report appendFormat:@"%@=%s\n", name, value ?: "(unset)"];
    }
    NSArray *paths = @[@"/var/jb", @"/var/jb/basebin",
        @"/var/jb/basebin/dopamine", @"/taurine", @"/odyssey",
        @"/chimera", @"/var/jb/usr/bin/dpkg-query",
        @"/usr/bin/dpkg-query", @"/var/jb/Library/dpkg/status",
        @"/Library/dpkg/status", @"/var/lib/dpkg/status"];
    for (NSString *path in paths) {
        VZAppendPathStatus(report, path);
        char resolved[PATH_MAX] = {0};
        if (realpath(path.fileSystemRepresentation, resolved))
            [report appendFormat:@"  resolved=%s\n", resolved];
    }
    if (rootHideRoot.length) {
        for (NSString *suffix in @[@"basebin", @"basebin/.version",
                                    @"usr/bin/dpkg-query",
                                    @"var/lib/dpkg/status",
                                    @"Applications/VirtualMac.app",
                                    @"var/root/VirtualMac",
                                    @"rootfs/var/root/VirtualMac"])
            VZAppendPathStatus(report,
                [rootHideRoot stringByAppendingPathComponent:suffix]);
    }
    for (NSString *path in @[@"/var/jb/basebin/.version",
                              @"/var/jb/.procursus_strapped",
                              @"/.installed_unc0ver"]) {
        NSData *data = VZBoundedFileData(path);
        if (!data.length)
            continue;
        NSString *value = [[[NSString alloc] initWithData:data
            encoding:NSUTF8StringEncoding] autorelease];
        [report appendFormat:@"%@ contents=%@\n", path,
            [value stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    }
    return [report dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *VZTweakInventoryData(void)
{
    NSMutableString *report = [NSMutableString string];
    NSMutableArray *directories = [NSMutableArray arrayWithArray:@[
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries",
        @"/var/jb/usr/lib/TweakInject",
        @"/Library/MobileSubstrate/DynamicLibraries",
        @"/usr/lib/TweakInject",
    ]];
    NSString *rootHideRoot = VZRootHideJailbreakRootPath();
    if (rootHideRoot.length) {
        [directories addObject:[rootHideRoot stringByAppendingPathComponent:
            @"Library/MobileSubstrate/DynamicLibraries"]];
        [directories addObject:[rootHideRoot stringByAppendingPathComponent:
            @"usr/lib/TweakInject"]];
    }
    for (NSString *directory in directories) {
        NSArray *entries = [[NSFileManager.defaultManager
            contentsOfDirectoryAtPath:directory error:nil]
            sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        if (!entries)
            continue;
        [report appendFormat:@"[%@]\n", directory];
        for (NSString *entry in entries)
            [report appendFormat:@"%@\n", entry];
        [report appendString:@"\n"];
    }
    if (!report.length)
        [report appendString:@"No tweak injection directories were readable.\n"];
    return [report dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *VZLanguageAndKeyboardData(void)
{
    NSMutableString *report = [NSMutableString stringWithFormat:
        @"Locale: %@\nPreferred languages: %@\nTime zone: %@\n"
         "Screen captured: %@\n",
        NSLocale.currentLocale.localeIdentifier,
        NSLocale.preferredLanguages,
        NSTimeZone.localTimeZone.name,
        UIScreen.mainScreen.isCaptured ? @"yes" : @"no"];
    id configured = [NSUserDefaults.standardUserDefaults
        objectForKey:@"AppleKeyboards"];
    id expanded = [NSUserDefaults.standardUserDefaults
        objectForKey:@"AppleKeyboardsExpanded"];
    [report appendFormat:@"AppleKeyboards: %@\nAppleKeyboardsExpanded: %@\n",
        configured ?: @"unavailable", expanded ?: @"unavailable"];
    [report appendString:@"Active input modes:\n"];
    NSUInteger index = 0;
    for (UITextInputMode *mode in UITextInputMode.activeInputModes) {
        [report appendFormat:@"%lu. class=%@ language=%@\n",
            (unsigned long)++index, NSStringFromClass(mode.class),
            mode.primaryLanguage ?: @"(none)"];
    }
    return [report dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *VZStorageData(void)
{
    NSMutableString *report = [NSMutableString string];
    NSArray *paths = @[@"/var", @"/var/mobile", VZDiagnosticsLibraryPath(),
        @"/var/root", @"/var/root/VirtualMac"];
    for (NSString *path in paths) {
        VZAppendPathStatus(report, path);
        struct statfs fileSystem = {0};
        if (statfs(path.fileSystemRepresentation, &fileSystem) != 0) {
            int error = errno;
            [report appendFormat:@"  statfs-error=%d (%s)\n", error,
                                 strerror(error)];
            continue;
        }
        uint64_t blockSize = (uint64_t)fileSystem.f_bsize;
        [report appendFormat:
            @"  filesystem=%s flags=0x%lx total=%llu free=%llu available=%llu\n",
            fileSystem.f_fstypename, (unsigned long)fileSystem.f_flags,
            (unsigned long long)((uint64_t)fileSystem.f_blocks * blockSize),
            (unsigned long long)((uint64_t)fileSystem.f_bfree * blockSize),
            (unsigned long long)((uint64_t)fileSystem.f_bavail * blockSize)];
    }
    return [report dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *VZNetworkData(void)
{
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) {
        return [[NSString stringWithFormat:@"getifaddrs failed: %s\n",
            strerror(errno)] dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSMutableArray *lines = [NSMutableArray array];
    for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
        if (!item->ifa_addr)
            continue;
        int family = item->ifa_addr->sa_family;
        if (family != AF_INET && family != AF_INET6)
            continue;
        char address[NI_MAXHOST] = {0};
        char netmask[NI_MAXHOST] = {0};
        if (getnameinfo(item->ifa_addr, item->ifa_addr->sa_len, address,
                        sizeof(address), NULL, 0, NI_NUMERICHOST) != 0)
            strlcpy(address, "?", sizeof(address));
        if (!item->ifa_netmask ||
            getnameinfo(item->ifa_netmask, item->ifa_netmask->sa_len, netmask,
                        sizeof(netmask), NULL, 0, NI_NUMERICHOST) != 0)
            strlcpy(netmask, "?", sizeof(netmask));
        [lines addObject:[NSString stringWithFormat:
            @"%s family=%s flags=0x%x address=%s netmask=%s",
            item->ifa_name ?: "?", family == AF_INET ? "IPv4" : "IPv6",
            item->ifa_flags, address, netmask]];
    }
    freeifaddrs(interfaces);
    [lines sortUsingSelector:@selector(compare:)];
    return [[[lines componentsJoinedByString:@"\n"]
        stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *VZRuntimePathData(void)
{
    NSMutableString *report = [NSMutableString string];
    NSArray *paths = @[
        @"/Applications/VirtualMac.app",
        @"/Applications/VirtualMac.app/VirtualMac",
        @"/var/jb/Applications/VirtualMac.app",
        @"/var/jb/Applications/VirtualMac.app/VirtualMac",
        @"/var/root/VirtualMac",
        @"/var/root/VirtualMac/install",
        @"/var/root/VirtualMac/payload",
        @"/usr/libexec/VirtualMac/InternetSharing",
        @"/usr/libexec/VirtualMac/InternetSharing.ipados14",
        @"/usr/libexec/VirtualMac/bootpd",
        @"/var/root/VirtualMac/rootful/Library/LaunchDaemons/com.apple.NetworkSharing.plist",
        @"/var/root/VirtualMac/rootful/Library/LaunchDaemons/com.apple.bootpd.plist",
        @"/var/root/VirtualMac/rootful/Library/LaunchDaemons/vzi.apple.bootpd-controller.plist",
        @(VZNetworkPath("bootpd.plist")),
        @(VZDHCPLeasesPath),
        @"/Library/MobileSubstrate/DynamicLibraries/VZKeyboardPassthrough.dylib",
        @"/usr/lib/TweakInject/VZKeyboardPassthrough.dylib",
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/VZKeyboardPassthrough.dylib",
        @"/var/jb/usr/lib/TweakInject/VZKeyboardPassthrough.dylib",
        @(VZUSBMuxSocket),
        @(VZSocketPath("vzusbmuxd")),
    ];
    for (NSString *path in paths) {
        VZAppendPathStatus(report, path);
        char resolved[PATH_MAX] = {0};
        if (realpath(path.fileSystemRepresentation, resolved))
            [report appendFormat:@"  resolved=%s\n", resolved];
    }
    NSString *rootHideRoot = VZRootHideJailbreakRootPath();
    if (rootHideRoot.length) {
        [report appendFormat:@"RootHide jailbreak root=%@\n", rootHideRoot];
        for (NSString *suffix in @[@"Applications/VirtualMac.app",
                                    @"var/root/VirtualMac",
                                    @"rootfs/var/root/VirtualMac",
                                    @"usr/libexec/VirtualMac",
                                    @"usr/lib/TweakInject/VZKeyboardPassthrough.dylib"])
            VZAppendPathStatus(report,
                [rootHideRoot stringByAppendingPathComponent:suffix]);
    }
    return [report dataUsingEncoding:NSUTF8StringEncoding];
}

static void VZEnumerateDiagnosticEntries(VZDiagnosticEntryHandler handler)
{
    struct utsname systemInfo = {0};
    uname(&systemInfo);
    size_t buildLength = 0;
    sysctlbyname("kern.osversion", NULL, &buildLength, NULL, 0);
    NSMutableData *buildData = [NSMutableData dataWithLength:buildLength ?: 1];
    if (buildLength)
        sysctlbyname("kern.osversion", buildData.mutableBytes,
                     &buildLength, NULL, 0);
    NSString *osBuild = buildLength
        ? [NSString stringWithUTF8String:buildData.bytes] : @"unknown";
    NSDictionary *fileSystem = [NSFileManager.defaultManager
        attributesOfFileSystemForPath:VZDiagnosticsLibraryPath() error:nil] ?: @{};
    NSDictionary *bundleInfo = NSBundle.mainBundle.infoDictionary ?: @{};
    UIScreen *screen = UIScreen.mainScreen;
    NSString *manifest = [NSString stringWithFormat:
        @"Virtual Mac diagnostics\n"
         "Created: %@\nApp version: %@ (%@)\nDevice: %s\n"
         "%@: %@ (%@)\nPhysical memory: %llu\nFree storage: %@\n"
         "Total storage: %@\nUptime: %.0f seconds\nThermal state: %ld\n"
         "Low Power Mode: %@\nProtected data available: %@\n"
         "Application state: %ld\nScreen bounds: %@\nNative bounds: %@\n"
         "Screen scale: %.2f\nNative scale: %.2f\nBundle path: %@\n"
         "Executable path: %@\nRootHide jailbreak root: %@\n",
        NSDate.date, bundleInfo[@"CFBundleShortVersionString"] ?: @"unknown",
        bundleInfo[@"CFBundleVersion"] ?: @"unknown", systemInfo.machine,
        UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone
            ? @"iOS" : @"iPadOS",
        NSProcessInfo.processInfo.operatingSystemVersionString, osBuild,
        (unsigned long long)NSProcessInfo.processInfo.physicalMemory,
        fileSystem[NSFileSystemFreeSize] ?: @"unknown",
        fileSystem[NSFileSystemSize] ?: @"unknown",
        NSProcessInfo.processInfo.systemUptime,
        (long)NSProcessInfo.processInfo.thermalState,
        NSProcessInfo.processInfo.lowPowerModeEnabled ? @"yes" : @"no",
        UIApplication.sharedApplication.protectedDataAvailable ? @"yes" : @"no",
        (long)UIApplication.sharedApplication.applicationState,
        NSStringFromCGRect(screen.bounds), NSStringFromCGRect(screen.nativeBounds),
        screen.scale, screen.nativeScale, NSBundle.mainBundle.bundlePath,
        NSBundle.mainBundle.executablePath ?: @"(unknown)",
        VZRootHideJailbreakRootPath() ?: @"(none)"];
    VZAddEntry(handler, @"manifest.txt",
        [manifest dataUsingEncoding:NSUTF8StringEncoding]);
    VZAddEntry(handler, @"installer/preflight.txt",
        VZInstallerPreflightData());
    VZAddEntry(handler, @"device/language-and-keyboards.txt",
        VZLanguageAndKeyboardData());
    VZAddEntry(handler, @"device/storage-and-mounts.txt", VZStorageData());
    VZAddEntry(handler, @"device/network-interfaces.txt", VZNetworkData());
    VZAddEntry(handler, @"device/dns/etc-resolv.conf",
        VZBoundedFileData(@"/etc/resolv.conf"));
    VZAddEntry(handler, @"device/dns/var-run-resolv.conf",
        VZBoundedFileData(@"/var/run/resolv.conf"));
    VZAddEntry(handler, @"network/bootpd.plist",
        VZBoundedFileData(@(VZNetworkPath("bootpd.plist"))));
    VZAddEntry(handler, @"network/dhcpd-leases.txt",
        VZBoundedFileData(@(VZDHCPLeasesPath)));
    VZAddEntry(handler, @"jailbreak/environment.txt", VZBootstrapData());
    VZAddEntry(handler, @"jailbreak/tweak-injection-files.txt",
        VZTweakInventoryData());
    NSString *rootHideRoot = VZRootHideJailbreakRootPath();
    NSMutableArray *dpkgQueryPaths = [NSMutableArray arrayWithArray:
        @[@"/var/jb/usr/bin/dpkg-query", @"/usr/bin/dpkg-query"]];
    if (rootHideRoot.length)
        [dpkgQueryPaths insertObject:[rootHideRoot
            stringByAppendingPathComponent:@"usr/bin/dpkg-query"] atIndex:0];
    NSString *dpkgQuery = VZFirstExecutablePath(dpkgQueryPaths);
    if (dpkgQuery) {
        VZAddEntry(handler, @"jailbreak/packages.txt",
            VZCommandOutput(dpkgQuery, @[@"-W",
                @"-f=${Package}\t${Version}\t${Architecture}\\n"]));
        VZAddEntry(handler, @"package/metadata.txt",
            VZCommandOutput(dpkgQuery, @[@"-s", @"com.mac.virtual"]));
    }
    NSMutableArray *dpkgPaths = [NSMutableArray arrayWithArray:
        @[@"/var/jb/usr/bin/dpkg", @"/usr/bin/dpkg"]];
    if (rootHideRoot.length)
        [dpkgPaths insertObject:[rootHideRoot
            stringByAppendingPathComponent:@"usr/bin/dpkg"] atIndex:0];
    NSString *dpkg = VZFirstExecutablePath(dpkgPaths);
    if (dpkg)
        VZAddEntry(handler, @"package/verification.txt",
            VZCommandOutput(dpkg, @[@"--verify", @"com.mac.virtual"]));
    VZAddEntry(handler, @"package/runtime-paths.txt", VZRuntimePathData());

    NSString *launchctl = VZFirstExecutablePath(
        @[@(VZBootstrapPath("/usr/bin/launchctl"))]);
    if (launchctl) {
        for (NSString *domain in @[@"system", @"user/501"]) {
            for (NSString *label in @[@"com.apple.NetworkSharing",
                                      @"vzi.apple.bootpd",
                                      @"vzi.apple.bootpd-controller"]) {
                NSString *safeDomain = [domain stringByReplacingOccurrencesOfString:@"/"
                    withString:@"-"];
                VZAddEntry(handler, [NSString stringWithFormat:
                    @"network/launchctl-%@-%@.txt", safeDomain, label],
                    VZCommandOutput(launchctl, @[@"print",
                        [NSString stringWithFormat:@"%@/%@", domain, label]]));
            }
        }
    }
    NSString *ps = VZFirstExecutablePath(@[@(VZBootstrapPath("/bin/ps"))
#if defined(VZ_ROOTHIDE)
        , @"/bin/ps"
#endif
    ]);
    if (ps)
        VZAddEntry(handler, @"device/processes.txt",
            VZCommandOutput(ps, @[@"-axo", @"pid,ppid,user,state,command"]));

    NSData *settings = [NSPropertyListSerialization dataWithPropertyList:
        VZAppSettings.sharedSettings.dictionaryRepresentation
        format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    VZAddEntry(handler, @"Settings.plist", settings);

    NSArray *logNames = @[@"VirtualMac.log", @"vmmhook.log",
        @"vmm.stderr.log", @"vzxpchook.log", @"pvg-trace.log",
        @"InternetSharing.stdout.log", @"InternetSharing.stderr.log",
        @"bootpd.stdout.log", @"bootpd.stderr.log",
        @"InternetSharing.out", @"InternetSharing.err",
        @"bootpd.out", @"bootpd.err",
        @"bootpd-controller.out", @"bootpd-controller.err"];
    for (NSString *name in logNames) {
        NSString *directory = @(VZTemporaryPath(""));
#if defined(VZ_ROOTHIDE)
        if ([name hasPrefix:@"InternetSharing"] || [name hasPrefix:@"bootpd"])
            directory = @(VZNetworkPath(""));
#endif
        VZAddEntry(handler, [@"logs" stringByAppendingPathComponent:name],
            VZBoundedFileData([directory stringByAppendingPathComponent:name]));
    }
#if defined(VZ_ROOTHIDE)
    VZAddEntry(handler, @"logs/vz-springboard-shortcuts.log",
        VZBoundedFileData(@(VZStatePath("Run/vz-springboard-shortcuts.log"))));
    for (NSString *name in @[@"vmmhook.log", @"vzxpchook.log",
                             @"restore-vmm.stderr.log", @"socket-connect.log"])
        VZAddEntry(handler, [@"restore" stringByAppendingPathComponent:name],
            VZBoundedFileData([@(VZRestorePath("")) stringByAppendingPathComponent:name]));
    for (NSString *name in @[@"com.apple.vmnet.plist", @"com.apple.dhcp6d.plist"])
        VZAddEntry(handler, [@"network" stringByAppendingPathComponent:name],
            VZBoundedFileData([@(VZNetworkPath("")) stringByAppendingPathComponent:name]));
#endif

    NSArray *temporary = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:@(VZRestorePath("")) error:nil];
    for (NSString *name in temporary) {
        if (![name hasPrefix:@"VirtualMac-install"] &&
            ![name hasPrefix:@"vz-usbmuxd"] &&
            ![name hasPrefix:@"installation"])
            continue;
        VZAddEntry(handler, [@"restore" stringByAppendingPathComponent:name],
            VZBoundedFileData([@(VZRestorePath("")) stringByAppendingPathComponent:name]));
    }

    NSMutableArray *inventory = [NSMutableArray array];
    NSArray *bundles = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:VZDiagnosticsLibraryPath() error:nil];
    for (NSString *name in bundles) {
        if (![name.pathExtension.lowercaseString isEqualToString:@"bundle"])
            continue;
        NSString *bundlePath = [VZDiagnosticsLibraryPath()
            stringByAppendingPathComponent:name];
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"Name"] = name;
        for (NSString *fileName in @[@"Disk.img", @"MachineIdentifier",
                                      @"AuxiliaryStorage", @"HardwareModel"]) {
            NSDictionary *attributes = [NSFileManager.defaultManager
                attributesOfItemAtPath:[bundlePath
                    stringByAppendingPathComponent:fileName] error:nil];
            if (attributes[NSFileSize])
                item[fileName] = attributes[NSFileSize];
        }
        [inventory addObject:item];
        NSString *configuration = [bundlePath
            stringByAppendingPathComponent:@"VirtualMac.plist"];
        VZAddEntry(handler,
            [NSString stringWithFormat:@"virtual-machines/%@/VirtualMac.plist",
                                       name],
            VZBoundedFileData(configuration));
    }
    NSData *inventoryData = [NSJSONSerialization dataWithJSONObject:inventory
        options:NSJSONWritingPrettyPrinted error:nil];
    VZAddEntry(handler, @"virtual-machines/inventory.json", inventoryData);

    NSString *crashRoot = @"/var/mobile/Library/Logs/CrashReporter";
    NSDirectoryEnumerator *crashEnumerator = [NSFileManager.defaultManager
        enumeratorAtPath:crashRoot];
    NSUInteger crashFileCount = 0;
    NSUInteger unreadableCrashFileCount = 0;
    for (NSString *relativePath in crashEnumerator) {
        NSString *path = [crashRoot stringByAppendingPathComponent:relativePath];
        BOOL directory = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:path
            isDirectory:&directory] || directory)
            continue;
        NSData *contents = [[NSData alloc] initWithContentsOfFile:path];
        if (!contents) {
            unreadableCrashFileCount++;
            continue;
        }
        crashFileCount++;
        VZAddEntry(handler, [@"crash-reports"
            stringByAppendingPathComponent:relativePath], contents);
        [contents release];
    }
    NSString *crashSummary = [NSString stringWithFormat:
        @"Included files: %lu\nUnreadable files: %lu\nSource: %@\n",
        (unsigned long)crashFileCount,
        (unsigned long)unreadableCrashFileCount, crashRoot];
    VZAddEntry(handler, @"crash-reports/summary.txt",
        [crashSummary dataUsingEncoding:NSUTF8StringEncoding]);

    for (NSString *artifactPath in VZDiagnosticsInstallationPaths()) {
        NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager
            enumeratorAtPath:artifactPath];
        NSMutableString *inventory = [NSMutableString string];
        for (NSString *relativePath in enumerator) {
            NSString *path = [artifactPath stringByAppendingPathComponent:
                relativePath];
            struct stat info = {0};
            if (lstat(path.fileSystemRepresentation, &info) != 0) {
                [inventory appendFormat:@"unreadable %@: %s\n", relativePath,
                    strerror(errno)];
                continue;
            }
            if (S_ISDIR(info.st_mode)) {
                [inventory appendFormat:@"directory %04o %@\n",
                    info.st_mode & 07777, relativePath];
                continue;
            }
            if (!S_ISREG(info.st_mode)) {
                [inventory appendFormat:@"other %04o %lld %@\n",
                    info.st_mode & 07777, (long long)info.st_size,
                    relativePath];
                continue;
            }
            [inventory appendFormat:@"file %04o %lld %@%@\n",
                info.st_mode & 07777, (long long)info.st_size, relativePath,
                info.st_size > (1LL << 20) ? @" (contents excluded)" : @""];
            NSString *extension = relativePath.pathExtension.lowercaseString;
            BOOL diagnosticText = [@[@"plist", @"log", @"txt"]
                containsObject:extension];
            if (!diagnosticText && info.st_size > (1LL << 20))
                continue;
            NSString *archiveName = [NSString stringWithFormat:
                @"restore/attempts/%@/%@", artifactPath.lastPathComponent,
                relativePath];
            VZAddEntry(handler, archiveName, VZBoundedFileData(path));
        }
        NSString *inventoryName = [NSString stringWithFormat:
            @"restore/attempts/%@/inventory.txt",
            artifactPath.lastPathComponent];
        VZAddEntry(handler, inventoryName,
            [inventory dataUsingEncoding:NSUTF8StringEncoding]);
    }
}

NSURL *VZCreateDiagnosticsArchive(NSError **error)
{
    NSString *directory = @(VZStatePath("Diagnostics"));
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:error])
        return nil;
    NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *path = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"VirtualMac-Diagnostics-%@.zip",
                                   [formatter stringFromDate:NSDate.date]]];

    [NSFileManager.defaultManager createFileAtPath:path contents:nil
                                       attributes:nil];
    NSFileHandle *archive = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!archive) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
            code:EIO userInfo:@{NSLocalizedDescriptionKey:
                @"The diagnostics archive could not be opened."}];
        return nil;
    }
    NSMutableArray *central = [NSMutableArray array];
    __block uint64_t archiveLength = 0;
    @try {
        VZEnumerateDiagnosticEntries(^(NSString *entryName, NSData *contents) {
            NSData *name = [entryName dataUsingEncoding:NSUTF8StringEncoding];
            uint64_t resultingLength = archiveLength + 30 + name.length +
                contents.length;
            if (name.length > UINT16_MAX || contents.length > UINT32_MAX ||
                resultingLength > UINT32_MAX || central.count >= UINT16_MAX)
                return;
            uint32_t offset = (uint32_t)archiveLength;
            uint32_t crc = VZCRC32(contents);
            NSMutableData *header = [NSMutableData data];
            VZAppend32(header, 0x04034b50);
            VZAppend16(header, 20); VZAppend16(header, 0);
            VZAppend16(header, 0); VZAppend16(header, 0);
            VZAppend16(header, 0); VZAppend32(header, crc);
            VZAppend32(header, (uint32_t)contents.length);
            VZAppend32(header, (uint32_t)contents.length);
            VZAppend16(header, (uint16_t)name.length); VZAppend16(header, 0);
            [archive writeData:header];
            [archive writeData:name];
            [archive writeData:contents];
            archiveLength = resultingLength;
            [central addObject:@{ @"name": name, @"size": @(contents.length),
                                  @"crc": @(crc), @"offset": @(offset) }];
        });
    } @catch (NSException *exception) {
        [archive closeFile];
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
            code:NSFileWriteUnknownError userInfo:@{NSLocalizedDescriptionKey:
                exception.reason ?: @"The diagnostics archive could not be written."}];
        return nil;
    }
    uint32_t centralOffset = (uint32_t)archiveLength;
    NSMutableData *centralData = [NSMutableData data];
    for (NSDictionary *entry in central) {
        NSData *name = entry[@"name"];
        VZAppend32(centralData, 0x02014b50);
        VZAppend16(centralData, 20); VZAppend16(centralData, 20);
        VZAppend16(centralData, 0); VZAppend16(centralData, 0);
        VZAppend16(centralData, 0); VZAppend16(centralData, 0);
        VZAppend32(centralData, [entry[@"crc"] unsignedIntValue]);
        VZAppend32(centralData, [entry[@"size"] unsignedIntValue]);
        VZAppend32(centralData, [entry[@"size"] unsignedIntValue]);
        VZAppend16(centralData, (uint16_t)name.length);
        VZAppend16(centralData, 0); VZAppend16(centralData, 0);
        VZAppend16(centralData, 0); VZAppend16(centralData, 0);
        VZAppend32(centralData, 0);
        VZAppend32(centralData, [entry[@"offset"] unsignedIntValue]);
        [centralData appendData:name];
    }
    uint32_t centralSize = (uint32_t)centralData.length;
    VZAppend32(centralData, 0x06054b50);
    VZAppend16(centralData, 0); VZAppend16(centralData, 0);
    VZAppend16(centralData, (uint16_t)central.count);
    VZAppend16(centralData, (uint16_t)central.count);
    VZAppend32(centralData, centralSize); VZAppend32(centralData, centralOffset);
    VZAppend16(centralData, 0);
    [archive writeData:centralData];
    [archive synchronizeFile];
    [archive closeFile];
    chmod(path.fileSystemRepresentation, 0644);
    if (geteuid() == 0) {
        struct passwd *mobile = getpwnam("mobile");
        if (mobile) {
            chown(directory.fileSystemRepresentation,
                  mobile->pw_uid, mobile->pw_gid);
            chown(path.fileSystemRepresentation,
                  mobile->pw_uid, mobile->pw_gid);
        }
    }
    return [NSURL fileURLWithPath:path];
}
