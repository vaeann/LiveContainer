//
//  LCStatusBarManager.h
//  LiveContainer
//
//  Created by Duy Tran on 20/2/26.
//
@import UIKit;
#import "AppSceneViewController.h"

@interface UIStatusBarManager(Private)
- (void)handleTapAction:(UIAction *)action;
@end

API_AVAILABLE(ios(16.0))
@interface LCStatusBarManager : UIStatusBarManager
@property(nonatomic) AppSceneViewController *nativeWindowViewController;
/// Hide or show the host status bar on every connected window scene via
/// UIStatusBarManager's private overriding setter (the only entry point
/// on iOS 16+). Returns YES when at least one scene applied it.
+ (BOOL)lc_setOverridingStatusBarHidden:(BOOL)hidden;
@end
