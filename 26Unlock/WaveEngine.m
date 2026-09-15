#import "WaveEngine.h"
#import "WaveTable.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kSpringMass = 1.5;
static const CGFloat kSpringDamping = 22.0;
static const CGFloat kSpringStiffness = 115.0;
static const CGFloat kSpringVelocity = 0.015;

static NSString * const kKeyPos = @"wave26.pos";
static NSString * const kKeyPosX = @"wave26.posx";
static NSString * const kKeyPosY = @"wave26.posy";
static NSString * const kKeyScale = @"wave26.scale";
static NSString * const kKeyDock = @"wave26.dock";

@implementation WaveEngine

- (instancetype)init {
    self = [super init];
    if (self) _icons = [NSMutableArray array];
    return self;
}

- (void)registerIcon:(UIView *)view col:(NSInteger)col row:(NSInteger)row {
    if (!view || ![WaveTable isValidCol:col row:row]) return;

    for (WaveIcon *existing in self.icons) {
        if (existing.view == view) {
            existing.col = col;
            existing.row = row;
            return;
        }
    }

    WaveIcon *icon = [WaveIcon new];
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

- (void)reset {
    for (WaveIcon *icon in self.icons) {
        [icon.view.layer removeAnimationForKey:kKeyPos];
        [icon.view.layer removeAnimationForKey:kKeyScale];
    }
    [self.dock.layer removeAnimationForKey:kKeyDock];
}

- (void)playWithPullVelocity:(double)pullVelocity {
    if (self.icons.count == 0) return;

    [self reset];

    for (WaveIcon *icon in [self.icons copy]) {
        NSInteger wave = [WaveTable waveForCol:icon.col row:icon.row];
        if (!wave) continue;
        double delay = [WaveTable delayForCol:icon.col row:icon.row waveInterval:0.055];
        [self animateIcon:icon delay:delay pullVelocity:pullVelocity];
    }

    [self animateDock:pullVelocity];
}

- (double)dampingForIcon:(WaveIcon *)icon pullVelocity:(double)pullVelocity {
    double magnitude = fabs(pullVelocity);
    double normalized = MIN(1.0, magnitude / 1500.0);
    double damping = 1.0;
    if (icon.col >= 1 && icon.col <= 3) {
        damping = -8.0 * normalized + 42.0;
    } else {
        damping = 26.0 + 8.0 * normalized;
    }
    return damping;
}

- (double)stiffnessForIcon:(WaveIcon *)icon {
    NSInteger wave = [WaveTable waveForCol:icon.col row:icon.row];
    return (wave >= 1 && wave <= 3) ? 150.0 : 115.0;
}

- (double)initialVelocityForIcon:(WaveIcon *)icon {
    // The original binary returns 12.0 for both branches; retain that value.
    return 12.0;
}

- (void)animateIcon:(WaveIcon *)icon delay:(double)delay pullVelocity:(double)pullVelocity {
    UIView *view = icon.view;
    if (!view) return;

    CALayer *layer = view.layer;
    CGPoint original = layer.position;
    CGFloat centerX = [WaveTable center].x;

    CGFloat horizontal = (icon.col < centerX) ? -1.0 : 1.0;
    CGFloat amplitude = 14.0 + MIN(20.0, fabs(pullVelocity) * 0.01);
    CGFloat dx = horizontal * amplitude;

    // The original uses two CASpringAnimation instances: one for position
    // and one for scale. The binary uses the same spring constants below.
    CASpringAnimation *position = [CASpringAnimation animationWithKeyPath:@"position"];
    position.fromValue = [NSValue valueWithCGPoint:original];
    position.toValue = [NSValue valueWithCGPoint:CGPointMake(original.x + dx, original.y)];
    position.damping = [self dampingForIcon:icon pullVelocity:pullVelocity];
    position.stiffness = [self stiffnessForIcon:icon];
    position.mass = kSpringMass;
    position.initialVelocity = [self initialVelocityForIcon:icon];
    position.duration = position.settlingDuration;
    position.beginTime = [layer convertTime:CACurrentMediaTime() fromLayer:nil] + delay;
    position.fillMode = kCAFillModeBackwards;
    position.removedOnCompletion = YES;
    [layer addAnimation:position forKey:kKeyPos];

    CASpringAnimation *scale = [CASpringAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @1.0;
    scale.toValue = @1.0;
    scale.damping = position.damping;
    scale.stiffness = position.stiffness;
    scale.mass = kSpringMass;
    scale.initialVelocity = kSpringVelocity;
    scale.duration = scale.settlingDuration;
    scale.beginTime = position.beginTime;
    scale.fillMode = kCAFillModeBackwards;
    scale.removedOnCompletion = YES;
    [layer addAnimation:scale forKey:kKeyScale];
}

- (void)animateDock:(double)pullVelocity {
    UIView *dock = self.dock;
    if (!dock) return;

    CALayer *layer = dock.layer;
    CGPoint p = layer.position;
    CGFloat shift = (pullVelocity >= 0 ? 1.0 : -1.0) * MIN(12.0, fabs(pullVelocity) * 0.004);

    CASpringAnimation *animation = [CASpringAnimation animationWithKeyPath:@"position"];
    animation.fromValue = [NSValue valueWithCGPoint:p];
    animation.toValue = [NSValue valueWithCGPoint:CGPointMake(p.x + shift, p.y)];
    animation.damping = 26.0;
    animation.stiffness = kSpringStiffness;
    animation.mass = kSpringMass;
    animation.initialVelocity = kSpringVelocity;
    animation.duration = animation.settlingDuration;
    animation.fillMode = kCAFillModeBackwards;
    animation.removedOnCompletion = YES;
    [layer addAnimation:animation forKey:kKeyDock];
}

@end
