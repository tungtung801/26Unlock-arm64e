/*
 * 26Unlock - iOS 26 style center-out unlock wave, rebuilt for arm64/arm64e.
 *
 * IMPORTANT: this tweak deliberately does NOT link CydiaSubstrate / libsubstrate.
 * Modern rootless jailbreaks (Dopamine 2 + ElleKit on iOS 16) do not ship
 * /var/jb/Library/Frameworks/CydiaSubstrate.framework, so any dylib whose
 * load command references it fails dlopen() before its constructor ever runs -
 * the tweak then looks "installed but dead" and writes nothing at all.  Hooking
 * is done with the Objective-C runtime (class_addMethod / class_replaceMethod),
 * which needs nothing but libobjc, so the dylib always loads.
 *
 * Firing logic is recovered instruction by instruction from the original
 * arm64 binary (26Unlock.dylib inside original.deb):
 *
 *   -[SBCoverSheetViewController viewWillAppear:]
 *        g_onLockScreen = YES;  g_panFired = NO;
 *
 *   -[UIGestureRecognizer setState:]   (SBCoverSheetScreenEdgePanGestureRecognizer)
 *        Ended / Cancelled -> remember velocity, g_panFired = YES,
 *                             fire IMMEDIATELY                       (0x60bc)
 *        Possible         -> stamp the dismissal time                (0x60dc)
 *
 *   -[SBCoverSheetViewController viewDidDisappear:]
 *        if (!g_onLockScreen) return;
 *        g_onLockScreen = NO;
 *        if (g_panFired) return;            <-- pan already played the wave
 *        dispatch_after(0.35 s) -> fire     <-- unlock without a swipe
 *
 * The animation maths (WaveEngine / WaveTable) is the reverse engineered
 * original and is not touched here.
 *
 * Diagnostics: /var/mobile/26Unlock.log
 */

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
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

static BOOL  g_haveCoverClass;
static BOOL  g_onLockScreen;    /* binary: g_onLockScreen                      */
static BOOL  g_panFired;        /* binary: g_panFired                          */
static BOOL  g_haveVel;         /* binary: g_haveVel                           */
static CGPoint g_lastVel;       /* binary: g_lastVel                           */

static CFTimeInterval g_lastFireTime;
static CFTimeInterval g_lockScreenDismissed;
static CFTimeInterval g_unlockedAt;

static const CFTimeInterval kW26Debounce = 0.5;
static const double kW26DefaultVelocity  = -1250.0;
static const double kW26DeferredDelay    = 0.35;
/* If the pan already played a wave but the unlock only finished much later
 * (passcode typing takes seconds), play a fresh one at the cover-sheet
 * moment so both cases look identical. */
static const CFTimeInterval kW26PanReFireWindow = 1.5;

/* ------------------------------------------------------------------ */
#pragma mark - runtime settings (/var/mobile/26Unlock.plist)
/* ------------------------------------------------------------------ */

#define W26_SETTINGS @"/var/mobile/26Unlock.plist"

/* Every value below can be changed on device without rebuilding: edit
 * /var/mobile/26Unlock.plist with Filza, then simply unlock again. */
static double g_cfgUnlockDelay = 0.00;  /* delay used on the unlock flow      */
static BOOL   g_cfgWaitSettle  = NO;    /* wait until the grid scale is 1.0   */
static BOOL   g_cfgWaitCover   = NO;   /* wait until the lock screen is gone */
static BOOL   g_cfgWaitGrid    = YES;   /* wait until the icon grid is at home*/
static double g_cfgGridMin     = 0.50;  /* min bbox width / screen width      */
static BOOL   g_cfgScaleComp   = YES;   /* keep travel constant when scaled   */
static double g_cfgGuard       = 0.60;  /* keep killing competing animations  */
static BOOL   g_cfgForcePres   = YES;   /* snap the home screen to 1.0 first  */

static void w26_loadSettings(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:W26_SETTINGS];
    if (![d isKindOfClass:[NSDictionary class]]) return;
    id v;
    v = [d objectForKey:@"UnlockDelay"];
    if ([v respondsToSelector:@selector(doubleValue)]) g_cfgUnlockDelay = [v doubleValue];
    v = [d objectForKey:@"WaitForSettle"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgWaitSettle  = [v boolValue];
    v = [d objectForKey:@"ScaleComp"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgScaleComp   = [v boolValue];
    v = [d objectForKey:@"GuardDuration"];
    if ([v respondsToSelector:@selector(doubleValue)]) g_cfgGuard       = [v doubleValue];
    v = [d objectForKey:@"ForcePresentation"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgForcePres   = [v boolValue];
    v = [d objectForKey:@"WaitForCoverSheet"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgWaitCover   = [v boolValue];
    v = [d objectForKey:@"WaitForGrid"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgWaitGrid    = [v boolValue];
    v = [d objectForKey:@"GridMinWidth"];
    if ([v respondsToSelector:@selector(doubleValue)]) g_cfgGridMin     = [v doubleValue];
}

/* ------------------------------------------------------------------ */
#pragma mark - flow state / forward declarations
/* ------------------------------------------------------------------ */

static BOOL g_fireScheduled;   /* a fire is already pending              */
static BOOL g_fireDone;        /* a wave already played for this flow    */
static BOOL g_unlockFlow;      /* cover sheet going away == unlock       */
static BOOL g_fireRequested;   /* a fire is already queued               */
static BOOL g_pinPresentation; /* keep progress pinned at 1.0             */
static CFTimeInterval g_requestedAt; /* when the fire was queued           */

/* Set right before a wave plays: the ancestor scale the wave offsets must be
 * divided by so the motion keeps its on-screen size.  Read by WaveEngine.m. */
double W26ScaleComp = 1.0;

static void   w26_forceHomePresentation(void);
static BOOL   w26_gridAtHome(NSArray *icons, double *outSpan);
static BOOL   w26_swizzle(Class cls, SEL sel, IMP replacement, IMP *original);
static double w26_effectiveScale(UIView *view);
static BOOL   w26_homeSettled(void);
static void   w26_stripForeign(UIView *view);
static void   w26_guardTick(NSArray *icons, int ticksLeft);
static void   w26_requestFire(double velocity, const char *source);
static void   w26_panSchedule(double velocity, int attempt);

/* original implementations */
static IMP w26_orig_setState;
static IMP w26_orig_hasAnimatedIconLayoutBefore;
static IMP w26_orig_shouldAnimateIconLaunch;
static IMP w26_orig_presentationProgress;
static SEL w26_presSEL;                 /* which selector actually exists   */
static int w26_presKind;                /* 0 none / 4 no-completion / 5 full */
static IMP w26_orig_viewWillAppear;
static IMP w26_orig_viewDidDisappear;

/* ------------------------------------------------------------------ */
#pragma mark - view helpers
/* ------------------------------------------------------------------ */

static NSArray *w26_allWindows(void) {
    NSMutableArray *windows = [NSMutableArray array];
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return windows;

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

    w26_loadSettings();
    w26_forceHomePresentation();

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

    if (g_cfgWaitGrid) {
        double span = 0.0;
        if (!w26_gridAtHome(icons, &span) && attempt < 20) {   /* 20 * 0.05 = 1.0 s */
            if (attempt == 0) {
                w26_log(@"grid not at home yet (span=%.0f) - waiting", span);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                w26_fire(velocity, attempt + 1);
            });
            return;
        }
    }

    g_lastFireTime = now;
    g_fireDone = YES;
    g_pinPresentation = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        g_pinPresentation = NO;
    });

    w26_log(@"fire: +%.2fs after request, +%.2fs after unlock, +%.2fs after cover sheet gone | "
            @"cfg(delay=%.2f settle=%d scaleComp=%d guard=%.2f)",
            (g_requestedAt > 0 ? now - g_requestedAt : -1.0),
            (g_unlockedAt > 0 ? now - g_unlockedAt : -1.0),
            (g_lockScreenDismissed > 0 ? now - g_lockScreenDismissed : -1.0),
            g_cfgUnlockDelay, (int)g_cfgWaitSettle, (int)g_cfgScaleComp, g_cfgGuard);

    /* ---- grid diagnostics (so a "clumped" wave can be diagnosed) ---- */
    {
        double minX = INFINITY, maxX = -INFINITY, minY = INFINITY, maxY = -INFINITY;
        for (UIView *v in icons) {
            CGRect f = [v convertRect:v.bounds toView:nil];
            double mx = CGRectGetMidX(f), my = CGRectGetMidY(f);
            if (mx < minX) minX = mx; if (mx > maxX) maxX = mx;
            if (my < minY) minY = my; if (my > maxY) maxY = my;
        }
        double cw = MAX(1.0, maxX - minX) / 4.0, ch = MAX(1.0, maxY - minY) / 6.0;
        NSMutableSet *cells = [NSMutableSet set];
        for (UIView *v in icons) {
            CGRect f = [v convertRect:v.bounds toView:nil];
            int c = (int)((CGRectGetMidX(f) - minX) / cw); if (c < 0) c = 0; if (c > 3) c = 3;
            int r = (int)((CGRectGetMidY(f) - minY) / ch); if (r < 0) r = 0; if (r > 5) r = 5;
            [cells addObject:[NSString stringWithFormat:@"%d,%d", c, r]];
        }
        UIView *first = icons.firstObject;
        double eff = first ? w26_effectiveScale(first) : 1.0;
        w26_log(@"grid: bbox=(%.0f,%.0f)-(%.0f,%.0f) cell=%.1fx%.1f cells=%lu/%lu ancestorScale=%.3f",
                minX, minY, maxX, maxY, cw, ch,
                (unsigned long)cells.count, (unsigned long)icons.count, eff);

        /* Keep the travelled distance constant on screen even if SpringBoard
         * currently scales the home screen. */
        W26ScaleComp = (g_cfgScaleComp && eff > 0.2 && eff < 5.0) ? eff : 1.0;
    }

    UIView *dock = w26_findDockView();
    w26_registerHome(icons, dock);

    for (UIView *view in icons) w26_stripAnimations(view);
    if (dock) w26_stripAnimations(dock);

    for (UIView *view in icons) w26_stripAncestors(view);
    if (dock) w26_stripAncestors(dock);

    [g_engine playWithPullVelocity:velocity];

    if (g_cfgGuard > 0.0) {
        int ticks = (int)(g_cfgGuard / 0.05);
        w26_guardTick(icons, ticks);
        if (dock) w26_guardTick(@[dock], ticks);
    }

    w26_log(@"fire: wave played - %lu icons, dock=%@, velocity=%.1f",
            (unsigned long)icons.count, dock ? @"yes" : @"no", velocity);
}

/* Is the icon grid already laid out at its home positions?  During the unlock
 * SpringBoard keeps the icons condensed near the middle of the screen until it
 * finishes presenting; playing the wave then makes every icon fly towards that
 * clump instead of towards its home, which is the "circle blob" symptom.  No
 * private API is needed: a condensed grid simply spans far less than the
 * screen. */
static BOOL w26_gridAtHome(NSArray *icons, double *outSpan) {
    if (icons.count < 2) return NO;

    double minX = INFINITY, maxX = -INFINITY;
    for (UIView *v in icons) {
        CGRect f = [v convertRect:v.bounds toView:nil];
        double mx = CGRectGetMidX(f);
        if (mx < minX) minX = mx;
        if (mx > maxX) maxX = mx;
    }

    double span = maxX - minX;
    double screenW = [UIScreen mainScreen].bounds.size.width;
    if (outSpan) *outSpan = span;

    return (screenW > 0) && (span >= g_cfgGridMin * screenW);
}

/* SpringBoard reveals the home screen gradually during the unlock
 * (setRootFolderViewControllerPresentationProgress:animated:).  While that
 * runs the whole icon grid is scaled, which is what made the wave look
 * "clumped" when it was played early.  Snapping the presentation to its final
 * value (animated:NO) removes the competing animation AND gives us a settled
 * grid, so the wave can start immediately instead of after a long wait. */
static void w26_forceHomePresentation(void) {
    if (!g_cfgForcePres) return;
    if (!w26_orig_presentationProgress) {
        w26_log(@"forcePresentation: hook not installed - skipped");
        return;
    }

    Class cls = NSClassFromString(@"SBIconController");
    if (!cls || ![cls respondsToSelector:@selector(sharedInstance)]) return;

    id controller = [cls sharedInstance];
    if (!controller) return;

    if (w26_presKind == 5) {
        void (*orig)(id, SEL, double, BOOL, id) =
            (void (*)(id, SEL, double, BOOL, id))w26_orig_presentationProgress;
        orig(controller, w26_presSEL, 1.0, NO, nil);
    } else if (w26_presKind == 4) {
        void (*orig)(id, SEL, double, BOOL) =
            (void (*)(id, SEL, double, BOOL))w26_orig_presentationProgress;
        orig(controller, w26_presSEL, 1.0, NO);
    } else {
        w26_log(@"forcePresentation: no presentation selector - skipped");
        return;
    }
    w26_log(@"forced home presentation to 1.0 (animated:NO)");
}

/* Effective scale of every ancestor of `view`.  During the unlock transition
 * SpringBoard scales the home screen down; a wave played on a scaled grid looks
 * "clumped" and the dock slide covers less distance (looks slow). */
static double w26_effectiveScale(UIView *view) {
    double s = 1.0;
    UIView *a = view.superview;
    for (int i = 0; a && i < 12; i++) {
        CALayer *l = a.layer;
        if (l) {
            /* UIView.transform lives in layer.transform - reading both would
             * count the same scale twice.  sublayerTransform scales all
             * descendants, so it has to be included too. */
            CATransform3D t = l.transform;
            if (!CATransform3DIsIdentity(t)) {
                double det = t.m11 * t.m22 - t.m12 * t.m21;
                if (det > 0.0001) s *= sqrt(det);
            }
            CATransform3D st = l.sublayerTransform;
            if (!CATransform3DIsIdentity(st)) {
                double det = st.m11 * st.m22 - st.m12 * st.m21;
                if (det > 0.0001) s *= sqrt(det);
            }
        }
        a = a.superview;
    }
    return s;
}

static BOOL w26_homeSettled(void) {
    NSArray *icons = w26_collectIconViews();
    UIView *first = icons.firstObject;
    if (!first) return NO;
    if (fabs(w26_effectiveScale(first) - 1.0) > 0.02) return NO;
    if ([first.layer animationKeys].count > 0) return NO;
    if (first.superview &&
        [first.superview.layer animationKeys].count > 0) return NO;
    return YES;
}

/* Remove every animation that is NOT ours (ours are keyed "wave26.*"). */
static void w26_stripForeign(UIView *view) {
    UIView *a = view;
    for (int i = 0; a && i < 8; i++) {
        CALayer *l = a.layer;
        NSArray *keys = [l animationKeys];
        if (keys.count) {
            for (NSString *k in [keys copy]) {
                if (![k hasPrefix:@"wave26."]) [l removeAnimationForKey:k];
            }
        }
        a = a.superview;
    }
}

static void w26_guardTick(NSArray *icons, int ticksLeft) {
    if (ticksLeft <= 0) return;
    for (UIView *v in icons) w26_stripForeign(v);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        w26_guardTick(icons, ticksLeft - 1);
    });
}

/* The unlock flow is tunable (UnlockDelay / WaitForSettle); the plain
 * cover-sheet flow (notification centre pulled down and pushed back up) keeps
 * the 0.35 s delay that already looks right. */
static double w26_delayForPath(void) {
    return g_unlockFlow ? g_cfgUnlockDelay : kW26DeferredDelay;
}

static void w26_fireDeferred(double velocity) {
    double delay = w26_delayForPath();
    w26_log(@"schedule fire in %.2f s (unlockFlow=%d, panFired=%d)",
            delay, (int)g_unlockFlow, (int)g_panFired);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        g_fireRequested = NO;
        w26_fire(velocity, 0);
    });
}

/* Optional pre-delay: wait until the home screen has finished its own
 * transition so the wave is played on a settled (scale == 1) grid. */
static void w26_waitSettleThenFire(double velocity, int attempt, const char *source) {
    if (g_fireScheduled) return;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - g_lastFireTime < kW26Debounce) return;

    /* Two independent, separately tunable waits:
     *   WaitForCoverSheet - the wave must not start while the lock screen
     *                       still covers the home screen (it would be over
     *                       before the home screen becomes visible).
     *   WaitForSettle     - wait until the icon grid is no longer scaled.
     * ForcePresentation already snaps the grid to its final layout, so the
     * second wait is normally unnecessary and defaults to off. */
    BOOL waiting = NO;
    if (g_cfgWaitCover && g_haveCoverClass && g_onLockScreen && attempt < 20) {
        waiting = YES;                              /* 20 * 0.05 s = 1.0 s */
    }
    if (g_cfgWaitSettle && attempt < 12 && !w26_homeSettled()) {
        waiting = YES;                              /* 12 * 0.05 s = 0.6 s */
    }

    if (!waiting) {
        if (attempt > 0) {
            w26_log(@"[%s] waited %.2f s before firing", source, attempt * 0.05);
        }
        w26_fireDeferred(velocity);
        return;
    }

    g_fireScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        g_fireScheduled = NO;
        w26_waitSettleThenFire(velocity, attempt + 1, source);
    });
}

/* Single entry point for every trigger, so all of them honour the settings
 * and none of them can queue a second wave. */
static void w26_requestFire(double velocity, const char *source) {
    if (g_fireDone || g_fireRequested) return;
    g_fireRequested = YES;
    g_requestedAt = CFAbsoluteTimeGetCurrent();
    w26_loadSettings();
    w26_waitSettleThenFire(velocity, 0, source);
}

/* A swipe up on the lock screen means one of two very different things:
 *   a) swipe to unlock (no passcode) - the cover sheet disappears within a
 *      few hundred milliseconds, so play the wave as the home screen appears;
 *   b) swipe up to reveal the passcode pad - the cover sheet STAYS on screen,
 *      so the wave must NOT be spent here or the real unlock shows the stock
 *      animation instead of ours.
 */
static void w26_panSchedule(double velocity, int attempt) {
    if (!g_haveCoverClass || !g_onLockScreen) {
        w26_requestFire(velocity, "pan");
        return;
    }
    if (attempt >= 12) {                        /* 12 * 0.05 s = 0.6 s */
        w26_log(@"[pan] cover sheet still visible after %.2f s - cancelling "
                @"(passcode flow); the unlock path fires later",
                attempt * 0.05);
        g_panFired = NO;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        w26_panSchedule(velocity, attempt + 1);
    });
}

static BOOL w26_isUnlockPan(UIGestureRecognizer *gesture) {
    if (!gesture) return NO;

    if (g_panClass && [gesture isKindOfClass:g_panClass]) return YES;

    if (!g_panClass && g_edgeClass && g_onLockScreen &&
        [gesture isKindOfClass:g_edgeClass]) {
        if ([gesture respondsToSelector:@selector(edges)]) {
            if ([(id<W26EdgeGesture>)gesture edges] & UIRectEdgeBottom) return YES;
        }
    }

    return NO;
}

/* ------------------------------------------------------------------ */
#pragma mark - hooked implementations
/* ------------------------------------------------------------------ */

static void w26_setState(UIGestureRecognizer *self, SEL _cmd, UIGestureRecognizerState state) {
    if (w26_orig_setState) {
        void (*orig)(UIGestureRecognizer *, SEL, UIGestureRecognizerState) =
            (void (*)(UIGestureRecognizer *, SEL, UIGestureRecognizerState))w26_orig_setState;
        orig(self, _cmd, state);
    }

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
    g_unlockFlow = YES;

    w26_log(@"unlock pan ended (vel.y=%.1f)", velocity.y);
    w26_panSchedule(velocity.y, 0);
}

static BOOL w26_hasAnimatedIconLayoutBefore(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return YES;
}

static BOOL w26_shouldAnimateIconLaunch(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return NO;
}

static void w26_presProgressReached(double progress) {
    if (progress < 1.0 || g_panFired) return;
    if (CFAbsoluteTimeGetCurrent() - g_unlockedAt > 2.5) return;

    w26_log(@"home screen fully presented after unlock");
    w26_requestFire(g_haveVel ? g_lastVel.y : kW26DefaultVelocity, "progress");
}

/* SpringBoard keeps feeding new progress values every frame while it reveals
 * the home screen.  While a wave runs we pin the value at 1.0 so the icons can
 * never be pulled back towards their condensed pre-unlock positions - that is
 * what turned the wave into a "circle blob". */
static void w26_presWithCompletion(id self, SEL _cmd, double progress, BOOL animated, id completion) {
    if (w26_orig_presentationProgress) {
        void (*orig)(id, SEL, double, BOOL, id) =
            (void (*)(id, SEL, double, BOOL, id))w26_orig_presentationProgress;
        orig(self, _cmd, g_pinPresentation ? 1.0 : progress, NO, completion);
    }
    w26_presProgressReached(progress);
}

static void w26_presNoCompletion(id self, SEL _cmd, double progress, BOOL animated) {
    if (w26_orig_presentationProgress) {
        void (*orig)(id, SEL, double, BOOL) =
            (void (*)(id, SEL, double, BOOL))w26_orig_presentationProgress;
        orig(self, _cmd, g_pinPresentation ? 1.0 : progress, NO);
    }
    w26_presProgressReached(progress);
}

/* The selector was renamed more than once across iOS versions, so try every
 * spelling and hook whichever one this device actually has. */
static void w26_hookPresentationProgress(Class cls) {
    static const char *names[] = {
        "setRootFolderViewControllerPresentationProgress:animated:completion:",
        "setRootFolderViewControllerPresentationProgress:animated:",
        "setRootFolderPresentationProgress:animated:completion:",
        "setRootFolderPresentationProgress:animated:",
        "setPresentationProgress:animated:completion:",
        "setPresentationProgress:animated:",
    };

    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        SEL sel = sel_registerName(names[i]);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;

        unsigned args = method_getNumberOfArguments(m);
        IMP replacement = NULL;
        if (args == 5)      replacement = (IMP)w26_presWithCompletion;
        else if (args == 4) replacement = (IMP)w26_presNoCompletion;
        else continue;

        if (w26_swizzle(cls, sel, replacement, &w26_orig_presentationProgress)) {
            w26_presSEL  = sel;
            w26_presKind = (int)args;
            w26_log(@"hook presentationProgress = %s (%u args)", names[i], args);
            return;
        }
    }

    w26_log(@"hook presentationProgress = NONE (no known selector on this iOS)");
}

static void w26_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (w26_orig_viewWillAppear) {
        void (*orig)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))w26_orig_viewWillAppear;
        orig(self, _cmd, animated);
    }
    g_onLockScreen = YES;
    g_panFired = NO;
    g_fireDone = NO;
    g_unlockFlow = NO;
    g_fireRequested = NO;
}

static void w26_viewDidDisappear(id self, SEL _cmd, BOOL animated) {
    if (w26_orig_viewDidDisappear) {
        void (*orig)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))w26_orig_viewDidDisappear;
        orig(self, _cmd, animated);
    }

    if (!g_onLockScreen) return;
    g_onLockScreen = NO;
    g_lockScreenDismissed = CFAbsoluteTimeGetCurrent();
    g_unlockedAt = g_lockScreenDismissed;

    if (g_fireDone) {
        /* a wave already played for this flow - unless the pan one was long
         * ago (swipe up -> type passcode), then a fresh one is wanted */
        if (!(g_panFired &&
              (CFAbsoluteTimeGetCurrent() - g_lastFireTime) >= kW26PanReFireWindow)) {
            return;
        }
        g_fireDone = NO;
    }

    w26_log(@"cover sheet disappeared (panFired=%d, lastFire=%.2fs ago)",
            (int)g_panFired, CFAbsoluteTimeGetCurrent() - g_lastFireTime);
    w26_requestFire(g_haveVel ? g_lastVel.y : kW26DefaultVelocity, "cover");
}

/* ------------------------------------------------------------------ */
#pragma mark - hooking (pure Objective-C runtime)
/* ------------------------------------------------------------------ */

static BOOL w26_swizzle(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (!cls || !sel || !replacement) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    const char *types = method_getTypeEncoding(method) ?: "v@:";
    IMP previous = method_getImplementation(method);

    if (class_addMethod(cls, sel, replacement, types)) {
        /* the class inherited the method - keep the inherited IMP as "original" */
        if (original) *original = previous;
        return YES;
    }

    IMP replaced = class_replaceMethod(cls, sel, replacement, types);
    if (replaced) {
        if (original) *original = replaced;
        return YES;
    }

    return NO;
}

static void w26_installHooks(void) {
    w26_log(@"hook UIGestureRecognizer setState: = %d",
            w26_swizzle([UIGestureRecognizer class], @selector(setState:),
                        (IMP)w26_setState, &w26_orig_setState));

    Class iconController = NSClassFromString(@"SBIconController");
    w26_log(@"hook SBIconController hasAnimatedIconLayoutBefore = %d",
            w26_swizzle(iconController, @selector(hasAnimatedIconLayoutBefore),
                        (IMP)w26_hasAnimatedIconLayoutBefore,
                        &w26_orig_hasAnimatedIconLayoutBefore));
    w26_log(@"hook SBIconController _shouldAnimateIconLaunch = %d",
            w26_swizzle(iconController, NSSelectorFromString(@"_shouldAnimateIconLaunch"),
                        (IMP)w26_shouldAnimateIconLaunch,
                        &w26_orig_shouldAnimateIconLaunch));
    w26_hookPresentationProgress(iconController);

    Class coverSheet = NSClassFromString(@"SBCoverSheetViewController");
    w26_log(@"hook SBCoverSheetViewController viewWillAppear: = %d",
            w26_swizzle(coverSheet, @selector(viewWillAppear:),
                        (IMP)w26_viewWillAppear, &w26_orig_viewWillAppear));
    w26_log(@"hook SBCoverSheetViewController viewDidDisappear: = %d",
            w26_swizzle(coverSheet, @selector(viewDidDisappear:),
                        (IMP)w26_viewDidDisappear, &w26_orig_viewDidDisappear));
}

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
            g_fireDone = NO;
            g_unlockFlow = NO;
            g_fireRequested = NO;
            return;
        }

        if (state != 0) return;     /* 0 == unlocked */

        g_unlockedAt = CFAbsoluteTimeGetCurrent();
        g_unlockFlow = YES;

        if (g_panFired) return;

        w26_log(@"unlocked without a pan");
        g_unlockFlow = YES;
        w26_requestFire(g_haveVel ? g_lastVel.y : kW26DefaultVelocity, "notify");
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

    w26_log(@"==== 26Unlock loaded (no substrate) ====");
    w26_log(@"iOS %@ | pan=%@ | edge=%@ | icon=%@ | dock=%@ | coverSheetClass=%@",
            [[UIDevice currentDevice] systemVersion],
            g_panClass  ? NSStringFromClass(g_panClass)  : @"MISSING",
            g_edgeClass ? NSStringFromClass(g_edgeClass) : @"MISSING",
            g_iconClass ? NSStringFromClass(g_iconClass) : @"MISSING",
            g_dockClass ? NSStringFromClass(g_dockClass) : @"MISSING",
            g_haveCoverClass ? @"YES" : @"MISSING");
    w26_log(@"log file: " W26_LOGFILE);
}

__attribute__((constructor))
static void w26_constructor(void) {
    @autoreleasepool {
        w26_init();
        w26_installHooks();
        w26_registerLockStateNotifications();
    }
}
