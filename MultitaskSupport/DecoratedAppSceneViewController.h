#import "FoundationPrivate.h"
#import "AppSceneViewController.h"

API_AVAILABLE(ios(16.0))
@interface DecoratedAppSceneViewController : UIViewController<AppSceneViewControllerDelegate>
@property(nonatomic) AppSceneViewController* appSceneVC;
@property(nonatomic) UIStackView *view;
@property(nonatomic) UINavigationBar *navigationBar;
@property(nonatomic) UINavigationItem *navigationItem;
@property(nonatomic) UIView *resizeHandle;
@property(nonatomic) UIView* contentView;
@property(nonatomic) UIView *tapOutsideScrim;

@property(nonatomic) BOOL isMaximized;
@property(nonatomic) CGFloat scaleRatio;
- (instancetype)initWindowName:(NSString*)windowName bundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID rootVC:(UIViewController*)rootVC;
- (void)closeWindow;
- (void)maximizeWindow;
- (void)minimizeWindow;
- (void)minimizeWindowPiP;
- (void)unminimizeWindowPiP;
- (void)updateVerticalConstraints;

// Tap-outside scrim （挡板）: a clear (test build: faint red) view over
// the guest scene, below the window bar and resize handle. While the
// multitask dock is expanded, the first outside tap lands on it and
// collapses the dock. Lives in this container — not in the key
// window — because the window-level scrim could not claim scene-area
// touches (backboardd gives them to the scene's remote layer), while
// views in this container above the scene (the window bar) provably
// receive touches.
- (void)setTapOutsideScrimVisible:(BOOL)visible;
@property(nonatomic, copy) void (^pidAvailableHandler)(NSNumber *pid, NSError *error);
@end

