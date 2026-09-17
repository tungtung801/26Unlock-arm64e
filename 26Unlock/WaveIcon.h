#import <UIKit/UIKit.h>

@interface WaveIcon : NSObject
@property(nonatomic, weak) UIView *view;
@property(nonatomic) NSInteger col;
@property(nonatomic) NSInteger row;
@property(nonatomic) BOOL hasHomeOverrideX;
@property(nonatomic) double homeOverrideX;
@property(nonatomic) BOOL hasHomeOverrideY;
@property(nonatomic) double homeOverrideY;
@property(nonatomic) BOOL horizontalFly;
@end
