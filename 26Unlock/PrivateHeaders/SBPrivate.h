#import <UIKit/UIKit.h>

@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
- (NSArray *)icons;
- (id)dockView;
- (BOOL)hasAnimatedIconLayoutBefore;
- (BOOL)_shouldAnimateIconLaunch;
- (void)setRootFolderViewControllerPresentationProgress:(double)progress animated:(BOOL)animated completion:(id)completion;
@end

@interface SBIconView : UIView
@end

@interface SBDockView : UIView
@end

@interface SBCoverSheetScreenEdgePanGestureRecognizer : UIGestureRecognizer
@end

@interface SBCoverSheetViewController : UIViewController
@end

/* Used only for -respondsToSelector:/casting on system edge-pan gestures. */
@protocol W26EdgeGesture <NSObject>
- (NSUInteger)edges;
@end
