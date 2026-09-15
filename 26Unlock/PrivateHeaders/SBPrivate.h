#import <UIKit/UIKit.h>

@interface SBIconController : NSObject
- (NSArray *)icons;
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
