//
//  LCStatusBarManager.m
//  LiveContainer
//
//  Created by Duy Tran on 20/2/26.
//
#import "LCStatusBarManager.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "VirtualWindowsHostView.h"
#import <objc/message.h>

@implementation LCStatusBarManager
+ (BOOL)lc_setOverridingStatusBarHidden:(BOOL)hidden {
    BOOL applied = NO;
    SEL plain = NSSelectorFromString(@"_setOverridingStatusBarHidden:");
    SEL animated = NSSelectorFromString(@"_setOverridingStatusBarHidden:animationParameters:");
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIStatusBarManager *manager = ((UIWindowScene *)scene).statusBarManager;
        if (!manager) continue;
        @try {
            // Prefer the unanimated variant: bringing an app to front
            // should not run an extra status bar transition.
            if ([manager respondsToSelector:plain]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(manager, plain, hidden);
                applied = YES;
            } else if ([manager respondsToSelector:animated]) {
                ((void (*)(id, SEL, BOOL, id))objc_msgSend)(manager, animated, hidden, nil);
                applied = YES;
            }
        } @catch (NSException *exception) {
        }
    }
    return applied;
}

- (void)handleTapAction:(UIAction *)action {
    if(self.nativeWindowViewController) {
        [self.nativeWindowViewController handleStatusBarTapAction:action];
        return;
    }
    BOOL handledByVirtualWindow = [MultitaskDockManager.shared.windowHostingView handleStatusBarTapAction:action];
    if(!handledByVirtualWindow) {
        [super handleTapAction:action];
    }
}
@end

@implementation UIApplication(LiveContainer)
+ (Class)_statusBarManagerClass {
    if (@available(iOS 16.0, *)) {
        return LCStatusBarManager.class;
    } else {
        return UIStatusBarManager.class;
    }
}
@end
