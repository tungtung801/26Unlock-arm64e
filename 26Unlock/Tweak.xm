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
#import <stdlib.h>
#import <string.h>

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
static double g_cfgDockUnlockSpeed = 1.10; /* unlock dock only; NC stays at 1.0 */

/* Read by WaveEngine.m.  W26ScaleComp = the ancestor scale the wave offsets
 * are divided by so the motion keeps its on-screen size.  The dock spring is
 * tunable at runtime through 26Unlock.plist - no rebuild needed. */
double W26ScaleComp = 1.0;
double W26WaveSpeed = 1.10;       /* 1.00 = recovered timing; 1.10 = 10% faster */
double W26DockSpeed = 1.0;        /* set per fire: unlock setting or NC reference */
double W26DockTravel    = 380.0;   /* pt below home (binary value)          */
double W26DockStiffness = 200.0;   /* binary 115 -> ~0.70s, far too slow    */
double W26DockDamping   = 28.0;    /* binary 22 -> ~3pt bounce; 28 = clean  */
double W26DockMass      = 1.0;     /* binary 1.5 -> now settles in ~0.29s   */

/* Unlock straight into a running app (not the home screen). */
static BOOL   g_cfgAppZoom       = YES;   /* zoom-out + clearing blur        */
static double g_cfgAppZoomScale  = 1.20;  /* start scale -> 1.0              */
static double g_cfgAppZoomDur    = 0.40;  /* ~0.11 @120Hz, needs ~2-4x @60Hz */
static double g_cfgAppZoomDamp   = 28.0;  /* >2*sqrt(stiffness*mass) = no bounce back */
static double g_cfgAppZoomStiff  = 180.0;
static double g_cfgAppZoomMassV  = 1.0;
static BOOL   g_cfgAppZoomHide   = YES;   /* hide the lock screen while shooting */
static BOOL   g_cfgAppZoomNow    = YES;   /* YES = capture AFTER the hide took   */
static int    g_cfgAppZoomStyle  = 8;     /* UIBlurEffectStyleSystemMaterial */
static double g_cfgAppZoomLevel  = 0.0;   /* 0 = auto: just under the sheet  */
static double g_cfgAppZoomDelay  = 0.05;  /* the sheet is hidden, not awaited */
static BOOL   g_cfgAppZoomEarly  = NO;    /* show the blur while dragging    */
static BOOL   g_cfgAppZoomBlur   = NO;    /* OFF for now - testing the flicker*/
static BOOL   g_cfgAppZoomDirect = YES;   /* Path B: animate the live app host */
static BOOL   g_cfgAppZoomHostFallback = NO; /* never fall back to screen shot */

/* App-transition fail-safe.  This is intentionally separate from the wave:
 * if SpringBoard restarts before the short boot grace period completes, the
 * next load disables only AppZoom/mesh.  Unlock and NC wave hooks remain on. */
#define W26_APPTRANSITION_BOOT_FILE @"/var/mobile/26Unlock.apptransition.boot"
#define W26_APPTRANSITION_SAFE_FILE @"/var/mobile/26Unlock.apptransition.safe"
static BOOL g_cfgAppTransitionSafeMode;
static BOOL g_appTransitionSafeMode;
static BOOL g_appTransitionSafetyArmed;

/* Recovered 26Anim path.  This is separate from the unlock-to-app fallback
 * above: normal icon launches are driven by SBIconView's live transition
 * object, not by a screen snapshot or a uniform host scale. */
static BOOL   g_cfgAppMesh = YES;                 /* AppZoomMesh            */
static BOOL   g_cfgAppMeshOpeningMask = YES;      /* exact 350-pt branch    */
static BOOL   g_cfgAppMeshHideIcons = YES;        /* hide home icons on open */
static BOOL   g_cfgAppMeshLayerFallback = NO;     /* only for older runtimes */

static BOOL      g_appMeshHooksInstalled;
static BOOL      g_appMeshLoggedUnavailable;
static CGPoint   g_appMeshIconCenter;
static BOOL      g_appMeshHasIconCenter;
static NSHashTable *g_appMeshGrabberViews;         /* weak SBIconView table */
static const void *g_appMeshDisplayLinkKey = &g_appMeshDisplayLinkKey;
static const void *g_appMeshSavedCRKey = &g_appMeshSavedCRKey;
static const void *g_appMeshSavedMTBKey = &g_appMeshSavedMTBKey;
static const void *g_appMeshSavedCurveKey = &g_appMeshSavedCurveKey;

/* Runtime-only diagnostics for the A12/iOS 16 port.  These counters limit
 * the log volume; they do not change the transition or its timing. */
static NSUInteger g_appMeshTransformCallCount;
static NSUInteger g_appMeshRuntimeShapeLogCount;

static IMP w26_orig_iconSetHighlighted;
static IMP w26_orig_iconDidMoveToWindow;
static IMP w26_orig_iconSetTransform3D;
static IMP w26_orig_iconSetTransformAffine;

static BOOL      w26_installAppMeshHooks(void);
static void      w26_meshStartForTarget(id target, double scalar);
static void      w26_meshObserveTransform(id target, double scalar);

static BOOL     g_appZoomFlow;            /* this unlock lands in an app     */
static BOOL     g_appZoomPlayed;
static UIWindow *g_zoomWindow;             /* old screenshot path only         */
static UIView   *g_zoomBlurHost;          /* old screenshot path only         */
static UIView   *g_zoomSnap;              /* old screenshot path only         */
static double   g_coverWindowLevel;
static NSString *g_appZoomBundleID;
static NSString *g_appZoomSceneID;
static id        g_appZoomApplication;
static id        g_appZoomScene;

/* Path B state: the actual SpringBoard host for the app's remote CAContext. */
static UIView    *g_appZoomHost;
static CATransform3D g_appZoomHostBaseTransform;
static BOOL      g_appZoomHostPrepared;
static uint64_t  g_appZoomHostCycle;
static BOOL      g_appZoomHostExternal;
static id        g_appZoomHostManager;
static NSString *g_appZoomHostRequester;

static void   w26_appZoomTeardown(void);
static void   w26_probeAppHost(void);
static void   w26_appZoomBegin(void);
static void   w26_appZoomPlay(void);
static void   w26_appZoomHostRestore(void);
static BOOL   w26_appZoomHostPrepare(void);
static void   w26_appZoomHostAttempt(int attempt, uint64_t cycle);
static BOOL   w26_unlockGoesToApp(void);
static void  w26_enterAppTransitionSafeMode(const char *reason);
static void  w26_armAppTransitionSafety(void);

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
    v = [d objectForKey:@"AppZoom"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgAppZoom      = [v boolValue];
    v = [d objectForKey:@"AppZoomScale"];
    if ([v respondsToSelector:@selector(doubleValue)]) g_cfgAppZoomScale = [v doubleValue];
    v = [d objectForKey:@"AppZoomDuration"];
    if ([v respondsToSelector:@selector(doubleValue)]) g_cfgAppZoomDur   = [v doubleValue];
    v = [d objectForKey:@"AppZoomBlurStyle"];
    if ([v respondsToSelector:@selector(intValue)])    g_cfgAppZoomStyle = [v intValue];
    v = [d objectForKey:@"AppZoomWindowLevel"];
    if ([v respondsToSelector:@selector(doubleValue)]) g_cfgAppZoomLevel = [v doubleValue];
    v = [d objectForKey:@"AppZoomSnapshotDelay"];
    if ([v respondsToSelector:@selector(doubleValue)]) g_cfgAppZoomDelay = [v doubleValue];
    v = [d objectForKey:@"AppZoomDamping"];
    if ([v respondsToSelector:@selector(doubleValue)]) g_cfgAppZoomDamp   = [v doubleValue];
    v = [d objectForKey:@"AppZoomStiffness"];
    if ([v respondsToSelector:@selector(doubleValue)]) g_cfgAppZoomStiff  = [v doubleValue];
    v = [d objectForKey:@"AppZoomMass"];
    if ([v respondsToSelector:@selector(doubleValue)]) g_cfgAppZoomMassV  = [v doubleValue];
    v = [d objectForKey:@"AppZoomSnapshotUpdates"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgAppZoomNow    = [v boolValue];
    v = [d objectForKey:@"AppZoomHideSheetForSnapshot"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgAppZoomHide   = [v boolValue];
    v = [d objectForKey:@"AppZoomDirectHost"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgAppZoomDirect = [v boolValue];
    v = [d objectForKey:@"AppZoomHostFallback"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgAppZoomHostFallback = [v boolValue];
    v = [d objectForKey:@"AppTransitionSafeMode"];
    if ([v respondsToSelector:@selector(boolValue)]) {
        g_cfgAppTransitionSafeMode = [v boolValue];
    }
    v = [d objectForKey:@"AppZoomMesh"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgAppMesh = [v boolValue];
    v = [d objectForKey:@"AppZoomMeshOpeningMask"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgAppMeshOpeningMask = [v boolValue];
    v = [d objectForKey:@"AppZoomMeshHideIcons"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgAppMeshHideIcons = [v boolValue];
    v = [d objectForKey:@"AppZoomMeshLayerFallback"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgAppMeshLayerFallback = [v boolValue];
    v = [d objectForKey:@"AppZoomBlur"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgAppZoomBlur   = [v boolValue];
    v = [d objectForKey:@"AppZoomEarlyBlur"];
    if ([v respondsToSelector:@selector(boolValue)])   g_cfgAppZoomEarly = [v boolValue];
    v = [d objectForKey:@"WaveSpeed"];
    if ([v respondsToSelector:@selector(doubleValue)]) {
        double speed = [v doubleValue];
        if (speed >= 0.50 && speed <= 2.00) W26WaveSpeed = speed;
    }
    v = [d objectForKey:@"DockUnlockSpeed"];
    if ([v respondsToSelector:@selector(doubleValue)]) {
        double speed = [v doubleValue];
        if (speed >= 0.50 && speed <= 2.00) g_cfgDockUnlockSpeed = speed;
    }
    v = [d objectForKey:@"DockTravel"];
    if ([v respondsToSelector:@selector(doubleValue)]) W26DockTravel    = [v doubleValue];
    v = [d objectForKey:@"DockStiffness"];
    if ([v respondsToSelector:@selector(doubleValue)]) W26DockStiffness = [v doubleValue];
    v = [d objectForKey:@"DockDamping"];
    if ([v respondsToSelector:@selector(doubleValue)]) W26DockDamping   = [v doubleValue];
    v = [d objectForKey:@"DockMass"];
    if ([v respondsToSelector:@selector(doubleValue)]) W26DockMass      = [v doubleValue];
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

    if (g_cfgAppTransitionSafeMode || g_appTransitionSafeMode) {
        g_cfgAppZoom = NO;
        g_cfgAppMesh = NO;
        g_cfgAppZoomDirect = NO;
        g_cfgAppZoomHostFallback = NO;
    }
}

static void w26_enterAppTransitionSafeMode(const char *reason) {
    g_appTransitionSafeMode = YES;
    g_cfgAppZoom = NO;
    g_cfgAppMesh = NO;
    g_cfgAppZoomDirect = NO;
    g_cfgAppZoomHostFallback = NO;

    NSString *why = reason ? [NSString stringWithUTF8String:reason] : @"unknown";
    NSDictionary *state = @{
        @"reason": why,
        @"date": [NSDate date]
    };
    [state writeToFile:W26_APPTRANSITION_SAFE_FILE atomically:YES];
    w26_log(@"[apptransition:safe] ENABLED reason=%@; wave remains enabled", why);
}

static void w26_armAppTransitionSafety(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL bootMarker = [fm fileExistsAtPath:W26_APPTRANSITION_BOOT_FILE];
    BOOL safeMarker = [fm fileExistsAtPath:W26_APPTRANSITION_SAFE_FILE];

    if (safeMarker) {
        w26_enterAppTransitionSafeMode("persistent safe marker");
    } else if (bootMarker) {
        w26_enterAppTransitionSafeMode(
            "SpringBoard restarted before the previous safety window completed");
    }

    NSDictionary *boot = @{
        @"pid": @([[NSProcessInfo processInfo] processIdentifier]),
        @"date": [NSDate date]
    };
    [boot writeToFile:W26_APPTRANSITION_BOOT_FILE atomically:YES];
    g_appTransitionSafetyArmed = YES;

    /* A normal, stable SpringBoard clears the boot marker.  If it dies before
     * this runs, the marker survives and the next load enters app-transition
     * safe mode automatically. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(30.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!g_appTransitionSafetyArmed) return;
        g_appTransitionSafetyArmed = NO;
        [[NSFileManager defaultManager]
            removeItemAtPath:W26_APPTRANSITION_BOOT_FILE error:NULL];
        w26_log(@"[apptransition:safe] boot window passed; transition=%@",
                (g_appTransitionSafeMode || g_cfgAppTransitionSafeMode)
                ? @"disabled" : @"enabled");
    });
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
#pragma mark - recovered iOS 26 app-transition mesh
/* ------------------------------------------------------------------ */

/* These are the private QuartzCore records consumed by
 * +[CAMeshTransform meshTransformWithVertexCount:vertices:faceCount:faces:
 * depthNormalization:].  The 26Anim binary uses 25 vertices and 16 quad
 * faces, not a pair of triangles per cell. */
typedef struct {
    CGPoint position;
    CGPoint texCoord;
    CGFloat z;
} W26MeshVertex;

typedef struct {
    unsigned int indices[4];
    float w[4];
} W26MeshFace;

@class W26MeshDriver;

static id w26_meshGetObject(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static CGRect w26_meshGetBounds(id object) {
    if (!object || ![object respondsToSelector:@selector(bounds)]) return CGRectZero;
    return ((CGRect (*)(id, SEL))objc_msgSend)(object, @selector(bounds));
}

static CATransform3D w26_meshGetTransform(id object) {
    if (!object || ![object respondsToSelector:@selector(transform)]) {
        return CATransform3DIdentity;
    }
    return ((CATransform3D (*)(id, SEL))objc_msgSend)(object, @selector(transform));
}

static CGFloat w26_meshGetCGFloat(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return 0.0;
    return ((CGFloat (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL w26_meshGetBool(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static void w26_meshSetObject(id object, SEL selector, id value) {
    if (!object || ![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
}

static void w26_meshSetCGFloat(id object, SEL selector, CGFloat value) {
    if (!object || ![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(object, selector, value);
}

static void w26_meshSetBool(id object, SEL selector, BOOL value) {
    if (!object || ![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
}

static void w26_meshSetTransform(id object, SEL selector, CATransform3D value) {
    if (!object || ![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL, CATransform3D))objc_msgSend)(object, selector, value);
}

static CGPoint w26_meshConvertPoint(id object, CGPoint point, id layer) {
    SEL selector = sel_registerName("convertPoint:toLayer:");
    if (!object || ![object respondsToSelector:selector]) return CGPointZero;
    return ((CGPoint (*)(id, SEL, CGPoint, id))objc_msgSend)(object, selector,
                                                               point, layer);
}

static NSArray *w26_meshSublayers(id object) {
    id value = w26_meshGetObject(object, @selector(sublayers));
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static NSString *w26_meshDelegateClassName(id object) {
    id delegate = w26_meshGetObject(object, @selector(delegate));
    return delegate ? NSStringFromClass([delegate class]) : @"(nil)";
}

static BOOL w26_meshHasSurfaceSelectors(id object) {
    return object &&
           [object respondsToSelector:@selector(setMeshTransform:)] &&
           [object respondsToSelector:@selector(setSublayerTransform:)] &&
           [object respondsToSelector:@selector(presentationLayer)];
}

static void w26_meshLogRuntimeShape(id object, NSUInteger call) {
    if (!object || g_appMeshRuntimeShapeLogCount >= 8) return;
    g_appMeshRuntimeShapeLogCount++;

    id layer = w26_meshGetObject(object, @selector(layer));
    CGRect bounds = w26_meshGetBounds(object);
    CGRect layerBounds = w26_meshGetBounds(layer);
    w26_log(@"[appmesh] runtime #%lu object=%@ bounds=(%.1f,%.1f) "
            @"delegate=%@ objectSurface=%d layer=%@ layerBounds=(%.1f,%.1f) "
            @"layerSurface=%d fallback=%d",
            (unsigned long)call,
            NSStringFromClass([object class]), bounds.size.width, bounds.size.height,
            w26_meshDelegateClassName(object),
            (int)w26_meshHasSurfaceSelectors(object),
            layer ? NSStringFromClass([layer class]) : @"(nil)",
            layerBounds.size.width, layerBounds.size.height,
            (int)w26_meshHasSurfaceSelectors(layer),
            (int)g_cfgAppMeshLayerFallback);
}

static id w26_meshDisplayLinkOnChain(id target) {
    id current = target;
    for (NSUInteger i = 0; current && i < 16; i++) {
        id link = objc_getAssociatedObject(current, g_appMeshDisplayLinkKey);
        if (link) return link;
        current = w26_meshGetObject(current, @selector(superlayer));
    }
    return nil;
}

/* The recovered helper negates its two direction inputs internally.  Keeping
 * that odd-looking double negation here makes the call site match the binary:
 * it passes -storedDirection and the effective vector is storedDirection. */
static id w26_meshCreateBulgedMesh(CGFloat amplitude, CGFloat inputDX,
                                   CGFloat inputDY) {
    Class meshClass = NSClassFromString(@"CAMeshTransform");
    SEL selector = sel_registerName(
        "meshTransformWithVertexCount:vertices:faceCount:faces:depthNormalization:");
    if (!meshClass || ![meshClass respondsToSelector:selector]) return nil;

    W26MeshVertex vertices[25];
    W26MeshFace faces[16];
    const CGFloat cap = 0.5175;
    CGFloat a = MIN(amplitude, cap);
    CGFloat directionX = -inputDX;
    CGFloat directionY = -inputDY;

    for (NSUInteger row = 0; row < 5; row++) {
        for (NSUInteger col = 0; col < 5; col++) {
            NSUInteger index = row * 5 + col;
            CGFloat u = (CGFloat)col / 4.0;
            CGFloat v = (CGFloat)row / 4.0;
            CGFloat cx = u - 0.5;
            CGFloat cy = v - 0.5;
            CGFloat dot = cx * directionX + cy * directionY;
            CGFloat k = a * dot * (dot < 0.0 ? 1.5 : 0.7);

            vertices[index].position = CGPointMake(u + cx * k, v + cy * k);
            vertices[index].texCoord = CGPointMake(u, v);
            vertices[index].z = 0.0;
        }
    }

    NSUInteger face = 0;
    for (NSUInteger row = 0; row < 4; row++) {
        for (NSUInteger col = 0; col < 4; col++) {
            unsigned int base = (unsigned int)(row * 5 + col);
            faces[face].indices[0] = base;
            faces[face].indices[1] = base + 1;
            faces[face].indices[2] = base + 6;
            faces[face].indices[3] = base + 5;
            faces[face].w[0] = 1.0f;
            faces[face].w[1] = 1.0f;
            faces[face].w[2] = 1.0f;
            faces[face].w[3] = 1.0f;
            face++;
        }
    }

    id (*make)(id, SEL, NSUInteger, const W26MeshVertex *, NSUInteger,
               const W26MeshFace *, CGFloat) =
        (id (*)(id, SEL, NSUInteger, const W26MeshVertex *, NSUInteger,
                const W26MeshFace *, CGFloat))objc_msgSend;
    return make(meshClass, selector, 25, vertices, 16, faces, 0.0);
}

static CGPoint w26_meshDirectionForTarget(id target, double scalar) {
    CGPoint anchor = CGPointZero;
    BOOL haveAnchor = g_appMeshHasIconCenter &&
                      g_appMeshIconCenter.x > 0.0 &&
                      g_appMeshIconCenter.y > 0.0;
    if (haveAnchor) {
        anchor = g_appMeshIconCenter;
    } else if (scalar > 0.05) {
        id presentation = w26_meshGetObject(target, @selector(presentationLayer));
        id source = presentation ?: target;
        CGRect bounds = w26_meshGetBounds(source);
        CGPoint midpoint = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
        anchor = w26_meshConvertPoint(source, midpoint, nil);
    }

    if (!isfinite(anchor.x) || !isfinite(anchor.y)) return CGPointZero;

    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat halfWidth = screen.size.width * 0.5;
    CGFloat halfHeight = screen.size.height * 0.5;
    if (halfWidth <= 0.0 || halfHeight <= 0.0) return CGPointZero;

    CGPoint result = CGPointMake((anchor.x - CGRectGetMidX(screen)) / halfWidth,
                                 (anchor.y - CGRectGetMidY(screen)) / halfHeight);
    CGFloat length = hypot(result.x, result.y);
    if (length > 0.05) {
        result.x /= length;
        result.y /= length;
    }
    return result;
}

static void w26_meshSaveOpeningSublayerState(id sublayer) {
    if (!sublayer) return;

    if (!objc_getAssociatedObject(sublayer, g_appMeshSavedCRKey)) {
        NSNumber *radius = nil;
        if ([sublayer respondsToSelector:@selector(cornerRadius)]) {
            radius = @(w26_meshGetCGFloat(sublayer, @selector(cornerRadius)));
        }
        if (radius) {
            objc_setAssociatedObject(sublayer, g_appMeshSavedCRKey, radius,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        NSNumber *masks = nil;
        if ([sublayer respondsToSelector:@selector(masksToBounds)]) {
            masks = @(w26_meshGetBool(sublayer, @selector(masksToBounds)));
        }
        if (masks) {
            objc_setAssociatedObject(sublayer, g_appMeshSavedMTBKey, masks,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        SEL curveSEL = sel_registerName("cornerCurve");
        id curve = w26_meshGetObject(sublayer, curveSEL);
        objc_setAssociatedObject(sublayer, g_appMeshSavedCurveKey,
                                 curve ?: [NSNull null],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void w26_meshApplyOpeningSublayers(id target, CGFloat scalar,
                                          CGFloat progress,
                                          CGFloat savedTargetRadius) {
    NSArray *sublayers = w26_meshSublayers(target);
    if (!sublayers) return;

    CGFloat radius = savedTargetRadius +
                     (scalar - progress) * (350.0 - savedTargetRadius);
    if (progress > 1.0) radius = savedTargetRadius;

    SEL curveSEL = sel_registerName("setCornerCurve:");
    id continuous = @"continuous";
    for (id sublayer in sublayers) {
        w26_meshSaveOpeningSublayerState(sublayer);
        w26_meshSetObject(sublayer, curveSEL, continuous);
        w26_meshSetBool(sublayer, @selector(setMasksToBounds:), YES);
        w26_meshSetCGFloat(sublayer, @selector(setCornerRadius:), radius);
    }

    /* The target itself carries the same clipping state in the recovered
     * branch.  Keeping this explicit is important: it is also the narrowed
     * source of the reported top-edge distortion. */
    w26_meshSetObject(target, curveSEL, continuous);
    w26_meshSetBool(target, @selector(setMasksToBounds:), YES);
    w26_meshSetCGFloat(target, @selector(setCornerRadius:), radius);
}

static void w26_meshRestoreOpeningSublayers(id target) {
    NSArray *sublayers = w26_meshSublayers(target);
    for (id sublayer in sublayers) {
        NSNumber *radius = objc_getAssociatedObject(sublayer, g_appMeshSavedCRKey);
        NSNumber *masks = objc_getAssociatedObject(sublayer, g_appMeshSavedMTBKey);
        id curve = objc_getAssociatedObject(sublayer, g_appMeshSavedCurveKey);

        if (radius) w26_meshSetCGFloat(sublayer, @selector(setCornerRadius:),
                                       radius.doubleValue);
        if (masks) w26_meshSetBool(sublayer, @selector(setMasksToBounds:),
                                   masks.boolValue);
        if (curve) {
            w26_meshSetObject(sublayer, @selector(setCornerCurve:),
                              curve == [NSNull null] ? nil : curve);
        }

        objc_setAssociatedObject(sublayer, g_appMeshSavedCRKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sublayer, g_appMeshSavedMTBKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sublayer, g_appMeshSavedCurveKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

@interface W26MeshDriver : NSObject
@property(nonatomic, weak) id targetLayer;
@property(nonatomic, weak) CADisplayLink *displayLink;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL opening;
@property(nonatomic) BOOL savedTargetState;
@property(nonatomic) BOOL savedTargetMasks;
@property(nonatomic) CGFloat savedTargetRadius;
@property(nonatomic, strong) id savedTargetCurve;
@property(nonatomic, strong) id savedTargetMask;
@property(nonatomic) CGFloat directionX;
@property(nonatomic) CGFloat directionY;
@property(nonatomic) CGFloat state;
@property(nonatomic) NSUInteger holdCounter;
@property(nonatomic) BOOL appliedMesh;
- (instancetype)initWithLayer:(id)layer;
- (void)prepareForTransition:(id)target scalar:(CGFloat)scalar;
- (void)tick:(CADisplayLink *)link;
@end

@implementation W26MeshDriver

- (instancetype)initWithLayer:(id)layer {
    self = [super init];
    if (self) {
        _targetLayer = layer;
        _state = 0.0;
        _holdCounter = 0;
    }
    return self;
}

- (void)prepareForTransition:(id)target scalar:(CGFloat)scalar {
    self.active = YES;
    self.opening = (scalar < 0.5);
    /* Opening starts at the icon-sized aperture and expands; closing starts
     * full-size and contracts.  This is the recovered ±0.15 state envelope. */
    self.state = self.opening ? 1.0 : 0.0;
    self.holdCounter = 0;
    self.appliedMesh = NO;

    self.savedTargetState = [target respondsToSelector:@selector(cornerRadius)];
    if (self.savedTargetState) {
        self.savedTargetRadius = w26_meshGetCGFloat(target, @selector(cornerRadius));
    }
    self.savedTargetMasks = [target respondsToSelector:@selector(masksToBounds)];
    if (self.savedTargetMasks) {
        self.savedTargetMasks = w26_meshGetBool(target, @selector(masksToBounds));
    }

    SEL curveSEL = sel_registerName("cornerCurve");
    self.savedTargetCurve = w26_meshGetObject(target, curveSEL) ?: [NSNull null];

    id mask = w26_meshGetObject(target, @selector(mask));
    id maskName = w26_meshGetObject(mask, @selector(name));
    if ([maskName isKindOfClass:[NSString class]] &&
        [maskName isEqualToString:@"Anim26Mask"]) {
        self.savedTargetMask = mask;
        w26_meshSetObject(target, @selector(setMask:), nil);
    }

    CGPoint direction = w26_meshDirectionForTarget(target, scalar);
    self.directionX = direction.x;
    self.directionY = direction.y;

    CGRect targetBounds = w26_meshGetBounds(target);
    w26_log(@"[appmesh] begin %@ scalar=%.3f opening=%d anchor=(%.1f,%.1f) "
            @"dir=(%.3f,%.3f) bounds=(%.1f,%.1f) surface=%d",
            NSStringFromClass([target class]), scalar,
            (int)self.opening, g_appMeshIconCenter.x, g_appMeshIconCenter.y,
            self.directionX, self.directionY, targetBounds.size.width,
            targetBounds.size.height, (int)w26_meshHasSurfaceSelectors(target));
}

- (void)restoreTrackedIcons {
    if (!g_appMeshGrabberViews) return;
    for (id view in [g_appMeshGrabberViews allObjects]) {
        if ([view respondsToSelector:@selector(setAlpha:)]) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(view,
                                                        @selector(setAlpha:), 1.0);
        }
    }
}

- (void)cleanup {
    id target = self.targetLayer;
    CADisplayLink *link = self.displayLink;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (target) {
        w26_meshSetObject(target, @selector(setMeshTransform:), nil);
        w26_meshSetTransform(target, @selector(setSublayerTransform:),
                             CATransform3DIdentity);
        w26_meshSetBool(target, sel_registerName("setShouldRasterize:"), NO);

        if (self.savedTargetState) {
            w26_meshSetCGFloat(target, @selector(setCornerRadius:),
                               self.savedTargetRadius);
        }
        if ([target respondsToSelector:@selector(setMasksToBounds:)] &&
            self.savedTargetMasks) {
            /* savedTargetMasks is also the original value; see the separate
             * flag below for the case where it was NO. */
        }
        if ([target respondsToSelector:@selector(setMasksToBounds:)]) {
            /* The binary restores the saved BOOL, including NO.  The ivar is
             * split below so a false saved value is not lost to BOOL typing. */
            w26_meshSetBool(target, @selector(setMasksToBounds:),
                            self.savedTargetMasks);
        }
        if (self.savedTargetCurve) {
            w26_meshSetObject(target, @selector(setCornerCurve:),
                              self.savedTargetCurve == [NSNull null]
                              ? nil : self.savedTargetCurve);
        }
        if (self.savedTargetMask) {
            w26_meshSetObject(target, @selector(setMask:), self.savedTargetMask);
        }
        w26_meshRestoreOpeningSublayers(target);
    }
    [CATransaction commit];

    [self restoreTrackedIcons];
    if (self.appliedMesh) {
        w26_log(@"[appmesh] cleanup target=%@ opening=%d",
                target ? NSStringFromClass([target class]) : @"(nil)",
                (int)self.opening);
    }
    if (link) [link invalidate];
    if (target && objc_getAssociatedObject(target, g_appMeshDisplayLinkKey) == link) {
        objc_setAssociatedObject(target, g_appMeshDisplayLinkKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    self.active = NO;
    self.targetLayer = nil;
    self.displayLink = nil;
    self.directionX = 0.0;
    self.directionY = 0.0;
    g_appMeshHasIconCenter = NO;
}

- (void)tick:(CADisplayLink *)link {
    id target = self.targetLayer;
    if (!target) {
        [link invalidate];
        self.displayLink = nil;
        return;
    }

    id presentation = w26_meshGetObject(target, @selector(presentationLayer));
    id source = presentation ?: target;
    CATransform3D transform = w26_meshGetTransform(source);
    CGFloat scalar = transform.m11;
    if (!isfinite(scalar)) {
        [self cleanup];
        return;
    }

    if (!self.active) {
        if (!(scalar > 0.01 && scalar < 0.995)) return;
        [self prepareForTransition:target scalar:scalar];
    } else if (scalar <= 0.01 || scalar >= 0.995) {
        [self cleanup];
        return;
    }

    CGFloat progress = (scalar - 0.05) / 0.94;
    if (progress < 0.0) progress = 0.0;

    if (self.opening) {
        self.state = MAX(0.0, self.state - 0.15);
    } else {
        self.state = MIN(1.0, self.state + 0.15);
    }

    CGFloat phase = progress * (CGFloat)M_PI;
    CGFloat bulge = 0.25 * sin(phase) * self.state;
    if (!isfinite(bulge) || bulge < 0.001) {
        [self cleanup];
        return;
    }

    id mesh = nil;
    @try {
        mesh = w26_meshCreateBulgedMesh(bulge, -self.directionX,
                                        -self.directionY);
    } @catch (NSException *exception) {
        w26_log(@"[appmesh] mesh factory exception %@: %@",
                exception.name, exception.reason);
        w26_enterAppTransitionSafeMode("CAMeshTransform factory exception");
        [self cleanup];
        return;
    }
    if (!mesh) {
        [self cleanup];
        return;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    w26_meshSetObject(target, @selector(setMeshTransform:), mesh);
    CGFloat scale = MAX(0.1, 1.0 - 1.2 * self.state);
    w26_meshSetTransform(target, @selector(setSublayerTransform:),
                         CATransform3DMakeScale(scale, scale, 1.0));
    w26_meshSetBool(target, sel_registerName("setShouldRasterize:"), YES);

    if (!self.appliedMesh) {
        self.appliedMesh = YES;
        w26_log(@"[appmesh] APPLY target=%@ opening=%d scalar=%.3f "
                @"progress=%.3f state=%.3f bulge=%.3f dir=(%.3f,%.3f) "
                @"openingMask=%d",
                NSStringFromClass([target class]), (int)self.opening, scalar,
                progress, self.state, bulge, self.directionX, self.directionY,
                (int)(self.opening && g_cfgAppMeshOpeningMask));
    }

    if (self.opening && g_cfgAppMeshOpeningMask) {
        w26_meshApplyOpeningSublayers(target, scalar, progress,
                                      self.savedTargetRadius);
    }
    [CATransaction commit];

    if (self.opening && g_cfgAppMeshHideIcons && g_appMeshGrabberViews) {
        for (id view in [g_appMeshGrabberViews allObjects]) {
            if ([view respondsToSelector:@selector(setAlpha:)]) {
                ((void (*)(id, SEL, CGFloat))objc_msgSend)(view,
                                                            @selector(setAlpha:),
                                                            0.0);
            }
        }
    }
}

@end

static id w26_meshTargetForObject(id object) {
    if (!object) return nil;

    if (w26_meshHasSurfaceSelectors(object)) {
        if (g_appMeshTransformCallCount <= 8) {
            w26_log(@"[appmesh] target=object %@ (native transition surface)",
                    NSStringFromClass([object class]));
        }
        return object;
    }

    if (g_cfgAppMeshLayerFallback && [object respondsToSelector:@selector(layer)]) {
        id layer = w26_meshGetObject(object, @selector(layer));
        if (w26_meshHasSurfaceSelectors(layer)) {
            if (g_appMeshTransformCallCount <= 8) {
                w26_log(@"[appmesh] target=layer %@ for object %@ (fallback)",
                        NSStringFromClass([layer class]),
                        NSStringFromClass([object class]));
            }
            return layer;
        }
    }

    if (g_appMeshTransformCallCount <= 8) {
        w26_log(@"[appmesh] target unavailable for %@ (fallback=%d)",
                NSStringFromClass([object class]),
                (int)g_cfgAppMeshLayerFallback);
    }
    return nil;
}

static BOOL w26_meshDelegateIsEligible(id object) {
    id delegate = w26_meshGetObject(object, @selector(delegate));
    if (!delegate) return NO;

    Class allowed[3] = {
        NSClassFromString(@"SBCrossfadeView"),
        NSClassFromString(@"SBFullscreenZoomView"),
        NSClassFromString(@"SBReusableSnapshotItemContainer")
    };
    BOOL match = NO;
    for (NSUInteger i = 0; i < 3; i++) {
        if (allowed[i] && ([delegate isKindOfClass:allowed[i]] ||
                           [delegate class] == allowed[i])) {
            match = YES;
            break;
        }
    }
    return match;
}

static void w26_meshStartForTarget(id target, double scalar) {
    if (!target || !g_cfgAppZoom || !g_cfgAppMesh) return;
    w26_loadSettings();
    if (!g_cfgAppZoom || !g_cfgAppMesh) return;

    if (!NSClassFromString(@"CAMeshTransform")) {
        if (!g_appMeshLoggedUnavailable) {
            g_appMeshLoggedUnavailable = YES;
            w26_log(@"[appmesh] CAMeshTransform unavailable; hook stays inert on this iOS");
        }
        return;
    }

    id existing = w26_meshDisplayLinkOnChain(target);
    if (existing) return;

    W26MeshDriver *driver = [[W26MeshDriver alloc] initWithLayer:target];
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:driver
                                                        selector:@selector(tick:)];
    if (!link) return;

    driver.displayLink = link;
    objc_setAssociatedObject(target, g_appMeshDisplayLinkKey, link,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if ([link respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        NSInteger fps = [UIScreen mainScreen].maximumFramesPerSecond;
        if (fps < 60) fps = 60;
        if (fps > 120) fps = 120;
        link.preferredFramesPerSecond = fps;
    }
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    w26_log(@"[appmesh] display link installed target=%@ scalar=%.3f",
            NSStringFromClass([target class]), scalar);
}

static void w26_meshObserveTransform(id object, double scalar) {
    if (!g_cfgAppZoom || !g_cfgAppMesh || !object) return;

    NSUInteger call = ++g_appMeshTransformCallCount;
    w26_meshLogRuntimeShape(object, call);

    BOOL eligible = w26_meshDelegateIsEligible(object);
    if (!eligible) {
        if (call <= 8) {
            w26_log(@"[appmesh] reject #%lu: delegate %@ is not one of "
                    @"SBCrossfadeView/SBFullscreenZoomView/"
                    @"SBReusableSnapshotItemContainer",
                    (unsigned long)call, w26_meshDelegateClassName(object));
        }
        return;
    }

    CGRect bounds = w26_meshGetBounds(object);
    if (bounds.size.width <= 200.0 || bounds.size.height <= 400.0) {
        if (call <= 8) {
            w26_log(@"[appmesh] reject #%lu: bounds too small %.1fx%.1f",
                    (unsigned long)call, bounds.size.width, bounds.size.height);
        }
        return;
    }

    id target = w26_meshTargetForObject(object);
    if (!target) return;
    w26_meshStartForTarget(target, scalar);
}

static void w26_iconSetHighlighted(id self, SEL _cmd, BOOL highlighted) {
    if (w26_orig_iconSetHighlighted) {
        ((void (*)(id, SEL, BOOL))w26_orig_iconSetHighlighted)(self, _cmd,
                                                               highlighted);
    }
    if (!highlighted || !g_cfgAppZoom || !g_cfgAppMesh) return;

    id window = w26_meshGetObject(self, @selector(window));
    if (!window || ![self respondsToSelector:@selector(convertRect:toView:)]) return;
    CGRect bounds = w26_meshGetBounds(self);
    CGRect inWindow = ((CGRect (*)(id, SEL, CGRect, id))objc_msgSend)(
        self, @selector(convertRect:toView:), bounds, window);
    g_appMeshIconCenter = CGPointMake(CGRectGetMidX(inWindow),
                                      CGRectGetMidY(inWindow));
    g_appMeshHasIconCenter = YES;
    /* Start a fresh bounded diagnostic window for this launch/close gesture;
     * normal home-layout transforms before the tap must not consume it. */
    g_appMeshTransformCallCount = 0;
    g_appMeshRuntimeShapeLogCount = 0;
    w26_log(@"[appmesh] highlighted anchor=(%.1f,%.1f) iconRectInWindow=%@ "
            @"window=%@ windowBounds=%@",
            g_appMeshIconCenter.x, g_appMeshIconCenter.y,
            NSStringFromCGRect(inWindow), NSStringFromClass([window class]),
            NSStringFromCGRect(window.bounds));
}

static void w26_iconDidMoveToWindow(id self, SEL _cmd) {
    if (w26_orig_iconDidMoveToWindow) {
        ((void (*)(id, SEL))w26_orig_iconDidMoveToWindow)(self, _cmd);
    }
    if (!g_appMeshGrabberViews) {
        g_appMeshGrabberViews = [NSHashTable weakObjectsHashTable];
    }
    id window = w26_meshGetObject(self, @selector(window));
    if (window) [g_appMeshGrabberViews addObject:self];
}

static void w26_iconSetTransform3D(id self, SEL _cmd, CATransform3D transform) {
    if (w26_orig_iconSetTransform3D) {
        ((void (*)(id, SEL, CATransform3D))w26_orig_iconSetTransform3D)(
            self, _cmd, transform);
    }
    w26_meshObserveTransform(self, transform.m11);
}

static void w26_iconSetTransformAffine(id self, SEL _cmd,
                                       CGAffineTransform transform) {
    if (w26_orig_iconSetTransformAffine) {
        ((void (*)(id, SEL, CGAffineTransform))w26_orig_iconSetTransformAffine)(
            self, _cmd, transform);
    }
    w26_meshObserveTransform(self, transform.a);
}

static BOOL w26_installAppMeshHooks(void) {
    if (!g_iconClass) g_iconClass = NSClassFromString(@"SBIconView");
    Class cls = g_iconClass;
    if (!cls) {
        w26_log(@"[appmesh] SBIconView unavailable");
        return NO;
    }

    Class meshClass = NSClassFromString(@"CAMeshTransform");
    SEL meshFactory = sel_registerName(
        "meshTransformWithVertexCount:vertices:faceCount:faces:depthNormalization:");
    w26_log(@"[appmesh] runtime meshClass=%@ factory=%d fallback=%d mask=%d",
            meshClass ? NSStringFromClass(meshClass) : @"(nil)",
            (int)(meshClass && [meshClass respondsToSelector:meshFactory]),
            (int)g_cfgAppMeshLayerFallback, (int)g_cfgAppMeshOpeningMask);

    BOOL highlighted = w26_swizzle(cls, @selector(setHighlighted:),
                                   (IMP)w26_iconSetHighlighted,
                                   &w26_orig_iconSetHighlighted);
    BOOL moved = w26_swizzle(cls, @selector(didMoveToWindow),
                             (IMP)w26_iconDidMoveToWindow,
                             &w26_orig_iconDidMoveToWindow);

    Method transformMethod = class_getInstanceMethod(cls, @selector(setTransform:));
    BOOL transform = NO;
    if (transformMethod && method_getNumberOfArguments(transformMethod) == 3) {
        char *argType = method_copyArgumentType(transformMethod, 2);
        const char *encoding = argType ?: "";
        NSUInteger doubleCount = 0;
        for (const char *p = encoding; *p; p++) {
            if (*p == 'd') doubleCount++;
        }

        if (strstr(encoding, "CATransform3D") || doubleCount >= 12) {
            transform = w26_swizzle(cls, @selector(setTransform:),
                                    (IMP)w26_iconSetTransform3D,
                                    &w26_orig_iconSetTransform3D);
            w26_log(@"[appmesh] SBIconView setTransform: ABI=CATransform3D");
        } else if (strstr(encoding, "CGAffineTransform") || doubleCount >= 4) {
            transform = w26_swizzle(cls, @selector(setTransform:),
                                    (IMP)w26_iconSetTransformAffine,
                                    &w26_orig_iconSetTransformAffine);
            w26_log(@"[appmesh] SBIconView setTransform: ABI=CGAffineTransform");
        } else {
            w26_log(@"[appmesh] setTransform: ABI not recognized (%s)", encoding);
        }
        if (argType) free(argType);
    }

    g_appMeshHooksInstalled = highlighted && moved && transform;
    w26_log(@"[appmesh] hooks highlighted=%d moved=%d transform=%d "
            @"mesh=%d fallback=%d delegates="
            @"SBCrossfadeView/SBFullscreenZoomView/SBReusableSnapshotItemContainer",
            (int)highlighted, (int)moved, (int)transform,
            (int)g_cfgAppMesh, (int)g_cfgAppMeshLayerFallback);
    return g_appMeshHooksInstalled;
}

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

/* Remove only the fade.  SpringBoard's own dock animation must survive:
 * it is what brings the dock back from its pre-reveal position. */
static void w26_stripFade(UIView *view) {
    if (!view) return;
    CALayer *l = view.layer;
    if (!l) return;

    for (NSString *k in [[l animationKeys] copy]) {
        if ([k hasPrefix:@"wave26."]) continue;
        CAAnimation *anim = [l animationForKey:k];
        NSString *path = [anim isKindOfClass:[CAPropertyAnimation class]]
                       ? [(CAPropertyAnimation *)anim keyPath] : nil;
        if ([path isEqualToString:@"opacity"]) {
            [l removeAnimationForKey:k];
        }
    }
    if (view.alpha < 1.0) {
        w26_log(@"  dock: alpha %.2f -> 1.00 (was fading in)", view.alpha);
        view.alpha = 1.0;
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
    /* NC is the timing reference.  Only the lock-screen unlock path receives
     * the small compensation for SpringBoard's concurrent dock reveal. */
    W26DockSpeed = g_unlockConfirmed ? g_cfgDockUnlockSpeed : 1.0;
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
            @"cfg(delay=%.2f settle=%d scaleComp=%d waveSpeed=%.2f "
             @"dockSpeed=%.2f guard=%.2f)",
            (g_requestedAt > 0 ? now - g_requestedAt : -1.0),
            (g_unlockedAt > 0 ? now - g_unlockedAt : -1.0),
            (g_lockScreenDismissed > 0 ? now - g_lockScreenDismissed : -1.0),
            g_cfgUnlockDelay, (int)g_cfgWaitSettle, (int)g_cfgScaleComp,
            W26WaveSpeed, W26DockSpeed, g_cfgGuard);

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

    if (dock) {
        CALayer *dl = dock.layer;
        CGPoint dm = dl ? dl.position : CGPointZero;
        CGPoint dp = dl ? [[dl presentationLayer] position] : CGPointZero;
        CGRect  dr = [dock convertRect:dock.bounds toView:nil];
        CGRect  sb = [UIScreen mainScreen].bounds;
        w26_log(@"probe dock: model=(%.1f,%.1f) pres=(%.1f,%.1f) alpha=%.2f "
                @"windowMid=(%.1f,%.1f) onScreen=%d (screen h=%.0f)",
                dm.x, dm.y, dp.x, dp.y, dock.alpha,
                CGRectGetMidX(dr), CGRectGetMidY(dr),
                (int)CGRectIntersectsRect(dr, sb), sb.size.height);
    } else {
        w26_log(@"probe dock: NOT FOUND");
    }

    w26_registerHome(icons, dock);

    w26_probe(icons);

    for (UIView *view in icons) w26_stripIcon(view);
    if (dock) w26_stripFade(dock);      /* keep SpringBoard's dock motion */

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
    g_appZoomFlow      = NO;
    g_appZoomPlayed    = NO;
    w26_appZoomTeardown();
    g_appZoomBundleID  = nil;
    g_appZoomSceneID   = nil;
    g_appZoomApplication = nil;
    g_appZoomScene     = nil;
    w26_log(@"cycle armed (%s) id=%llu", why, (unsigned long long)g_cycleID);
}

static void w26_retry(int attempt, uint64_t cycle, const char *reason) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kW26RetryInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        w26_waitAndPlay(attempt + 1, cycle, reason);
    });
}

/* ------------------------------------------------------------------ */
#pragma mark - unlock into a running app: quick zoom-out + clearing blur
/* ------------------------------------------------------------------ */

/* SpringBoard does not own the app's UIKit view hierarchy, but it does host
 * the app's remote CAContext.  Path B transforms that existing host, so the
 * running app itself zooms; no screen snapshot or image handover is involved. */

/* Path B does not create a screenshot.  The running app is a remote
 * CAContext, hosted by SpringBoard through a view such as SBAppView or
 * FBSceneHostWrapperView.  Find that existing host and animate its layer.
 * If the host cannot be identified, we deliberately do nothing rather than
 * revive the old full-screen snapshot path (which is the source of ghosting).
 */

static id w26_msg(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *w26_bundleIDOfObject(id object) {
    id bid = w26_msg(object, @selector(bundleIdentifier));
    return [bid isKindOfClass:[NSString class]] ? bid : nil;
}

static NSString *w26_sceneIDOfObject(id object) {
    id ident = w26_msg(object, @selector(identifier));
    return [ident isKindOfClass:[NSString class]] ? ident : nil;
}

static BOOL w26_appObjectMatchesTarget(id object) {
    if (!object) return NO;
    if (object == g_appZoomApplication) return YES;
    NSString *bid = w26_bundleIDOfObject(object);
    return (g_appZoomBundleID.length && [bid isEqualToString:g_appZoomBundleID]);
}

static BOOL w26_sceneObjectMatchesTarget(id object) {
    if (!object) return NO;
    if (object == g_appZoomScene) return YES;
    NSString *ident = w26_sceneIDOfObject(object);
    return (g_appZoomSceneID.length && [ident isEqualToString:g_appZoomSceneID]);
}

/* Walk the responder chain as well as the view tree.  SBAppView's responder
 * is normally SBAppViewController, which implements -hostedApp; a
 * FBSceneHostWrapperView instead exposes -scene. */
static BOOL w26_viewBelongsToTargetApp(UIView *view) {
    id responder = view;
    SEL hostedSEL = sel_registerName("hostedApp");
    SEL applicationSEL = sel_registerName("application");
    SEL sceneSEL = sel_registerName("scene");

    for (int i = 0; responder && i < 12; i++) {
        id hosted = w26_msg(responder, hostedSEL);
        if (w26_appObjectMatchesTarget(hosted)) return YES;

        id application = w26_msg(responder, applicationSEL);
        if (w26_appObjectMatchesTarget(application)) return YES;

        id scene = w26_msg(responder, sceneSEL);
        if (w26_sceneObjectMatchesTarget(scene)) return YES;

        if (![responder respondsToSelector:@selector(nextResponder)]) break;
        id next = [responder nextResponder];
        if (next == responder) break;
        responder = next;
    }
    return NO;
}

static int w26_hostScore(UIView *view) {
    NSString *name = NSStringFromClass([view class]);
    if ([name isEqualToString:@"FBSceneHostWrapperView"] ||
        [name containsString:@"SceneHostWrapper"]) return 120;
    if ([name containsString:@"FBSceneHost"]) return 110;
    if ([name isEqualToString:@"SBAppView"] ||
        [name containsString:@"SBAppView"]) return 100;
    if ([name containsString:@"HostWrapper"]) return 80;
    if ([name containsString:@"HostView"]) return 70;
    return 0;
}

static void w26_scanHostTree(UIView *view, UIView **best, int *bestScore,
                             NSUInteger *visited, NSUInteger *candidateCount) {
    if (!view || *visited >= 6000) return;
    (*visited)++;

    int score = w26_hostScore(view);
    if (score > 0) {
        (*candidateCount)++;
        BOOL match = w26_viewBelongsToTargetApp(view);
        if (*candidateCount <= 12) {
            w26_log(@"[appzoom:host] candidate %@ match=%d frame=%@",
                    NSStringFromClass([view class]), (int)match,
                    NSStringFromCGRect(view.frame));
        }
        if (match && score > *bestScore) {
            *best = view;
            *bestScore = score;
        }
    }

    for (UIView *child in view.subviews) {
        w26_scanHostTree(child, best, bestScore, visited, candidateCount);
        if (*visited >= 6000) break;
    }
}

static UIView *w26_findAppHostView(void) {
    if (!g_appZoomBundleID.length) return nil;

    UIView *best = nil;
    int bestScore = 0;
    NSUInteger visited = 0;
    NSUInteger candidates = 0;

    for (UIWindow *window in w26_allWindows()) {
        if (window == g_zoomWindow || window.hidden || window.alpha < 0.01) continue;
        UIView *root = window.rootViewController.view;
        if (root) {
            w26_scanHostTree(root, &best, &bestScore, &visited, &candidates);
        }
    }

    w26_log(@"[appzoom:host] scan app=%@ scene=%@ windows=%lu "
            @"visited=%lu candidates=%lu best=%@ score=%d",
            g_appZoomBundleID, g_appZoomSceneID,
            (unsigned long)w26_allWindows().count,
            (unsigned long)visited, (unsigned long)candidates,
            best ? NSStringFromClass([best class]) : @"(none)", bestScore);
    return best;
}

static void w26_appZoomHostRestore(void) {
    if (!g_appZoomHost) {
        g_appZoomHostPrepared = NO;
        return;
    }

    CALayer *layer = g_appZoomHost.layer;
    [layer removeAnimationForKey:@"wave26.appzoom.host"];
    if (g_appZoomHostPrepared) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.transform = g_appZoomHostBaseTransform;
        [CATransaction commit];
    }
    if (g_appZoomHostExternal && g_appZoomHostManager &&
        g_appZoomHostRequester.length) {
        SEL disableSEL = sel_registerName("disableHostingForRequester:");
        if ([g_appZoomHostManager respondsToSelector:disableSEL]) {
            void (*disable)(id, SEL, NSString *) =
                (void (*)(id, SEL, NSString *))objc_msgSend;
            disable(g_appZoomHostManager, disableSEL, g_appZoomHostRequester);
        }
    }
    if (g_appZoomHostExternal) {
        [g_appZoomHost removeFromSuperview];
        if (g_zoomWindow && !g_zoomSnap && !g_zoomBlurHost) {
            g_zoomWindow.hidden = YES;
            g_zoomWindow = nil;
        }
    }
    w26_log(@"[appzoom:host] restored %@", NSStringFromClass([g_appZoomHost class]));
    g_appZoomHost = nil;
    g_appZoomHostPrepared = NO;
    g_appZoomHostCycle = 0;
    g_appZoomHostExternal = NO;
    g_appZoomHostManager = nil;
    g_appZoomHostRequester = nil;
}

static UIWindow *w26_makeLiveHostWindow(void) {
    CGRect bounds = [UIScreen mainScreen].bounds;
    UIWindow *window = nil;
    UIWindowScene *scene = nil;

    for (UIScene *sc in [[UIApplication sharedApplication] connectedScenes]) {
        if ([sc isKindOfClass:[UIWindowScene class]]) {
            scene = (UIWindowScene *)sc;
            break;
        }
    }
    if (scene && [UIWindow instancesRespondToSelector:@selector(initWithWindowScene:)]) {
        window = [[UIWindow alloc] initWithWindowScene:scene];
    }
    if (!window) window = [[UIWindow alloc] initWithFrame:bounds];

    double level = (g_coverWindowLevel > 1.0)
                 ? (g_coverWindowLevel - 1.0) : 100.0;
    window.frame = bounds;
    window.windowLevel = level;
    window.backgroundColor = [UIColor clearColor];
    window.userInteractionEnabled = NO;
    window.hidden = NO;
    return window;
}

static UIView *w26_requestExternalHost(void) {
    if (!g_appZoomScene) {
        w26_log(@"[appzoom:host] no target FBScene");
        return nil;
    }

    id manager = w26_msg(g_appZoomScene, @selector(contextHostManager));
    SEL hostSEL = sel_registerName("hostViewForRequester:enableAndOrderFront:");
    if (!manager || ![manager respondsToSelector:hostSEL]) {
        w26_log(@"[appzoom:host] context host manager unavailable (%@)",
                manager ? NSStringFromClass([manager class]) : @"(none)");
        return nil;
    }

    NSString *requester = @"com.blu-tek.26Unlock.pathB";
    UIView *(*call)(id, SEL, NSString *, BOOL) =
        (UIView *(*)(id, SEL, NSString *, BOOL))objc_msgSend;
    UIView *host = call(manager, hostSEL, requester, NO);
    if (!host) {
        w26_log(@"[appzoom:host] hostViewForRequester returned nil");
        return nil;
    }

    g_appZoomHostManager = manager;
    g_appZoomHostRequester = [requester copy];
    g_appZoomHostExternal = YES;
    w26_log(@"[appzoom:host] external host %@ manager=%@ super=%@",
            NSStringFromClass([host class]), NSStringFromClass([manager class]),
            host.superview ? NSStringFromClass([host.superview class]) : @"(none)");

    /* If the manager returned an unattached wrapper, put the live remote
     * surface in our transparent window. This is still Path B: no bitmap is
     * created and the app keeps rendering through its CAContext. */
    if (!host.superview) {
        UIWindow *window = w26_makeLiveHostWindow();
        if (!window) return nil;
        host.frame = window.bounds;
        host.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [window addSubview:host];
        g_zoomWindow = window;
    }
    return host;
}

static BOOL w26_appZoomHostPrepare(void) {
    if (!g_appZoomFlow || !g_cfgAppZoomDirect) return NO;
    if (g_appZoomHostPrepared && g_appZoomHost &&
        g_appZoomHostCycle == g_cycleID) return YES;

    UIView *host = w26_findAppHostView();
    if (!host) host = w26_requestExternalHost();
    if (!host) return NO;

    if (g_appZoomHost && g_appZoomHost != host) w26_appZoomHostRestore();

    CALayer *layer = host.layer;
    g_appZoomHost = host;
    g_appZoomHostBaseTransform = layer.transform;

    CATransform3D start = CATransform3DConcat(
        g_appZoomHostBaseTransform,
        CATransform3DMakeScale(g_cfgAppZoomScale, g_cfgAppZoomScale, 1.0));

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.transform = start;
    [CATransaction commit];

    g_appZoomHostPrepared = YES;
    g_appZoomHostCycle = g_cycleID;
    w26_log(@"[appzoom:host] prepared %@ frame=%@ scale=%.3f",
            NSStringFromClass([host class]), NSStringFromCGRect(host.frame),
            g_cfgAppZoomScale);
    return YES;
}

static void w26_appZoomHostAnimate(void) {
    if (!g_appZoomHostPrepared || !g_appZoomHost) return;

    CALayer *layer = g_appZoomHost.layer;
    CATransform3D start = layer.transform;
    CATransform3D base = g_appZoomHostBaseTransform;

    CASpringAnimation *spring =
        [CASpringAnimation animationWithKeyPath:@"transform"];
    spring.fromValue = [NSValue valueWithCATransform3D:start];
    spring.toValue = [NSValue valueWithCATransform3D:base];
    spring.damping = g_cfgAppZoomDamp;
    spring.stiffness = g_cfgAppZoomStiff;
    spring.mass = g_cfgAppZoomMassV;
    spring.initialVelocity = 0.0;
    spring.duration = g_cfgAppZoomDur;
    spring.fillMode = kCAFillModeBackwards;
    spring.removedOnCompletion = YES;
    [layer addAnimation:spring forKey:@"wave26.appzoom.host"];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.transform = base;
    [CATransaction commit];

    w26_log(@"[appzoom:host] play: %@ scale=%.3f dur=%.3f "
            @"spring(damp=%.0f stiff=%.0f mass=%.1f)",
            NSStringFromClass([g_appZoomHost class]), g_cfgAppZoomScale,
            g_cfgAppZoomDur, g_cfgAppZoomDamp, g_cfgAppZoomStiff,
            g_cfgAppZoomMassV);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)((g_cfgAppZoomDur + 0.08) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (g_appZoomHost) {
            [g_appZoomHost.layer removeAnimationForKey:@"wave26.appzoom.host"];
            w26_log(@"[appzoom:host] done");
        }
        g_appZoomHostPrepared = NO;
        g_appZoomHost = nil;
        g_appZoomHostCycle = 0;
    });
}

static void w26_appZoomHostAttempt(int attempt, uint64_t cycle) {
    if (cycle != g_cycleID || !g_appZoomFlow || g_appZoomPlayed) return;

    if (!w26_appZoomHostPrepare()) {
        if (attempt == 0) w26_probeAppHost();
        if (attempt == 0 || attempt == 5 || attempt == 10 || attempt == 19) {
            w26_log(@"[appzoom:host] not found, retry=%d", attempt);
        }
        if (attempt < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                            (int64_t)(kW26RetryInterval * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                w26_appZoomHostAttempt(attempt + 1, cycle);
            });
            return;
        }

        g_appZoomPlayed = YES;
        w26_log(@"[appzoom:host] unavailable after retries - no snapshot fallback");
        if (g_cfgAppZoomHostFallback) {
            w26_log(@"[appzoom:host] fallback requested; using legacy screen path");
            g_cfgAppZoomDirect = NO;
            g_appZoomPlayed = NO;
            w26_appZoomPlay();
        }
        return;
    }

    g_appZoomPlayed = YES;
    w26_appZoomHostAnimate();
}

/* Log-only fallback probe.  It remains useful when the direct host cannot be
 * found, but the actual Path B resolver above is the code that animates. */
static void w26_probeAppHost(void) {
    id (*msg)(id, SEL) = (id (*)(id, SEL))objc_msgSend;

    for (UIWindow *w in w26_allWindows()) {
        w26_log(@"probe win: %@ level=%.0f hidden=%d alpha=%.2f",
                NSStringFromClass([w class]), w.windowLevel,
                (int)w.hidden, w.alpha);
    }

    id mgr = [NSClassFromString(@"FBSceneManager") sharedInstance];
    if (!mgr) mgr = [NSClassFromString(@"SBSceneManager") sharedInstance];
    if (!mgr) {
        w26_log(@"probe scene: no scene manager");
        return;
    }

    NSArray *scenes = nil;
    if ([mgr respondsToSelector:@selector(allScenes)]) {
        scenes = msg(mgr, @selector(allScenes));
    }
    w26_log(@"probe scene manager: %@ scenes=%lu",
            NSStringFromClass([mgr class]), (unsigned long)scenes.count);

    for (id sc in scenes) {
        NSString *ident = [sc respondsToSelector:@selector(identifier)]
                        ? msg(sc, @selector(identifier)) : nil;
        id host = [sc respondsToSelector:@selector(contextHostManager)]
                ? msg(sc, @selector(contextHostManager)) : nil;
        w26_log(@"probe scene: %@ id=%@ host=%@",
                NSStringFromClass([sc class]), ident,
                host ? NSStringFromClass([host class]) : @"(none)");
    }
}

static void w26_appZoomTeardown(void) {
    w26_appZoomHostRestore();
    if (!g_zoomWindow) return;
    g_zoomWindow.hidden = YES;
    [g_zoomSnap removeFromSuperview];
    [g_zoomBlurHost removeFromSuperview];
    g_zoomSnap = nil;
    g_zoomBlurHost = nil;
    g_zoomWindow = nil;
}

static void w26_appZoomBegin(void) {
    if (g_cfgAppZoomDirect) return;
    if (g_zoomWindow) return;

    CGRect b = [UIScreen mainScreen].bounds;
    if (CGRectIsEmpty(b)) return;

    double level = g_cfgAppZoomLevel;
    if (level <= 0.0) {
        level = (g_coverWindowLevel > 1.0) ? (g_coverWindowLevel - 1.0) : 100.0;
    }

    UIWindow *w = nil;
    UIWindowScene *scene = nil;
    for (UIScene *sc in [[UIApplication sharedApplication] connectedScenes]) {
        if ([sc isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)sc; break; }
    }
    if (scene && [UIWindow instancesRespondToSelector:@selector(initWithWindowScene:)]) {
        w = [[UIWindow alloc] initWithWindowScene:scene];
    }
    if (!w) w = [[UIWindow alloc] initWithFrame:b];

    w.frame = b;
    w.windowLevel = level;
    w.backgroundColor = [UIColor clearColor];
    w.userInteractionEnabled = NO;
    w.hidden = NO;
    g_zoomWindow = w;

    /* The blur sits in its own host view: animating a UIVisualEffectView's
     * own alpha is unreliable, animating its container is not. */
    UIView *host = [[UIView alloc] initWithFrame:b];
    host.backgroundColor = [UIColor clearColor];
    if (g_cfgAppZoomBlur) {
        UIBlurEffect *fx =
            [UIBlurEffect effectWithStyle:(UIBlurEffectStyle)g_cfgAppZoomStyle];
        UIVisualEffectView *fxv = [[UIVisualEffectView alloc] initWithEffect:fx];
        fxv.frame = b;
        fxv.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host addSubview:fxv];
    }
    [w addSubview:host];
    g_zoomBlurHost = host;

    w26_log(@"[appzoom] blur up (level=%.0f style=%d)", level, g_cfgAppZoomStyle);
}

static void w26_appZoomPlay(void) {
    if (!g_appZoomFlow || g_appZoomPlayed) return;

    /* Re-read the settings here too: this path never goes through w26_fire,
     * so without this every AppZoom* knob needed a respring. */
    w26_loadSettings();

    /* Path B: transform the live app host.  Do not create a screen snapshot;
     * the old path is retained only as an explicit diagnostic fallback. */
    if (g_cfgAppZoomDirect) {
        w26_appZoomHostAttempt(0, g_cycleID);
        return;
    }

    g_appZoomPlayed = YES;
    CGRect b = [UIScreen mainScreen].bounds;
    if (CGRectIsEmpty(b)) { w26_appZoomTeardown(); return; }

    /* Give the leaving lock screen one frame, then capture the app.  The
     * blur must not be on screen while doing so or it gets baked in. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                (int64_t)(g_cfgAppZoomDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!g_appZoomFlow) return;

        /* Is the lock screen really gone?  If it is still around the snapshot
         * is of the LOCK SCREEN, and zooming that is the flicker. */
        {
            BOOL sheetStillUp = NO;
            for (UIWindow *cw in w26_allWindows()) {
                if (cw.hidden || cw.alpha < 0.01) continue;
                if (g_coverWindowLevel > 1.0 &&
                    cw.windowLevel >= g_coverWindowLevel - 1.0) {
                    sheetStillUp = YES;
                }
            }
            w26_log(@"[appzoom] snapshot: lockScreenStillUp=%d", (int)sheetStillUp);
            w26_probeAppHost();
        }

        BOOL wasVisible = (g_zoomWindow != nil);
        if (wasVisible) g_zoomWindow.hidden = YES;

        /* Any part of the lock screen still on screen gets baked into the
         * snapshot, and zooming THAT is the flicker.  Hide it for the one
         * frame the capture needs, then put it straight back. */
        NSMutableArray *hidden = [NSMutableArray array];
        if (g_cfgAppZoomHide && g_coverWindowLevel > 1.0) {
            for (UIWindow *cw in w26_allWindows()) {
                if (!cw.hidden && cw.windowLevel >= g_coverWindowLevel - 1.0) {
                    cw.hidden = YES;
                    [hidden addObject:cw];
                    w26_log(@"[appzoom] hiding %@ (level=%.0f)",
                            NSStringFromClass([cw class]), cw.windowLevel);
                }
            }
        }

        /* NO would hand back the PREVIOUS commit - i.e. the frame from
         * before the lock screen was hidden, which is exactly the ghost
         * left over the keyboard.  YES renders the current state. */
        UIView *snap = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (g_cfgAppZoomNow) {
            snap = [[UIScreen mainScreen] snapshotViewAfterScreenUpdates:YES];
        }
        if (!snap) {
            snap = [[UIScreen mainScreen] snapshotViewAfterScreenUpdates:NO];
        }
#pragma clang diagnostic pop

        for (UIWindow *cw in hidden) cw.hidden = NO;
        if (hidden.count) {
            w26_log(@"[appzoom] hid %lu lock-screen window(s) for the capture",
                    (unsigned long)hidden.count);
        }
        w26_log(@"[appzoom] capture: mode=%s ok=%d",
                g_cfgAppZoomNow ? "current(YES)" : "previous(NO)", (int)(snap != nil));

        if (wasVisible && g_zoomWindow) g_zoomWindow.hidden = NO;

        if (!snap) {
            w26_log(@"[appzoom] snapshot failed - zoom skipped");
            w26_appZoomTeardown();
            return;
        }

        if (!g_zoomWindow) w26_appZoomBegin();
        if (!g_zoomWindow) return;

        snap.frame = b;
        [g_zoomWindow insertSubview:snap belowSubview:g_zoomBlurHost];
        g_zoomSnap = snap;

        w26_log(@"[appzoom] play: scale=%.3f dur=%.3f blur=%d "
                @"spring(damp=%.0f stiff=%.0f mass=%.1f)",
                g_cfgAppZoomScale, g_cfgAppZoomDur, (int)g_cfgAppZoomBlur,
                g_cfgAppZoomDamp, g_cfgAppZoomStiff, g_cfgAppZoomMassV);

        void (^w26_runZoom)(void) = ^{
            /* "Bounce in from outside, never spring back": a critically
             * damped spring - fast start, long smooth settle, no overshoot.
             * damping > 2*sqrt(stiffness*mass) is what removes the bounce. */
            CATransform3D from =
                CATransform3DMakeScale(g_cfgAppZoomScale, g_cfgAppZoomScale, 1.0);

            CASpringAnimation *spring =
                [CASpringAnimation animationWithKeyPath:@"transform"];
            spring.fromValue = [NSValue valueWithCATransform3D:from];
            spring.toValue   = [NSValue valueWithCATransform3D:CATransform3DIdentity];
            spring.damping   = g_cfgAppZoomDamp;
            spring.stiffness = g_cfgAppZoomStiff;
            spring.mass      = g_cfgAppZoomMassV;
            spring.initialVelocity = 0.0;
            spring.duration  = g_cfgAppZoomDur;
            spring.fillMode  = kCAFillModeBackwards;
            spring.removedOnCompletion = YES;
            [snap.layer addAnimation:spring forKey:@"wave26.appzoom"];

            /* Commit the model value so removing it cannot pop. */
            snap.layer.transform = CATransform3DIdentity;

            /* The blur HOLDS while the app is still flying in, then clears
             * over the last 60% - fading it from frame one is what made it
             * look like a plain zoom with a flash of frosting on top. */
            [UIView animateWithDuration:g_cfgAppZoomDur * 0.6
                                  delay:g_cfgAppZoomDur * 0.4
                                options:UIViewAnimationOptionCurveEaseIn
                             animations:^{
                g_zoomBlurHost.alpha = 0.0;
            } completion:nil];

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                            (int64_t)((g_cfgAppZoomDur + 0.05) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                w26_appZoomTeardown();
                w26_log(@"[appzoom] done");
            });
        };

        if (g_cfgAppZoomBlur) {
            /* A brand new UIVisualEffectView can come up blank for one
             * frame; letting it render first is what avoids that flash.
             * With the blur off there is nothing to warm up - start now. */
            dispatch_async(dispatch_get_main_queue(), w26_runZoom);
        } else {
            w26_runZoom();
        }
    });
}

/* Which bundle is in the foreground?  nil / SpringBoard = home screen.
 * The entry points differ between iOS versions and none of them is in a
 * public header, so all three are tried and the winner is logged. */
static NSString *w26_frontmostBundleID(void) {
    id (*msg)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    int method = 0;
    id front = nil;

    id ac = [NSClassFromString(@"SBApplicationController") sharedInstance];
    if (ac && [ac respondsToSelector:@selector(frontmostApplication)]) {
        front = msg(ac, @selector(frontmostApplication));
        if (front) method = 1;
    }
    if (!front) {
        id ws = [NSClassFromString(@"SBMainWorkspace") sharedInstance];
        if (ws && [ws respondsToSelector:@selector(frontmostApplication)]) {
            front = msg(ws, @selector(frontmostApplication));
            if (front) method = 2;
        }
    }
    if (!front) {
        UIApplication *app = [UIApplication sharedApplication];
        SEL sel = @selector(_accessibilityFrontMostApplication);
        if (app && [app respondsToSelector:sel]) {
            front = msg(app, sel);
            if (front) method = 3;
        }
    }

    NSString *bid = nil;
    if ([front respondsToSelector:@selector(bundleIdentifier)]) {
        bid = msg(front, @selector(bundleIdentifier));
    }
    if (!bid && front) bid = NSStringFromClass([front class]);

    g_appZoomApplication = front;
    g_appZoomBundleID = [bid copy];
    g_appZoomScene = w26_msg(front, @selector(mainScene));
    g_appZoomSceneID = [w26_sceneIDOfObject(g_appZoomScene) copy];

    w26_log(@"probe frontmost: method=%d id=%@ scene=%@", method,
            bid ? bid : @"(none)",
            g_appZoomSceneID ? g_appZoomSceneID : @"(none)");
    return bid;
}

static BOOL w26_unlockGoesToApp(void) {
    if (!g_cfgAppZoom) return NO;
    NSString *bid = w26_frontmostBundleID();
    if (bid.length == 0) return NO;
    if ([bid isEqualToString:@"com.apple.springboard"]) return NO;
    return YES;
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

    /* Unlocking straight into a running app: there is no icon grid to wave,
     * so play the short zoom-out with the blur clearing as it lands. */
    if (g_appZoomFlow) {
        g_fireRequested = NO;
        if (!g_coverSheetGone && giveUp) {
            w26_log(@"[appzoom] cancelled - the lock screen never left");
            w26_appZoomTeardown();
            return;
        }
        g_fireDone = YES;
        w26_log(@"[appzoom] into an app - icon wave skipped");
        w26_appZoomPlay();
        return;
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
    {
        UIWindow *cw = [(UIViewController *)self view].window;
        if (cw && cw.windowLevel > 1.0) g_coverWindowLevel = cw.windowLevel;
    }
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
    w26_installAppMeshHooks();

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
        w26_loadSettings();
        g_appZoomFlow = w26_unlockGoesToApp();
        if (g_appZoomFlow && g_cfgAppZoomDirect) {
            /* Prime the live host while the lock screen still covers it.
             * This prevents an identity-frame flash before the spring starts. */
            w26_appZoomHostPrepare();
        }
        if (g_appZoomFlow && g_cfgAppZoomEarly && !g_cfgAppZoomDirect) {
            w26_appZoomBegin();      /* legacy screen path only */
        }
        w26_log(@"unlock confirmed (pan=%d) appZoom=%d",
                (int)g_panFired, (int)g_appZoomFlow);
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
    w26_loadSettings();
    w26_armAppTransitionSafety();

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
