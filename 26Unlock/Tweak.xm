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

static const CFTimeInterval kW26Debounce = 0.08;
static const double kW26DefaultVelocity  = -1250.0;
/* If the pan already played a wave but the unlock only finished much later
 * (passcode typing takes seconds), play a fresh one at the cover-sheet
 * moment so both cases look identical. */
static const CFTimeInterval kW26PanReFireWindow = 1.5;
static const CFTimeInterval kW26RetryInterval   = 0.06;  /* 60 ms           */
static const int            kW26MaxAttempts     = 20;    /* 20 * 0.06 = 1.2 s */

/* ------------------------------------------------------------------ */
#pragma mark - runtime settings (/var/mobile/26Unlock.plist)
/* ------------------------------------------------------------------ */

#define W26_SETTINGS @"/var/mobile/26Unlock.plist"

/* Every value below can be changed on device without rebuilding: edit
 * /var/mobile/26Unlock.plist with Filza, then simply unlock again. */
static double g_cfgUnlockDelay = 0.00;  /* settle delay - 0 = fire as soon as  */
                                        /* the layout is ready (no dead time) */
static int    g_cfgStableSamp  = 1;     /* identical samples before firing    */
static BOOL   g_cfgPinPres     = YES;   /* suppress SpringBoard's own reveal  */
static BOOL   g_cfgWaitStable  = NO;    /* wait for the grid to stop moving   */
static BOOL   g_cfgWaitSettle  = NO;    /* wait until the grid scale is 1.0   */
static BOOL   g_cfgWaitCover   = NO;   /* wait until the lock screen is gone */
static BOOL   g_cfgWaitGrid    = NO;    /* wait until the icon grid is at home*/
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
    v = [d objectForKey:@"WaitForStable"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgWaitStable  = [v boolValue];
    v = [d objectForKey:@"PinPresentation"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgPinPres     = [v boolValue];
    v = [d objectForKey:@"StableSamples"];
    if ([v respondsToSelector:@selector(intValue)])    g_cfgStableSamp  = MAX(1, [v intValue]);
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

static BOOL g_fireDone;        /* a wave already played for this flow    */
static BOOL g_fireRequested;   /* a fire is already queued               */
static BOOL g_pinPresentation; /* keep progress pinned at 1.0             */

/* ---- unlock cycle state machine ---- */
static uint64_t g_cycleID;          /* invalidates stale dispatch_after      */
static BOOL     g_cycleArmed;       /* cover sheet shown / device locked     */
static BOOL     g_unlockConfirmed;  /* lockstate == 0 (a real unlock)        */
static BOOL     g_coverSheetGone;   /* SBCoverSheetViewController dismissed  */
static BOOL     g_presComplete;     /* no home presentation pending          */
static int      g_stableSamples;    /* consecutive identical layout samples  */
static NSMutableArray *g_prevCenters;

static void w26_waitAndPlay(int attempt, uint64_t cycle, const char *reason);
static void w26_retry(int attempt, uint64_t cycle, const char *reason);
static void w26_armCycle(const char *why);
static void w26_requestWaveCheck(const char *reason);
static BOOL w26_iconsHaveValidFrames(NSArray *icons);
static BOOL w26_iconLayoutStable(NSArray *icons);
static CFTimeInterval g_requestedAt; /* when the fire was queued           */

/* Set right before a wave plays: the ancestor scale the wave offsets must be
 * divided by so the motion keeps its on-screen size.  Read by WaveEngine.m. */
double W26ScaleComp = 1.0;

static void   w26_forceHomePresentation(void);
static BOOL   w26_swizzle(Class cls, SEL sel, IMP replacement, IMP *original);
static double w26_effectiveScale(UIView *view);
static void   w26_stripForeign(UIView *view);
static void   w26_guardTick(NSArray *icons, int ticksLeft);

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

/* Only transforms may be touched.  removeAllAnimations() up the whole chain
 * also killed SpringBoard's own cross-fades (lock screen clock, torch/camera
 * buttons, wallpaper) - that is why they vanished early, and the layout then
 * snapped back when the guard stopped and they resumed. */
static void w26_stripIcon(UIView *view) {
    if (!view) return;
    CALayer *l = view.layer;
    if (!l) return;

    for (NSString *k in [[l animationKeys] copy]) {
        if ([k hasPrefix:@"wave26."]) continue;              /* our own    */
        CAAnimation *anim = [l animationForKey:k];
        NSString *path = [anim isKindOfClass:[CAPropertyAnimation class]]
                       ? [(CAPropertyAnimation *)anim keyPath] : nil;
        /* opacity stays - SpringBoard may still fade the icons in. */
        if ([path isEqualToString:@"position"] ||
            [path isEqualToString:@"transform"]) {
            [l removeAnimationForKey:k];
        }
    }
}

/* SpringBoard's unlock reveal is a transform on a container ABOVE the icons.
 * Cancelling it, and forcing any leftover transform back to identity, makes
 * the grid render 1:1 - so the wave neither starts squeezed (the clump) nor
 * jumps when the reveal finishes (the hard snap). */
static void w26_neutralizeReveal(UIView *view, BOOL verbose) {
    UIView *a = view;
    for (int i = 0; a && i < 8; i++) {
        if ([a isKindOfClass:[UIWindow class]]) break;
        CALayer *l = a.layer;
        if (!l) break;

        for (NSString *k in [[l animationKeys] copy]) {
            if ([k hasPrefix:@"wave26."]) continue;
            CAAnimation *anim = [l animationForKey:k];
            NSString *path = [anim isKindOfClass:[CAPropertyAnimation class]]
                           ? [(CAPropertyAnimation *)anim keyPath] : nil;
            /* position/bounds on a container are the page scroll offset and
             * opacity is SpringBoard's cross-fade - leave both alone. */
            if ([path isEqualToString:@"transform"] ||
                [path isEqualToString:@"sublayerTransform"]) {
                [l removeAnimationForKey:k];
            }
        }

        if (!CATransform3DIsIdentity(l.transform)) {
            if (verbose) {
                w26_log(@"  reveal: forced %@ transform -> identity",
                        NSStringFromClass([a class]));
            }
            l.transform = CATransform3DIdentity;
        }
        if (!CATransform3DIsIdentity(l.sublayerTransform)) {
            l.sublayerTransform = CATransform3DIdentity;
        }

        a = a.superview;
    }
}

/* One-shot dump so the next log shows exactly which layer carries the reveal
 * and what SpringBoard animates on it. */
static void w26_probe(NSArray *icons) {
    if (icons.count == 0) return;

    for (NSUInteger i = 0; i < icons.count && i < 3; i++) {
        UIView *v = icons[i];
        CALayer *l = v.layer;
        CGPoint model = l ? l.position : CGPointZero;
        CGPoint pres  = l ? [[l presentationLayer] position] : CGPointZero;
        CGRect  wf    = [v convertRect:v.bounds toView:nil];
        w26_log(@"probe icon%lu: model=(%.1f,%.1f) pres=(%.1f,%.1f) "
                @"window=(%.1f,%.1f) ancestorScale=%.3f",
                (unsigned long)i, model.x, model.y, pres.x, pres.y,
                CGRectGetMidX(wf), CGRectGetMidY(wf), w26_effectiveScale(v));
    }

    UIView *a = [icons[0] superview];
    for (int i = 0; a && i < 8; i++) {
        CALayer *l = a.layer;
        NSMutableArray *paths = [NSMutableArray array];
        for (NSString *k in [l animationKeys]) {
            CAAnimation *anim = [l animationForKey:k];
            NSString *pp = [anim isKindOfClass:[CAPropertyAnimation class]]
                         ? [(CAPropertyAnimation *)anim keyPath] : @"(basic)";
            [paths addObject:pp ? pp : @"(nil)"];
        }
        w26_log(@"probe anc%d: %@ | transform=%@ | anims=%@", i,
                NSStringFromClass([a class]),
                CATransform3DIsIdentity(l.transform) ? @"identity" : @"SCALED",
                paths.count ? [paths componentsJoinedByString:@","] : @"none");
        if ([a isKindOfClass:[UIWindow class]]) break;
        a = a.superview;
    }
}

/* ------------------------------------------------------------------ */
#pragma mark - grid registration (identical to the original binary)
/* ------------------------------------------------------------------ */

static void w26_registerHome(NSArray *icons, UIView *dock) {
    if (icons.count == 0) return;
    [g_engine setDockView:dock];

    NSMutableArray *ordered = [NSMutableArray array];
    NSMutableArray *centres = [NSMutableArray array];  /* window-space, TRUE home when known */

    double minX = INFINITY, maxX = -INFINITY;
    double minY = INFINITY, maxY = -INFINITY;

    for (id item in icons) {
        if (![item isKindOfClass:[UIView class]]) continue;
        UIView *view = (UIView *)item;
        if (dock && w26_isInDock(view, dock)) continue;

        CGRect frame = [view convertRect:view.bounds toView:nil];
        if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) continue;

        /* Use the recorded at-rest position for binning whenever we have
         * one. A condensed/transient frame (SpringBoard mid-reveal) would
         * otherwise squeeze every icon's centre into a tiny bounding box,
         * so they all land in the same handful of grid cells - same wave
         * number, same delay, same huge scale-up factor - which is what
         * made the whole grid look like one shrinking blob instead of a
         * staggered, per-position wave. */
        CGPoint centre = view.center;

        [ordered addObject:view];
        [centres addObject:[NSValue valueWithCGPoint:centre]];

        if (centre.x < minX) minX = centre.x;
        if (centre.x > maxX) maxX = centre.x;
        if (centre.y < minY) minY = centre.y;
        if (centre.y > maxY) maxY = centre.y;
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

    g_lastFireTime = now;
    g_fireDone = YES;

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

    w26_probe(icons);

    for (UIView *view in icons) w26_stripIcon(view);
    if (dock) w26_stripIcon(dock);

    for (UIView *view in icons) w26_neutralizeReveal(view, YES);
    if (dock) w26_neutralizeReveal(dock, YES);

    [g_engine playWithPullVelocity:velocity];

    if (g_cfgGuard > 0.0) {
        int ticks = (int)(g_cfgGuard / 0.05);
        w26_guardTick(icons, ticks);
        if (dock) w26_guardTick(@[dock], ticks);
    }

    w26_log(@"fire: wave played - %lu icons, dock=%@, velocity=%.1f",
            (unsigned long)icons.count, dock ? @"yes" : @"no", velocity);
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

/* Remove every animation that is NOT ours (ours are keyed "wave26.*"). */
static void w26_stripForeign(UIView *view) {
    w26_neutralizeReveal(view, NO);   /* transforms only - never the fades */
}

static void w26_guardTick(NSArray *icons, int ticksLeft) {
    if (ticksLeft <= 0) return;
    for (UIView *v in icons) w26_stripForeign(v);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        w26_guardTick(icons, ticksLeft - 1);
    });
}

/* ------------------------------------------------------------------ */
#pragma mark - unlock cycle state machine
/* ------------------------------------------------------------------ */

/* One wave per unlock cycle and ONE pipeline for every situation:
 *
 *     LOCKED
 *       ->  swipe: capture velocity only  (never fire from the gesture)
 *       ->  lockstate == unlocked                      (passcode OR swipe)
 *       ->  home presentation complete
 *       ->  icon frames valid  (not the condensed pre-unlock layout)
 *       ->  icon layout stable for N consecutive samples
 *       ->  PLAY WAVE
 *
 * The notification-centre flow ends with the cover sheet disappearing, which
 * is the same final state, so it runs through exactly the same pipeline and
 * keeps the timing that already looked right. */

static void w26_armCycle(const char *why) {
    g_cycleID++;
    g_cycleArmed       = YES;
    g_unlockConfirmed  = NO;
    g_coverSheetGone   = NO;
    g_presComplete     = YES;   /* nothing is presented until we see it */
    g_panFired         = NO;
    g_haveVel          = NO;
    g_fireDone         = NO;
    g_fireRequested    = NO;
    g_pinPresentation  = NO;
    g_stableSamples    = 0;
    g_prevCenters      = nil;
    w26_log(@"cycle armed (%s) id=%llu", why, (unsigned long long)g_cycleID);
}

static void w26_retry(int attempt, uint64_t cycle, const char *reason) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kW26RetryInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        w26_waitAndPlay(attempt + 1, cycle, reason);
    });
}

static void w26_waitAndPlay(int attempt, uint64_t cycle, const char *reason) {
    if (cycle != g_cycleID) {                /* device locked again -> stale */
        g_fireRequested = NO;                /* never leave the flag stuck   */
        return;
    }
    if (g_fireDone) return;

    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    BOOL giveUp = (attempt >= kW26MaxAttempts);

    /* 0. the lock screen must have ACTUALLY, VISUALLY gone - not merely
     *    reported unlocked at the data layer. See rationale above. */
    if (g_haveCoverClass && !g_coverSheetGone && !giveUp) {
        w26_retry(attempt, cycle, reason);
        return;
    }
    /* 1. the home screen must actually be on its way in (fallback for iOS
     *    versions where the cover sheet class could not be found at all) */
    if (!g_unlockConfirmed && !g_coverSheetGone && !giveUp) {
        w26_retry(attempt, cycle, reason);
        return;
    }
    /* 2. SpringBoard must not still be revealing the icon grid */
    if (!g_presComplete && !giveUp) {
        w26_retry(attempt, cycle, reason);
        return;
    }

    /* The notification-centre flow is not an unlock: the grid is already at
     * rest, so there is nothing to wait for here - only a real unlock needs
     * the readiness checks below. */
    BOOL strict = g_unlockConfirmed;

    if (strict) {
        NSArray *icons = w26_collectIconViews();

        /* Waiting for the icons to come to rest guarantees a clean grid but
         * costs the length of SpringBoard's reveal, and the home override
         * registered in w26_registerHome() already makes the wave land
         * correctly even when it starts early - so this wait is off by
         * default and can be switched back on with WaitForStable. */
        if (g_cfgWaitStable && !g_pinPresentation) {
            if (!w26_iconLayoutStable(icons) && !giveUp) {
                w26_retry(attempt, cycle, reason);
                return;
            }
        }
        /* No recorded home layout at all (first unlock right after a
         * respring): fall back to the width heuristic. */
        if (g_cfgWaitGrid && !w26_iconsHaveValidFrames(icons) && !giveUp) {
            if (attempt == 0) w26_log(@"[%s] icon frames not valid yet", reason);
            w26_retry(attempt, cycle, reason);
            return;
        }
    }
    /* 4b. optional: only start once the lock screen has actually gone */
    if (g_cfgWaitCover && !g_coverSheetGone && !giveUp) {
        w26_retry(attempt, cycle, reason);
        return;
    }
    /* 5. the settle delay runs in parallel with the checks above, so a flow
     *    that is ready immediately keeps its original timing */
    if ((now - g_requestedAt) < g_cfgUnlockDelay && !giveUp) {
        w26_retry(attempt, cycle, reason);
        return;
    }

    if (giveUp) {
        w26_log(@"[%s] gave up waiting for a stable layout", reason);
    } else {
        w26_log(@"[%s] ready after %.2f s (%d samples) vel=%.0f pin=%d",
                reason, now - g_requestedAt, attempt,
                g_haveVel ? g_lastVel.y : kW26DefaultVelocity,
                (int)g_pinPresentation);
    }

    /* Pin SpringBoard's reveal so the icons cannot be pulled back into the
     * condensed pre-unlock layout while the wave plays. Done here, not at
     * request time, so it can never force-complete the layout while the
     * lock screen is still visually covering the screen. */
    if (g_cfgPinPres) {
        g_pinPresentation = YES;
        w26_forceHomePresentation();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            g_pinPresentation = NO;
        });
    }

    g_fireRequested = NO;
    w26_fire(g_haveVel ? g_lastVel.y : kW26DefaultVelocity, 0);
}

static void w26_requestWaveCheck(const char *reason) {
    /* The notification centre can be pulled down and dismissed again without
     * a lock cycle in between, so the "already played" flag has to be cleared
     * or a quick second swipe would silently do nothing. */
    if (g_fireDone && !g_unlockConfirmed &&
        (CFAbsoluteTimeGetCurrent() - g_lastFireTime) > 0.25) {
        w26_armCycle("re-arm (no lock cycle)");
    }
    if (g_fireDone || g_fireRequested) {
        w26_log(@"wave request skipped (%s) fireDone=%d requested=%d",
                reason, (int)g_fireDone, (int)g_fireRequested);
        return;
    }

    g_fireRequested = YES;
    g_requestedAt   = CFAbsoluteTimeGetCurrent();
    w26_loadSettings();

    w26_log(@"wave requested (%s) confirmed=%d coverGone=%d presComplete=%d",
            reason, (int)g_unlockConfirmed, (int)g_coverSheetGone,
            (int)g_presComplete);
    w26_waitAndPlay(0, g_cycleID, reason);
}

/* A condensed grid (icons still gathered near the middle of the screen while
 * SpringBoard reveals them) spans far less than the screen and every frame is
 * a temporary one - playing the wave on it is the "circle blob" bug. */
static BOOL w26_iconsHaveValidFrames(NSArray *icons) {
    if (icons.count < 2) return NO;

    CGRect bounds = [UIScreen mainScreen].bounds;
    double minX = INFINITY, maxX = -INFINITY;

    for (UIView *v in icons) {
        CGRect f = [v convertRect:v.bounds toView:nil];
        if (f.size.width < 1.0 || f.size.height < 1.0) return NO;
        if (CGRectGetMidX(f) < -100 || CGRectGetMidX(f) > bounds.size.width  + 100) return NO;
        if (CGRectGetMidY(f) < -100 || CGRectGetMidY(f) > bounds.size.height + 100) return NO;
        if (CGRectGetMidX(f) < minX) minX = CGRectGetMidX(f);
        if (CGRectGetMidX(f) > maxX) maxX = CGRectGetMidX(f);
    }

    double span = maxX - minX;
    return (bounds.size.width > 0) && (span >= g_cfgGridMin * bounds.size.width);
}

static BOOL w26_iconLayoutStable(NSArray *icons) {
    NSMutableArray *cur = [NSMutableArray arrayWithCapacity:icons.count];
    for (UIView *v in icons) {
        CGRect f = [v convertRect:v.bounds toView:nil];
        [cur addObject:[NSValue valueWithCGPoint:
            CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f))]];
    }

    BOOL same = (g_prevCenters != nil && g_prevCenters.count == cur.count);
    if (same) {
        for (NSUInteger i = 0; i < cur.count; i++) {
            CGPoint a = [[g_prevCenters objectAtIndex:i] CGPointValue];
            CGPoint b = [[cur objectAtIndex:i] CGPointValue];
            if (fabs(a.x - b.x) > 0.5 || fabs(a.y - b.y) > 0.5) { same = NO; break; }
        }
    }

    g_prevCenters   = cur;
    g_stableSamples = same ? (g_stableSamples + 1) : 0;
    return g_stableSamples >= g_cfgStableSamp;
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

    /* Velocity only.  Firing here would read icon frames in the middle of
     * SpringBoard's own transition - that is what made rows 4/5 clump. */
    w26_log(@"unlock pan ended (vel.y=%.1f) - velocity captured", velocity.y);
}

static BOOL w26_hasAnimatedIconLayoutBefore(id self, SEL _cmd) {
    if (g_cycleArmed && g_unlockConfirmed) return YES;
    if (w26_orig_hasAnimatedIconLayoutBefore) {
        return ((BOOL (*)(id, SEL))w26_orig_hasAnimatedIconLayoutBefore)(self, _cmd);
    }
    return NO;
}

static BOOL w26_shouldAnimateIconLaunch(id self, SEL _cmd) {
    if (g_cycleArmed && g_unlockConfirmed) return NO;
    if (w26_orig_shouldAnimateIconLaunch) {
        return ((BOOL (*)(id, SEL))w26_orig_shouldAnimateIconLaunch)(self, _cmd);
    }
    return YES;
}

static void w26_presProgressReached(double progress) {
    if (progress >= 0.999) {
        g_presComplete = YES;
        /* Readiness signal only - never an independent unlock trigger. */
        w26_requestWaveCheck("progress");
    } else {
        if (g_presComplete) {
            /* Progress just left 1.0: SpringBoard is condensing the grid
             * again for a brand-new pull-down (or the same one bouncing).
             * That is unambiguous proof this is a fresh gesture, so let the
             * next completion fire for sure - a time-based debounce alone
             * can't tell "same event settling" from "user was just fast",
             * which is what dropped the wave on a quick down+up. */
            g_fireDone = NO;
            g_fireRequested = NO;
        }
        g_presComplete = NO;
    }
}

/* SpringBoard keeps feeding new progress values every frame while it reveals
 * the home screen.  While a wave runs we pin the value at 1.0 so the icons can
 * never be pulled back towards their condensed pre-unlock positions - that is
 * what turned the wave into a "circle blob". */
static void w26_presWithCompletion(id self, SEL _cmd, double progress, BOOL animated, id completion) {
    if (w26_orig_presentationProgress) {
        void (*orig)(id, SEL, double, BOOL, id) =
            (void (*)(id, SEL, double, BOOL, id))w26_orig_presentationProgress;

        if (g_pinPresentation) {
            /* The home screen is already pinned at its final state, so
             * SpringBoard's per-frame updates are pointless work: they force a
             * layout pass every frame (dropped frames) and keep rewriting the
             * icon positions our wave is animating (the stutter on rows 3+).
             * Only the final value is allowed through. */
            if (progress >= 0.999) orig(self, _cmd, 1.0, NO, completion);
        } else {
            orig(self, _cmd, progress, NO, completion);
        }
    }
    w26_presProgressReached(progress);
}

static void w26_presNoCompletion(id self, SEL _cmd, double progress, BOOL animated) {
    if (w26_orig_presentationProgress) {
        void (*orig)(id, SEL, double, BOOL) =
            (void (*)(id, SEL, double, BOOL))w26_orig_presentationProgress;

        if (g_pinPresentation) {
            if (progress >= 0.999) orig(self, _cmd, 1.0, NO);
        } else {
            orig(self, _cmd, progress, NO);
        }
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
        w26_armCycle("cover appeared");
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

    g_coverSheetGone = YES;
    w26_log(@"cover sheet disappeared (panFired=%d, lastFire=%.2fs ago)",
            (int)g_panFired, CFAbsoluteTimeGetCurrent() - g_lastFireTime);
    w26_requestWaveCheck("cover");
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

        if (state == 1) {           /* locked again - re-arm the cycle */
            g_onLockScreen = YES;
                        w26_armCycle("locked");
            return;
        }

        if (state != 0) return;     /* 0 == unlocked */

        g_unlockedAt = CFAbsoluteTimeGetCurrent();
        g_unlockConfirmed = YES;

        /* Works for both flows: passcode (no pan) and swipe (velocity already
         * captured).  This is the only place the unlock is confirmed. */
        w26_log(@"unlock confirmed (pan=%d)", (int)g_panFired);
        w26_requestWaveCheck("lockstate");
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

    /* Nothing is being presented until SpringBoard says otherwise, so the
     * very first unlock after a respring must start from a clean cycle. */
    w26_armCycle("boot");

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
