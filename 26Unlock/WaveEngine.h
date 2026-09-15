#import <UIKit/UIKit.h>
#import "WaveIcon.h"

@interface WaveEngine : NSObject
@property(nonatomic, strong) NSMutableArray<WaveIcon *> *icons;
@property(nonatomic, weak) UIView *dock;
- (void)registerIcon:(UIView *)view col:(NSInteger)col row:(NSInteger)row;
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
