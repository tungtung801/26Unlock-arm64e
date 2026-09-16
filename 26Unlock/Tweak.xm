/*
 * 26Unlock - iOS 26 style center-out unlock wave, rebuilt for arm64e.
 *
 * The animation maths (WaveEngine / WaveTable) is the reverse engineered
 * original and is left untouched.  This file is the plumbing: notice that
 * the device is being unlocked and hand the icon grid to the engine.
 *
 * Firing logic, recovered instruction by instruction from the original
 * arm64 binary (26Unlock.dylib in original.deb):
 *
 *   -[SBCoverSheetViewController viewWillAppear:]
 *        g_onLockScreen = YES;  g_panFired = NO;
 *
 *   -[UIGestureRecognizer setState:]          (SBCoverSheetScreenEdgePanGestureRecognizer)
 *        Ended / Cancelled -> remember velocity, g_panFired = YES,
 *                             wave26_fire()  IMMEDIATELY          (0x60bc)
 *        Possible         -> stamp the dismissal time              (0x60dc)
 *
 *   -[SBCoverSheetViewController viewDidDisappear:]
 *        if (!g_onLockScreen) return;
 *        g_onLockScreen = NO;
 *        if (g_panFired) return;              <-- NOTE: inverted!
 *        dispatch_after(0.35 s, wave26_fire)  <-- unlock without a swipe
 *                                                 (Face ID / passcode), or
 *                                                 when the pan class is missing
 *
 * The previous reconstruction had that last gate backwards
 * ("if (!g_haveLastVel) return;"), which made the tweak 100 % dependent on
 * SBCoverSheetScreenEdgePanGestureRecognizer existing.  On any iOS where
 * that class is missing the tweak stayed completely silent.  This version
 * reproduces the original behaviour and adds a Darwin-notification
 * backstop on top, so the wave plays even when every SpringBoard class
 * lookup fails.
 *
 * Diagnostics are appended to /var/mobile/26Unlock.log
 */

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <notify.h>
#import <math.h>
#import <stdio.h>

#import "PrivateHeaders/SBPrivate.h"
#import "WaveEngine.h"

/* ------------------------------------------------------------------ */
#pragma mark - diagnostics
/* ------------------------------------------------------------------ */

#define W26_LOGFILE "/var/mobile/26Unlock.log"

static void w26_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

static void w26_log(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[26Unlock] %@", msg);

    @autoreleasepool {
        NSString *path = @W26_LOGFILE;
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
        if (attrs && [attrs fileSize] > 200 * 1024) {
            [fm removeItemAtPath:path error:NULL];
        }
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        FILE *f = fopen(W26_LOGFILE, "a");
        if (f) {
            fputs([line UTF8String], f);
            fclose(f);
        }
    }
}

/* ------------------------------------------------------------------ */
#pragma mark - state
/* ------------------------------------------------------------------ */

static WaveEngine *g_engine;

static Class g_panClass;        /* SBCoverSheetScreenEdgePanGestureRecognizer  */
static Class g_edgeClass;       /* SBScreenEdgePanGestureRecognizer (fallback) */
static Class g_iconClass;       /* SBIconView                                  */
static Class g_dockClass;       /* SBDockView                                  */

static BOOL  g_haveCoverClass;  /* SBCoverSheetViewController exists?          */
static BOOL  g_onLockScreen;    /* binary: g_onLockScreen                      */
static BOOL  g_panFired;        /* binary: g_panFired                          */
static BOOL  g_haveVel;         /* binary: g_haveVel                           */
static CGPoint g_lastVel;       /* binary: g_lastVel                           */

static CFTimeInterval g_lastFireTime;      /* binary: g_lastFireTime           */
static CFTimeInterval g_lockScreenDismissed;

static const CFTimeInterval kW26Debounce = 0.5;   /* fcmp 0.5 in wave26_fire   */
static const double kW26DefaultVelocity  = -1250.0;
static const double kW26DeferredDelay    = 0.35;  /* 350000000 ns in the binary */

/* ------------------------------------------------------------------ */
#pragma mark - view helpers
/* ------------------------------------------------------------------ */

static NSArray *w26_allWindows(void) {
    NSMutableArray *windows = [NSMutableArray array];
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return windows;

    /* iOS 13+: the home screen lives in its own UIWindowScene and
     * -[UIApplication windows] is deprecated, so walk every connected
     * scene first and only then fall back to the legacy property. */
    if ([app respondsToSelector:@selector(connectedScenes)]) {
        for (UIScene *scene in [app connectedScenes]) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window && [windows indexOfObjectIdenticalTo:window] == NSNotFound) {
                    [windows addObject:window];
                }
            }
        }
    }

    for (UIWindow *window in [app windows]) {
        if (window && [windows indexOfObjectIdenticalTo:window] == NSNotFound) {
            [windows addObject:window];
        }
    }

    UIWindow *key = [app keyWindow];
    if (key && [windows indexOfObjectIdenticalTo:key] == NSNotFound) {
        [windows addObject:key];
    }

    return windows;
}

static void w26_collectViewsOfClass(Class cls, UIView *view, NSMutableArray *out) {
    if (!view || !cls) return;
    if ([view isKindOfClass:cls]) [out addObject:view];
    for (UIView *subview in view.subviews) {
        w26_collectViewsOfClass(cls, subview, out);
    }
}

/* Last-resort root view when no window exposes the icon hierarchy. */
static UIView *w26_iconControllerRootView(void) {
    Class cls = NSClassFromString(@"SBIconController");
    if (!cls) return nil;
    if (![cls respondsToSelector:@selector(sharedInstance)]) return nil;

    id controller = [cls sharedInstance];
    if (!controller) return nil;
    if (![controller respondsToSelector:@selector(view)]) return nil;

    id view = [controller view];
    return [view isKindOfClass:[UIView class]] ? (UIView *)view : nil;
}

static NSArray *w26_collectIconViews(void) {
    NSMutableArray *out = [NSMutableArray array];
    if (!g_iconClass) return out;

    for (UIWindow *window in w26_allWindows()) {
        w26_collectViewsOfClass(g_iconClass, window, out);
    }

    if (out.count == 0) {
        UIView *root = w26_iconControllerRootView();
        if (root) w26_collectViewsOfClass(g_iconClass, root, out);
    }

    return out;
}

static UIView *w26_findDockView(void) {
    NSMutableArray *out = [NSMutableArray array];

    if (g_dockClass) {
        for (UIWindow *window in w26_allWindows()) {
            w26_collectViewsOfClass(g_dockClass, window, out);
        }
        if (out.count == 0) {
            UIView *root = w26_iconControllerRootView();
            if (root) w26_collectViewsOfClass(g_dockClass, root, out);
        }
        if (out.firstObject) return out.firstObject;
    }

    /* Fallback: -[SBIconController dockView] */
    Class cls = NSClassFromString(@"SBIconController");
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        id controller = [cls sharedInstance];
        if (controller && [controller respondsToSelector:@selector(dockView)]) {
            id dock = [controller dockView];
            if ([dock isKindOfClass:[UIView class]]) return (UIView *)dock;
        }
    }

    return nil;
}

static BOOL w26_isInDock(UIView *view, UIView *dock) {
    if (!view || !dock) return NO;
    UIView *current = view;
    while (current) {
        if (current == dock) return YES;
        current = current.superview;
    }
    return NO;
}

static void w26_stripAnimations(UIView *view) {
    if (!view) return;
    [view.layer removeAllAnimations];
}

static void w26_stripAncestors(UIView *view) {
    UIView *current = view;
    while (current) {
        [current.layer removeAllAnimations];
        current = current.superview;
    }
}

/* ------------------------------------------------------------------ */
#pragma mark - grid registration (identical to the original binary)
/* ------------------------------------------------------------------ */

static void w26_registerHome(NSArray *icons, UIView *dock) {
    if (icons.count == 0) return;
    [g_engine setDockView:dock];

    NSMutableArray *ordered = [NSMutableArray array];
    NSMutableArray *centres = [NSMutableArray array];

    double minX = INFINITY, maxX = -INFINITY;
    double minY = INFINITY, maxY = -INFINITY;

    for (id item in icons) {
        if (![item isKindOfClass:[UIView class]]) continue;
        UIView *view = (UIView *)item;
        if (dock && w26_isInDock(view, dock)) continue;

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

/* ------------------------------------------------------------------ */
#pragma mark - firing
/* ------------------------------------------------------------------ */

static void w26_fire(double velocity, int attempt) {
    if (!g_engine) return;

    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - g_lastFireTime < kW26Debounce) return;

    [g_engine reset];
    [g_engine clearIcons];

    NSArray *icons = w26_collectIconViews();
    if (icons.count == 0) {
        w26_log(@"fire: no icon views yet (attempt %d, iconClass=%@), retrying",
                attempt, g_iconClass ? NSStringFromClass(g_iconClass) : @"MISSING");
        if (attempt < 3) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                w26_fire(velocity, attempt + 1);
            });
        }
        return;
    }

    g_lastFireTime = now;

    UIView *dock = w26_findDockView();
    w26_registerHome(icons, dock);

    for (UIView *view in icons) w26_stripAnimations(view);
    if (dock) w26_stripAnimations(dock);

    for (UIView *view in icons) w26_stripAncestors(view);
    if (dock) w26_stripAncestors(dock);

    [g_engine playWithPullVelocity:velocity];

    w26_log(@"fire: wave played - %lu icons, dock=%@, velocity=%.1f",
            (unsigned long)icons.count, dock ? @"yes" : @"no", velocity);
}

/* The 0.35 s path used when the unlock happened without a swipe. */
static void w26_fireDeferred(double velocity) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kW26DeferredDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        w26_fire(velocity, 0);
    });
}

static BOOL w26_isUnlockPan(UIGestureRecognizer *gesture) {
    if (!gesture) return NO;

    if (g_panClass && [gesture isKindOfClass:g_panClass]) return YES;

    /* Fallback when SBCoverSheetScreenEdgePanGestureRecognizer is gone:
     * any system edge pan from the BOTTOM edge while the lock screen is up. */
    if (!g_panClass && g_edgeClass && g_onLockScreen &&
        [gesture isKindOfClass:g_edgeClass]) {
        if ([gesture respondsToSelector:@selector(edges)]) {
            if ([(id<W26EdgeGesture>)gesture edges] & UIRectEdgeBottom) return YES;
        }
    }

    return NO;
}

/* ------------------------------------------------------------------ */
#pragma mark - hooks
/* ------------------------------------------------------------------ */

%hook UIGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state {
    %orig;

    if (!g_engine) return;
    if (!w26_isUnlockPan(self)) return;

    if (state != UIGestureRecognizerStateEnded &&
        state != UIGestureRecognizerStateCancelled) {
        if (state == UIGestureRecognizerStatePossible) {
            g_lockScreenDismissed = CFAbsoluteTimeGetCurrent();
        }
        return;
    }

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
    g_haveVel = YES;
    g_lockScreenDismissed = CFAbsoluteTimeGetCurrent();
    g_panFired = YES;

    w26_log(@"unlock pan ended (vel.y=%.1f) - firing now", velocity.y);
    w26_fire(velocity.y, 0);
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
    g_onLockScreen = YES;
    g_panFired = NO;
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig(animated);

    if (!g_onLockScreen) return;
    g_onLockScreen = NO;
    g_lockScreenDismissed = CFAbsoluteTimeGetCurrent();

    if (g_panFired) return;   /* the pan already played the wave */

    w26_log(@"cover sheet disappeared without a pan - deferred fire in 0.35 s");
    w26_fireDeferred(g_haveVel ? g_lastVel.y : kW26DefaultVelocity);
}
%end

/* ------------------------------------------------------------------ */
#pragma mark - init
/* ------------------------------------------------------------------ */

static void w26_registerLockStateNotifications(void) {
    static int token = 0;
    notify_register_dispatch("com.apple.springboard.lockstate", &token,
                             dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 1;
        notify_get_state(t, &state);
        w26_log(@"lockstate = %llu", (unsigned long long)state);

        if (state == 1) {           /* locked again - re-arm */
            g_onLockScreen = YES;
            g_panFired = NO;
            return;
        }

        if (state != 0) return;     /* 0 == unlocked */

        if (g_panFired) return;     /* already played by the pan */

        w26_log(@"unlocked without a pan - deferred fire in 0.35 s");
        w26_fireDeferred(g_haveVel ? g_lastVel.y : kW26DefaultVelocity);
    });
}

static void w26_init(void) {
    g_panClass  = NSClassFromString(@"SBCoverSheetScreenEdgePanGestureRecognizer");
    if (!g_panClass) g_panClass = NSClassFromString(@"SBCoverSheetPanGestureRecognizer");
    g_edgeClass = NSClassFromString(@"SBScreenEdgePanGestureRecognizer");
    g_iconClass = NSClassFromString(@"SBIconView");
    g_dockClass = NSClassFromString(@"SBDockView");
    g_haveCoverClass = (NSClassFromString(@"SBCoverSheetViewController") != nil);

    g_engine = [WaveEngine new];

    w26_log(@"==== 26Unlock loaded ====");
    w26_log(@"iOS %@ | pan=%@ | edge=%@ | icon=%@ | dock=%@ | coverSheetClass=%@",
            [[UIDevice currentDevice] systemVersion],
            g_panClass  ? NSStringFromClass(g_panClass)  : @"MISSING",
            g_edgeClass ? NSStringFromClass(g_edgeClass) : @"MISSING",
            g_iconClass ? NSStringFromClass(g_iconClass) : @"MISSING",
            g_dockClass ? NSStringFromClass(g_dockClass) : @"MISSING",
            g_haveCoverClass ? @"YES" : @"MISSING");
    w26_log(@"log file: " W26_LOGFILE);
}

%ctor {
    @autoreleasepool {
        w26_init();
        %init;
        w26_registerLockStateNotifications();
    }
}
