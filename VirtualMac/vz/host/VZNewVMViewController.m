#import "VZNewVMViewController.h"
#import "VZLocalization.h"
#import "VZRestoreCatalog.h"

static NSString *VZCatalogString(id value)
{
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static UIImage *VZCatalogIcon(NSDictionary *image)
{
    NSString *name = [VZRestoreCatalog artworkNameForImage:image];
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSMutableDictionary alloc] init]; });
    UIImage *cached = cache[name];
    if (cached)
        return cached;
    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png"
                                               inDirectory:@"Installers"];
    UIImage *source = [UIImage imageWithContentsOfFile:path];
    if (!source)
        return nil;
    CGSize size = CGSizeMake(48, 48);
    UIGraphicsBeginImageContextWithOptions(size, NO, UIScreen.mainScreen.scale);
    [source drawInRect:(CGRect){CGPointZero, size}];
    UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (scaled)
        cache[name] = scaled;
    return scaled;
}

@interface VZNewVMViewController ()
@property(nonatomic, retain) NSArray<NSDictionary *> *catalog;
@property(nonatomic, retain) UIActivityIndicatorView *activity;
@property(nonatomic, assign) BOOL showMinorReleases;
@property(nonatomic, assign) BOOL showDeveloperBetas;
@property(nonatomic, assign) BOOL showVersionDetails;
@property(nonatomic, assign) BOOL versionDetailsBeforeDeveloperBetas;
@property(nonatomic, assign) CGFloat lastLayoutWidth;
@end

@implementation VZNewVMViewController

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = VZL(@"New Virtual Mac");
    self.tableView.rowHeight = 54.0;
    self.tableView.estimatedRowHeight = 54.0;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 24, 0);
    self.tableView.verticalScrollIndicatorInsets = UIEdgeInsetsMake(0, 0, 24, 0);
    self.navigationItem.leftBarButtonItem = [[[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self
        action:@selector(cancel:)] autorelease];
    self.activity = [[[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium]
        autorelease];
    [self.activity startAnimating];
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
        initWithCustomView:self.activity] autorelease];
    [VZRestoreCatalog loadWithCompletion:^(NSArray<NSDictionary *> *images,
                                            NSError *error) {
        self.catalog = images;
        [self.activity stopAnimating];
        self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
            menu:[self filterMenu]] autorelease];
        [self.tableView reloadData];
        if (error)
            NSLog(@"Virtual Mac restore catalog fallback failed: %@", error);
    }];
}

- (void)cancel:(id)sender
{
    (void)sender;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    BOOL changed = self.lastLayoutWidth > 0 &&
        fabs(width - self.lastLayoutWidth) > 0.5;
    self.lastLayoutWidth = width;
    if (changed)
        [self.tableView reloadData];
}

- (UIMenu *)filterMenu
{
    UIAction *minor = [UIAction actionWithTitle:VZL(@"Show Minor Releases")
        image:nil identifier:nil handler:^(__kindof UIAction *action) {
        (void)action;
        self.showMinorReleases = !self.showMinorReleases;
        self.navigationItem.rightBarButtonItem.menu = [self filterMenu];
        [self.tableView reloadData];
    }];
    minor.state = self.showMinorReleases ? UIMenuElementStateOn
                                         : UIMenuElementStateOff;
    UIAction *betas = [UIAction actionWithTitle:VZL(@"Show Developer Betas")
        image:nil identifier:nil handler:^(__kindof UIAction *action) {
        (void)action;
        if (!self.showDeveloperBetas) {
            self.versionDetailsBeforeDeveloperBetas = self.showVersionDetails;
            self.showDeveloperBetas = YES;
            self.showVersionDetails = YES;
        } else {
            self.showDeveloperBetas = NO;
            self.showVersionDetails = self.versionDetailsBeforeDeveloperBetas;
        }
        self.navigationItem.rightBarButtonItem.menu = [self filterMenu];
        [self.tableView reloadData];
    }];
    betas.state = self.showDeveloperBetas ? UIMenuElementStateOn
                                          : UIMenuElementStateOff;
    UIAction *details = [UIAction actionWithTitle:VZL(@"Show Version Details")
        image:nil identifier:nil handler:^(__kindof UIAction *action) {
        (void)action;
        self.showVersionDetails = !self.showVersionDetails;
        self.navigationItem.rightBarButtonItem.menu = [self filterMenu];
        [self.tableView reloadData];
    }];
    details.state = self.showVersionDetails ? UIMenuElementStateOn
                                            : UIMenuElementStateOff;
    details.attributes = self.showDeveloperBetas
        ? UIMenuElementAttributesDisabled : 0;
    return [UIMenu menuWithTitle:VZL(@"Available macOS Versions")
                         children:@[minor, betas, details]];
}

- (NSArray<NSDictionary *> *)versionImages
{
    NSMutableArray *result = [NSMutableArray array];
    BOOL showsAdvancedVersions = self.showMinorReleases ||
        self.showDeveloperBetas || self.showVersionDetails;
    for (NSString *group in [VZRestoreCatalog orderedGroupsForImages:self.catalog]) {
        NSArray *matches = [self.catalog filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSDictionary *image,
                                                   NSDictionary *bindings) {
            (void)bindings;
            return [VZCatalogString(image[@"group"]) isEqualToString:group];
        }]];
        NSArray *sorted = [matches sortedArrayUsingComparator:
            ^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            return [VZCatalogString(right[@"version"])
                compare:VZCatalogString(left[@"version"])
                options:NSNumericSearch];
        }];
        NSMutableArray *releases = [NSMutableArray array];
        NSMutableArray *betas = [NSMutableArray array];
        for (NSDictionary *image in sorted) {
            if (!showsAdvancedVersions &&
                [VZRestoreCatalog isUnsupportedImage:image])
                continue;
            if ([VZCatalogString(image[@"channel"]) isEqualToString:@"devbeta"])
                [betas addObject:image];
            else
                [releases addObject:image];
        }
        if (self.showMinorReleases)
            [result addObjectsFromArray:releases];
        else if (releases.count)
            [result addObject:releases.firstObject];
        if (self.showDeveloperBetas)
            [result addObjectsFromArray:betas];
        else if (!releases.count && betas.count)
            [result addObject:betas.firstObject];
    }
    return result;
}

- (NSDictionary *)recommendedImage
{
    BOOL showsAdvancedVersions = self.showMinorReleases ||
        self.showDeveloperBetas || self.showVersionDetails;
    NSArray *eligible = self.catalog;
    if (!showsAdvancedVersions) {
        eligible = [self.catalog filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSDictionary *image,
                                                   NSDictionary *bindings) {
            (void)bindings;
            return ![VZRestoreCatalog isUnsupportedImage:image];
        }]];
    }
    return [VZRestoreCatalog recommendedImageFromImages:eligible];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 0)
        return self.recommendedImage ? 1 : 0;
    if (section == 1)
        return self.versionImages.count;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 0)
        return VZL(@"Recommended macOS Release");
    if (section == 1)
        return VZL(@"Available macOS Releases");
    return VZL(@"Advanced");
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
#if defined(VZ_ROOTHIDE)
    return nil;
#else
    return section == 2
        ? VZL(@"You can also copy an existing Virtual Mac bundle to /var/mobile/Media/VirtualMac using an app such as iMazing or Filza.")
        : nil;
#endif
}

- (CGFloat)tableView:(UITableView *)tableView
 heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    if (indexPath.section == 2)
        return self.showVersionDetails ? 68.0 : 54.0;
    return self.showVersionDetails ? 68.0 : 54.0;
}

- (void)setAccessoryForImage:(NSDictionary *)image
                         cell:(UITableViewCell *)cell
{
    cell.accessoryView = nil;
    if (![VZRestoreCatalog isExperimentalImage:image]) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return;
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    UIView *accessory = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 24)]
        autorelease];
    UIImageView *warning = [[[UIImageView alloc] initWithFrame:
        CGRectMake(0, 2, 20, 20)] autorelease];
    warning.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
    warning.contentMode = UIViewContentModeScaleAspectFit;
    warning.tintColor = UIColor.quaternaryLabelColor;
    warning.isAccessibilityElement = YES;
    warning.accessibilityLabel = VZL(@"Experimental");
    UIImageView *chevron = [[[UIImageView alloc] initWithFrame:
        CGRectMake(32, 5, 8, 14)] autorelease];
    chevron.image = [UIImage systemImageNamed:@"chevron.right"];
    chevron.tintColor = UIColor.tertiaryLabelColor;
    [accessory addSubview:warning];
    [accessory addSubview:chevron];
    cell.accessoryView = accessory;
}

- (NSDictionary *)imageAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0)
        return self.recommendedImage;
    if (indexPath.section == 1 && indexPath.row < self.versionImages.count)
        return self.versionImages[indexPath.row];
    return nil;
}

- (BOOL)title:(NSString *)title fitsCell:(UITableViewCell *)cell
{
    [cell setNeedsLayout];
    [cell layoutIfNeeded];
    CGFloat available = CGRectGetWidth(cell.textLabel.bounds);
    if (available <= 0)
        available = MAX(CGRectGetWidth(self.tableView.bounds) - 200.0, 80.0);
    CGFloat needed = [title sizeWithAttributes:
        @{NSFontAttributeName: cell.textLabel.font}].width;
    return needed <= available;
}

- (void)fitTitleForImage:(NSDictionary *)image
                    cell:(UITableViewCell *)cell
{
    BOOL compactName = !self.showMinorReleases &&
        !self.showDeveloperBetas && !self.showVersionDetails;
    NSString *displayName = [VZRestoreCatalog displayNameForImage:image
                                                           compact:compactName];
    NSString *title = compactName
        ? [NSString stringWithFormat:VZL(@"Install %@"), displayName]
        : displayName;
    cell.textLabel.text = title;
    [self setAccessoryForImage:image cell:cell];
    if (![self title:title fitsCell:cell] && compactName) {
        NSString *marketing = [VZRestoreCatalog marketingNameForImage:image];
        if (marketing.length) {
            displayName = [NSString stringWithFormat:@"macOS %@", marketing];
            title = [NSString stringWithFormat:VZL(@"Install %@"), displayName];
            cell.textLabel.text = title;
        }
    }
    // The warning is supplementary: preserve the complete actionable title
    // on narrow windows and retain the normal disclosure chevron.
    if ([VZRestoreCatalog isExperimentalImage:image] &&
        ![self title:title fitsCell:cell]) {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"image"];
    if (!cell)
        cell = [[[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"image"]
            autorelease];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.imageView.layer.cornerRadius = 9.0;
    cell.imageView.layer.cornerCurve = kCACornerCurveContinuous;
    cell.imageView.layer.masksToBounds = YES;
    cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
    if (indexPath.section == 2) {
        cell.textLabel.text = VZL(@"Choose Custom IPSW");
        cell.detailTextLabel.text = self.showVersionDetails
            ? VZDeviceString(VZL(@"Use an IPSW on your iPad"),
                             VZL(@"Use an IPSW on your iPhone")) : nil;
        cell.imageView.layer.cornerRadius = 9.0;
        cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
        cell.imageView.tintColor = nil;
        cell.imageView.image = VZCatalogIcon(@{});
        return cell;
    }
    NSDictionary *image = [self imageAtIndexPath:indexPath];
    cell.imageView.image = VZCatalogIcon(image);
    NSMutableArray *details = [NSMutableArray array];
    if (self.showVersionDetails) {
        NSString *build = VZCatalogString(image[@"build"]);
        if (build.length)
            [details addObject:[NSString stringWithFormat:VZL(@"Build %@"), build]];
        NSString *channel = VZCatalogString(image[@"channel"]);
        if ([channel isEqualToString:@"devbeta"])
            [details addObject:VZL(@"Developer Beta")];
        else if ([channel isEqualToString:@"regular"])
            [details addObject:VZL(@"Release")];
        long long size = [image[@"downloadSize"] longLongValue];
        if (size > 0) {
            NSByteCountFormatter *formatter = [[[NSByteCountFormatter alloc]
                init] autorelease];
            formatter.countStyle = NSByteCountFormatterCountStyleFile;
            [details addObject:[formatter stringFromByteCount:size]];
        }
    }
    cell.detailTextLabel.text = self.showVersionDetails
        ? [details componentsJoinedByString:@" · "] : nil;
    [self fitTitleForImage:image cell:cell];
    return cell;
}

- (void)tableView:(UITableView *)tableView
   willDisplayCell:(UITableViewCell *)cell
 forRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    NSDictionary *image = [self imageAtIndexPath:indexPath];
    if (image)
        [self fitTitleForImage:image cell:cell];
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2) {
        [self.delegate newVMControllerChooseLocalRestoreImage:self];
        return;
    }
    NSDictionary *image = indexPath.section == 0
        ? self.recommendedImage
        : self.versionImages[indexPath.row];
    if (image)
        [self.delegate newVMController:self downloadRestoreImage:image];
}

- (void)dealloc
{
    [_catalog release];
    [_activity release];
    [super dealloc];
}

@end
