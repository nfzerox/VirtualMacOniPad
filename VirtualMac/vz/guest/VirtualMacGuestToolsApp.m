#import <AppKit/AppKit.h>
#import <dlfcn.h>

static NSString * const VMOpenGLKey = @"OpenGLAcceleration";
static NSString * const VMOpenGLAllowedKey = @"OpenGLAllowed";
static NSString * const VMPencilSupportKey =
    @"ApplePencilPressureTiltEnabled";
static NSString * const VMLibrary = @"/Library/VirtualMac";
static NSString * const VMHostConfiguration =
    @"/Library/VirtualMac/HostConfiguration.plist";
static NSString * const VMReadyTokenKey = @"LastHostReadyToken";
static NSString * const VMReadyPath = @"/tmp/VirtualMacGuestTools.ready";
static NSString * const VMGamepadScriptPath =
    @"/Library/VirtualMac/Gamepad/Start VirtualMac Gamepad.command";

static NSString *VML(NSString *key)
{
    return [NSBundle.mainBundle localizedStringForKey:key value:key table:nil];
}

@interface VMGuestToolsDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, retain) NSStatusItem *statusItem;
@property(nonatomic, retain) NSMenuItem *statusMenuItem;
@property(nonatomic, retain) NSMenuItem *openGLMenuItem;
@property(nonatomic, retain) NSMenuItem *gamepadScriptMenuItem;
@property(nonatomic, copy) NSString *readyToken;
@end

@implementation VMGuestToolsDelegate

- (NSUserDefaults *)preferences { return NSUserDefaults.standardUserDefaults; }

- (BOOL)preferenceForKey:(NSString *)key defaultValue:(BOOL)value
{
    if ([self.preferences objectForKey:key] == nil)
        [self.preferences setBool:value forKey:key];
    return [self.preferences boolForKey:key];
}

- (void)applyHostConfiguration
{
    NSDictionary *configuration = [NSDictionary
        dictionaryWithContentsOfFile:VMHostConfiguration];
    if (![configuration isKindOfClass:NSDictionary.class]) return;
    NSString *token = configuration[@"ReadyToken"];
    if (![token isKindOfClass:NSString.class] || !token.length) return;
    self.readyToken = token;

    // Host policy is machine-owned, while the menu extra is the authority for
    // its own user preference domain. Initialize a new VM boot exactly once so
    // a user can still toggle OpenGL for the rest of that boot without a host
    // repair relaunch overwriting the choice.
    NSString *lastToken = [self.preferences stringForKey:VMReadyTokenKey];
    if (![lastToken isEqualToString:token]) {
        NSNumber *openGL = configuration[VMOpenGLKey];
        if ([openGL isKindOfClass:NSNumber.class])
            [self.preferences setBool:openGL.boolValue forKey:VMOpenGLKey];
        [self.preferences setObject:token forKey:VMReadyTokenKey];
    }
    for (NSString *key in @[VMOpenGLAllowedKey, VMPencilSupportKey]) {
        NSNumber *value = configuration[key];
        if ([value isKindOfClass:NSNumber.class])
            [self.preferences setBool:value.boolValue forKey:key];
    }
    [self.preferences synchronize];
}

- (void)publishReady
{
    if (!self.readyToken.length || !self.statusItem.button || !self.statusItem.menu)
        return;
    NSString *temporary = [VMReadyPath stringByAppendingFormat:@".%d", getpid()];
    NSData *data = [self.readyToken dataUsingEncoding:NSUTF8StringEncoding];
    if ([data writeToFile:temporary atomically:YES]) {
        [NSFileManager.defaultManager removeItemAtPath:VMReadyPath error:nil];
        [NSFileManager.defaultManager moveItemAtPath:temporary
                                               toPath:VMReadyPath error:nil];
    }
}

- (NSString *)outputForExecutable:(NSString *)path arguments:(NSArray *)arguments
{
    NSPipe *pipe = [NSPipe pipe];
    NSTask *task = [[[NSTask alloc] init] autorelease];
    task.launchPath = path;
    task.arguments = arguments;
    task.standardOutput = pipe;
    task.standardError = pipe;
    @try {
        [task launch];
        [task waitUntilExit];
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        return [[[NSString alloc] initWithData:data
            encoding:NSUTF8StringEncoding] autorelease] ?: @"";
    } @catch (__unused NSException *exception) { return @""; }
}

- (void)setEnvironmentVariable:(NSString *)name value:(NSString *)value
{
    [self outputForExecutable:@"/bin/launchctl"
        arguments:value ? @[@"setenv", name, value] : @[@"unsetenv", name]];
}

- (void)setSavedApplicationRelaunchSuppressed:(BOOL)suppressed
{
    NSUserDefaults *loginwindow = [[[NSUserDefaults alloc]
        initWithSuiteName:@"com.apple.loginwindow"] autorelease];
    for (NSString *key in @[@"TALLogoutSavesState",
                             @"LoginwindowLaunchesRelaunchApps"]) {
        if (suppressed)
            [loginwindow setBool:NO forKey:key];
        else
            [loginwindow removeObjectForKey:key];
    }
    [loginwindow synchronize];
}

- (BOOL)hostAllowsOpenGL
{
    return [self preferenceForKey:VMOpenGLAllowedKey defaultValue:NO];
}

- (BOOL)guestSupportsOpenGL
{
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14;
}

- (BOOL)securityPolicySupportsOpenGL
{
    // Virtual Mac applies SIP capabilities to the running guest kernel while
    // leaving its signed persistent LocalPolicy untouched. Modern csrutil
    // reports that persistent startup policy, so query the enforcement ABI
    // used by dyld and the kernel instead.
    int (*csr_check_fn)(uint32_t) = dlsym(RTLD_DEFAULT, "csr_check");
    BOOL unrestrictedFilesystem = csr_check_fn && csr_check_fn(1U << 1) == 0;
    NSString *bootArguments = [self outputForExecutable:@"/usr/sbin/nvram"
                                      arguments:@[@"boot-args"]];
    return unrestrictedFilesystem &&
        [bootArguments containsString:@"-arm64e_preview_abi"];
}

- (BOOL)openGLAvailable
{
    return [self guestSupportsOpenGL] && [self hostAllowsOpenGL] &&
        [self securityPolicySupportsOpenGL] &&
        [NSFileManager.defaultManager fileExistsAtPath:[VMLibrary
            stringByAppendingPathComponent:@"OpenGLPVGCompat.dylib"]];
}

- (void)applyOpenGL
{
    BOOL requested = [self preferenceForKey:VMOpenGLKey defaultValue:YES] &&
        [self guestSupportsOpenGL] && [self hostAllowsOpenGL];
    BOOL enabled = requested && [self securityPolicySupportsOpenGL] &&
        [NSFileManager.defaultManager fileExistsAtPath:[VMLibrary
            stringByAppendingPathComponent:@"OpenGLPVGCompat.dylib"]];
    NSString *library = [VMLibrary
        stringByAppendingPathComponent:@"OpenGLPVGCompat.dylib"];
    // This changes only the requested Aqua environment variable and leaves
    // unrelated values intact.
    [self setEnvironmentVariable:@"DYLD_INSERT_LIBRARIES"
        value:enabled ? library : nil];
    // loginwindow can restore applications before an ordinary LaunchAgent is
    // scheduled, so those processes cannot inherit a value published by this
    // menu extra. While acceleration is enabled, turn off saved-application
    // relaunch instead of racing loginwindow or injecting a boot-time agent.
    // Removing the OpenGL preference restores the guest's normal defaults.
    // Preserve the configured intent if the host is still applying its
    // running-kernel policy when this login item starts. That transient state
    // must not re-enable saved-app restoration for the following boot.
    [self setSavedApplicationRelaunchSuppressed:requested];
}

- (NSImage *)statusImageNamed:(NSString *)name
{
    NSImage *image = [NSImage imageNamed:name];
    image.template = YES;
    image.size = NSMakeSize(18, 18);
    return image;
}

- (void)updateMenu
{
    BOOL available = [self openGLAvailable];
    BOOL enabled = available &&
        [self preferenceForKey:VMOpenGLKey defaultValue:YES];
    self.statusMenuItem.title = VML(@"Virtual Mac");
    self.openGLMenuItem.state = enabled ? NSControlStateValueOn
                                        : NSControlStateValueOff;
    self.openGLMenuItem.enabled = [self guestSupportsOpenGL];
    self.gamepadScriptMenuItem.enabled =
        [NSFileManager.defaultManager fileExistsAtPath:VMGamepadScriptPath];
    self.statusItem.button.image = [self statusImageNamed:enabled
        ? @"vm.laptopcomputer.badge.checkmark" : @"vm.laptopcomputer"];
    self.statusItem.button.imageScaling = NSImageScaleProportionallyDown;
}

- (void)menuWillOpen:(NSMenu *)menu
{
    (void)menu;
    // The host applies the running-kernel policy asynchronously during boot.
    // Refresh both the effective environment and the visible checkmark when
    // the user opens the menu instead of freezing startup-time state.
    [self applyOpenGL];
    [self updateMenu];
}

- (void)showOpenGLUnavailable
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = VML(@"OpenGL Acceleration Is Off");
    alert.informativeText = [self guestSupportsOpenGL]
        ? VML(@"To enable OpenGL acceleration, shut down this Virtual Mac, then in its options, enable OpenGL Acceleration.")
        : VML(@"OpenGL Acceleration requires macOS Sonoma or later.");
    [alert addButtonWithTitle:VML(@"OK")];
    [alert runModal];
}

- (void)toggleOpenGL:(NSMenuItem *)sender
{
    (void)sender;
    if (![self openGLAvailable]) {
        [self showOpenGLUnavailable];
        [self updateMenu];
        return;
    }
    BOOL enabled = ![self preferenceForKey:VMOpenGLKey defaultValue:YES];
    [self.preferences setBool:enabled forKey:VMOpenGLKey];
    [self applyOpenGL];
    [self updateMenu];
}

- (void)openGamepadScriptFolder:(NSMenuItem *)sender
{
    (void)sender;
    NSURL *script = [NSURL fileURLWithPath:VMGamepadScriptPath];
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[script]];
}

- (NSString *)productVersion
{
    NSString *version = [self outputForExecutable:@"/usr/bin/sw_vers"
                                      arguments:@[@"-productVersion"]];
    return [version stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

- (void)openWebItem:(NSMenuItem *)sender
{
    NSURLComponents *components = [NSURLComponents componentsWithString:
        @"https://nfzerox.github.io/virtual-mac/app/"];
    NSString *virtualMacVersion = [NSBundle.mainBundle
        objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"app" value:sender.representedObject],
        [NSURLQueryItem queryItemWithName:@"vm" value:virtualMacVersion],
        [NSURLQueryItem queryItemWithName:@"os" value:self.productVersion],
    ];
    [NSWorkspace.sharedWorkspace openURL:components.URL];
}

- (void)openSupport:(NSMenuItem *)sender
{
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
        sender.representedObject]];
}

- (NSMenuItem *)itemWithTitle:(NSString *)title action:(SEL)action
             representedObject:(id)object
{
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title action:action
        keyEquivalent:@""] autorelease];
    item.target = self;
    item.representedObject = object;
    return item;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    [self applyHostConfiguration];
    [self applyOpenGL];
    self.statusItem = [NSStatusBar.systemStatusBar
        statusItemWithLength:NSSquareStatusItemLength];
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:VML(@"Virtual Mac Guest Tools")]
        autorelease];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    self.statusMenuItem = [[[NSMenuItem alloc]
        initWithTitle:VML(@"Virtual Mac")
        action:nil keyEquivalent:@""] autorelease];
    self.statusMenuItem.enabled = NO;
    [menu addItem:self.statusMenuItem];
    BOOL supportsOpenGL = [self guestSupportsOpenGL];
    self.openGLMenuItem = [self itemWithTitle:supportsOpenGL
        ? VML(@"OpenGL Acceleration")
        : VML(@"OpenGL Acceleration requires macOS Sonoma or later.")
        action:@selector(toggleOpenGL:) representedObject:nil];
    [menu addItem:self.openGLMenuItem];
    self.gamepadScriptMenuItem = [self itemWithTitle:
        VML(@"Open Gamepad Script Folder")
        action:@selector(openGamepadScriptFolder:) representedObject:nil];
    [menu addItem:self.gamepadScriptMenuItem];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self itemWithTitle:VML(@"Download Xcode")
        action:@selector(openWebItem:) representedObject:@"xcode"]];
    if (supportsOpenGL) {
        [menu addItem:[self itemWithTitle:VML(@"Download Final Cut Pro Trial")
            action:@selector(openWebItem:)
            representedObject:@"final-cut-pro-trial"]];
    }
    [menu addItem:[self itemWithTitle:VML(@"Download Logic Pro Trial")
        action:@selector(openWebItem:) representedObject:@"logic-pro-trial"]];
    [menu addItem:[self itemWithTitle:VML(@"Download Pixelmator Pro Trial")
        action:@selector(openWebItem:)
        representedObject:@"pixelmator-pro-trial"]];
    if ([self preferenceForKey:VMPencilSupportKey defaultValue:NO]) {
        [menu addItem:[self itemWithTitle:VML(@"Download Apple Pencil Support")
            action:@selector(openWebItem:) representedObject:@"pencil"]];
    }
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self itemWithTitle:VML(@"Get Help")
        action:@selector(openSupport:) representedObject:
        @"https://nfzerox.github.io/virtual-mac/help/"]];
    [menu addItem:[self itemWithTitle:VML(@"Report Issue")
        action:@selector(openSupport:) representedObject:
        @"https://nfzerox.github.io/virtual-mac/issues/"]];
    self.statusItem.menu = menu;
    [self updateMenu];
    [self publishReady];
}

@end


int main(int argc, const char *argv[])
{
    (void)argc; (void)argv;
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    NSApplication *application = NSApplication.sharedApplication;
    VMGuestToolsDelegate *delegate = [VMGuestToolsDelegate new];
    application.delegate = delegate;
    [application run];
    [delegate release];
    [pool drain];
    return 0;
}
