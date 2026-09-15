#import <UIKit/UIKit.h>

@interface WaveTable : NSObject
+ (CGPoint)center;
+ (NSInteger)waveForCol:(NSInteger)col row:(NSInteger)row;
+ (BOOL)isValidCol:(NSInteger)col row:(NSInteger)row;
+ (double)microOffsetForCol:(NSInteger)col row:(NSInteger)row;
+ (double)delayForCol:(NSInteger)col row:(NSInteger)row waveInterval:(double)waveInterval;
@end
