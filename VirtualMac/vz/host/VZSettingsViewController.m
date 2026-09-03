#import "VZSettingsViewController.h"
#import "VZAppSettings.h"
#import "VZDiagnostics.h"
#import "VZGamepadBridge.h"
#import "VZGamepadSettingsViewController.h"
#import "VZLocalization.h"
#import "VZSupport.h"
#import "VZVMLibraryViewController.h"

@interface VZContributorChip : UIControl
@property(nonatomic, copy) NSString *urlString;
- (instancetype)initWithName:(NSString *)name imageName:(NSString *)imageName
                          url:(NSString *)url;
@end

@implementation VZContributorChip
- (instancetype)initWithName:(NSString *)name imageName:(NSString *)imageName
                          url:(NSString *)url
{
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.urlString = url;
    self.backgroundColor = UIColor.tertiarySystemFillColor;
    self.layer.cornerRadius = 20.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    NSString *path = [NSBundle.mainBundle pathForResource:
        imageName.stringByDeletingPathExtension ofType:imageName.pathExtension
        inDirectory:@"Developers"];
    UIImage *image = path.length ? [UIImage imageWithContentsOfFile:path] : nil;
    if (!image)
        image = [UIImage systemImageNamed:@"person.crop.circle"];
    UIImageView *avatar = [[[UIImageView alloc] initWithImage:image] autorelease];
    avatar.translatesAutoresizingMaskIntoConstraints = NO;
    avatar.contentMode = UIViewContentModeScaleAspectFill;
    avatar.layer.cornerRadius = 14.0;
    avatar.layer.masksToBounds = YES;
    [avatar.widthAnchor constraintEqualToConstant:28].active = YES;
    [avatar.heightAnchor constraintEqualToConstant:28].active = YES;
    UILabel *label = [[[UILabel alloc] init] autorelease];
    label.text = name;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    UIStackView *stack = [[[UIStackView alloc] initWithArrangedSubviews:
        @[avatar, label]] autorelease];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 7;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.userInteractionEnabled = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:9],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-9],
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-6],
    ]];
    [self addTarget:self action:@selector(open:) forControlEvents:UIControlEventTouchUpInside];
    return self;
}
- (void)open:(id)sender { (void)sender; VZOpenSupportURL(self.urlString); }
- (void)dealloc { [_urlString release]; [super dealloc]; }
@end

@interface VZContributorFlowView : UIView
@property(nonatomic, retain) NSArray<UIView *> *chips;
- (instancetype)initWithChips:(NSArray<UIView *> *)chips;
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
@end

@implementation VZContributorFlowView {
    CGFloat _measuredHeight;
}
- (instancetype)initWithChips:(NSArray<UIView *> *)chips
{
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.chips = chips;
    for (UIView *chip in chips) [self addSubview:chip];
    return self;
}
- (CGSize)intrinsicContentSize
{
    return CGSizeMake(UIViewNoIntrinsicMetric, MAX(_measuredHeight, 40));
}
- (CGFloat)preferredHeightForWidth:(CGFloat)width
{
    const CGFloat horizontalSpacing = 10;
    const CGFloat verticalSpacing = 6;
    CGFloat x = 0, y = 0, rowHeight = 0;
    for (UIView *chip in self.chips) {
        CGSize size = [chip systemLayoutSizeFittingSize:
            UILayoutFittingCompressedSize];
        size.width = MIN(size.width, width);
        if (x > 0 && x + size.width > width) {
            x = 0;
            y += rowHeight + verticalSpacing;
            rowHeight = 0;
        }
        x += size.width + horizontalSpacing;
        rowHeight = MAX(rowHeight, size.height);
    }
    return MAX(y + rowHeight, 40);
}
- (void)layoutSubviews
{
    [super layoutSubviews];
    const CGFloat horizontalSpacing = 10;
    const CGFloat verticalSpacing = 6;
    CGFloat x = 0, y = 0, rowHeight = 0;
    CGFloat width = CGRectGetWidth(self.bounds);
    for (UIView *chip in self.chips) {
        CGSize size = [chip systemLayoutSizeFittingSize:
            UILayoutFittingCompressedSize];
        size.width = MIN(size.width, width);
        if (x > 0 && x + size.width > width) {
            x = 0;
            y += rowHeight + verticalSpacing;
            rowHeight = 0;
        }
        chip.frame = CGRectMake(x, y, size.width, size.height);
        x += size.width + horizontalSpacing;
        rowHeight = MAX(rowHeight, size.height);
    }
    CGFloat measured = y + rowHeight;
    if (ABS(measured - _measuredHeight) > 0.5) {
        _measuredHeight = measured;
        [self invalidateIntrinsicContentSize];
    }
}
- (void)dealloc
{
    [_chips release];
    [super dealloc];
}
@end

@interface VZSettingsViewController ()
@property(nonatomic, retain) NSArray<NSDictionary *> *machines;
@property(nonatomic) CGFloat lastLayoutWidth;
@property(nonatomic) NSUInteger versionTapCount;
@end

static CGFloat VZSettingsContentWidth(UITableView *tableView)
{
    CGFloat width = CGRectGetWidth(tableView.bounds);
    // Inset-grouped cells and their content margins consume approximately
    // 40 points per side at regular width and 32 points per side when narrow.
    return MAX(width - 80.0, 120.0);
}

static NSString *VZSettingsFittingTitle(UITableView *tableView,
                                        NSString *fullTitle,
                                        NSString *compactTitle,
                                        CGFloat accessoryWidth)
{
    CGFloat available = VZSettingsContentWidth(tableView) - accessoryWidth;
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    CGFloat needed = [fullTitle sizeWithAttributes:@{NSFontAttributeName: font}].width;
    return needed <= available ? fullTitle : compactTitle;
}

@implementation VZSettingsViewController

- (instancetype)initWithMachines:(NSArray<NSDictionary *> *)machines
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        NSMutableArray *validMachines = [NSMutableArray array];
        if ([machines isKindOfClass:NSArray.class]) {
            for (id candidate in machines) {
                if (![candidate isKindOfClass:NSDictionary.class]) continue;
                id path = candidate[@"path"];
                id name = candidate[@"name"];
                if (![path isKindOfClass:NSString.class] || ![path length] ||
                    ![name isKindOfClass:NSString.class] || ![name length])
                    continue;
                [validMachines addObject:candidate];
            }
        }
        _machines = [validMachines copy];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = VZL(@"Settings");
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 44.0;
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self
        action:@selector(done:)] autorelease];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(settingsChanged:)
        name:VZSettingsDidChangeNotification object:nil];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    BOOL changed = self.lastLayoutWidth > 0 &&
        ABS(width - self.lastLayoutWidth) > 0.5;
    self.lastLayoutWidth = width;
    if (changed)
        [self.tableView reloadData];
}

- (void)settingsChanged:(NSNotification *)notification
{
    (void)notification;
    // HUD menu actions and the Home Screen quick action can change this value
    // while the sheet is visible. Update just that value: reloading the whole
    // table here would replace sliders while the user is dragging them.
    NSIndexPath *path = [NSIndexPath indexPathForRow:2 inSection:0];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
    if (!cell)
        return;
    NSDictionary *names = @{ @"always": VZL(@"On"),
                             @"hidden": VZL(@"Off") };
    NSString *visibility = [VZAppSettings.sharedSettings
        stringForKey:VZHUDVisibilityKey];
    cell.detailTextLabel.text = names[visibility] ?: VZL(@"On");
}

- (void)done:(id)sender
{
    (void)sender;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return 8;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    return section == 0 ? 4 : section == 1 ? 6 : section == 2 ? 5 :
        section == 3 ? 3 : section == 4 ? 3 : section == 5 ? 2 :
        section == 6 ? 1 : 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    return @[VZL(@"General"), VZL(@"Touch"), VZL(@"Input"),
             VZL(@"Compatibility"), VZL(@"Storage"), VZL(@"About"),
             VZL(@"Developers"), VZL(@"Support")][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 4)
        return [NSString stringWithFormat:VZL(@"Virtual Mac devices are stored in %@."), VZVMLibraryPath()];
    if (section == 2)
        return VZDeviceString(
            VZL(@"These options affect iPadOS only while Virtual Mac is frontmost and a Virtual Mac is running."),
            VZL(@"These options affect iOS only while Virtual Mac is frontmost and a Virtual Mac is running."));
    if (section == 3)
        return VZL(@"Debug Logging takes effect the next time a Virtual Mac starts.");
    return nil;
}

- (UITableViewCell *)baseCellForTableView:(UITableView *)tableView identifier:(NSString *)identifier
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell)
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
            reuseIdentifier:identifier] autorelease];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.textLabel.textAlignment = NSTextAlignmentNatural;
    cell.detailTextLabel.text = nil;
    cell.imageView.image = nil;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    VZAppSettings *settings = VZAppSettings.sharedSettings;
    UITableViewCell *cell = [self baseCellForTableView:tableView identifier:@"setting"];
    if (indexPath.section == 6) {
        NSArray *people = @[
            @{@"name": @"nfzerox", @"url": @"https://github.com/nfzerox", @"image": @"nfzerox.png"},
            @{@"name": @"qwqVictor", @"url": @"https://github.com/qwqVictor", @"image": @"qwqVictor.jpg"},
            @{@"name": @"jamesy0ung", @"url": @"https://github.com/jamesy0ung", @"image": @"jamesy0ung.jpg"},
            @{@"name": @"ma-syu", @"url": @"https://github.com/ma-syu", @"image": @"ma-syu.jpg"},
            @{@"name": @"LemomQ", @"url": @"https://github.com/LemomQ", @"image": @"LemomQ.png"}
        ];
        cell = [self baseCellForTableView:tableView identifier:@"contributors"];
        for (UIView *view in cell.contentView.subviews)
            if (view.tag == 1101) [view removeFromSuperview];
        NSMutableArray *chips = [NSMutableArray array];
        for (NSDictionary *person in people) {
            VZContributorChip *chip = [[[VZContributorChip alloc]
                initWithName:person[@"name"] imageName:person[@"image"]
                url:person[@"url"]] autorelease];
            [chips addObject:chip];
        }
        VZContributorFlowView *flow = [[[VZContributorFlowView alloc]
            initWithChips:chips] autorelease];
        flow.tag = 1101;
        flow.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:flow];
        CGFloat flowWidth = VZSettingsContentWidth(tableView);
        [flow.heightAnchor constraintEqualToConstant:
            [flow preferredHeightForWidth:flowWidth]].active = YES;
        [NSLayoutConstraint activateConstraints:@[
            [flow.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [flow.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [flow.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
            [flow.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        ]];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (indexPath.section == 0 && indexPath.row == 0) {
        cell.textLabel.text = VZL(@"Start on Launch");
        NSString *path = [settings stringForKey:VZAutoBootVMPathKey];
        NSString *identifier = [settings stringForKey:VZAutoBootVMIdentifierKey];
        NSDictionary *selected = nil;
        for (NSDictionary *machine in self.machines)
            if ([machine[@"path"] isEqualToString:path] ||
                (identifier.length && [VZVMStableIdentifier(machine[@"path"])
                    isEqualToString:identifier])) selected = machine;
        cell.detailTextLabel.text = selected[@"name"] ?: VZL(@"Show Library");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 0 && indexPath.row == 1) {
        cell.textLabel.text = VZL(@"Virtual Mac Display");
        cell.detailTextLabel.text = [[settings stringForKey:VZDisplayScalingKey]
            isEqualToString:@"fill"] ? VZL(@"Fill Window") : VZL(@"Fit in Window");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 0 && indexPath.row == 2) {
        cell.textLabel.text = VZL(@"Virtual Mac Controls");
        NSDictionary *names = @{@"always": VZL(@"On"),
                                @"hidden": VZL(@"Off")};
        NSString *visibility = [settings stringForKey:VZHUDVisibilityKey];
        cell.detailTextLabel.text = names[visibility] ?: VZL(@"On");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 0) {
        cell.textLabel.text = VZSettingsFittingTitle(tableView,
            VZL(@"Virtual Mac Controls Opacity"), VZL(@"Controls Opacity"), 196.0);
        UISlider *slider = [[[UISlider alloc] initWithFrame:
            CGRectMake(0, 0, 180, 32)] autorelease];
        slider.minimumValue = 0.0;
        slider.maximumValue = 1.0;
        slider.value = [[settings stringForKey:VZHUDOpacityKey] floatValue];
        [slider addTarget:self action:@selector(hudOpacityChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = slider;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 1 && indexPath.row < 5) {
        NSArray *titles = @[VZL(@"Show Cursor When Using Touch"),
                            VZL(@"Scroll with Two Fingers"),
                            VZL(@"Accommodate Double Tap"),
                            VZSettingsFittingTitle(tableView,
                                VZL(@"Two Finger Tap to Secondary Click"),
                                VZL(@"Two Finger Tap Right Click"), 67.0),
                            VZSettingsFittingTitle(tableView,
                                VZL(@"Touch and Hold to Secondary Click"),
                                VZL(@"Touch and Hold Right Click"), 67.0)];
        NSArray *keys = @[VZShowCursorWhenUsingTouchKey,
                          VZTouchTwoFingerScrollingKey,
                          VZTouchDoubleTapAccommodationKey,
                          VZTouchTwoFingerRightClickKey,
                          VZTouchLongPressRightClickKey];
        cell.textLabel.text = titles[indexPath.row];
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        toggle.tag = indexPath.row;
        toggle.on = [settings boolForKey:keys[indexPath.row]];
        [toggle addTarget:self action:@selector(inputToggleChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 1) {
        cell.textLabel.text = VZL(@"Scrolling Speed");
        UISlider *slider = [[[UISlider alloc] initWithFrame:
            CGRectMake(0, 0, 180, 32)] autorelease];
        slider.minimumValue = 0.1;
        slider.maximumValue = 1.0;
        slider.value = [[settings stringForKey:VZScrollingSpeedKey]
            floatValue];
        [slider addTarget:self action:@selector(scrollingSpeedChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = slider;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 2 && indexPath.row == 0) {
        cell.textLabel.text = VZL(@"Mac Keyboard Shortcuts");
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        toggle.tag = 20;
        toggle.on = [settings boolForKey:VZKeyboardShortcutCaptureKey];
        [toggle addTarget:self action:@selector(inputToggleChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 2 && indexPath.row < 4) {
        NSArray *titles = @[
            VZSettingsFittingTitle(tableView,
                VZDeviceString(VZL(@"Suppress iPadOS System Edge Gestures"),
                               VZL(@"Suppress iOS System Edge Gestures")),
                VZL(@"Suppress System Edge Gestures"), 67.0),
            VZSettingsFittingTitle(tableView,
                VZDeviceString(VZL(@"Suppress iPadOS Multitasking Gestures"),
                               VZL(@"Suppress iOS Multitasking Gestures")),
                VZL(@"Suppress Multitasking Gestures"), 67.0),
            VZSettingsFittingTitle(tableView,
                VZDeviceString(VZL(@"Suppress iPadOS Home Indicator"),
                               VZL(@"Suppress iOS Home Indicator")),
                VZL(@"Suppress Home Indicator"), 67.0)];
        NSArray *keys = @[VZSystemGestureSuppressionKey,
                          VZMultitaskingGestureSuppressionKey,
                          VZHomeIndicatorSuppressionKey];
        cell.textLabel.text = titles[indexPath.row - 1];
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        toggle.tag = 30 + indexPath.row - 1;
        toggle.on = [settings boolForKey:keys[indexPath.row - 1]];
        [toggle addTarget:self action:@selector(inputToggleChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 2) {
        cell.textLabel.text = [NSString stringWithUTF8String:
            "Network Gamepad Relay"];
        NSDictionary *state = [[VZGamepadBridge sharedBridge] stateSnapshot];
        cell.detailTextLabel.text = [state[@"controllerConnected"] boolValue]
            ? [NSString stringWithUTF8String:"Controller Connected"]
            : [NSString stringWithUTF8String:"No Controller"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 3) {
        NSArray *titles = @[VZL(@"Fix Keyboard Crash"),
                            VZL(@"Fix External Display Scroll Direction"),
                            VZL(@"Debug Logging")];
        cell.textLabel.text = titles[indexPath.row];
        if (indexPath.row == 2) {
            NSString *mode = [settings stringForKey:VZDebugLoggingKey];
            cell.detailTextLabel.text =
                [mode isEqualToString:VZDebugLoggingModeAlways]
                    ? VZL(@"Always On")
                : [mode isEqualToString:VZDebugLoggingModeNextBoot]
                    ? VZL(@"On for Next Boot") : VZL(@"Off");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        NSArray *keys = @[VZKeyboardCrashWorkaroundKey,
                          VZExternalDisplayScrollFixKey];
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        toggle.tag = 100 + indexPath.row;
        toggle.on = [settings boolForKey:keys[indexPath.row]];
        [toggle addTarget:self action:@selector(inputToggleChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 4 && indexPath.row == 0) {
        cell.textLabel.text = VZSettingsFittingTitle(tableView,
            VZL(@"Delete IPSW After Successful Installation"),
            VZL(@"Delete IPSW After Installation"), 67.0);
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        toggle.on = [settings boolForKey:VZAutoDeleteRestoreImageKey];
        [toggle addTarget:self action:@selector(autoDeleteToggleChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 4) {
        NSArray *paths = indexPath.row == 1 ? VZCachedRestoreImagePaths()
                                            : VZInstallationArtifactPaths();
        cell.textLabel.text = indexPath.row == 1 ? VZL(@"Delete Cached IPSW")
                                                 : VZL(@"Delete Temporary Installation Files");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)paths.count];
        cell.textLabel.textColor = paths.count ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
        cell.selectionStyle = paths.count ? UITableViewCellSelectionStyleDefault
                                          : UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 5 && indexPath.row == 0) {
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        NSString *version = info[@"CFBundleShortVersionString"] ?: @"—";
        NSString *build = info[@"CFBundleVersion"] ?: @"—";
        cell.textLabel.text = VZL(@"Version");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)",
            version, build];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 5) {
        cell.textLabel.text = VZL(@"Reset Settings");
        cell.textLabel.textColor = UIColor.systemRedColor;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
    } else if (indexPath.section == 7) {
        NSArray *titles = @[VZL(@"Copy Library Path"), VZL(@"Export Diagnostics"),
                            VZL(@"Get Help"), VZL(@"Report Issue")];
        NSArray *images = @[@"doc.on.doc", @"square.and.arrow.up",
                            @"questionmark.circle", @"exclamationmark.bubble"];
        cell.textLabel.text = titles[indexPath.row];
        cell.imageView.image = [UIImage systemImageNamed:images[indexPath.row]];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)inputToggleChanged:(UISwitch *)sender
{
    NSArray *touchKeys = @[VZShowCursorWhenUsingTouchKey,
                           VZTouchTwoFingerScrollingKey,
                           VZTouchDoubleTapAccommodationKey,
                           VZTouchTwoFingerRightClickKey,
                           VZTouchLongPressRightClickKey];
    NSArray *iPadOSKeys = @[VZSystemGestureSuppressionKey,
                            VZMultitaskingGestureSuppressionKey,
                            VZHomeIndicatorSuppressionKey];
    NSArray *compatibilityKeys = @[VZKeyboardCrashWorkaroundKey,
                                   VZExternalDisplayScrollFixKey];
    NSString *key = sender.tag >= 100 ? compatibilityKeys[sender.tag - 100]
        : sender.tag >= 30 ? iPadOSKeys[sender.tag - 30]
        : sender.tag == 20 ? VZKeyboardShortcutCaptureKey
                           : touchKeys[sender.tag];
    [VZAppSettings.sharedSettings setBool:sender.on forKey:key];
}

- (void)chooseDebugLoggingFrom:(UITableViewCell *)cell
{
    UIAlertController *picker = [UIAlertController
        alertControllerWithTitle:VZL(@"Debug Logging") message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *titles = @[VZL(@"Off"), VZL(@"On for Next Boot"),
                        VZL(@"Always On")];
    NSArray *values = @[VZDebugLoggingModeOff, VZDebugLoggingModeNextBoot,
                        VZDebugLoggingModeAlways];
    for (NSUInteger index = 0; index < values.count; ++index) {
        [picker addAction:[UIAlertAction actionWithTitle:titles[index]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                (void)action;
                [VZAppSettings.sharedSettings setString:values[index]
                    forKey:VZDebugLoggingKey];
                [self.tableView reloadData];
            }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    picker.popoverPresentationController.sourceView = cell;
    picker.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)chooseDisplayScalingFrom:(UITableViewCell *)cell
{
    UIAlertController *picker = [UIAlertController
        alertControllerWithTitle:VZL(@"Virtual Mac Display")
        message:VZL(@"Fit in Window shows the entire display. Fill Window crops its edges when the window has a different shape.")
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *titles = @[VZL(@"Fit in Window"), VZL(@"Fill Window")];
    NSArray *values = @[@"fit", @"fill"];
    for (NSUInteger index = 0; index < titles.count; index++) {
        [picker addAction:[UIAlertAction actionWithTitle:titles[index]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                (void)action;
                [VZAppSettings.sharedSettings setString:values[index]
                    forKey:VZDisplayScalingKey];
                [self.tableView reloadData];
            }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    picker.popoverPresentationController.sourceView = cell;
    picker.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)autoDeleteToggleChanged:(UISwitch *)sender
{
    [VZAppSettings.sharedSettings setBool:sender.on forKey:VZAutoDeleteRestoreImageKey];
}

- (void)hudOpacityChanged:(UISlider *)sender
{
    [VZAppSettings.sharedSettings setString:
        [NSString stringWithFormat:@"%.2f", sender.value]
        forKey:VZHUDOpacityKey];
}

- (void)scrollingSpeedChanged:(UISlider *)sender
{
    [VZAppSettings.sharedSettings setString:
        [NSString stringWithFormat:@"%.2f", sender.value]
        forKey:VZScrollingSpeedKey];
}

- (void)chooseHUDVisibilityFrom:(UITableViewCell *)cell
{
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:VZL(@"Virtual Mac Controls")
        message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *titles = @[VZL(@"On"), VZL(@"Off")];
    NSArray *values = @[@"always", @"hidden"];
    for (NSUInteger index = 0; index < titles.count; index++) {
        [picker addAction:[UIAlertAction actionWithTitle:titles[index]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                (void)action;
                [VZAppSettings.sharedSettings setString:values[index] forKey:VZHUDVisibilityKey];
                [self.tableView reloadData];
                if (![values[index] isEqualToString:@"always"]) {
                    UIAlertController *notice = [UIAlertController
                        alertControllerWithTitle:VZL(@"Show Virtual Mac Controls")
                        message:VZL(@"To show the controls, touch and hold the Virtual Mac icon on the Home Screen, then choose Show Virtual Mac Controls.")
                        preferredStyle:UIAlertControllerStyleAlert];
                    [notice addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
                        style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:notice animated:YES completion:nil];
                }
            }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    picker.popoverPresentationController.sourceView = cell;
    picker.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)chooseAutoBootFrom:(UITableViewCell *)cell
{
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:VZL(@"Start on Launch")
        message:VZL(@"Choose whether Virtual Mac opens its library or starts a Virtual Mac.")
        preferredStyle:UIAlertControllerStyleActionSheet];
    [picker addAction:[UIAlertAction actionWithTitle:VZL(@"Show Library")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            [VZAppSettings.sharedSettings setString:nil forKey:VZAutoBootVMPathKey];
            [VZAppSettings.sharedSettings setString:nil forKey:VZAutoBootVMIdentifierKey];
            [self.tableView reloadData];
        }]];
    for (NSDictionary *machine in self.machines) {
        [picker addAction:[UIAlertAction actionWithTitle:machine[@"name"]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                (void)action;
                [VZAppSettings.sharedSettings setString:machine[@"path"] forKey:VZAutoBootVMPathKey];
                [VZAppSettings.sharedSettings setString:VZVMStableIdentifier(machine[@"path"])
                                                   forKey:VZAutoBootVMIdentifierKey];
                [self.tableView reloadData];
            }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    picker.popoverPresentationController.sourceView = cell;
    picker.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)confirmDeletePaths:(NSArray<NSString *> *)paths title:(NSString *)title
{
    if (!paths.count) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:VZL(@"Complete Virtual Mac devices and restore images outside Virtual Mac are not removed.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Delete") style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
            (void)action;
            VZRemovePaths(paths);
            [self.tableView reloadData];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmResetSettings
{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:VZL(@"Reset Settings?")
        message:VZL(@"This restores all Virtual Mac settings to their defaults. Virtual Macs, restore images, and installation files won’t be removed.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Reset")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            (void)action;
            [VZAppSettings.sharedSettings resetToDefaults];
            [self.tableView reloadData];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exportDiagnosticsFrom:(UITableViewCell *)cell
{
    UIActivityIndicatorView *spinner = [[[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium]
        autorelease];
    cell.accessoryView = spinner;
    cell.userInteractionEnabled = NO;
    [spinner startAnimating];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *archive = VZCreateDiagnosticsArchive(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.userInteractionEnabled = YES;
            if (!archive) {
                VZPresentFailureReport(self,
                    VZL(@"Couldn’t Export Diagnostics"),
                    error.localizedDescription ?:
                        VZL(@"The diagnostics archive could not be created."),
                    error.debugDescription,
                    VZFailureSupportOptionDiagnosticsUnavailable);
                return;
            }
            // The activity sheet initializes Core Image to draw the AirDrop
            // activity icon. That crashes on iPadOS 16 while Virtual Mac's
            // extracted graphics stack is loaded. The Files exporter is the
            // native file-save UI and does not enter that unsafe code path.
            UIDocumentPickerViewController *picker =
                [[[UIDocumentPickerViewController alloc]
                  initForExportingURLs:@[archive] asCopy:YES] autorelease];
            [self presentViewController:picker animated:YES completion:nil];
        });
    });
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 5 && indexPath.row == 0) {
        self.versionTapCount++;
        if (self.versionTapCount >= 5) {
            self.versionTapCount = 0;
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            BOOL alternate = [defaults boolForKey:@"VZSimulateAlternateUI"];
            [defaults setBool:!alternate forKey:@"VZSimulateAlternateUI"];
            [defaults synchronize];
            [self.tableView reloadData];
            UINotificationFeedbackGenerator *feedback =
                [[[UINotificationFeedbackGenerator alloc] init] autorelease];
            [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
        }
        return;
    }
    self.versionTapCount = 0;
    if (indexPath.section == 0 && indexPath.row == 0)
        [self chooseAutoBootFrom:cell];
    else if (indexPath.section == 0 && indexPath.row == 1)
        [self chooseDisplayScalingFrom:cell];
    else if (indexPath.section == 0 && indexPath.row == 2)
        [self chooseHUDVisibilityFrom:cell];
    else if (indexPath.section == 3 && indexPath.row == 2)
        [self chooseDebugLoggingFrom:cell];
    else if (indexPath.section == 2 && indexPath.row == 4) {
        VZGamepadSettingsViewController *gamepad =
            [[[VZGamepadSettingsViewController alloc] init] autorelease];
        [self.navigationController pushViewController:gamepad animated:YES];
    }
    else if (indexPath.section == 7 && indexPath.row == 0) {
        UIPasteboard.generalPasteboard.string = VZVMLibraryPath();
        UINotificationFeedbackGenerator *feedback = [[[UINotificationFeedbackGenerator alloc] init] autorelease];
        [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
    } else if (indexPath.section == 4 && indexPath.row == 1)
        [self confirmDeletePaths:VZCachedRestoreImagePaths() title:VZL(@"Delete Cached IPSW?")];
    else if (indexPath.section == 4 && indexPath.row == 2)
        [self confirmDeletePaths:VZInstallationArtifactPaths() title:VZL(@"Delete Temporary Installation Files?")];
    else if (indexPath.section == 7 && indexPath.row == 1)
        [self exportDiagnosticsFrom:cell];
    else if (indexPath.section == 5 && indexPath.row == 1)
        [self confirmResetSettings];
    else if (indexPath.section == 7 && indexPath.row >= 2)
        VZOpenSupportURL(indexPath.row == 2 ? VZGetHelpURLString : VZReportIssueURLString);
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_machines release];
    [super dealloc];
}

@end
