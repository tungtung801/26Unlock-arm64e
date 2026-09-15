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

    double velocity = g_haveLastVel ? g_lastVel.y : 0.0;
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

    // The original enumerates icon views and maps them into a 4 x 6 wave table.
    NSInteger index = 0;
    for (UIView *view in icons) {
        NSInteger col = index % 4;
        NSInteger row = MIN(index / 4, 5);
        if (isInDock(view, dock)) {
            index++;
            continue;
        }
        [g_engine registerIcon:view col:col row:row];
        index++;
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
