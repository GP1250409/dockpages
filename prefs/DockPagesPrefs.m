// DockPagesPrefs - settings bundle for DockPages
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#define PREF_DOMAIN CFSTR("cc.gonepaul.dockpages")
#define PER_PAGE 4

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)i;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationIdentifier;
@end
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end
@interface UIImage (DPPrefsPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)b format:(int)f scale:(CGFloat)s;
@end

static NSArray *DPGetApps(NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, PREF_DOMAIN);
    NSArray *a = (__bridge_transfer id)v;
    return [a isKindOfClass:NSArray.class] ? a : @[];
}
static void DPSetValue(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, PREF_DOMAIN);
    CFPreferencesAppSynchronize(PREF_DOMAIN);
    notify_post("cc.gonepaul.dockpages/changed");
}
static NSString *DPAppName(NSString *bid) {
    LSApplicationProxy *p = [NSClassFromString(@"LSApplicationProxy") applicationProxyForIdentifier:bid];
    return p.localizedName ?: bid;
}

#pragma mark - App picker (one page)

@interface DPAppPickerController : UITableViewController
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) NSMutableArray<NSString *> *chosen;
@property (nonatomic, strong) NSArray<NSString *> *all;
@property (nonatomic, strong) NSArray<NSString *> *names;
@end

@implementation DPAppPickerController
- (instancetype)initWithKey:(NSString *)key title:(NSString *)title {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.key = key;
    self.title = title;
    self.chosen = [DPGetApps(key) mutableCopy];
    NSMutableArray *ids = [NSMutableArray array];
    for (id p in [[NSClassFromString(@"LSApplicationWorkspace") defaultWorkspace] allInstalledApplications]) {
        NSString *bid = [p valueForKey:@"applicationIdentifier"];
        NSString *type = [p valueForKey:@"applicationType"];
        if (!bid || [bid hasPrefix:@"com.apple.webapp"]) continue;
        if ([type isEqualToString:@"Hidden"]) continue;
        if ([[p valueForKey:@"appTags"] containsObject:@"hidden"]) continue;
        [ids addObject:bid];
    }
    NSMutableDictionary *nm = [NSMutableDictionary dictionary];
    for (NSString *b in ids) nm[b] = DPAppName(b);
    self.all = [ids sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [nm[a] localizedStandardCompare:nm[b]];
    }];
    self.names = [self.all valueForKey:@"self"];
    NSMutableArray *n2 = [NSMutableArray array];
    for (NSString *b in self.all) [n2 addObject:nm[b]];
    self.names = n2;
    return self;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 2; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return s == 0 ? (NSInteger)self.chosen.count : (NSInteger)self.all.count; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? [NSString stringWithFormat:@"已选 %lu/%d（左滑删除，长按拖动排序）", (unsigned long)self.chosen.count, PER_PAGE] : @"全部应用";
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSString *bid = ip.section == 0 ? self.chosen[ip.row] : self.all[ip.row];
    c.textLabel.text = ip.section == 0 ? DPAppName(bid) : self.names[ip.row];
    c.detailTextLabel.text = bid;
    c.imageView.image = [UIImage _applicationIconImageForBundleIdentifier:bid format:0 scale:UIScreen.mainScreen.scale];
    c.imageView.layer.cornerRadius = 7;
    c.imageView.clipsToBounds = YES;
    c.accessoryType = (ip.section == 1 && [self.chosen containsObject:bid]) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}
- (void)save { DPSetValue(self.key, [self.chosen copy]); }
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 1) return;
    NSString *bid = self.all[ip.row];
    if ([self.chosen containsObject:bid]) [self.chosen removeObject:bid];
    else if (self.chosen.count >= PER_PAGE) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已满" message:@"每页最多 4 个应用" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    } else [self.chosen addObject:bid];
    [self save];
    [t reloadData];
}
- (BOOL)tableView:(UITableView *)t canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 0; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)t editingStyleForRowAtIndexPath:(NSIndexPath *)ip { return UITableViewCellEditingStyleDelete; }
- (void)tableView:(UITableView *)t commitEditingStyle:(UITableViewCellEditingStyle)s forRowAtIndexPath:(NSIndexPath *)ip {
    [self.chosen removeObjectAtIndex:ip.row];
    [self save];
    [t reloadData];
}
- (BOOL)tableView:(UITableView *)t canMoveRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 0; }
- (void)tableView:(UITableView *)t moveRowAtIndexPath:(NSIndexPath *)a toIndexPath:(NSIndexPath *)b {
    NSString *x = self.chosen[a.row];
    [self.chosen removeObjectAtIndex:a.row];
    [self.chosen insertObject:x atIndex:b.row];
    [self save];
}
- (NSIndexPath *)tableView:(UITableView *)t targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)a toProposedIndexPath:(NSIndexPath *)b {
    return b.section == 0 ? b : [NSIndexPath indexPathForRow:MAX(0, (NSInteger)self.chosen.count - 1) inSection:0];
}
- (void)viewDidLoad { [super viewDidLoad]; self.tableView.editing = YES; self.tableView.allowsSelectionDuringEditing = YES; }
@end

#pragma mark - Root list

@interface DockPagesRootListController : PSListController
@end

@implementation DockPagesRootListController
- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *s = [NSMutableArray array];
    PSSpecifier *g = [PSSpecifier groupSpecifierWithName:@"Dock 额外页"];
    [g setProperty:@"在 Dock 任意位置左右滑动即可翻页。每页最多 4 个应用，最多 3 个额外页；系统原 Dock 是第 1 页。" forKey:@"footerText"];
    [s addObject:g];
    for (int i = 1; i <= 3; i++) {
        NSString *key = [NSString stringWithFormat:@"page%d", i];
        PSSpecifier *p = [PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"第 %d 页（额外）", i + 1]
                                                         target:self set:nil get:@selector(countFor:)
                                                         detail:Nil cell:PSLinkListCell edit:Nil];
        [p setProperty:key forKey:@"dpKey"];
        p->action = @selector(openPage:);
        [s addObject:p];
    }
    PSSpecifier *g2 = [PSSpecifier groupSpecifierWithName:@""];
    [g2 setProperty:@"打开后，主屏幕翻页时 Dock 会跟着翻到同一页；主屏幕页数超过 Dock 页数时，Dock 停在最后一页。" forKey:@"footerText"];
    [s addObject:g2];
    PSSpecifier *sw = [PSSpecifier preferenceSpecifierNamed:@"跟随页面" target:self set:@selector(setFollow:specifier:) get:@selector(getFollow:) detail:Nil cell:PSSwitchCell edit:Nil];
    [s addObject:sw];
    _specifiers = s;
    return s;
}
- (id)countFor:(PSSpecifier *)spec {
    NSArray *a = DPGetApps([spec propertyForKey:@"dpKey"]);
    return a.count ? [NSString stringWithFormat:@"%lu 个", (unsigned long)a.count] : @"未设置";
}
- (void)openPage:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"dpKey"];
    DPAppPickerController *c = [[DPAppPickerController alloc] initWithKey:key title:spec.name];
    [self.navigationController pushViewController:c animated:YES];
}
- (id)getFollow:(PSSpecifier *)spec {
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("followHomePage"), PREF_DOMAIN);
    id o = (__bridge_transfer id)v;
    return o ?: @YES;
}
- (void)setFollow:(id)value specifier:(PSSpecifier *)spec { DPSetValue(@"followHomePage", value); }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadSpecifiers]; }
@end
