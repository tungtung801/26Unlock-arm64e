#import "WaveEngine.h"
#import "WaveTable.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static NSString * const kKeyPos  = @"wave26.pos";
static NSString * const kKeyPosX = @"wave26.posx";
static NSString * const kKeyPosY = @"wave26.posy";
static NSString * const kKeyScale = @"wave26.scale";
static NSString * const kKeyDock = @"wave26.dock";

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

- (void)clearIcons {
    [self.icons removeAllObjects];
}

- (void)setDockView:(UIView *)dock {
    self.dock = dock;
}

- (void)playWithPullVelocity:(double)pullVelocity {
    /*
     * Reconstructed from the original arm64 binary.
     *
     * The original performs a preprocessing pass that finds the two
     * wave-1 icons at row 3, columns 1 and 2. When both exist, it gives
     * every wave-1 icon a homeOverrideX and enables horizontalFly.
     */
    UIScreen *screen = [UIScreen mainScreen];
    CGFloat screenMidX = CGRectGetMidX(screen.bounds);

    WaveIcon *leftWaveIcon = nil;
    WaveIcon *rightWaveIcon = nil;

    for (WaveIcon *icon in self.icons) {
        NSInteger wave = [WaveTable waveForCol:icon.col row:icon.row];

        if (wave == 1 && icon.row == 3) {
            if (icon.col == 1) {
                leftWaveIcon = icon;
            } else if (icon.col == 2) {
                rightWaveIcon = icon;
            }
        }
    }

    CGFloat halfDeltaX = 0.0;

    if (leftWaveIcon && rightWaveIcon) {
        UIView *leftView = leftWaveIcon.view;
        UIView *rightView = rightWaveIcon.view;

        if (leftView && rightView) {
            halfDeltaX = (leftView.layer.position.x - rightView.layer.position.x) * 0.5;

            /*
             * This intentionally preserves the direction recovered from
             * the original binary: col 1 receives midX - halfDeltaX and
             * col 2 receives midX + halfDeltaX.
             */
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
                } else if (icon.col == 2) {
                    icon.homeOverrideX = screenMidX + halfDeltaX;
                }

                icon.horizontalFly = YES;
            }
        }
    }

    /*
     * Binary calls animateIcon for every registered icon and passes the
     * WaveTable delay using a 0.055 wave interval.
     */
    for (WaveIcon *icon in self.icons) {
        double delay = [WaveTable delayForCol:icon.col
                                         row:icon.row
                                waveInterval:0.055];
        [self animateIcon:icon delay:delay pullVelocity:pullVelocity];
    }

    [self animateDock:pullVelocity];
}

- (double)dampingForIcon:(WaveIcon *)icon pullVelocity:(double)pullVelocity {
    NSInteger wave = [WaveTable waveForCol:icon.col row:icon.row];

    double normalized = fabs(pullVelocity) / 2500.0;
    normalized = MIN(1.0, normalized);

    if (wave >= 1 && wave <= 3) {
        return -8.0 * normalized + 42.0;
    }

    return -2.1 * normalized + 26.0;
}

- (double)stiffnessForIcon:(WaveIcon *)icon {
    NSInteger wave = [WaveTable waveForCol:icon.col row:icon.row];

    if (wave >= 1 && wave <= 3) {
        return 150.0;
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

    double damping = [self dampingForIcon:icon pullVelocity:pullVelocity];
    double stiffness = [self stiffnessForIcon:icon];
    double initialVelocity = [self initialVelocityForIcon:icon];

    CGPoint original = layer.position;

    if (icon.hasHomeOverrideX) {
        original.x = icon.homeOverrideX;
    }

    /*
     * Binary special-case: row 5 is moved behind other layers.
     */
    if (icon.row == 5) {
        layer.zPosition = -1.0;
    }

    UIScreen *screen = [UIScreen mainScreen];
    CGPoint center = CGPointMake(CGRectGetMidX(screen.bounds),
                                 CGRectGetMidY(screen.bounds));

    /*
     * Vector from screen center to the icon.
     */
    CGFloat dx = original.x - center.x;
    CGFloat dy = original.y - center.y;
    CGFloat distance = hypot(dx, dy);

    /*
     * Binary threshold: if distance < 0.0001, force (0, -1) and
     * distance = 1 to avoid division by zero.
     */
    if (distance < 0.0001) {
        dx = 0.0;
        dy = -1.0;
        distance = 1.0;
    } else {
        dx /= distance;
        dy /= distance;
    }

    /*
     * Horizontal-fly mode uses an alternate direction/target path.
     * The recovered binary selects +0.8 for icons on the right side
     * of the screen and -0.8 for icons on the left, while the vertical
     * component is normalized by 150.0.
     */
    if (icon.horizontalFly) {
        dx = (original.x >= center.x) ? 0.8 : -0.8;
        dy = (original.y - center.y) / 150.0;
    }

    /*
     * The scale/stretch factor recovered from the binary:
     *
     *   factor = min(1, distance / 3)
     *   stretch = 4.5 + 2.1 * (1 - factor)
     */
    double factor = MIN(1.0, distance / 3.0);
    double stretch = 4.5 + 2.1 * (1.0 - factor);

    CGPoint toPoint;

    if (icon.horizontalFly) {
        /*
         * Horizontal-fly target:
         *   center + (original - center) * stretch
         *
         * (dx/dy above are still kept because they are part of the
         * original control flow, although this target branch does not
         * use them directly.)
         */
        (void)dx;
        (void)dy;

        toPoint = CGPointMake(center.x + (original.x - center.x) * stretch,
                              center.y + (original.y - center.y) * stretch);
    } else {
        /*
         * Normal target:
         *   original + normalizedDirection * 800
         */
        toPoint = CGPointMake(original.x + dx * 800.0,
                              original.y + dy * 800.0);
    }

    CFTimeInterval beginTime =
        [layer convertTime:CACurrentMediaTime() fromLayer:nil] + delay;

    CASpringAnimation *position =
        [CASpringAnimation animationWithKeyPath:@"position"];

    position.fromValue = [NSValue valueWithCGPoint:original];
    position.toValue = [NSValue valueWithCGPoint:toPoint];
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

    /*
     * Binary uses stretch -> 1.0, not 1.0 -> 1.0.
     */
    scale.fromValue = @(stretch);
    scale.toValue = @1.0;
    scale.damping = damping;
    scale.stiffness = stiffness;
    scale.mass = kSpringMass;
    scale.initialVelocity = 0.0;
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

    /*
     * Binary target is exactly +380 points on Y.
     */
    CGPoint toPoint = CGPointMake(original.x, original.y + 380.0);

    CFTimeInterval beginTime =
        [layer convertTime:CACurrentMediaTime() fromLayer:nil];

    CASpringAnimation *animation =
        [CASpringAnimation animationWithKeyPath:@"position"];

    animation.fromValue = [NSValue valueWithCGPoint:original];
    animation.toValue = [NSValue valueWithCGPoint:toPoint];
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
