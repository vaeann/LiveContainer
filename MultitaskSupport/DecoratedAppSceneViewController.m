#import "DecoratedAppSceneViewController.h"
#import "ResizeHandleView.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "AppSceneViewController.h"
#import "UIKitPrivate+MultitaskSupport.h"
#import "PiPManager.h"
#import "VirtualWindowsHostView.h"
#import "../LiveContainer/Localization.h"
#import "utils.h"

// 操作栏高度（Ann 2026-11-22 定）：36，比上游的 44 矮一截、
// 和 macOS 风的三钮更协调。右下缩放把手仍是 44×44（单独常量，
// 不再跟栏高绑在一起）。
static const CGFloat LCWindowBarHeight = 36;
static const CGFloat LCResizeHandleSize = 44;
// 操作栏改「盖」不「拼」（Ann 2026-11-22 定）：画面铺满整个窗口、
// 顶部伸到操作栏底下，栏盖住画面顶部的自带安全区（约 50 点，
// 原生全屏时藏在灵动岛/状态栏后面的那截，App 在里面不放正经
// 内容，Telegram 的招牌就在那）。安全区比栏高，盖完还剩一截
// 会从栏下沿漏出来，所以画面整体再上移这个数、由窗口上沿裁
// 掉，漏出的那截连同招牌一起藏进栏后面。
static const CGFloat LCWindowTopCrop = 14;

@interface DecoratedAppSceneViewController()
@property(nonatomic) NSArray* activatedVerticalConstraints;
@property(nonatomic) NSString* dataUUID;
@property(nonatomic) int pid;
@property(nonatomic) CGRect originalFrame;
@property(nonatomic) UIButton *maximizeButton;

@property(nonatomic) UIView *lightsView;
@property(nonatomic) UIButton *menuButton;
@property(nonatomic) NSLayoutConstraint *menuButtonTrailing;
@property(nonatomic) bool isAppTerminationRequested;
- (UIButton *)trafficLightButtonWithColor:(UIColor *)color action:(SEL)action;
- (NSArray<UIMenuElement *> *)windowMenuElements;
- (void)refreshBarOverlay;
@end

@implementation DecoratedAppSceneViewController
- (instancetype)initWindowName:(NSString*)windowName bundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID rootVC:(UIViewController*)rootVC {
    self = [super initWithNibName:nil bundle:nil];
    self.view = [[UIStackView alloc] initWithFrame:self.view.frame];
    [MultitaskDockManager.shared.windowHostingView addSubview:self.view];
    [rootVC addChildViewController:self];
    
    _dataUUID = dataUUID;
    _scaleRatio = 1.0;
    _isMaximized = [NSUserDefaults.lcUserDefaults boolForKey:@"LCLaunchMultitaskMaximized"];
    _appSceneVC = [[AppSceneViewController alloc] initWithBundleId:bundleId dataUUID:dataUUID delegate:self];
    self.title = windowName;
    [self setupDecoratedView];
    
    [MultitaskDockManager.shared addRunningApp:windowName appUUID:dataUUID view:self.view];
    
    // 操作栏（Ann 2026-11-22 定，macOS 风）：左边三个实心红黄绿
    // 圆钮（关 / 最小化 / 最大化，圆内不放符号，就是 macOS 那种
    // 纯色圆点），中间不显示 App 名字，右边只留一个箭头钮，点
    // 开还是原来的 PID 菜单（见 windowMenuElements）。
    // 按钮不走导航栏的 item 系统：这条独立栏（非导航控制器托管）
    // 的 item 布局由栏内部说了算——自定义视图会被拉宽（箭头圆
    // 变药丸）、整组偏下约 4 点。改成窗口视图上的悬浮层：约束
    // 对着栏的中心线定位，栏只剩背景和拖动。
    UIView *lightsView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 82, 36)];
    self.lightsView = lightsView;
    UIButton *closeButton = [self trafficLightButtonWithColor:[UIColor colorWithRed:1.0 green:0.373 blue:0.341 alpha:1.0] action:@selector(closeWindow)];
    closeButton.frame = CGRectMake(0, 0, 26, 36);
    [lightsView addSubview:closeButton];
    UIButton *minimizeButton = [self trafficLightButtonWithColor:[UIColor colorWithRed:0.996 green:0.737 blue:0.180 alpha:1.0] action:@selector(minimizeWindow)];
    minimizeButton.frame = CGRectMake(28, 0, 26, 36);
    [lightsView addSubview:minimizeButton];
    self.maximizeButton = [self trafficLightButtonWithColor:[UIColor colorWithRed:0.157 green:0.784 blue:0.251 alpha:1.0] action:@selector(maximizeWindow)];
    self.maximizeButton.frame = CGRectMake(56, 0, 26, 36);
    [lightsView addSubview:self.maximizeButton];

    // 箭头钮就是演示图那样：圆形描边里一个箭头图标，30×30。
    UIButton *menuButton = [UIButton buttonWithType:UIButtonTypeCustom];
    menuButton.frame = CGRectMake(0, 0, 30, 30);
    menuButton.layer.cornerRadius = 15;
    menuButton.layer.borderWidth = 1;
    menuButton.layer.borderColor = UIColor.separatorColor.CGColor;
    UIImageSymbolConfiguration *chevronConfig = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIFontWeightSemibold];
    [menuButton setImage:[[UIImage systemImageNamed:@"chevron.down"] imageWithConfiguration:chevronConfig] forState:UIControlStateNormal];
    menuButton.tintColor = UIColor.secondaryLabelColor;
    __weak typeof(self) weakSelf = self;
    UIDeferredMenuElement *deferredMenu = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^ _Nonnull completion)(NSArray<UIMenuElement *> * _Nonnull)) {
        completion(weakSelf ? [weakSelf windowMenuElements] : @[]);
    }];
    menuButton.menu = [UIMenu menuWithChildren:@[deferredMenu]];
    menuButton.showsMenuAsPrimaryAction = YES;
    self.menuButton = menuButton;

    // 悬浮层定位：三钮组左缘离窗边 20（第一个圆点左缘 26 ——
    // Ann 2026-11-22 晚定：贴 12 太靠左，回到早先那版的距离）；
    // 箭头钮右边距 12；两者都对着栏的垂直中心，栏在顶部还是
    // 底部都跟着栏走。
    [self.view addSubview:lightsView];
    [self.view addSubview:menuButton];
    lightsView.translatesAutoresizingMaskIntoConstraints = NO;
    menuButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.menuButtonTrailing = [menuButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12];
    [NSLayoutConstraint activateConstraints:@[
        [lightsView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [lightsView.centerYAnchor constraintEqualToAnchor:self.navigationBar.centerYAnchor],
        [lightsView.widthAnchor constraintEqualToConstant:82],
        [lightsView.heightAnchor constraintEqualToConstant:36],
        [menuButton.centerYAnchor constraintEqualToAnchor:self.navigationBar.centerYAnchor],
        [menuButton.widthAnchor constraintEqualToConstant:30],
        [menuButton.heightAnchor constraintEqualToConstant:30],
        self.menuButtonTrailing,
    ]];
    if ([self shouldHideWindowBar]) {
        lightsView.hidden = YES;
        menuButton.hidden = YES;
    }
    [self refreshBarOverlay];

    return self;
}

// 箭头钮菜单的元素：就是原来点标题弹出的 PID 菜单的内容（PID
// 一行 + 复制 PID / PiP 开关 / 缩放滑杆），直接作为菜单元素返回，
// 不能再包一层 UIMenu——那样点箭头会先弹一个子菜单（Ann
// 2026-11-22 真机发现）。每次打开时现建，PID 和运行状态都是
// 最新的（标题菜单的 provider 语义用延迟元素复刻）；PID 行是
// 禁用态，只展示不可点。
- (NSArray<UIMenuElement *> *)windowMenuElements {
    if (!self.appSceneVC.isAppRunning) {
        UIAction *terminated = [UIAction actionWithTitle:NSLocalizedString(@"lc.multitaskAppWindow.appTerminated", nil) image:nil identifier:nil handler:^(UIAction * _Nonnull action) {}];
        terminated.attributes = UIMenuElementAttributesDisabled;
        return @[terminated];
    }
    NSString *pidText = [NSString stringWithFormat:@"PID: %d", self.pid];
    UIAction *pidHeader = [UIAction actionWithTitle:pidText image:nil identifier:nil handler:^(UIAction * _Nonnull action) {}];
    pidHeader.attributes = UIMenuElementAttributesDisabled;
    NSArray *menuItems = @[
        pidHeader,
        [UIAction actionWithTitle:@"lc.multitask.copyPid".loc image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction * _Nonnull action) {
            UIPasteboard.generalPasteboard.string = @(self.appSceneVC.pid).stringValue;
        }],
        [UIAction actionWithTitle:@"lc.multitask.enablePip".loc image:[UIImage systemImageNamed:@"pip.enter"] identifier:nil handler:^(UIAction * _Nonnull action) {
            if ([PiPManager.shared isPiPWithVC:self.appSceneVC]) {
                [PiPManager.shared stopPiP];
            } else {
                [PiPManager.shared startPiPWithVC:self.appSceneVC];
            }
        }],
        [UICustomViewMenuElement elementWithViewProvider:^UIView *(UICustomViewMenuElement *element) {
            return [self scaleSliderViewWithTitle:@"lc.multitask.scale".loc min:0.5 max:2.0 value:self.scaleRatio stepInterval:0.01];
        }]
    ];
    return menuItems;
}


// 一个红绿灯钮：26×36 的点击区里居中放 14 的实心圆，纯色、
// 不放符号（Ann 2026-11-22 晚定，跟 macOS 一样）。
- (UIButton *)trafficLightButtonWithColor:(UIColor *)color action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(6, 11, 14, 14)];
    dot.backgroundColor = color;
    dot.layer.cornerRadius = 7;
    dot.layer.borderWidth = 0.5;
    dot.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.15].CGColor;
    dot.userInteractionEnabled = NO;
    [button addSubview:dot];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

// 箭头钮的位置恒定（右、居中于栏）；只有操作栏在底部时，右下
// 角有缩放把手，箭头钮的右边距加大给把手让位（左置三钮不受
// 影响）。
- (void)refreshBarOverlay {
    BOOL bottomWindowBar = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"];
    self.menuButtonTrailing.constant = bottomWindowBar ? -46 : -12;
}

- (void)setupDecoratedView {
    CGFloat navBarHeight = LCWindowBarHeight;
    BOOL isLandscape = UIInterfaceOrientationIsLandscape(UIApp.statusBarOrientation);
    CGRect frame = CGRectMake(0, 0, isLandscape ? 480 : 320, (isLandscape ? 320 : 480) + navBarHeight);
    CGPoint rootViewCenter = self.view.superview.center;
    frame.origin = CGPointMake(rootViewCenter.x - frame.size.width / 2, rootViewCenter.y - frame.size.height / 2);
    
    if(_isMaximized) {
        CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
        // save origin as normalized coordinates
        frame.origin.x /= maxFrame.size.width;
        frame.origin.y /= maxFrame.size.height;
        self.originalFrame = frame;
    } else {
        self.view.frame = frame;
    }
    
    // Navigation bar
    UINavigationBar *navigationBar = [[UINavigationBar alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, navBarHeight)];
    navigationBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    // Start in the final state: updateVerticalConstraints animates over
    // 0.3s, which made the bar flash on screen when a window opens
    // maximized with the bar disabled.
    if ([self shouldHideWindowBar]) {
        navigationBar.alpha = 0;
        navigationBar.hidden = YES;
    }
    // 栏上不显示 App 名字（Ann 2026-11-22 定），标题留空。
    UINavigationItem *navigationItem = [[UINavigationItem alloc] initWithTitle:@""];
    navigationBar.items = @[navigationItem];
    
    self.view.axis = UILayoutConstraintAxisVertical;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    // 窗口圆角 16（原 10）：操作栏贴在窗口顶部、左右两角跟着
    // 窗口一起圆（masksToBounds 裁切），和新栏更协调。最大化时
    // 圆角归零：圆角会在屏幕顶边左右各留一块黑三角，看着像黑线
    // （Ann 2026-11-22 真机发现），归零后和屏幕无缝衔接。
    self.view.layer.cornerRadius = _isMaximized ? 0 : 16;
    self.view.layer.masksToBounds = YES;

    self.navigationBar = navigationBar;
    self.navigationItem = navigationBar.items.firstObject;
    if (!self.navigationBar.superview) {
        [self.view addArrangedSubview:self.navigationBar];
    }
    
    CGRect contentFrame = CGRectMake(0, 0, self.view.frame.size.width, self.view.frame.size.height - navBarHeight);
    UIView *fixedPositionContentView = [[UIView alloc] initWithFrame:contentFrame];
    self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if([NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"]) {
        [self.view insertArrangedSubview:fixedPositionContentView atIndex:0];
    } else {
        [self.view addArrangedSubview:fixedPositionContentView];
    }
    [self.view sendSubviewToBack:fixedPositionContentView];
    
    self.contentView = [[UIView alloc] initWithFrame:contentFrame];
    self.contentView.layer.anchorPoint = self.contentView.layer.position = CGPointMake(0, 0);
    self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [fixedPositionContentView addSubview:self.contentView];
    
    UIPanGestureRecognizer *moveGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveWindow:)];
    moveGesture.minimumNumberOfTouches = 1;
    moveGesture.maximumNumberOfTouches = 1;
    [self.navigationBar addGestureRecognizer:moveGesture];

    // Resize handle (idea stolen from Notes debugging window)
    UIPanGestureRecognizer *resizeGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(resizeWindow:)];
    resizeGesture.minimumNumberOfTouches = 1;
    resizeGesture.maximumNumberOfTouches = 1;
    self.resizeHandle = [[ResizeHandleView alloc] initWithFrame:CGRectMake(self.view.frame.size.width - LCResizeHandleSize, self.view.frame.size.height - LCResizeHandleSize, LCResizeHandleSize, LCResizeHandleSize)];
    self.resizeHandle.alpha = _isMaximized ? 0.0 : 1.0;
    [self.resizeHandle addGestureRecognizer:resizeGesture];
    [self.view addSubview:self.resizeHandle];
    
    self.view.layer.borderWidth = _isMaximized ? 0.0 : 1.0;
    self.view.layer.borderColor = UIColor.secondarySystemBackgroundColor.CGColor;
    
    [self addChildViewController:_appSceneVC];
    [self.view insertSubview:_appSceneVC.view atIndex:0];
    _appSceneVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    
    [self updateVerticalConstraints];
    [NSLayoutConstraint activateConstraints:@[
        [_appSceneVC.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_appSceneVC.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    
    
    NSUserDefaults *defaults = NSUserDefaults.lcSharedDefaults;

    [defaults addObserver:self forKeyPath:@"LCMultitaskBottomWindowBar" options:NSKeyValueObservingOptionNew context:NULL];
    [self updateOriginalFrame];
}


// Stolen from UIKitester
- (UIView *)scaleSliderViewWithTitle:(NSString *)title min:(CGFloat)minValue max:(CGFloat)maxValue value:(CGFloat)initialValue stepInterval:(CGFloat)step {
    UIView *containerView = [[UIView alloc] init];
    containerView.translatesAutoresizingMaskIntoConstraints = NO;
    containerView.exclusiveTouch = YES;

    UIStackView *stackView = [[UIStackView alloc] init];
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.spacing = 0.0;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [containerView addSubview:stackView];
    
    [NSLayoutConstraint activateConstraints:@[
        [stackView.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:10.0],
        [stackView.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-8.0],
        [stackView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:16.0],
        [stackView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-16.0]
    ]];
    
    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont boldSystemFontOfSize:12.0];
    [stackView addArrangedSubview:label];
    
    _UIPrototypingMenuSlider *slider = [[_UIPrototypingMenuSlider alloc] init];
    slider.minimumValue = minValue;
    slider.maximumValue = maxValue;
    slider.value = initialValue;
    slider.stepSize = step;
    
    NSLayoutConstraint *sliderHeight = [slider.heightAnchor constraintEqualToConstant:40.0];
    sliderHeight.active = YES;
    
    [stackView addArrangedSubview:slider];
    
    [slider addTarget:self action:@selector(scaleSliderChanged:) forControlEvents:UIControlEventValueChanged];
    
    return containerView;
}

- (void)scaleSliderChanged:(_UIPrototypingMenuSlider *)slider {
    self.scaleRatio = slider.value;
    self.appSceneVC.scaleRatio = _scaleRatio;
    if(self.appSceneVC.usesHostingControllerAPI) {
        self.appSceneVC.contentView.transform = CGAffineTransformMakeScale(_scaleRatio, _scaleRatio);
    } else {
        self.appSceneVC.contentView.layer.sublayerTransform = CATransform3DMakeScale(_scaleRatio, _scaleRatio, 1.0);
    }
    __weak typeof(self) weakSelf = self;
    [self.appSceneVC updateFrameWithSettingsBlock:^(UIMutableApplicationSceneSettings *settings) {
        if(weakSelf.isMaximized) {
            [weakSelf updateMaximizedSafeAreaWithSettings:settings];
        } else {
            // it seems some apps don't honor these settings so we don't cover the top of the app
            settings.peripheryInsets = UIEdgeInsetsZero;
            settings.safeAreaInsetsPortrait = UIEdgeInsetsZero;
        }
    }];
}

- (void)closeWindow {
    _isAppTerminationRequested = true;
    if([_appSceneVC isAppRunning]) {
        [_appSceneVC terminate];
    } else {
        [self appSceneVCAppDidExit:self.appSceneVC];
    }
}

- (void)minimizeWindow {
    if (self.view.hidden) return;
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha = 0;
        self.view.transform = CGAffineTransformMakeScale(0.1, 0.1);
    } completion:^(BOOL finished) {
        if (!finished) return;
        self.view.hidden = YES;
        self.view.transform = CGAffineTransformIdentity;
        [self.view.superview sendSubviewToBack:self.view];
        [[MultitaskDockManager shared] updateStatusBarFix];
    }];
}

- (void)minimizeWindowPiP {
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha = 0;
    } completion:^(BOOL finished) {
        self.view.hidden = YES;
    }];
}

- (void)unminimizeWindowPiP {
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.hidden = NO;
        self.view.alpha = 1;
    } completion:nil];
}

- (void)maximizeWindow {
    void (^updateSettingsBlock)(UIMutableApplicationSceneSettings *settings);
    
    [self.view layoutIfNeeded];
    if (self.isMaximized) {
        updateSettingsBlock = ^(UIMutableApplicationSceneSettings *settings) {
            [self updateWindowedFrameWithSettings:settings];
        };
        CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
        CGRect newFrame = CGRectMake(self.originalFrame.origin.x * maxFrame.size.width, self.originalFrame.origin.y * maxFrame.size.height, self.originalFrame.size.width, self.originalFrame.size.height);
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            self.view.frame = newFrame;
            self.view.layer.borderWidth = 1;
            self.view.layer.cornerRadius = 16;
            self.resizeHandle.alpha = 1;
            
            [self.appSceneVC updateSettingsWithBlock:updateSettingsBlock];
            
            [self.view layoutIfNeeded];
        } completion:^(BOOL finished) {
            self.isMaximized = NO;
            [[MultitaskDockManager shared] updateStatusBarFix];
            [self updateCornerHandles];
        }];
    } else {
        updateSettingsBlock = ^(UIMutableApplicationSceneSettings *settings) {
            [self updateMaximizedFrameWithSettings:settings];
        };
        [self updateOriginalFrame];
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            self.isMaximized = YES;
            [self updateVerticalConstraints];
            
            self.view.layer.borderWidth = 0;
            self.view.layer.cornerRadius = 0;
            self.resizeHandle.alpha = 0;
            
            [self.appSceneVC updateSettingsWithBlock:updateSettingsBlock];
            
            [self.view layoutIfNeeded];
        } completion:^(BOOL finished) {
            [[MultitaskDockManager shared] updateStatusBarFix];
            [self updateCornerHandles];
        }];
    }
}

- (void)appSceneVCAppDidExit:(AppSceneViewController*)vc {
    BOOL skipTerminationScreen = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCSkipTerminatedScreen"];
    BOOL isManual = _isAppTerminationRequested;
    if(isManual || skipTerminationScreen) {
        
        MultitaskDockManager *dock = [MultitaskDockManager shared];
        [dock removeRunningApp:self.dataUUID];
        
        self.view.layer.masksToBounds = NO;
        // 退出不播任何动画（Ann 2026-11-22 定）：上游的 0.4 秒卷页
        // （CurlUp）已整个去掉——不管是窗口栏关闭键、红 X，还是
        // App 自己退出（崩溃、保活到期后被系统回收），窗口都直接
        // 移除，免得重开 LC 时看到莫名其妙的翻页。
        self.view.hidden = YES;
        [self.view removeFromSuperview];
        
        if(skipTerminationScreen) {
            [MultitaskRelaunchManager scheduleRelaunchIfNeededWithBundleId:self.appSceneVC.bundleId dataUUID:self.dataUUID isManualTermination:isManual];
        }
    } else {
        UILabel *label = [[UILabel alloc] initWithFrame:self.view.bounds];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        label.lineBreakMode = NSLineBreakByWordWrapping;
        label.numberOfLines = 0;
        label.text = NSLocalizedString(@"lc.multitaskAppWindow.appTerminated", @"");
        label.textAlignment = NSTextAlignmentCenter;
        [self.view insertSubview:label atIndex:0];
    }
}

- (void)appSceneVC:(AppSceneViewController*)vc didInitializeWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if(error) {
            [vc appTerminationCleanUp];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"lc.common.error".loc message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.copy".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                UIPasteboard.generalPasteboard.string = error.localizedDescription;
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        } else {
            self.pid = vc.pid;
            [self updateOriginalFrame];
            if (self.pidAvailableHandler) {
                self.pidAvailableHandler(@(self.pid), nil);
            }
        }
    });
}

- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc {
    // Set up initial settings such as frame, safe area, etc
    [self appSceneVC:vc didUpdateFromSettings:vc.presenter.scene.settings.mutableCopy transitionContext:nil lifecycleActionType:0];
}

- (void)appSceneVC:(AppSceneViewController*)vc didUpdateFromSettings:(UIMutableApplicationSceneSettings *)baseSettings transitionContext:(id)newContext lifecycleActionType:(uint32_t)actionType {
    [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
        settings.userInterfaceStyle = baseSettings.userInterfaceStyle;
        settings.interfaceOrientation = baseSettings.interfaceOrientation;
        settings.deviceOrientation = baseSettings.deviceOrientation;
        settings.foreground = YES;
        
        if(self.isMaximized) {
            [self updateMaximizedFrameWithSettings:settings];
        } else {
            [self updateWindowedFrameWithSettings:settings];
        }
        CGRect newFrame = CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height - self.navigationBar.frame.size.height/self.scaleRatio);
        
        if(UIInterfaceOrientationIsLandscape(baseSettings.interfaceOrientation)) {
            settings.frame = CGRectMake(0, 0, newFrame.size.height, newFrame.size.width);
        } else {
            settings.frame = CGRectMake(0, 0, newFrame.size.width, newFrame.size.height);
        }
    }];
}

- (void)setTapOutsideScrimVisible:(BOOL)visible {
    if (visible) {
        if (self.tapOutsideScrim || !self.navigationBar) return;
        UIView *scrim = [[UIView alloc] initWithFrame:self.view.bounds];
        scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        // Fade in with the dock's expansion instead of snapping
        // on: an instant full-screen dim reads as a black flash
        // (Ann 2026-11-22).
        scrim.alpha = 0;
        // The scrim must carry a slight tint: fully clear views do
        // not claim touches in this window stack (proven twice on
        // device 2026-11-22 — the clear scrim and the hidden corner
        // wedges both went dead; the earlier 0.12 red test tint
        // worked). Black 0.10 reads as a gentle dim of the app
        // while the dock is expanded, nothing more.
        scrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.10];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapOutsideScrimTapped)];
        [scrim addGestureRecognizer:tap];
        // Insert above the scene view and its content container, below
        // the window bar and the resize handle (both direct subviews
        // of self.view and both must stay interactive).
        NSInteger barIndex = [self.view.subviews indexOfObject:self.navigationBar];
        NSInteger handleIndex = self.resizeHandle ? [self.view.subviews indexOfObject:self.resizeHandle] : NSNotFound;
        NSInteger targetIndex = (handleIndex == NSNotFound) ? barIndex : MIN(barIndex, handleIndex);
        [self.view insertSubview:scrim atIndex:targetIndex];
        self.tapOutsideScrim = scrim;
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            scrim.alpha = 1;
        } completion:nil];
    } else {
        UIView *scrim = self.tapOutsideScrim;
        if (!scrim) return;
        self.tapOutsideScrim = nil;
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            scrim.alpha = 0;
        } completion:^(BOOL finished) {
            [scrim removeFromSuperview];
        }];
    }
}

- (void)tapOutsideScrimTapped {
    // The tap is consumed by the scrim (the guest app never sees it);
    // all it does is collapse the dock.
    [[MultitaskDockManager shared] toggleDockCollapse];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    [self.view layoutIfNeeded];
    [UIView animateWithDuration:0.3 animations:^{
        BOOL bottomWindowBar = [change[NSKeyValueChangeNewKey] boolValue];
        if(bottomWindowBar) {
            [self.view addArrangedSubview:self.navigationBar];
        } else {
            [self.view insertArrangedSubview:self.navigationBar atIndex:0];
        }
        // 按钮位置不随栏的位置变（恒左三钮、右箭头）；变的只是
        // 底部栏时箭头钮要给右下缩放把手让位（refreshBarOverlay）。
        [self refreshBarOverlay];
        [self updateVerticalConstraints];
        
        if(_isMaximized) {
            [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [self updateMaximizedFrameWithSettings:settings];
            }];
        }
        [self.view layoutIfNeeded];
    }];
}

- (void)moveWindow:(UIPanGestureRecognizer*)sender {
    if(_isMaximized) return;
    
    CGPoint point = [sender translationInView:self.view];
    [sender setTranslation:CGPointZero inView:self.view];

    self.view.center = CGPointMake(self.view.center.x + point.x, self.view.center.y + point.y);
    [self updateOriginalFrame];
}

- (void)resizeWindow:(UIPanGestureRecognizer*)sender {
    if(_isMaximized) return;
    
    CGPoint point = [sender translationInView:self.view];
    [sender setTranslation:CGPointZero inView:self.view];

    CGRect frame = self.view.frame;
    frame.size.width = MAX(50, frame.size.width + point.x);
    frame.size.height = MAX(50, frame.size.height + point.y);
    self.view.frame = frame;
    [self updateOriginalFrame];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    // FIXME: how to bring view to front when touching the passthrough view?
    [self.view.superview bringSubviewToFront:self.view];
}

// 是否隐藏窗口栏（操作栏），由独立开关「隐藏操作栏」
// （LCHideWindowBar）控制（Ann 2026-11-22 定）：开 = 所有多任务
// 窗口都不显示窗口栏，不分最大化还是小窗口；关 = 窗口栏常在。
// 「默认最大化多任务窗口」（LCLaunchMultitaskMaximized）已恢复
// 原生职责，只决定窗口打开时是否最大化，不再掺和窗口栏。
- (BOOL)shouldHideWindowBar {
    return [NSUserDefaults.lcUserDefaults boolForKey:@"LCHideWindowBar"];
}

// 四角把手（Ann 2026-11-22 定）：形态照抄右下角现有的缩放把手
// （ResizeHandleView，44×44、半透明白三角），只是功能不同——
// 左上移动、右上最大化/还原、左下最小化（右下缩放是原有的，
// 不归这里管）。仅在「隐藏操作栏」开启时生效：操作栏在时有它
// 的按钮和拖动，不需要四角。ResizeHandleView 的三角长在右下
// 角（东南），其余三个角靠旋转/翻转把手视图把三角转过去：
// 左上 = 旋转 180° 到西北；右上 = 垂直翻转 (1,-1) 到东北；
// 左下 = 水平翻转 (-1,1) 到西南。（右上/左下的翻转曾经写反，
// 三角跑到了把手框的内侧角，Ann 2026-11-22 真机发现后修正。）
// 注意：三角不能全透明——试过只藏楔形子视图，四角操作全部
// 失效（Ann 2026-11-22 真机证伪），已恢复上游的半透明楔形。
- (void)updateCornerHandles {
    BOOL active = [self shouldHideWindowBar];
    if (active && !self.moveHandle) {
        CGFloat size = 44;
        CGRect bounds = self.view.bounds;
        // 左上：移动（拖动）
        self.moveHandle = [[ResizeHandleView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
        self.moveHandle.transform = CGAffineTransformMakeRotation(M_PI);
        self.moveHandle.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        UIPanGestureRecognizer *move = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveWindow:)];
        move.minimumNumberOfTouches = 1;
        move.maximumNumberOfTouches = 1;
        [self.moveHandle addGestureRecognizer:move];
        [self.view addSubview:self.moveHandle];
        // 右上：最大化/还原（点击）
        self.maximizeHandle = [[ResizeHandleView alloc] initWithFrame:CGRectMake(bounds.size.width - size, 0, size, size)];
        self.maximizeHandle.transform = CGAffineTransformMakeScale(1, -1);
        self.maximizeHandle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        [self.maximizeHandle addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(maximizeWindow)]];
        [self.view addSubview:self.maximizeHandle];
        // 左下：最小化（点击）
        self.minimizeHandle = [[ResizeHandleView alloc] initWithFrame:CGRectMake(0, bounds.size.height - size, size, size)];
        self.minimizeHandle.transform = CGAffineTransformMakeScale(-1, 1);
        self.minimizeHandle.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
        [self.minimizeHandle addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(minimizeWindow)]];
        [self.view addSubview:self.minimizeHandle];
    }
    // 最大化时四角把手全撤（Ann 2026-11-22 定，左下是最后撤的）：
    // 左上移动无意义（moveWindow 直接返回），右上还原不好点，
    // 左下最小化贴着圆角也不好点。最大化后的还原走展开坞里
    // 双击当前 App 图标。
    self.moveHandle.hidden = !active || self.isMaximized;
    self.maximizeHandle.hidden = !active || self.isMaximized;
    self.minimizeHandle.hidden = !active || self.isMaximized;
}

- (void)updateVerticalConstraints {
    [self.view layoutIfNeeded];
    [UIView animateWithDuration:0.3 animations:^{
        BOOL bottomWindowBar = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"];
        BOOL hideWindowBar = [self shouldHideWindowBar];
        CGFloat navBarHeight = hideWindowBar ? 0 : LCWindowBarHeight;
        self.navigationBar.alpha = hideWindowBar ? 0 : 1;
        self.navigationBar.hidden = hideWindowBar;
        // 悬浮层的钮跟栏一起显隐。
        self.lightsView.alpha = hideWindowBar ? 0 : 1;
        self.lightsView.hidden = hideWindowBar;
        self.menuButton.alpha = hideWindowBar ? 0 : 1;
        self.menuButton.hidden = hideWindowBar;
        
        // Update safe area insets
        if(self.isMaximized) {
            self.appSceneVC.shouldSkipDebounceOnce = YES;
            __weak typeof(self) weakSelf = self;
            [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [weakSelf updateMaximizedFrameWithSettings:settings];
            }];
        }
        
        [NSLayoutConstraint deactivateConstraints:self.activatedVerticalConstraints];
        if(bottomWindowBar) {
            self.activatedVerticalConstraints = @[
                [self.appSceneVC.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
                [self.appSceneVC.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-navBarHeight],
                [self.navigationBar.heightAnchor constraintEqualToConstant:navBarHeight]
            ];
        } else {
            // 顶栏模式：画面顶边不再让出栏高，而是上移
            // LCWindowTopCrop 伸到栏底下（见 LCWindowTopCrop 的
            // 注释）；栏隐藏时没有遮盖，画面回到窗口顶边不裁。
            CGFloat sceneTop = hideWindowBar ? 0 : -LCWindowTopCrop;
            self.activatedVerticalConstraints = @[
                [self.appSceneVC.view.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:sceneTop],
                [self.appSceneVC.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
                [self.navigationBar.heightAnchor constraintEqualToConstant:navBarHeight]
            ];
        }
        [NSLayoutConstraint activateConstraints:self.activatedVerticalConstraints];

        [self.view layoutIfNeeded];
    }];
    [self updateCornerHandles];
}

- (UIEdgeInsets)updateMaximizedSafeAreaWithSettings:(UIMutableApplicationSceneSettings *)settings {
    BOOL bottomWindowBar = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"];
    UIEdgeInsets safeAreaInsets = self.view.window.safeAreaInsets;
    if(self.navigationBar.hidden) {
        settings.peripheryInsets = safeAreaInsets;
        safeAreaInsets = UIEdgeInsetsZero;
    } else if(bottomWindowBar) {
        // allow the control bar to overlap the bottom safe area
        safeAreaInsets.bottom = 0;
        settings.peripheryInsets = safeAreaInsets;
        safeAreaInsets.top = safeAreaInsets.left = safeAreaInsets.right = 0;
    } else {
        settings.peripheryInsets = UIEdgeInsetsMake(0, safeAreaInsets.left, safeAreaInsets.bottom, safeAreaInsets.right);
        safeAreaInsets.bottom = safeAreaInsets.left = safeAreaInsets.right = 0;
        // 探针（Ann 2026-11-22 晚）：最大化窗口顶边上移 20 点，
        // 看状态栏下方那两条淡影线跟不跟着窗口走。跟着走 = 线是
        // 窗口的；留在原地（屏幕 y≈58）= 线是状态栏那侧的。定性
        // 后决定去留。
        safeAreaInsets.top = MAX(0, safeAreaInsets.top - 20);
    }
    
    // scale peripheryInsets to match the scale ratio
    settings.peripheryInsets = UIEdgeInsetsMake(settings.peripheryInsets.top/_scaleRatio, settings.peripheryInsets.left/_scaleRatio, settings.peripheryInsets.bottom/_scaleRatio, settings.peripheryInsets.right/_scaleRatio);
    if(UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) {
        UIInterfaceOrientation currentOrientation = UIApp.statusBarOrientation;
        if(UIInterfaceOrientationIsLandscape(currentOrientation)) {
            safeAreaInsets.top = 0;
        }
        settings.safeAreaInsetsPortrait = LCUIEdgeInsetsRotateToOrientation(settings.peripheryInsets, currentOrientation);

    } else {
        settings.safeAreaInsetsPortrait = UIEdgeInsetsMake(settings.peripheryInsets.top, settings.peripheryInsets.left, settings.peripheryInsets.bottom, settings.peripheryInsets.right);
    }
    
    safeAreaInsets.bottom = 0;
    return safeAreaInsets;
}

- (void)updateMaximizedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, [self updateMaximizedSafeAreaWithSettings:settings]);
    self.view.frame = maxFrame;
}

- (void)updateWindowedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
    UIEdgeInsets safeAreaInsets = self.view.window.safeAreaInsets;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, safeAreaInsets);
    settings.peripheryInsets = UIEdgeInsetsZero;
    settings.safeAreaInsetsPortrait = UIEdgeInsetsZero;
    
    CGRect newFrame = CGRectMake(self.originalFrame.origin.x * maxFrame.size.width, self.originalFrame.origin.y * maxFrame.size.height, self.originalFrame.size.width, self.originalFrame.size.height);
    CGPoint center = self.view.center;
    CGRect frame = CGRectZero;
    frame.size.width = MIN(newFrame.size.width, maxFrame.size.width);
    frame.size.height = MIN(newFrame.size.height, maxFrame.size.height);
    CGFloat oobOffset = MAX(30, frame.size.width - 30);
    frame.origin.x = MAX(maxFrame.origin.x - oobOffset, MIN(CGRectGetMaxX(maxFrame) - frame.size.width + oobOffset, center.x - frame.size.width / 2));
    frame.origin.y = MAX(maxFrame.origin.y, MIN(center.y - frame.size.height / 2, CGRectGetMaxY(maxFrame) - frame.size.height));
    [UIView animateWithDuration:0.3 animations:^{
        self.view.frame = frame;
    }];
}

- (void)updateOriginalFrame {
    if(_isMaximized) return;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
    // save origin as normalized coordinates
    self.originalFrame = CGRectMake(self.view.frame.origin.x / maxFrame.size.width, self.view.frame.origin.y / maxFrame.size.height, self.view.frame.size.width, self.view.frame.size.height);
}

@end
