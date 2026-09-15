#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "PrivateHeaders/SBPrivate.h"
#import "WaveEngine.h"

static WaveEngine *g_engine;
static Class g_panClass;
static Class g_iconClass;
static Class g_dockClass;
static CGPoint g_lastVel;
static BOOL g_haveLastVel;
static BOOL g_coverVisible;
static BOOL g_deferredFire;
static CFTimeInterval g_lastFire;

static void wave26_init(void);
static void wave26_fire(void);
static NSArray *collectIconViews(void);
static UIView *findDockView(void);
static void wave26_registerHome(NSArray *icons, UIView *dock);
static void wave26_stripAnimations(UIView *view);
static void wave26_stripAncestors(UIView *view);
static NSArray *allWindows(void);
static void wave26_collectViewsOfClass(Class cls, UIView *view, NSMutableArray *out);
static BOOL isInDock(UIView *view, UIView *dock);

%hook UIGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state {
    %orig;

    if (!g_panClass || ![self isKindOfClass:g_panClass]) return;
    if (state != UIGestureRecognizerStateEnded && state != UIGestureRecognizerStateCancelled) return;

    UIView *view = nil;
    if ([self respondsToSelector:@selector(view)]) {
        view = [self view];
    }
    if (!view) return;

    CGPoint velocity = CGPointZero;
    if ([self isKindOfClass:[UIPanGestureRecognizer class]]) {
        velocity = [(UIPanGestureRecognizer *)self velocityInView:view];
    }
    g_lastVel = velocity;
    g_haveLastVel = YES;

    // The binary uses a ~0.5 s debounce gate before firing the effect.
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - g_lastFire < 0.5) return;
    g_lastFire = now;
    g_deferredFire = YES;
    wave26_fire();
}
%end

%hook SBIconController
- (BOOL)hasAnimatedIconLayoutBefore {
    return YES;
}

- (BOOL)_shouldAnimateIconLaunch {
    return NO;
}

- (void)setRootFolderViewControllerPresentationProgress:(double)progress animated:(BOOL)animated completion:(id)completion {
    %orig(progress, NO, completion);
}
%end

%hook SBCoverSheetViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    g_coverVisible = YES;
    g_deferredFire = NO;
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig(animated);
    if (!g_coverVisible) return;
    g_coverVisible = NO;
    g_lastFire = CFAbsoluteTimeGetCurrent();
    g_deferredFire = NO;

    if (!g_haveLastVel) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.14 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!g_coverVisible && !g_deferredFire) wave26_fire();
    });
}
%end

%ctor {
    wave26_init();
    %init;
}

static void wave26_init(void) {
    g_panClass = NSClassFromString(@"SBCoverSheetScreenEdgePanGestureRecognizer");
    g_iconClass = NSClassFromString(@"SBIconView");
    g_dockClass = NSClassFromString(@"SBDockView");
    g_engine = [WaveEngine new];
}

static void wave26_fire(void) {
    static CFTimeInterval last;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - last < 0.5) return;
    last = now;
    if (!g_engine) return;

    [g_engine reset];
    [g_engine clearIcons];

    NSArray *icons = collectIconViews();
    if (icons.count == 0) return;

    UIView *dock = findDockView();
    wave26_registerHome(icons, dock);

    for (UIView *view in icons) wave26_stripAnimations(view);
    if (dock) wave26_stripAnimations(dock);

    for (UIView *view in icons) wave26_stripAncestors(view);
    if (dock) wave26_stripAncestors(dock);

    // FIX: the binary falls back to -1250.0, not 0.0.
    double velocity = g_haveLastVel ? g_lastVel.y : -1250.0;
    [g_engine playWithPullVelocity:velocity];
}

static NSArray *collectIconViews(void) {
    NSMutableArray *result = [NSMutableArray array];
    if (!g_iconClass) return result;

    for (UIWindow *window in allWindows()) {
        wave26_collectViewsOfClass(g_iconClass, window, result);
    }
    return result;
}

static UIView *findDockView(void) {
    if (!g_dockClass) return nil;
    NSMutableArray *result = [NSMutableArray array];
    for (UIWindow *window in allWindows()) {
        wave26_collectViewsOfClass(g_dockClass, window, result);
    }
    return result.firstObject;
}

static void wave26_registerHome(NSArray *icons, UIView *dock) {
    if (icons.count == 0) return;
    [g_engine setDockView:dock];

    // FIX: the original never uses the array index.  It converts every icon
    // frame to WINDOW coordinates, drops invalid ones, takes the bounding box
    // of the remaining icon CENTRES and derives
    //     col = clamp((midX - minX) / (MAX(1, maxX - minX) / 4), 0, 3)
    //     row = clamp((midY - minY) / (MAX(1, maxY - minY) / 6), 0, 5)
    // (division truncates towards zero, then clamps).  The /4 and /6 overshoot
    // by one cell on the last column/row - the clamp pins them back to 3 / 5.
    NSMutableArray *ordered = [NSMutableArray array];
    NSMutableArray *centres = [NSMutableArray array];

    double minX = INFINITY, maxX = -INFINITY;
    double minY = INFINITY, maxY = -INFINITY;

    for (id item in icons) {
        if (![item isKindOfClass:[UIView class]]) continue;
        UIView *view = (UIView *)item;
        if (dock && isInDock(view, dock)) continue;

        CGRect frame = [view convertRect:view.bounds toView:nil];
        if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) continue;

        double midX = CGRectGetMidX(frame);
        double midY = CGRectGetMidY(frame);

        [ordered addObject:view];
        [centres addObject:[NSValue valueWithCGPoint:CGPointMake(midX, midY)]];

        if (midX < minX) minX = midX;
        if (midX > maxX) maxX = midX;
        if (midY < minY) minY = midY;
        if (midY > maxY) maxY = midY;
    }

    if (ordered.count == 0) return;

    double cellW = MAX(1.0, maxX - minX) / 4.0;
    double cellH = MAX(1.0, maxY - minY) / 6.0;

    for (NSUInteger i = 0; i < ordered.count; i++) {
        UIView *view = ordered[i];
        CGPoint centre = [centres[i] CGPointValue];

        NSInteger col = (NSInteger)((centre.x - minX) / cellW);
        NSInteger row = (NSInteger)((centre.y - minY) / cellH);

        if (col < 0) col = 0; else if (col > 3) col = 3;
        if (row < 0) row = 0; else if (row > 5) row = 5;

        [g_engine registerIcon:view col:col row:row];
    }
}

static void wave26_stripAnimations(UIView *view) {
    if (!view) return;
    [view.layer removeAllAnimations];
}

static void wave26_stripAncestors(UIView *view) {
    UIView *current = view;
    while (current) {
        [current.layer removeAllAnimations];
        current = current.superview;
    }
}

static NSArray *allWindows(void) {
    return UIApplication.sharedApplication.windows ?: @[];
}

static void wave26_collectViewsOfClass(Class cls, UIView *view, NSMutableArray *out) {
    if (!view || !cls) return;
    if ([view isKindOfClass:cls]) [out addObject:view];
    for (UIView *subview in view.subviews) {
        wave26_collectViewsOfClass(cls, subview, out);
    }
}

static BOOL isInDock(UIView *view, UIView *dock) {
    if (!view || !dock) return NO;
    UIView *current = view;
    while (current) {
        if (current == dock) return YES;
        current = current.superview;
    }
    return NO;
}
