// DockPages - multi-page Dock for SpringBoard (iOS 16, arm64e)
// Page 0 = the system Dock. Pages 1..3 = extra pages (4 apps each).
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <dlfcn.h>
#import <objc/message.h>

#define NOTIFY_CHANGED "cc.gonepaul.dockpages/changed"
#define MAX_EXTRA 3
#define PER_PAGE 4

static os_log_t L;
#define LOG(fmt, ...) os_log(L, fmt, ##__VA_ARGS__)

@interface UIImage (DPPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)b format:(int)f scale:(CGFloat)s;
@end

static NSArray<NSArray<NSString *> *> *gPages = nil;
static BOOL gFollow = YES;

static void LoadPrefs(void) {
    CFPreferencesAppSynchronize(CFSTR("cc.gonepaul.dockpages"));
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in @[@"page1", @"page2", @"page3", @"followHomePage"]) {
        CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)k, CFSTR("cc.gonepaul.dockpages"));
        if (v) d[k] = (__bridge_transfer id)v;
    }
    NSMutableArray *pages = [NSMutableArray array];
    for (int i = 1; i <= MAX_EXTRA; i++) {
        NSArray *a = d[[NSString stringWithFormat:@"page%d", i]];
        if (![a isKindOfClass:NSArray.class]) a = @[];
        if (a.count > PER_PAGE) a = [a subarrayWithRange:NSMakeRange(0, PER_PAGE)];
        [pages addObject:a];
    }
    while (pages.count && [pages.lastObject count] == 0) [pages removeLastObject];
    gPages = pages;
    gFollow = d[@"followHomePage"] ? [d[@"followHomePage"] boolValue] : YES;
}

// SBSLaunchApplicationWithIdentifier avoids LSApplicationWorkspace openApplication,
// which deadlocks ~10s against lsd when called on the SpringBoard main thread.
static void LaunchApp(NSString *bid) {
    static int (*fn)(NSString *, BOOL);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        if (h) fn = dlsym(h, "SBSLaunchApplicationWithIdentifier");
    });
    if (fn) { int r = fn(bid, NO); LOG("launch %{public}@ -> %d", bid, r); }
    else LOG("no launcher for %{public}@", bid);
}

@interface DPController : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *dock;
@property (nonatomic, weak) UIView *iconList;
@property (nonatomic, strong) UIView *clip;
@property (nonatomic, strong) NSMutableArray<UIView *> *pageViews;
@property (nonatomic, strong) UIPanGestureRecognizer *pan;
@property (nonatomic) CGFloat position;
@property (nonatomic) CGFloat panStart;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic) CGFloat target;
@property (nonatomic) CGFloat velocity;
@property (nonatomic, copy) id builtKey;
- (void)attachTo:(UIView *)dock list:(UIView *)list;
- (void)layoutPages;
- (void)syncWithHome:(CGFloat)homePage;
- (void)homeSettled:(CGFloat)homePage;
@end

static DPController *gCtl = nil;

@implementation DPController

- (NSInteger)pageCount { return (NSInteger)gPages.count + 1; }

- (void)attachTo:(UIView *)dock list:(UIView *)list {
    self.dock = dock;
    self.iconList = list;
    if (!self.clip) {
        self.clip = [[UIView alloc] initWithFrame:dock.bounds];
        self.clip.clipsToBounds = YES;
        self.clip.backgroundColor = UIColor.clearColor;
        self.pageViews = [NSMutableArray array];
        self.pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        self.pan.delegate = self;
        self.pan.maximumNumberOfTouches = 1;
        [dock addGestureRecognizer:self.pan];
    }
    if (self.clip.superview != dock) [dock addSubview:self.clip];
}

- (NSArray<NSValue *> *)slotCenters:(CGFloat *)sizeOut {
    // Use the real system dock icon positions; fall back to an even 4-slot grid.
    NSMutableArray<UIView *> *icons = [NSMutableArray array];
    Class iv = NSClassFromString(@"SBIconView");
    for (UIView *v in self.iconList.subviews) if (iv && [v isKindOfClass:iv]) [icons addObject:v];
    CGFloat w = self.dock.bounds.size.width;
    CGFloat size = 60, cy = self.dock.bounds.size.height / 2;
    NSMutableArray *out = [NSMutableArray array];
    if (icons.count >= 1) {
        UIView *first = icons.firstObject;
        UIView *img = [first respondsToSelector:NSSelectorFromString(@"iconImageView")] ? [first valueForKey:@"iconImageView"] : nil;
        if (img && img.bounds.size.width > 20) size = img.bounds.size.width;
        CGPoint c = [self.dock convertPoint:first.center fromView:self.iconList];
        cy = c.y;
        if (img) { CGPoint ic = [self.dock convertPoint:img.center fromView:img.superview]; cy = ic.y; }
    }
    CGFloat margin = 15, slot = (w - margin * 2) / PER_PAGE;
    if (icons.count >= PER_PAGE) {
        NSArray *sorted = [icons sortedArrayUsingComparator:^NSComparisonResult(UIView *x, UIView *y) {
            return [@(x.center.x) compare:@(y.center.x)];
        }];
        for (NSUInteger i = 0; i < PER_PAGE; i++) {
            CGPoint c = [self.dock convertPoint:[sorted[i] center] fromView:self.iconList];
            [out addObject:[NSValue valueWithCGPoint:CGPointMake(c.x - self.iconList.transform.tx, cy)]];
        }
    } else {
        for (NSUInteger i = 0; i < PER_PAGE; i++) [out addObject:[NSValue valueWithCGPoint:CGPointMake(margin + slot * (i + 0.5), cy)]];
    }
    if (sizeOut) *sizeOut = size;
    return out;
}

- (void)rebuildWithCenters:(NSArray<NSValue *> *)centers size:(CGFloat)icon {
    for (UIView *v in self.pageViews) [v removeFromSuperview];
    [self.pageViews removeAllObjects];
    CGFloat w = self.dock.bounds.size.width;
    for (NSArray *apps in gPages) {
        UIView *pv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, self.dock.bounds.size.height)];
        pv.backgroundColor = UIColor.clearColor;
        NSUInteger i = 0;
        for (NSString *bid in apps) {
            if (i >= centers.count) break;
            CGPoint c = [centers[i] CGPointValue];
            UIImage *img = [UIImage _applicationIconImageForBundleIdentifier:bid format:2 scale:UIScreen.mainScreen.scale];
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(0, 0, icon, icon);
            b.center = c;
            [b setImage:img forState:UIControlStateNormal];
            b.imageView.contentMode = UIViewContentModeScaleAspectFit;
            b.accessibilityIdentifier = bid;
            [b addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
            [pv addSubview:b];
            i++;
        }
        [self.clip addSubview:pv];
        [self.pageViews addObject:pv];
    }
}

- (void)tapped:(UIButton *)b {
    NSString *bid = b.accessibilityIdentifier;
    dispatch_async(dispatch_get_main_queue(), ^{ LaunchApp(bid); });
}

- (void)layoutPages {
    if (!self.dock) return;
    self.clip.frame = self.dock.bounds;
    CGFloat size = 60;
    NSArray *centers = [self slotCenters:&size];
    NSString *geom = [NSString stringWithFormat:@"%@|%@|%.1f|%.1f", gPages, centers, size, self.dock.bounds.size.width];
    if (![self.builtKey isEqual:geom]) {
        [self rebuildWithCenters:centers size:size];
        self.builtKey = geom;
        LOG("rebuilt %lu extra pages, icon %.0f, dock %{public}@, list %{public}@, p=%.2f", (unsigned long)gPages.count, size, NSStringFromCGRect(self.dock.bounds), NSStringFromCGRect(self.iconList.frame), self.position);
    }
    CGFloat n = (CGFloat)([self pageCount] - 1);
    if (self.position > n) self.position = n;
    [self applyPosition];
}

- (void)applyPosition {
    CGFloat w = self.dock.bounds.size.width;
    CGFloat p = self.position;
    self.iconList.transform = CGAffineTransformMakeTranslation(-p * w, 0);
    CGFloat la = 1 - p; if (la < 0) la = 0; if (la > 1) la = 1;
    self.iconList.alpha = la;
    for (NSUInteger i = 0; i < self.pageViews.count; i++) {
        self.pageViews[i].frame = CGRectMake(((CGFloat)(i + 1) - p) * w, 0, w, self.dock.bounds.size.height);
        self.pageViews[i].hidden = fabs((CGFloat)(i + 1) - p) >= 1.0;
    }
    self.clip.hidden = (gPages.count == 0);
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g != self.pan || gPages.count == 0) return NO;
    CGPoint v = [self.pan velocityInView:self.dock];
    return fabs(v.x) > fabs(v.y);
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGFloat w = self.dock.bounds.size.width;
    CGFloat n = (CGFloat)([self pageCount] - 1);
    if (g.state == UIGestureRecognizerStateBegan) {
        [self stop];
        self.panStart = self.position;
    }
    CGFloat dx = [g translationInView:self.dock].x;
    if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat p = self.panStart - dx / w;
        if (p < 0) p = p * 0.3;
        if (p > n) p = n + (p - n) * 0.3;
        self.position = p;
        [self applyPosition];
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CGFloat vx = -[g velocityInView:self.dock].x / w;
        CGFloat t = round(self.position + vx * 0.15);
        if (t < 0) t = 0;
        if (t > n) t = n;
        [self springTo:t];
    }
}

- (void)stop { [self.link invalidate]; self.link = nil; }

- (void)springTo:(CGFloat)t {
    [self stop];
    self.target = t;
    self.velocity = 0;
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)tick:(CADisplayLink *)l {
    CGFloat dt = l.targetTimestamp - l.timestamp;
    CGFloat a = 220 * (self.target - self.position) - 26 * self.velocity;
    self.velocity += a * dt;
    self.position += self.velocity * dt;
    if (fabs(self.target - self.position) < 0.002 && fabs(self.velocity) < 0.02) {
        self.position = self.target;
        [self stop];
    }
    [self applyPosition];
}

- (void)syncWithHome:(CGFloat)homePage {
    if (!gFollow || gPages.count == 0) return;
    CGFloat n = (CGFloat)([self pageCount] - 1);
    CGFloat p = homePage;
    if (p < 0) p = 0;
    if (p > n) p = n;
    [self stop];
    self.position = p;
    [self applyPosition];
}

- (void)homeSettled:(CGFloat)homePage {
    if (!gFollow || gPages.count == 0) return;
    CGFloat n = (CGFloat)([self pageCount] - 1);
    CGFloat t = round(homePage);
    if (t < 0) t = 0;
    if (t > n) t = n;
    [self springTo:t];
}
@end

static void (*orig_layoutSubviews)(UIView *, SEL);
static void new_layoutSubviews(UIView *self, SEL _cmd) {
    orig_layoutSubviews(self, _cmd);
    UIView *list = nil;
    if ([self respondsToSelector:NSSelectorFromString(@"dockListView")]) list = [self valueForKey:@"dockListView"];
    if (!list) return;
    if (!gCtl) gCtl = [DPController new];
    [gCtl attachTo:self list:list];
    [gCtl layoutPages];
}

static CGFloat HomePage(id folder, UIScrollView *sv) {
    CGFloat w = sv.bounds.size.width;
    if (w <= 0) return 0;
    CGFloat page = sv.contentOffset.x / w;
    SEL sel = NSSelectorFromString(@"firstIconPageIndex");
    if ([folder respondsToSelector:sel]) {
        NSInteger first = ((NSInteger (*)(id, SEL))objc_msgSend)(folder, sel);
        if (first > 0 && first < 10) page -= (CGFloat)first;
    }
    return page;
}

static void (*orig_scroll)(id, SEL, UIScrollView *);
static void new_scroll(id self, SEL _cmd, UIScrollView *sv) {
    orig_scroll(self, _cmd, sv);
    if (!gCtl || ![self isKindOfClass:NSClassFromString(@"SBRootFolderView")]) return;
    [gCtl syncWithHome:HomePage(self, sv)];
}

static void (*orig_end)(id, SEL, UIScrollView *);
static void new_end(id self, SEL _cmd, UIScrollView *sv) {
    orig_end(self, _cmd, sv);
    if (!gCtl || ![self isKindOfClass:NSClassFromString(@"SBRootFolderView")]) return;
    [gCtl homeSettled:HomePage(self, sv)];
}

static void hook(Class c, SEL s, IMP n, IMP *o) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) { LOG("missing %{public}s", sel_getName(s)); return; }
    *o = method_getImplementation(m);
    method_setImplementation(m, n);
}

static void changed(CFNotificationCenterRef a, void *b, CFStringRef c, const void *d, CFDictionaryRef e) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        LoadPrefs();
        [gCtl layoutPages];
    });
}

__attribute__((constructor)) static void dp_init(void) {
    L = os_log_create("cc.gonepaul.dockpages", "tweak");
    LoadPrefs();
    Class dock = NSClassFromString(@"SBDockView");
    if (!dock) { LOG("no SBDockView"); return; }
    hook(dock, @selector(layoutSubviews), (IMP)new_layoutSubviews, (IMP *)&orig_layoutSubviews);
    Class rf = NSClassFromString(@"SBRootFolderView");
    if (rf) {
        hook(rf, @selector(scrollViewDidScroll:), (IMP)new_scroll, (IMP *)&orig_scroll);
        hook(rf, @selector(scrollViewDidEndDecelerating:), (IMP)new_end, (IMP *)&orig_end);
    }
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, changed, CFSTR(NOTIFY_CHANGED), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    LOG("DockPages loaded, %lu extra pages", (unsigned long)gPages.count);
}
