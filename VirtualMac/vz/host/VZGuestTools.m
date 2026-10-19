#import "VZGuestTools.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <sys/socket.h>
#include <unistd.h>

typedef void (^VZGuestAgentResponse)(NSDictionary *response);
typedef void (^VZGuestCommandCompletion)(BOOL success, NSData *output);

static NSMutableData *gGuestOutputBuffer;
static dispatch_source_t gGuestOutputSource;
static id gGuestSocketListener;
static id gGuestSocketDelegate;
static id gGuestSocketConnection;
static int gGuestReadDescriptor = -1;
static int gGuestWriteDescriptor = -1;
static uint64_t gGuestRequestIdentifier;
static NSMutableDictionary *gGuestCallbacks;
static BOOL gGuestProvisioningStarted;
static NSUInteger gGuestDiagnosticReads;
static BOOL gGuestToolsEnabled;
static BOOL gGuestOpenGLAccelerationEnabled;
static BOOL gGuestPencilSupportEnabled;
static BOOL gGuestRemovalPending;
static NSString *gGuestBundlePath;
static NSString *gGuestReadyToken;
static BOOL gGuestToolsAcknowledged;
static BOOL gGuestMenuRestartedForToken;
static uint64_t gGuestProvisioningGeneration;
static NSUInteger gGuestConnectionCount;

static void VZGuestToolsProbeAgent(uint64_t generation, NSUInteger attempt);

static void VZGuestToolsLog(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[[NSString alloc] initWithFormat:format
        arguments:arguments] autorelease];
    va_end(arguments);
    dprintf(STDERR_FILENO, "[GuestTools] %s\n", message.UTF8String ?: "");
}

static SEL S(const char *name)
{
    return sel_registerName(name);
}

static id New(const char *name)
{
    Class cls = objc_getClass(name);
    return cls ? ((id(*)(id, SEL))objc_msgSend)(cls, S("new")) : nil;
}

static void SetObject(id object, const char *selector, id value)
{
    if (object && [object respondsToSelector:S(selector)])
        ((void(*)(id, SEL, id))objc_msgSend)(object, S(selector), value);
}

static void VZGuestToolsReadOutput(void)
{
    int descriptor = gGuestReadDescriptor;
    if (descriptor < 0) return;
    uint8_t bytes[4096];
    for (;;) {
        ssize_t count = recv(descriptor, bytes, sizeof(bytes), MSG_DONTWAIT);
        if (count > 0) {
            if (gGuestDiagnosticReads++ < 8) {
                NSData *sample = [NSData dataWithBytes:bytes
                    length:(NSUInteger)MIN(count, 96)];
                VZGuestToolsLog(@"received %zd bytes: %@", count, sample);
            }
            [gGuestOutputBuffer appendBytes:bytes length:(NSUInteger)count];
            continue;
        }
        break;
    }

    for (;;) {
        const uint8_t *bytes = gGuestOutputBuffer.bytes;
        NSUInteger length = gGuestOutputBuffer.length;
        const uint8_t *newline = length ? memchr(bytes, '\n', length) : NULL;
        if (!newline)
            break;
        NSUInteger lineLength = (NSUInteger)(newline - bytes);
        NSData *line = [gGuestOutputBuffer subdataWithRange:
            NSMakeRange(0, lineLength)];
        [gGuestOutputBuffer replaceBytesInRange:NSMakeRange(0, lineLength + 1)
                                      withBytes:NULL length:0];
        if (!line.length)
            continue;
        NSError *error = nil;
        id response = [NSJSONSerialization JSONObjectWithData:line options:0
                                                        error:&error];
        if (response) {
            NSNumber *identifier = [response objectForKey:@"id"];
            VZGuestAgentResponse callback = nil;
            @synchronized (gGuestCallbacks) {
                // AppleQEMUGuestAgent accepts QGA request identifiers but does
                // not echo them in its replies. Commands on one virtio port
                // are strictly ordered, so pair an untagged reply with the
                // oldest outstanding callback. Keep identifier matching for
                // guest-agent implementations which implement standard QGA.
                if (!identifier && gGuestCallbacks.count) {
                    identifier = [[gGuestCallbacks.allKeys
                        sortedArrayUsingSelector:@selector(compare:)] firstObject];
                }
                callback = [[gGuestCallbacks objectForKey:identifier] copy];
                if (identifier) [gGuestCallbacks removeObjectForKey:identifier];
            }
            if (callback) {
                callback(response);
                [callback release];
            } else if ([response objectForKey:@"error"])
                VZGuestToolsLog(@"unsolicited agent error: %@", response);
        } else
            VZGuestToolsLog(@"invalid guest agent response: %@", error);
    }
}

static BOOL VZGuestToolsSend(NSString *command, NSDictionary *arguments,
                             VZGuestAgentResponse callback)
{
    if (gGuestWriteDescriptor < 0)
        return NO;
    NSMutableDictionary *request = [NSMutableDictionary dictionaryWithObject:
        command forKey:@"execute"];
    if (arguments.count)
        request[@"arguments"] = arguments;
    NSNumber *identifier = nil;
    @synchronized (gGuestCallbacks) {
        identifier = @(++gGuestRequestIdentifier);
        if (callback) [gGuestCallbacks setObject:[[callback copy] autorelease]
                                           forKey:identifier];
    }
    request[@"id"] = identifier;
    NSError *error = nil;
    NSMutableData *data = [[[NSJSONSerialization dataWithJSONObject:request
        options:0 error:&error] mutableCopy] autorelease];
    if (!data) {
        VZGuestToolsLog(@"could not encode %@: %@", command, error);
        return NO;
    }
    [data appendBytes:"\n" length:1];
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining) {
        ssize_t count = write(gGuestWriteDescriptor, bytes, remaining);
        if (count > 0) {
            bytes += count;
            remaining -= (NSUInteger)count;
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        @synchronized (gGuestCallbacks) {
            [gGuestCallbacks removeObjectForKey:identifier];
        }
        VZGuestToolsLog(@"guest agent write failed for %@: %s", command,
                        strerror(errno));
        return NO;
    }
    return YES;
}

void VZGuestToolsReset(void)
{
    __atomic_add_fetch(&gGuestProvisioningGeneration, 1, __ATOMIC_ACQ_REL);
    if (gGuestOutputSource) {
        dispatch_source_cancel(gGuestOutputSource);
        dispatch_release(gGuestOutputSource);
        gGuestOutputSource = NULL;
    }
    [gGuestSocketConnection release];
    gGuestSocketConnection = nil;
    [gGuestSocketListener release];
    gGuestSocketListener = nil;
    [gGuestSocketDelegate release];
    gGuestSocketDelegate = nil;
    gGuestReadDescriptor = -1;
    gGuestWriteDescriptor = -1;
    [gGuestOutputBuffer release];
    gGuestOutputBuffer = nil;
    [gGuestCallbacks release];
    gGuestCallbacks = nil;
    gGuestRequestIdentifier = 0;
    gGuestProvisioningStarted = NO;
    gGuestDiagnosticReads = 0;
    gGuestConnectionCount = 0;
    [gGuestBundlePath release];
    gGuestBundlePath = nil;
    [gGuestReadyToken release];
    gGuestReadyToken = nil;
    gGuestToolsAcknowledged = NO;
    gGuestMenuRestartedForToken = NO;
}

BOOL VZGuestToolsConfigureDevice(id configuration)
{
    VZGuestToolsReset();
    id device = New("VZVirtioSocketDeviceConfiguration");
    if (!device) {
        VZGuestToolsLog(@"virtio socket configuration unavailable");
        return NO;
    }
    SetObject(configuration, "setSocketDevices:", @[device]);
    VZGuestToolsLog(@"configured Apple guest agent socket device");
    [device release];
    return YES;
}

static void VZGuestToolsAcceptConnection(id connection)
{
    if (!connection) return;
    BOOL reconnected = gGuestConnectionCount++ > 0;
    if (reconnected && (gGuestToolsEnabled || gGuestRemovalPending)) {
        // AppleQEMUGuestAgent opens a new virtio connection after an in-guest
        // reboot. The previous menu-extra acknowledgement belongs to the old
        // Aqua session, so invalidate its asynchronous work and require a new
        // end-to-end acknowledgement. Treat an unexpected agent reconnection
        // the same way; repairing an interrupted session is harmless.
        __atomic_add_fetch(&gGuestProvisioningGeneration, 1,
                           __ATOMIC_ACQ_REL);
        gGuestToolsAcknowledged = NO;
        gGuestMenuRestartedForToken = NO;
        [gGuestReadyToken release];
        gGuestReadyToken = [NSUUID.UUID.UUIDString copy];
        VZGuestToolsLog(@"guest agent reconnected; starting a new guest "
                        @"tools acknowledgement cycle");
    }
    if (gGuestOutputSource) {
        dispatch_source_cancel(gGuestOutputSource);
        dispatch_release(gGuestOutputSource);
        gGuestOutputSource = NULL;
    }
    [gGuestSocketConnection release];
    gGuestSocketConnection = [connection retain];
    int descriptor = ((int(*)(id, SEL))objc_msgSend)(
        connection, S("fileDescriptor"));
    gGuestReadDescriptor = descriptor;
    gGuestWriteDescriptor = descriptor;
    [gGuestOutputBuffer release];
    gGuestOutputBuffer = [NSMutableData new];
    [gGuestCallbacks release];
    gGuestCallbacks = [NSMutableDictionary new];
    gGuestRequestIdentifier = 0;
    gGuestProvisioningStarted = NO;
    gGuestDiagnosticReads = 0;
    gGuestOutputSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
        (uintptr_t)descriptor, 0,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_event_handler(gGuestOutputSource, ^{
        VZGuestToolsReadOutput();
    });
    dispatch_resume(gGuestOutputSource);
    VZGuestToolsLog(@"Apple guest agent connected over Virtio socket");
    VZGuestToolsLog(@"Apple guest agent %@ accepted",
                    reconnected ? @"reconnection" : @"connection");
    uint64_t generation = __atomic_load_n(&gGuestProvisioningGeneration,
                                          __ATOMIC_ACQUIRE);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            VZGuestToolsProbeAgent(generation, 1);
        });
}

@interface VZGuestSocketListenerDelegate : NSObject
@end

@implementation VZGuestSocketListenerDelegate
- (BOOL)listener:(id)listener shouldAcceptNewConnection:(id)connection
 fromSocketDevice:(id)socketDevice
{
    (void)listener;
    (void)socketDevice;
    VZGuestToolsAcceptConnection(connection);
    return YES;
}
@end

static void VZGuestToolsAttachOnCurrentThread(id virtualMachine)
{
    VZGuestToolsLog(@"resolving guest socket runtime devices");
    NSArray *devices = [virtualMachine respondsToSelector:S("socketDevices")]
        ? ((id(*)(id, SEL))objc_msgSend)(virtualMachine, S("socketDevices"))
        : ([virtualMachine respondsToSelector:S("_socketDevices")]
            ? ((id(*)(id, SEL))objc_msgSend)(virtualMachine,
                                             S("_socketDevices")) : nil);
    id device = devices.firstObject;
    VZGuestToolsLog(@"guest socket runtime device=%@", device);
    id listener = New("VZVirtioSocketListener");
    VZGuestToolsLog(@"created guest socket listener=%@", listener);
    if (!device || !listener) {
        VZGuestToolsLog(@"Apple guest agent socket listener unavailable");
        [listener release];
        return;
    }
    gGuestSocketDelegate = [VZGuestSocketListenerDelegate new];
    SetObject(listener, "setDelegate:", gGuestSocketDelegate);
    VZGuestToolsLog(@"configured guest socket listener delegate");
    ((void(*)(id, SEL, id, uint32_t))objc_msgSend)(
        device, S("setSocketListener:forPort:"), listener, 505050);
    VZGuestToolsLog(@"registered guest socket listener port 505050");
    gGuestSocketListener = [listener retain];
    [listener release];
    VZGuestToolsLog(@"listening for Apple guest agent on Virtio port 505050");
}

static void VZGuestToolsAttachOnMain(void *opaque)
{
    VZGuestToolsAttachOnCurrentThread((id)opaque);
}

void VZGuestToolsAttachToVirtualMachine(id virtualMachine)
{
    // VZVirtioSocketDevice's listener registration is main-thread-affine.
    // iPadOS 14 constructs the otherwise synchronous VZ configuration on a
    // worker queue to avoid its scene-update watchdog; calling
    // setSocketListener:forPort: from that queue makes CoreFoundation terminate
    // the UIKit host with SIGTRAP. Marshal only this small registration step.
    // iPadOS 15/16 already arrive on main and retain their existing path.
    if (!pthread_main_np()) {
        dispatch_sync_f(dispatch_get_main_queue(), virtualMachine,
                        VZGuestToolsAttachOnMain);
        return;
    }
    VZGuestToolsAttachOnCurrentThread(virtualMachine);
}

static void VZGuestToolsPollProcess(NSNumber *processIdentifier,
                                    NSUInteger attempts,
                                    VZGuestCommandCompletion completion)
{
    VZGuestToolsSend(@"guest-exec-status", @{ @"pid": processIdentifier },
        ^(NSDictionary *response) {
        if (response[@"error"])
            VZGuestToolsLog(@"guest-exec-status failed: %@", response[@"error"]);
        NSDictionary *result = response[@"return"];
        if ([result[@"exited"] boolValue]) {
            NSMutableData *output = [NSMutableData data];
            for (NSString *key in @[@"out-data", @"err-data"]) {
                NSString *base64 = result[key];
                if (![base64 isKindOfClass:NSString.class]) continue;
                NSData *part = [[[NSData alloc]
                    initWithBase64EncodedString:base64 options:0] autorelease];
                if (part.length) [output appendData:part];
            }
            completion([result[@"exitcode"] integerValue] == 0,
                       output);
            return;
        }
        if (!result || attempts >= 300) {
            completion(NO, [NSData data]);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            200 * NSEC_PER_MSEC),
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                VZGuestToolsPollProcess(processIdentifier, attempts + 1,
                                        completion);
            });
    });
}

static void VZGuestToolsRun(NSString *path, NSArray *arguments,
                            VZGuestCommandCompletion completion)
{
    VZGuestToolsSend(@"guest-exec", @{
        @"path": path,
        @"arg": arguments ?: @[],
        @"capture-output": @YES,
    }, ^(NSDictionary *response) {
        if (response[@"error"])
            VZGuestToolsLog(@"guest-exec %@ failed: %@", path,
                            response[@"error"]);
        NSNumber *processIdentifier = response[@"return"][@"pid"];
        if (![processIdentifier isKindOfClass:NSNumber.class]) {
            completion(NO, [NSData data]);
            return;
        }
        VZGuestToolsPollProcess(processIdentifier, 0, completion);
    });
}

static void VZGuestToolsWriteChunks(NSNumber *handle, NSData *data,
                                    NSUInteger offset,
                                    void (^completion)(BOOL success))
{
    if (offset >= data.length) {
        VZGuestToolsSend(@"guest-file-close", @{ @"handle": handle },
            ^(NSDictionary *response) {
                completion(response[@"error"] == nil);
            });
        return;
    }
    NSUInteger length = MIN((NSUInteger)(48 * 1024), data.length - offset);
    NSData *chunk = [data subdataWithRange:NSMakeRange(offset, length)];
    NSString *encoded = [chunk base64EncodedStringWithOptions:0];
    VZGuestToolsSend(@"guest-file-write", @{
        @"handle": handle,
        @"buf-b64": encoded,
    }, ^(NSDictionary *response) {
        NSUInteger written = [response[@"return"][@"count"]
            unsignedIntegerValue];
        if (written != length) {
            completion(NO);
            return;
        }
        VZGuestToolsWriteChunks(handle, data, offset + written, completion);
    });
}

static void VZGuestToolsWriteFile(NSString *path, NSData *data,
                                  void (^completion)(BOOL success))
{
    VZGuestToolsSend(@"guest-file-open", @{
        @"path": path, @"mode": @"w"
    }, ^(NSDictionary *response) {
        NSNumber *handle = response[@"return"];
        if (![handle isKindOfClass:NSNumber.class]) {
            completion(NO);
            return;
        }
        VZGuestToolsWriteChunks(handle, data, 0, completion);
    });
}

static void VZGuestToolsProvisionDesktop(NSUInteger attempt);

static NSData *VZGuestToolsConfigurationData(NSString *build)
{
    NSDictionary *configuration = @{
        @"Build": build ?: @"",
        @"ReadyToken": gGuestReadyToken ?: @"",
        @"OpenGLAllowed": @(gGuestOpenGLAccelerationEnabled),
        @"OpenGLAcceleration": @(gGuestOpenGLAccelerationEnabled),
        @"ApplePencilPressureTiltEnabled": @(gGuestPencilSupportEnabled),
    };
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:configuration
        format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
    if (!data)
        VZGuestToolsLog(@"could not encode guest policy: %@", error);
    return data;
}

static void VZGuestToolsActivate(BOOL payloadChanged, uint64_t generation,
                                 void (^completion)(BOOL success))
{
    BOOL forceRestart = payloadChanged || !gGuestMenuRestartedForToken;
    NSString *registeredJobCommand = forceRestart
        ? @"/bin/launchctl kickstart -k \"$job\" 2>/dev/null || true"
        : @"/bin/launchctl kickstart \"$job\" 2>/dev/null || true";
    NSString *script = [NSString stringWithFormat:
        @"uid=$(/usr/bin/stat -f %%u /dev/console); "
         "case $uid in ''|0) "
             "echo VIRTUAL_MAC_WAITING_FOR_DESKTOP; exit 75;; esac; "
         "test -f /var/db/.AppleSetupDone || { "
             "echo VIRTUAL_MAC_WAITING_FOR_DESKTOP; exit 75; }; "
         "/bin/rm -f /tmp/VirtualMacGuestTools.ready; "
         "/usr/bin/xattr -cr /Library/VirtualMac "
             "/Library/LaunchAgents/com.mac.virtual.guest-tools.plist; "
         "job=\"gui/$uid/com.mac.virtual.guest-tools\"; "
         "if /bin/launchctl print \"$job\" >/dev/null 2>&1; then "
             "%@; "
         "else "
             "/bin/launchctl bootstrap \"gui/$uid\" "
                 "/Library/LaunchAgents/com.mac.virtual.guest-tools.plist "
                 "2>&1; "
             "bootstrap_status=$?; "
             "if test $bootstrap_status -ne 0; then "
                 "exit $bootstrap_status; "
             "fi; "
         "fi; "
         "/bin/launchctl print \"$job\" "
             "2>&1 | /usr/bin/tail -n 24; "
         "echo VIRTUAL_MAC_ACTIVATED",
         registeredJobCommand];
    VZGuestToolsRun(@"/bin/sh", @[@"-c", script],
        ^(BOOL success, NSData *output) {
            if (generation != __atomic_load_n(&gGuestProvisioningGeneration,
                                              __ATOMIC_ACQUIRE)) return;
            NSString *text = [[[NSString alloc] initWithData:output
                encoding:NSUTF8StringEncoding] autorelease];
            text = [text stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            text = [text stringByReplacingOccurrencesOfString:
                @"VIRTUAL_MAC_ACTIVATED" withString:@""];
            text = [text stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            VZGuestToolsLog(@"guest menu activation %@: %@",
                            success ? @"succeeded" : @"failed", text ?: @"");
            if (success) gGuestMenuRestartedForToken = YES;
            completion(success);
        });
}

static void VZGuestToolsDiscoverGuestVersion(void (^completion)(void))
{
    VZGuestToolsRun(@"/usr/bin/sw_vers", @[@"-productVersion"],
        ^(BOOL success, NSData *output) {
            NSString *version = [[[NSString alloc] initWithData:output
                encoding:NSUTF8StringEncoding] autorelease];
            version = [version stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSInteger majorVersion = success
                ? [[[version componentsSeparatedByString:@"."] firstObject]
                    integerValue] : 0;
            if (majorVersion > 0) {
                if (majorVersion < 14) {
                    // Scope compatibility to this observed boot. Do not alter
                    // the saved preference: the same VM can be upgraded to a
                    // newer macOS release before its next start.
                    gGuestOpenGLAccelerationEnabled = NO;
                    VZGuestToolsLog(@"OpenGL disabled for macOS %@; Sonoma "
                                    @"or later is required", version);
                }
            } else {
                VZGuestToolsLog(@"could not determine guest macOS version");
            }
            completion();
        });
}

static void VZGuestToolsMarkRemovalComplete(void)
{
    if (!gGuestBundlePath.length) return;
    NSString *path = [gGuestBundlePath
        stringByAppendingPathComponent:@"VirtualMac.plist"];
    NSMutableDictionary *configuration = [NSMutableDictionary
        dictionaryWithContentsOfFile:path];
    if (![configuration isKindOfClass:NSMutableDictionary.class]) return;
    configuration[@"GuestToolsRemovalPending"] = @NO;
    [configuration writeToFile:path atomically:YES];
}

static void VZGuestToolsUninstall(void)
{
    NSString *script =
        @"uid=$(/usr/bin/stat -f %u /dev/console); "
         "case $uid in ''|0) exit 0;; esac; "
         "user=$(/usr/bin/id -nu \"$uid\"); "
         "/bin/launchctl bootout \"gui/$uid/com.mac.virtual.guest-tools\" "
             "2>/dev/null || true; "
         "/bin/launchctl bootout system/com.mac.virtual.opengl-compat "
             "2>/dev/null || true; "
         "/bin/launchctl bootout system/com.mac.virtual.gamepad-receiver "
             "2>/dev/null || true; "
         "/bin/launchctl unsetenv DYLD_INSERT_LIBRARIES "
             "2>/dev/null || true; "
         "/bin/launchctl asuser \"$uid\" /bin/launchctl unsetenv "
             "DYLD_INSERT_LIBRARIES; "
         "/usr/bin/sudo -u \"$user\" -H /usr/bin/defaults delete "
             "com.mac.virtual.guest-tools 2>/dev/null || true; "
         "/usr/bin/sudo -u \"$user\" -H /usr/bin/defaults delete "
             "com.apple.loginwindow TALLogoutSavesState "
             "2>/dev/null || true; "
         "/usr/bin/sudo -u \"$user\" -H /usr/bin/defaults delete "
             "com.apple.loginwindow LoginwindowLaunchesRelaunchApps "
             "2>/dev/null || true; "
         "/bin/rm -rf /Library/VirtualMac "
             "/Library/LaunchAgents/com.mac.virtual.guest-tools.plist "
             "/Library/LaunchAgents/com.mac.virtual.opengl-compat.plist "
             "/Library/LaunchDaemons/com.mac.virtual.opengl-compat.plist "
             "/Library/LaunchDaemons/com.mac.virtual.gamepad-receiver.plist; "
         "/bin/rm -f /Users/Shared/.VirtualMacGamepadMappingEnabled";
    VZGuestToolsRun(@"/bin/sh", @[@"-c", script],
        ^(BOOL success, NSData *output) {
            (void)output;
            VZGuestToolsLog(@"guest payload removal %@",
                            success ? @"succeeded" : @"failed");
            if (success) VZGuestToolsMarkRemovalComplete();
        });
}

static void VZGuestToolsAuditSecurityState(void)
{
    NSString *script =
        @"uid=$(/usr/bin/stat -f %u /dev/console); "
         "/usr/bin/csrutil status; "
         "/usr/sbin/nvram boot-args 2>/dev/null || true; "
         "/bin/launchctl asuser \"$uid\" /bin/launchctl getenv "
             "DYLD_INSERT_LIBRARIES 2>/dev/null || true; "
         "/usr/bin/pgrep -fl 'Virtual Mac Guest Tools' 2>/dev/null || true; "
         "/bin/cat /tmp/VirtualMacGuestTools.stderr.log "
             "/tmp/VirtualMacGuestTools.stdout.log 2>/dev/null || true; "
         "/bin/launchctl print \"gui/$uid/com.mac.virtual.guest-tools\" "
             "2>&1 | /usr/bin/tail -n 20 || true";
    VZGuestToolsRun(@"/bin/sh", @[@"-c", script],
        ^(BOOL success, NSData *output) {
            NSString *text = [[[NSString alloc] initWithData:output
                encoding:NSUTF8StringEncoding] autorelease];
            text = [text stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            VZGuestToolsLog(@"guest security state (%@): %@",
                success ? @"queried" : @"query failed", text ?: @"");
        });
}

static void VZGuestToolsInstallPayload(uint64_t generation,
                                       void (^completion)(BOOL success))
{
    NSString *directory = [NSBundle.mainBundle.resourcePath
        stringByAppendingPathComponent:@"GuestTools"];
    NSData *archive = [NSData dataWithContentsOfFile:[directory
        stringByAppendingPathComponent:@"VirtualMacGuestTools.tar.gz"]];
    if (!archive.length) {
        VZGuestToolsLog(@"packaged guest payload is incomplete");
        completion(NO);
        return;
    }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(archive.bytes, (CC_LONG)archive.length, digest);
    NSMutableString *payloadDigest = [NSMutableString string];
    for (NSUInteger index = 0; index < 8; ++index)
        [payloadDigest appendFormat:@"%02x", digest[index]];
    NSString *build = [NSString stringWithFormat:@"%@-%@",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]
            ?: @"0", payloadDigest];
    NSData *configuration = VZGuestToolsConfigurationData(build);
    if (!configuration.length) {
        completion(NO);
        return;
    }
    VZGuestToolsWriteFile(@"/tmp/VirtualMacGuestToolsConfiguration.plist",
        configuration, ^(BOOL wroteConfiguration) {
        if (!wroteConfiguration || generation != __atomic_load_n(
                &gGuestProvisioningGeneration, __ATOMIC_ACQUIRE)) {
            VZGuestToolsLog(@"guest policy write failed");
            completion(NO);
            return;
        }
        NSString *check = [NSString stringWithFormat:
            @"test \"$(cat /Library/VirtualMac/.build 2>/dev/null)\" = '%@'",
            build];
        VZGuestToolsRun(@"/bin/sh", @[@"-c", check],
            ^(BOOL current, NSData *output) {
            (void)output;
            if (generation != __atomic_load_n(&gGuestProvisioningGeneration,
                                              __ATOMIC_ACQUIRE)) return;
            if (current) {
                NSString *update =
                    @"set -e; /bin/mkdir -p /Library/VirtualMac; "
                     "/usr/sbin/chown root:wheel "
                         "/tmp/VirtualMacGuestToolsConfiguration.plist; "
                     "/bin/chmod 644 "
                         "/tmp/VirtualMacGuestToolsConfiguration.plist; "
                     "/bin/mv -f /tmp/VirtualMacGuestToolsConfiguration.plist "
                         "/Library/VirtualMac/HostConfiguration.plist";
                VZGuestToolsRun(@"/bin/sh", @[@"-c", update],
                    ^(BOOL updated, NSData *updateOutput) {
                    (void)updateOutput;
                    if (!updated) {
                        completion(NO);
                        return;
                    }
                    VZGuestToolsLog(@"guest payload is current (build %@)", build);
                    VZGuestToolsActivate(NO, generation, completion);
                });
                return;
            }
            VZGuestToolsWriteFile(@"/tmp/VirtualMacGuestTools.tar.gz", archive,
                ^(BOOL wroteArchive) {
                if (!wroteArchive) {
                    VZGuestToolsLog(@"guest payload archive write failed");
                    completion(NO);
                    return;
                }
                NSString *finish = [NSString stringWithFormat:
                    @"set -e; "
                     "uid=$(/usr/bin/stat -f %%u /dev/console); "
                     "case $uid in ''|0) exit 75;; esac; "
                     "test -f /var/db/.AppleSetupDone; "
                     "/bin/launchctl bootout "
                        "\"gui/$uid/com.mac.virtual.guest-tools\" "
                        "2>/dev/null || true; "
                     "/bin/launchctl bootout "
                        "\"gui/$uid/com.mac.virtual.opengl-compat\" "
                        "2>/dev/null || true; "
                     "/bin/launchctl bootout system/com.mac.virtual.opengl-compat "
                        "2>/dev/null || true; "
                     "/bin/launchctl bootout "
                        "system/com.mac.virtual.gamepad-receiver "
                        "2>/dev/null || true; "
                     "/bin/rm -f "
                        "/Library/LaunchDaemons/com.mac.virtual.gamepad-receiver.plist "
                        "/Users/Shared/.VirtualMacGamepadMappingEnabled "
                        "/Library/VirtualMac/VirtualMacGamepadReceiver "
                        "/Library/VirtualMac/VirtualMacGamepadReceiverService "
                        "/Library/VirtualMac/GamepadRelayAllowed "
                        "/Library/VirtualMac/GamepadRelayTransport; "
                     "/bin/launchctl unsetenv DYLD_INSERT_LIBRARIES "
                        "2>/dev/null || true; "
                     "login_hook=$(/usr/bin/defaults read "
                        "/Library/Preferences/com.apple.loginwindow LoginHook "
                        "2>/dev/null || true); "
                     "if test \"$login_hook\" = "
                        "'/Library/VirtualMac/Virtual Mac OpenGL Acceleration'; "
                     "then /usr/bin/defaults delete "
                        "/Library/Preferences/com.apple.loginwindow LoginHook "
                        "2>/dev/null || true; fi; "
                     "/bin/rm -rf /tmp/VirtualMacGuestToolsPayload; "
                     "/bin/mkdir -p /tmp/VirtualMacGuestToolsPayload; "
                     "/usr/bin/tar --no-same-owner -xmzf "
                        "/tmp/VirtualMacGuestTools.tar.gz "
                        "-C /tmp/VirtualMacGuestToolsPayload; "
                     "/bin/mkdir -p /Library/VirtualMac /Library/LaunchAgents; "
                     "/bin/rm -rf '/Library/VirtualMac/Virtual Mac Guest Tools.app'; "
                     "/bin/rm -rf /Library/VirtualMac/Gamepad; "
                     "/bin/cp -R '/tmp/VirtualMacGuestToolsPayload/Library/VirtualMac/Virtual Mac Guest Tools.app' "
                        "/Library/VirtualMac/; "
                     "/bin/cp -f /tmp/VirtualMacGuestToolsPayload/Library/VirtualMac/OpenGLPVGCompat.dylib "
                        "/Library/VirtualMac/OpenGLPVGCompat.dylib; "
                     "/bin/cp -R /tmp/VirtualMacGuestToolsPayload/Library/VirtualMac/Gamepad "
                        "/Library/VirtualMac/Gamepad "
                        "|| /bin/rm -rf /Library/VirtualMac/Gamepad; "
                     "/usr/sbin/chown root:wheel "
                        "/tmp/VirtualMacGuestToolsConfiguration.plist; "
                     "/bin/chmod 644 "
                        "/tmp/VirtualMacGuestToolsConfiguration.plist; "
                     "/bin/mv -f /tmp/VirtualMacGuestToolsConfiguration.plist "
                        "/Library/VirtualMac/HostConfiguration.plist; "
                     "/usr/sbin/chown -R root:wheel /Library/VirtualMac; "
                     "/bin/chmod 755 /Library/VirtualMac/OpenGLPVGCompat.dylib "
                        "'/Library/VirtualMac/Virtual Mac Guest Tools.app/Contents/MacOS/Virtual Mac Guest Tools'; "
                     "/usr/bin/xattr -cr /Library/VirtualMac; "
                     "/usr/bin/codesign --verify --strict "
                        "'/Library/VirtualMac/Virtual Mac Guest Tools.app'; "
                     "/usr/bin/codesign --verify --strict "
                        "/Library/VirtualMac/OpenGLPVGCompat.dylib; "
                     "if test -f /Library/VirtualMac/Gamepad/VirtualMacGamepadReceiver "
                        "-a -f '/Library/VirtualMac/Gamepad/Start VirtualMac Gamepad.command'; "
                     "then /bin/chmod 755 "
                        "/Library/VirtualMac/Gamepad/VirtualMacGamepadReceiver "
                        "'/Library/VirtualMac/Gamepad/Start VirtualMac Gamepad.command' "
                        "&& /usr/bin/codesign --verify --strict "
                        "/Library/VirtualMac/Gamepad/VirtualMacGamepadReceiver "
                        "|| /bin/rm -rf /Library/VirtualMac/Gamepad; "
                     "else /bin/rm -rf /Library/VirtualMac/Gamepad; fi; "
                     "/bin/cp -f /tmp/VirtualMacGuestToolsPayload/Library/LaunchAgents/com.mac.virtual.guest-tools.plist "
                        "/Library/LaunchAgents/com.mac.virtual.guest-tools.plist.new; "
                     "/usr/sbin/chown root:wheel "
                        "/Library/LaunchAgents/com.mac.virtual.guest-tools.plist.new; "
                     "/bin/chmod 644 "
                        "/Library/LaunchAgents/com.mac.virtual.guest-tools.plist.new; "
                     "/bin/mv -f "
                        "/Library/LaunchAgents/com.mac.virtual.guest-tools.plist.new "
                        "/Library/LaunchAgents/com.mac.virtual.guest-tools.plist; "
                     "printf '%%s' '%@' > /Library/VirtualMac/.build; "
                     "/bin/rm -rf /tmp/VirtualMacGuestToolsPayload "
                        "/tmp/VirtualMacGuestTools.tar.gz; "
                     "echo VIRTUAL_MAC_PAYLOAD_INSTALLED", build];
                VZGuestToolsRun(@"/bin/sh", @[@"-c", finish],
                    ^(BOOL installed, NSData *finishOutput) {
                    NSString *text = [[[NSString alloc]
                        initWithData:finishOutput
                        encoding:NSUTF8StringEncoding] autorelease];
                    text = [text stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (!installed) {
                        VZGuestToolsLog(@"payload setup failed: %@",
                                        text ?: @"unknown error");
                        completion(NO);
                        return;
                    }
                    VZGuestToolsLog(@"installed guest payload build %@", build);
                    VZGuestToolsActivate(YES, generation, completion);
                });
            });
        });
    });
}

static void VZGuestToolsProvisionDesktop(NSUInteger attempt)
{
    uint64_t generation = __atomic_load_n(
        &gGuestProvisioningGeneration, __ATOMIC_ACQUIRE);
    if (gGuestToolsAcknowledged || !gGuestReadyToken.length) return;
    NSString *probe =
        @"uid=$(/usr/bin/stat -f %u /dev/console); "
         "case $uid in ''|0) exit 75;; esac; "
         "test -f /var/db/.AppleSetupDone || exit 75; "
         "/bin/cat /tmp/VirtualMacGuestTools.ready 2>/dev/null || true";
    VZGuestToolsRun(@"/bin/sh", @[@"-c", probe],
        ^(BOOL success, NSData *output) {
            NSString *text = [[[NSString alloc] initWithData:output
                encoding:NSUTF8StringEncoding] autorelease];
            text = [text stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (generation != __atomic_load_n(&gGuestProvisioningGeneration,
                                              __ATOMIC_ACQUIRE)) return;
            if (success && !gGuestToolsEnabled) {
                if (gGuestRemovalPending) VZGuestToolsUninstall();
                return;
            }
            if (success && [text isEqualToString:gGuestReadyToken]) {
                gGuestToolsAcknowledged = YES;
                VZGuestToolsLog(@"guest menu extra acknowledged token %@",
                                gGuestReadyToken);
                VZGuestToolsAuditSecurityState();
                return;
            }
            if (!success) {
                if (attempt == 0)
                    VZGuestToolsLog(@"waiting for a macOS desktop user session");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    10 * NSEC_PER_SEC),
                    dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        if (generation == __atomic_load_n(
                                &gGuestProvisioningGeneration,
                                __ATOMIC_ACQUIRE))
                            VZGuestToolsProvisionDesktop(attempt + 1);
                    });
                return;
            }
            if (attempt == 0 || attempt % 6 == 0)
                VZGuestToolsLog(@"guest menu extra not acknowledged; %@ attempt %lu",
                    attempt ? @"repair" : @"installing", (unsigned long)attempt + 1);
            VZGuestToolsInstallPayload(generation, ^(BOOL installed) {
                if (!installed && (attempt == 0 || attempt % 6 == 0))
                    VZGuestToolsLog(@"guest payload repair will be retried");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    10 * NSEC_PER_SEC),
                    dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        if (generation == __atomic_load_n(
                                &gGuestProvisioningGeneration,
                                __ATOMIC_ACQUIRE) && !gGuestToolsAcknowledged)
                            VZGuestToolsProvisionDesktop(attempt + 1);
                    });
            });
        });
}

static void VZGuestToolsProbeAgent(uint64_t generation, NSUInteger attempt)
{
    if (generation != __atomic_load_n(&gGuestProvisioningGeneration,
                                      __ATOMIC_ACQUIRE) ||
        gGuestProvisioningStarted || gGuestReadDescriptor < 0)
        return;
    if (attempt == 1 || attempt % 60 == 0)
        VZGuestToolsLog(@"probing Apple guest agent (attempt %lu)",
                        (unsigned long)attempt);
    // Before the first successful response every outstanding command is this
    // same readiness probe. AppleQEMUGuestAgent can silently discard requests
    // sent while it is starting, so retry, but retain at most one callback.
    // This bounds memory use during a long Setup Assistant or a guest whose
    // agent never becomes available.
    @synchronized (gGuestCallbacks) {
        [gGuestCallbacks removeAllObjects];
    }
    VZGuestToolsSend(@"guest-info", nil, ^(NSDictionary *response) {
        if (generation != __atomic_load_n(&gGuestProvisioningGeneration,
                                          __ATOMIC_ACQUIRE)) return;
        if (response[@"return"] && !gGuestProvisioningStarted) {
            gGuestProvisioningStarted = YES;
            VZGuestToolsLog(@"Apple guest agent ready");
            VZGuestToolsDiscoverGuestVersion(^{
                VZGuestToolsProvisionDesktop(0);
            });
        }
    });
    // Do not make durability depend on receiving a reply to an earlier probe.
    // QGA can appear late during Setup Assistant or after a slow first login.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            VZGuestToolsProbeAgent(generation, attempt + 1);
        });
}

void VZGuestToolsStartProvisioning(NSString *bundlePath,
                                   BOOL guestToolsEnabled,
                                   BOOL openGLAccelerationEnabled,
                                   BOOL pencilSupportEnabled,
                                   BOOL removalPending)
{
    gGuestToolsEnabled = guestToolsEnabled;
    gGuestOpenGLAccelerationEnabled = openGLAccelerationEnabled;
    gGuestPencilSupportEnabled = pencilSupportEnabled;
    gGuestRemovalPending = removalPending;
    gGuestToolsAcknowledged = NO;
    gGuestMenuRestartedForToken = NO;
    [gGuestReadyToken release];
    gGuestReadyToken = (guestToolsEnabled || removalPending)
        ? [NSUUID.UUID.UUIDString copy] : nil;
    [gGuestBundlePath release];
    gGuestBundlePath = [bundlePath copy];
    if (!guestToolsEnabled && !removalPending) return;
    uint64_t generation = __atomic_load_n(&gGuestProvisioningGeneration,
                                          __ATOMIC_ACQUIRE);
    if (gGuestReadDescriptor >= 0)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                VZGuestToolsProbeAgent(generation, 1);
            });
}

BOOL VZGuestToolsConfigureBootArguments(id auxiliaryStorage,
                                        BOOL guestAgentEnabled,
                                        BOOL openGLAccelerationEnabled,
                                        NSError **error)
{
    SEL getter = S("_valueForNVRAMVariableNamed:error:");
    SEL setter = S("_setValue:forNVRAMVariableNamed:error:");
    if (!auxiliaryStorage || ![auxiliaryStorage respondsToSelector:setter]) {
        if (error)
            *error = [NSError errorWithDomain:@"VirtualMacGuestTools"
                code:1 userInfo:@{NSLocalizedDescriptionKey:
                @"The Virtual Mac NVRAM interface is unavailable."}];
        return NO;
    }
    NSError *readError = nil;
    id existing = [auxiliaryStorage respondsToSelector:getter]
        ? ((id(*)(id, SEL, id, NSError **))objc_msgSend)(
            auxiliaryStorage, getter, @"boot-args", &readError)
        : nil;
    NSString *arguments = nil;
    if ([existing isKindOfClass:NSData.class])
        arguments = [[[NSString alloc] initWithData:existing
            encoding:NSUTF8StringEncoding] autorelease];
    else if ([existing isKindOfClass:NSString.class])
        arguments = existing;
    arguments = [arguments stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *token in [arguments componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (token.length && ![token isEqualToString:@"-arm64e_preview_abi"])
            [tokens addObject:token];
    }
    if (openGLAccelerationEnabled)
        [tokens addObject:@"-arm64e_preview_abi"];
    NSString *updated = [tokens componentsJoinedByString:@" "];
    BOOL result = YES;
    if (![updated isEqualToString:arguments]) {
        result = ((BOOL(*)(id, SEL, id, id, NSError **))objc_msgSend)(
            auxiliaryStorage, setter, updated, @"boot-args", error);
    }
    if (!result) return NO;

    // VZ advertises this port identifier in the product device-tree node.
    // AppleQEMUGuestAgent reads the corresponding NVRAM variable from /options
    // before connecting to host CID 2 through AppleVirtIOAgentDevice. VMs
    // originally restored without guest-agent support do not have that
    // variable, so adding the socket device alone leaves the daemon exiting
    // with status 1. The value is VZ's stable agent port identifier, not a
    // guest-version or build-specific address.
    if (!guestAgentEnabled) {
        SEL remover = S("_removeNVRAMVariableNamed:error:");
        if ([auxiliaryStorage respondsToSelector:remover]) {
            @try {
                ((BOOL(*)(id, SEL, id, NSError **))objc_msgSend)(
                    auxiliaryStorage, remover, @"apple-guest-agent-port",
                    NULL);
            } @catch (__unused NSException *exception) {}
        }
        return YES;
    }
    // AppleQEMUGuestAgent parses the /options value as an ASCII decimal port.
    // (Its fallback copy in the product node is a binary uint32.) The private
    // setter therefore receives the textual NVRAM representation.
    @try {
        result = ((BOOL(*)(id, SEL, id, id, NSError **))objc_msgSend)(
            auxiliaryStorage, setter, @"505050", @"apple-guest-agent-port",
            error);
    } @catch (NSException *exception) {
        result = NO;
        if (error)
            *error = [NSError errorWithDomain:@"VirtualMacGuestTools" code:2
                userInfo:@{NSLocalizedDescriptionKey:
                    exception.reason ?: @"The guest agent port could not be staged."}];
    }
    if (result) {
        VZGuestToolsLog(@"staged NVRAM boot arguments %@", updated);
        VZGuestToolsLog(@"staged Apple guest agent port 505050");
    }
    return result;
}
