#import <UIKit/UIKit.h>
#import "WaveIcon.h"

@interface WaveEngine : NSObject
@property(nonatomic, strong) NSMutableArray<WaveIcon *> *icons;
@property(nonatomic, weak) UIView *dock;
- (void)registerIcon:(UIView *)view col:(NSInteger)col row:(NSInteger)row;
/* Force an icon to land at this point (in its own layer coordinate space)
 * instead of at the position SpringBoard currently has it at. */
- (void)setHomeOverride:(CGPoint)home forView:(UIView *)view;
- (void)clearIcons;
- (void)setDockView:(UIView *)dock;
- (void)playWithPullVelocity:(double)pullVelocity;
- (double)dampingForIcon:(WaveIcon *)icon pullVelocity:(double)pullVelocity;
- (double)stiffnessForIcon:(WaveIcon *)icon;
- (double)initialVelocityForIcon:(WaveIcon *)icon;
- (void)animateIcon:(WaveIcon *)icon delay:(double)delay pullVelocity:(double)pullVelocity;
- (void)animateDock:(double)pullVelocity;
- (void)reset;
@end
