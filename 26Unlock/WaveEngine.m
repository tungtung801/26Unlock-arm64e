#import "WaveEngine.h"
#import "WaveTable.h"
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <math.h>

static NSString * const kKeyPos   = @"wave26.pos";
static NSString * const kKeyPosX  = @"wave26.posx";
static NSString * const kKeyPosY  = @"wave26.posy";
static NSString * const kKeyScale = @"wave26.scale";

/* Set by Tweak.xm right before a wave plays: when SpringBoard scales the home
 * screen (unlock transition) every offset must be divided by that scale so the
 * icons still travel the same distance on screen.  1.0 == no compensation. */
extern double W26ScaleComp;
static NSString * const kKeyDock  = @"wave26.dock";

static const CGFloat kSpringMass = 1.5;

@implementation WaveEngine

- (instancetype)init {
    self = [super init];
    if (self) {
        _icons = [NSMutableArray array];
    }
    return self;
}

- (void)registerIcon:(UIView *)view col:(NSInteger)col row:(NSInteger)row {
    if (!view || ![WaveTable isValidCol:col row:row]) {
        return;
    }

    for (WaveIcon *icon in self.icons) {
        if (icon.view == view) {
            icon.col = col;
            icon.row = row;
            return;
        }
    }

    WaveIcon *icon = [[WaveIcon alloc] init];
    icon.view = view;
    icon.col = col;
    icon.row = row;
    [self.icons addObject:icon];
}

- (void)setHomeOverride:(CGPoint)home forView:(UIView *)view {
    if (!view) return;

    for (WaveIcon *icon in self.icons) {
        if (icon.view == view) {
            icon.hasHomeOverrideX = YES;
            icon.homeOverrideX = home.x;
            icon.hasHomeOverrideY = YES;
            icon.homeOverrideY = home.y;
            return;
        }
    }
}

- (void)clearIcons {
    [self.icons removeAllObjects];
}

- (void)setDockView:(UIView *)dock {
    self.dock = dock;
}

- (void)playWithPullVelocity:(double)pullVelocity {
    UIScreen *screen = [UIScreen mainScreen];
    CGRect bounds = screen.bounds;
    CGFloat screenMidX = CGRectGetMidX(bounds);

    WaveIcon *col1Row3 = nil;
    WaveIcon *col2Row3 = nil;

    /*
     * First pass in the original binary:
     * find wave 1 icons specifically at row 3, columns 1 and 2.
     */
    for (WaveIcon *icon in self.icons) {
        if ([WaveTable waveForCol:icon.col row:icon.row] != 1) {
            continue;
        }
        if (!icon.view) {
            continue;
        }
        if (icon.row != 3) {
            continue;
        }

        if (icon.col == 1) {
            col1Row3 = icon;
        } else if (icon.col == 2) {
            col2Row3 = icon;
        }
    }

    /*
     * When both reference icons exist, the original binary derives a
     * half horizontal spacing from their actual layer positions and uses
     * the screen midpoint as the anchor for wave-1 horizontal flight.
     */
    CGFloat halfDeltaX = 0.0;

    if (col1Row3 && col2Row3) {
        CALayer *leftLayer = col1Row3.view.layer;
        CALayer *rightLayer = col2Row3.view.layer;

        if (leftLayer && rightLayer) {
            // FIX (binary: (col2.x - col1.x) * 0.5, i.e. positive).
            // The old order produced a negative half-spacing and mirrored the
            // wave-1 icons around the screen centre.
            halfDeltaX =
                (rightLayer.position.x - leftLayer.position.x) * 0.5;

            for (WaveIcon *icon in self.icons) {
                if ([WaveTable waveForCol:icon.col row:icon.row] != 1) {
                    continue;
                }

                if (!icon.view) {
                    continue;
                }

                icon.hasHomeOverrideX = YES;

                if (icon.col == 1) {
                    icon.homeOverrideX = screenMidX - halfDeltaX;
                } else {
                    icon.homeOverrideX = screenMidX + halfDeltaX;
                }

                icon.horizontalFly = YES;
            }
        }
    }

    /*
     * Second pass: the original uses WaveTable's 0.055 wave interval.
     */
    for (WaveIcon *icon in self.icons) {
        double delay =
            [WaveTable delayForCol:icon.col
                               row:icon.row
                     waveInterval:0.055];

        [self animateIcon:icon
                     delay:delay
              pullVelocity:pullVelocity];
    }

    [self animateDock:pullVelocity];
}

- (double)dampingForIcon:(WaveIcon *)icon
            pullVelocity:(double)pullVelocity {
    NSInteger wave = [WaveTable waveForCol:icon.col row:icon.row];

    double normalized = fabs(pullVelocity) / 2500.0;
    if (normalized > 1.0) {
        normalized = 1.0;
    }

    if (wave >= 1 && wave <= 3) {
        return 42.0 - 8.0 * normalized;
    }

    return 26.0 - 2.1 * normalized;
}

- (double)stiffnessForIcon:(WaveIcon *)icon {
    NSInteger wave = [WaveTable waveForCol:icon.col row:icon.row];

    // FIX: the binary uses 300.0 for waves 1..3 (150.0 is only the dy
    // divisor inside -animateIcon:). 150.0 made the centre icons too soft.
    if (wave >= 1 && wave <= 3) {
        return 300.0;
    }

    return 115.0;
}

- (double)initialVelocityForIcon:(WaveIcon *)icon {
    (void)icon;
    return 12.0;
}

- (void)animateIcon:(WaveIcon *)icon
              delay:(double)delay
       pullVelocity:(double)pullVelocity {
    UIView *view = icon.view;
    CALayer *layer = view.layer;

    if (!view || !layer) {
        return;
    }

    double damping = [self dampingForIcon:icon
                             pullVelocity:pullVelocity];
    double stiffness = [self stiffnessForIcon:icon];
    double initialVelocity = [self initialVelocityForIcon:icon];

    CGPoint original = layer.position;

    if (icon.hasHomeOverrideX) {
        original.x = icon.homeOverrideX;
    }

    if (icon.hasHomeOverrideY) {
        original.y = icon.homeOverrideY;
    }

    if (icon.row == 5) {
        layer.zPosition = -1.0;
    }

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGPoint screenCenter =
        CGPointMake(CGRectGetMidX(screenBounds),
                    CGRectGetMidY(screenBounds));

    CGFloat dx = original.x - screenCenter.x;
    CGFloat dy = original.y - screenCenter.y;
    CGFloat distance = hypot(dx, dy);

    if (distance < 0.0001) {
        dx = 0.0;
        dy = -1.0;
        distance = 1.0;
    } else {
        dx /= distance;
        dy /= distance;
    }

    /*
     * Horizontal-fly branch, recovered literally:
     * dx = +/-0.8 according to the horizontal side,
     * dy = (original.y - screenCenter.y) / 150.
     *
     * These values are used only to form the normal target branch;
     * the horizontal-fly target below uses the screen center directly.
     */
    if (icon.horizontalFly) {
        dx = (original.x >= screenCenter.x) ? 0.8 : -0.8;
        dy = (original.y - screenCenter.y) / 150.0;
    }

    /*
     * IMPORTANT: the scale factor is based on WaveTable.center(), not
     * the physical screen center.
     *
     * Grid centre = (1.5, 2.5)  [verified in the binary: fmov d0,#1.5 / fmov d1,#2.5].
     */
    CGPoint tableCenter = [WaveTable center];
    CGFloat gridX = (CGFloat)icon.col + 0.5 - tableCenter.x;
    CGFloat gridY = (CGFloat)icon.row + 0.5 - tableCenter.y;

    CGFloat gridDistance = hypot(gridX, gridY);

    double factor = gridDistance / 3.0;
    if (factor > 1.0) {
        factor = 1.0;
    }

    double stretch =
        4.5 + 2.1 * (1.0 - factor);

    CGPoint target;

    if (icon.horizontalFly) {
        target = CGPointMake(
            screenCenter.x +
                (original.x - screenCenter.x) * stretch,
            screenCenter.y +
                (original.y - screenCenter.y) * stretch
        );
    } else {
        target = CGPointMake(
            original.x + dx * 800.0 / W26ScaleComp,
            original.y + dy * 800.0 / W26ScaleComp
        );
    }

    CFTimeInterval beginTime =
        [layer convertTime:CACurrentMediaTime() fromLayer:nil] + delay;

    CASpringAnimation *position =
        [CASpringAnimation animationWithKeyPath:@"position"];

    // FIX (main bug): the binary animates FROM the far target TO the home
    // position.  The swapped order sent every icon ~800 pt outward and let it
    // snap back - the "icons stuck at the wrong position / jitter" symptom.
    position.fromValue = [NSValue valueWithCGPoint:target];
    position.toValue = [NSValue valueWithCGPoint:original];
    position.damping = damping;
    position.stiffness = stiffness;
    position.mass = kSpringMass;
    position.initialVelocity = initialVelocity;
    position.duration = position.settlingDuration;
    position.beginTime = beginTime;
    position.fillMode = kCAFillModeBackwards;
    position.removedOnCompletion = YES;

    [layer addAnimation:position forKey:kKeyPos];

    CASpringAnimation *scale =
        [CASpringAnimation animationWithKeyPath:@"transform.scale"];

    scale.fromValue = @(stretch);
    scale.toValue = @1.0;
    scale.damping = damping;
    scale.stiffness = stiffness;
    scale.mass = kSpringMass;
    scale.initialVelocity = initialVelocity;
    scale.duration = scale.settlingDuration;
    scale.beginTime = beginTime;
    scale.fillMode = kCAFillModeBackwards;
    scale.removedOnCompletion = YES;

    [layer addAnimation:scale forKey:kKeyScale];
}

- (void)animateDock:(double)pullVelocity {
    (void)pullVelocity;

    UIView *dock = self.dock;
    CALayer *layer = dock.layer;

    if (!dock || !layer) {
        return;
    }

    CGPoint original = layer.position;

    /* The dock starts 380 pt BELOW its home position and springs up into
     * place.  Recovered from the original binary:
     *   0x9f08  d0/d1 <- (x, y + 380)  -> valueWithCGPoint: -> setFromValue:
     *   0x9f44  d0/d1 <- original      -> valueWithCGPoint: -> setToValue:
     * The previous reconstruction had these two swapped, which made the dock
     * slide DOWN and snap back - the "dock appears abruptly / jerks" bug. */
    CGPoint target =
        CGPointMake(original.x, original.y + 380.0 / W26ScaleComp);

    CFTimeInterval beginTime =
        [layer convertTime:CACurrentMediaTime() fromLayer:nil];

    CASpringAnimation *animation =
        [CASpringAnimation animationWithKeyPath:@"position"];

    animation.fromValue = [NSValue valueWithCGPoint:target];
    animation.toValue = [NSValue valueWithCGPoint:original];
    animation.damping = 22.0;
    animation.stiffness = 115.0;
    animation.mass = 1.5;
    animation.initialVelocity = 0.0;
    animation.duration = animation.settlingDuration;
    animation.beginTime = beginTime;
    animation.fillMode = kCAFillModeBackwards;
    animation.removedOnCompletion = YES;

    [layer addAnimation:animation forKey:kKeyDock];
}

- (void)reset {
    for (WaveIcon *icon in self.icons) {
        UIView *view = icon.view;
        CALayer *layer = view.layer;

        if (!view || !layer) {
            continue;
        }

        [layer removeAnimationForKey:kKeyPos];
        [layer removeAnimationForKey:kKeyPosX];
        [layer removeAnimationForKey:kKeyPosY];
        [layer removeAnimationForKey:kKeyScale];
    }

    CALayer *dockLayer = self.dock.layer;
    if (self.dock && dockLayer) {
        [dockLayer removeAnimationForKey:kKeyDock];
    }
}

@end
