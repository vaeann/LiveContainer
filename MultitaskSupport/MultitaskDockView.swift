//
//  MultitaskDockView.swift
//  LiveContainer
//
//  Created by boa-z on 2025/6/28.
//

import Foundation
import SwiftUI
import UIKit
import Combine

// MARK: - App Info Provider
class AppInfoProvider {
    
    static let shared = AppInfoProvider()
    
    private var infoCacheByUUID = [String: LCAppInfo]()
    private var infoCacheByName = [String: LCAppInfo]()
    private let cacheQueue = DispatchQueue(label: "com.livecontainer.appinfoprovider.cachequeue", attributes: .concurrent)
    
    private init() {}
    
    public func findAppInfo(appName: String, dataUUID: String) -> LCAppInfo? {
        if let appInfo = findAppInfoFromSharedModel(appName: appName, dataUUID: dataUUID) {
            return appInfo
        }
        if let appInfo = findAppInfo(byUUID: dataUUID) {
            return appInfo
        }
        return findAppInfo(byName: appName)
    }
    
    public func findAppInfo(byUUID dataUUID: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByUUID[dataUUID] }) {
            return cachedInfo
        }
        
        guard let appGroupPath = LCSharedUtils.appGroupPath()?.path else { return nil }
        
        let searchPaths = [
            "\(appGroupPath)/LiveContainer/Data/Application/\(dataUUID)/LCAppInfo.plist",
            "\(appGroupPath)/Containers/\(dataUUID)/LCAppInfo.plist",
            "\(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "")/Data/Application/\(dataUUID)/LCAppInfo.plist"
        ]
        
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path),
               let appInfoDict = NSDictionary(contentsOfFile: path),
               let bundlePath = appInfoDict["bundlePath"] as? String,
               let appInfo = LCAppInfo(bundlePath: bundlePath) {
                
                cacheQueue.async(flags: .barrier) { self.infoCacheByUUID[dataUUID] = appInfo }
                return appInfo
            }
        }
        return nil
    }

    public func findAppInfo(byName appName: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByName[appName] }) {
            return cachedInfo
        }

        var searchPaths: [String] = []
        if let appGroupPath = LCSharedUtils.appGroupPath()?.path {
            searchPaths.append("\(appGroupPath)/LiveContainer/Applications")
        }
        if let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path {
            searchPaths.append("\(docPath)/Applications")
        }

        for appsPath in searchPaths {
            guard let appDirs = try? FileManager.default.contentsOfDirectory(atPath: appsPath) else { continue }
            
            for appDir in appDirs where appDir.hasSuffix(".app") {
                if let appInfo = LCAppInfo(bundlePath: "\(appsPath)/\(appDir)"), appInfo.displayName() == appName {
                    cacheQueue.async(flags: .barrier) { self.infoCacheByName[appName] = appInfo }
                    return appInfo
                }
            }
        }
        return nil
    }

    private func findAppInfoFromSharedModel(appName: String, dataUUID: String) -> LCAppInfo? {
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        
        for appModel in allApps {
            if appModel.appInfo.containers.contains(where: { $0.folderName == dataUUID }) {
                return appModel.appInfo
            }
        }
        
        for appModel in allApps {
            if appModel.appInfo.displayName() == appName {
                return appModel.appInfo
            }
        }
        return nil
    }
    
    public func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.infoCacheByUUID.removeAll()
            self.infoCacheByName.removeAll()
        }
    }
}

// MARK: - App Model for Dock
@objc class DockAppModel: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    @objc let appName: String
    @objc let appUUID: String
    let appInfo: LCAppInfo?
    let view: UIView?
    
    @objc init(appName: String, appUUID: String, appInfo: LCAppInfo? = nil, view: UIView?) {
        self.appName = appName
        self.appUUID = appUUID
        self.appInfo = appInfo
        self.view = view
        super.init()
    }
}

// MARK: - MultitaskDockView Manager
@available(iOS 16.0, *)
@objc public class MultitaskDockManager: NSObject, ObservableObject {
    @objc public static let shared = MultitaskDockManager()
    
    @Published var apps: [DockAppModel] = []
    @Published var isVisible: Bool = false
    /// The dock's resting state is the collapsed button; expanding is a
    /// deliberate double-tap, so a fresh multitask session never opens
    /// with the dock already expanded.
    @Published @objc var isCollapsed: Bool = true
    @Published var settingsChanged: Bool = false

    /// The dock no longer hides off-screen: it stays visible at 60%
    /// opacity and dims to 20% after 3 seconds without interaction.
    @Published var isDockIdleDimmed: Bool = false

    /// Whether the dock is currently slid to the screen edge
    /// (hide-to-side). 微珠's multitask takeover probes the @objc
    /// methods that drive this state (showDockFromHidden,
    /// toggleDockVisibility, hideDockToSide) by name.
    @Published var isDockHidden: Bool = false
    private var dockIdleTimer: Timer?

    /// Status bar fix state: whether the host status bar override is
    /// currently applied.
    private var statusBarFixApplied = false

    /// The app currently in front in multitask (nil when every window
    /// is minimized, i.e. the user is on the LC home screen). The dock
    /// marks its icon with a breathing green dot. Maintained by
    /// updateStatusBarFix(), which already runs on every front-app
    /// change.
    @Published var frontAppUUID: String?
    /// The app that was in front before the current one — or the
    /// last one before everything went home: the collapsed orb's
    /// long press jumps back to it (Ann 2026-11-23).
    var previousAppUUID: String?

    /// Reset the idle-dim countdown; any dock interaction counts.
    public func noteDockInteraction() {
        DispatchQueue.main.async {
            self.isDockIdleDimmed = false
            self.dockIdleTimer?.invalidate()
            self.dockIdleTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                // Idle dimming applies to the collapsed button only; the
                // expanded dock is always fully opaque.
                if self.isCollapsed {
                    self.isDockIdleDimmed = true
                }
            }
        }
    }

    @objc public var windowHostingView = VirtualWindowsHostView()

    /// Tap-outside scrim （挡板）, second placement: the scrim lives
    /// inside each visible guest window's container (DecoratedApp-
    /// SceneViewController), above the scene and below the window bar
    /// and resize handle — the one spot proven to receive touches
    /// over a scene (the window bar does). The first attempt put the
    /// scrim in the key window above the app windows; on device the
    /// scene's remote layer still claimed those touches, so it never
    /// fired. Still pure host-side hit-testing: no cross-process
    /// machinery, no sendEvent hooks (both bisect-proven dead ends).
    /// Synced from updateDockFrame and hideDock; the per-window
    /// scrim carries a faint black 0.10 tint (a clear view claims
    /// no touches in this stack). A matching full-screen backdrop
    /// inside the hosting view covers the non-window areas.
    internal var hostingController: UIHostingController<AnyView>?
    private var tapOutsideBackdrop: UIView?

    public struct Constants {
        // MARK: - Layout & Sizing
        static let defaultDockWidth: CGFloat = 90.0
        static let minAdaptiveDockWidth: CGFloat = 50.0
        static let minAdaptiveIconSize: CGFloat = 10.0
        static let maxIconSize: CGFloat = 100.0
        static let minCollapsedButtonSize: CGFloat = 44.0
        static let maxCollapsedButtonSize: CGFloat = 80.0
        static let initialDockShowHeight: CGFloat = 120.0

        // MARK: - Margins & Padding
        static let adaptiveWidthVerticalMargin: CGFloat = 20.0
        static let dockVerticalMargin: CGFloat = 30.0
        static let dockContentSpacing: CGFloat = 8.0
        static let dockVerticalPadding: CGFloat = 30.0
        // Extra padding is derived from dockVerticalPadding to match the SwiftUI layout exactly
        
        // MARK: - Ratios & Factors
        // 0.68 (Ann 2026-11-23, recalculated): at the old 0.75 the
        // icons filled the pill — 11.25 pt of side glass at width 90
        // read as oversized and cramped. 0.68 leaves a side margin of
        // ~24% of the icon size, ~1.8x the 8 pt inter-icon spacing:
        // icons 61.2, margins 14.4 at the default width.
        static let iconToWidthRatio: CGFloat = 0.68
        static let collapsedButtonToWidthRatio: CGFloat = 0.7
        static let maxHeightRatioOfAvailableArea: CGFloat = 0.85
        
        // MARK: - Animation & Interaction

        static var dockHiddenOffset: CGFloat {
            let ans = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
            if ans != 0 {
                return ans * 2 / 3
            } else {
                return 50
            }
        }
        static let edgeSwipeThreshold: CGFloat = 30.0

        static let standardAnimationDuration: TimeInterval = 0.3
        static let longAnimationDuration: TimeInterval = 0.4
        
        static let standardSpringDamping: CGFloat = 0.8
        static let standardSpringVelocity: CGFloat = 0.3

        // Show/hide (Ann 2026-11-23): a calm materialize, not a
        // performance — the old entrance grew from 0.8 on a 0.7-
        // damping spring and overshot, which read as a flash every
        // time the first app of a session launched. Both directions
        // now use the same small scale, plain ease curves, and the
        // exit is a touch faster than the entrance.
        static let showHideScale: CGFloat = 0.92
        static let showAnimationDuration: TimeInterval = 0.22
        static let hideAnimationDuration: TimeInterval = 0.18
    }
    
    // Original dock width from user settings (without auto-adjustment)
    private var originalDockWidth: CGFloat {
        let storedValue = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
        return storedValue > 0 ? CGFloat(storedValue) : Constants.defaultDockWidth
    }
    
    // Calculate adaptive dock width (auto-adjust when exceeding safe area)
    public var dockWidth: CGFloat {
        guard !apps.isEmpty else { return originalDockWidth }
        
        let totalVerticalMargin = Constants.adaptiveWidthVerticalMargin * 2
        let availableHeight = self.safeAreaHeight - totalVerticalMargin
        
        let maxSafeHeight = availableHeight * Constants.maxHeightRatioOfAvailableArea
        
        let userWidth = originalDockWidth
        let iconSize = calculateIconSize(for: userWidth)
        let requiredHeight = expandedDockHeight(for: userWidth, iconSize: iconSize)
        
        if requiredHeight > maxSafeHeight && !apps.isEmpty {
            let buttonSize = calculateButtonSize(for: userWidth)
            let baseHeight = expandedDockBaseHeight(for: userWidth, buttonSize: buttonSize)
            let availableForIcons = maxSafeHeight - baseHeight
            let maxAllowedIconSize = availableForIcons / CGFloat(apps.count)
            
            let targetIconSize = max(Constants.minAdaptiveIconSize, maxAllowedIconSize)
            
            let targetWidth = targetIconSize / Constants.iconToWidthRatio
            
            return max(Constants.minAdaptiveDockWidth, targetWidth)
        }
        
        return userWidth
    }
    
    // Calculate icon size based on dock width
    private func calculateIconSize(for width: CGFloat) -> CGFloat {
        let iconSize = width * Constants.iconToWidthRatio
        return max(Constants.minAdaptiveIconSize, min(Constants.maxIconSize, iconSize))
    }

    private func calculateButtonSize(for width: CGFloat) -> CGFloat {
        let targetSize = width * Constants.collapsedButtonToWidthRatio
        return max(Constants.minCollapsedButtonSize, min(Constants.maxCollapsedButtonSize, targetSize))
    }

    /// Extra end inset the pill shape needs beyond the side
    /// padding. A capsule's end is a semicircle of radius width/2;
    /// a square icon of the adaptive size only fits under that
    /// curve once its top edge clears
    /// width/2 - sqrt(width² - icon²)/2 — with the plain side
    /// padding the first icon's corners cross the glass outline
    /// (Ann 2026-11-22). Two points of air on top of the bare
    /// geometric minimum.
    func dockEndExtra(for width: CGFloat) -> CGFloat {
        let iconSize = calculateIconSize(for: width)
        let needed = width / 2 - (width * width - iconSize * iconSize).squareRoot() / 2
        // The +2 is the original snug fit; the extra +7 is
        // breathing room (Ann 2026-11-23: with the end icons
        // grazing the arc — a couple of points of glass at their
        // corners against ~17 at the tip — the pill's ends read
        // as pointy; more glass around the end icons makes the
        // caps read round instead).
        return max(0, needed - 4) + 9
    }

    private func expandedDockBaseHeight(for width: CGFloat, buttonSize: CGFloat) -> CGFloat {
        // Expanded dock contents: the app icons and the home button
        // at the bottom — (apps.count + 1) items, apps.count gaps
        // between them, and one button-height allowance. (The
        // collapse button that used to sit on top is gone: tapping
        // outside the dock collapses it now, both on the LC home
        // screen and from inside the front guest.) The pill's curved
        // ends add their own allowance on top of the vertical
        // padding, mirrored by the layout's vertical padding.
        let spacingCount = max(self.apps.count, 0)
        let totalSpacingHeight = CGFloat(spacingCount) * Constants.dockContentSpacing
        return Constants.dockVerticalPadding + buttonSize + totalSpacingHeight + 2 * dockEndExtra(for: width)
    }

    private func expandedDockHeight(for width: CGFloat, iconSize: CGFloat) -> CGFloat {
        let buttonSize = calculateButtonSize(for: width)
        let baseHeight = expandedDockBaseHeight(for: width, buttonSize: buttonSize)
        let iconHeight = CGFloat(self.apps.count) * iconSize
        return baseHeight + iconHeight
    }

    private func collapsedDockHeight(for width: CGFloat) -> CGFloat {
        // 正圆（Ann 2026-11-23 定）：收起帧高直接等于宽，胶囊
        // 在正方形帧里就是正圆，圆弧半径与展开坞的端弧同为
        // 宽/2。旧公式（留白 30 + 按钮尺寸）是收起态还有按钮
        // 瓷砖时代的遗留；现在收起态只有字形（0.75×宽）加小
        // 留白，远小于宽，不会挤。
        return width
    }
    

    // Calculate adaptive icon size
    public var adaptiveIconSize: CGFloat {
        return calculateIconSize(for: dockWidth)
    }

    public var keyWindow: UIWindow? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first
    }

    public var safeAreaInsets: UIEdgeInsets {
        if #available(iOS 11.0, *) {
            return keyWindow?.safeAreaInsets ?? .zero
        }
        return .zero
    }

    private var safeAreaHeight: CGFloat {
        keyWindow!.bounds.height - safeAreaInsets.top - safeAreaInsets.bottom
    }
    
    override init() {
        super.init()
        keyWindow!.rootViewController!.view.subviews.first!.addSubview(self.windowHostingView)
        setupDockView()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: LCUtils.appGroupUserDefault
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    @objc private func deviceOrientationDidChange() {
        DispatchQueue.main.async {
            if self.isVisible {
                self.updateDockFrame()
            }
        }
    }
    
    @objc private func userDefaultsDidChange() {
        DispatchQueue.main.async {
            self.settingsChanged.toggle()
            if self.isVisible {
                self.updateDockFrame()
            }
        }
    }
    
    private func setupDockView() {
        DispatchQueue.main.async {
            let dockView = AnyView(MultitaskDockSwiftView()
                .environmentObject(self))
            
            self.hostingController = UIHostingController(rootView: dockView)
            self.hostingController?.view.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin, .flexibleRightMargin, .flexibleBottomMargin]
            self.hostingController?.view.backgroundColor = .clear
        }
    }

    private func updateDockFrame(animated: Bool = true) {
        guard let hostingController = hostingController else { return }

        let screenBounds = keyWindow!.bounds
        let currentDockWidth = self.dockWidth
        
        let dockHeight = calculateTargetDockHeight(forWidth: currentDockWidth)

        let currentFrame = hostingController.view.frame
        let isOnRightSide = (currentFrame.midX > screenBounds.width / 2) || (currentFrame.isEmpty)
        let targetX = calculateTargetX( 
                                    isDockHidden: self.isDockHidden, isOnRightSide: isOnRightSide, 
                                    dockWidth: currentDockWidth, 
                                    screenWidth: screenBounds.width)

        let targetY = calculateTargetY(for: currentFrame, 
                                    dockHeight: dockHeight, 
                                    screenHeight: screenBounds.height)
        
        let newFrame = CGRect(x: targetX, y: targetY, width: currentDockWidth, height: dockHeight)

        applyNewFrame(newFrame, for: hostingController, animated: animated)
        updateStatusBarFix()
        syncTapOutsideScrim()
    }

    /// Keep the tap-outside scrim in step with the dock: present on
    /// every visible guest window only while the dock is visible,
    /// expanded and not hidden to the side.
    private func syncTapOutsideScrim() {
        let shouldShow = isVisible && !isCollapsed && !isDockHidden
        for app in apps {
            guard let view = app.view, !view.isHidden, view.alpha >= 0.1,
                  let vc = view._viewDelegate() as? DecoratedAppSceneViewController else { continue }
            vc.setTapOutsideScrimVisible(shouldShow)
        }
        // The per-window scrims only cover the window areas; the
        // rest of the screen (LC's home interface around and
        // between windows) gets a matching backdrop inside the
        // hosting view, below every window, so the dim is uniform
        // and a tap on a blank area collapses the dock too
        // (Ann 2026-11-22).
        if shouldShow {
            if let backdrop = tapOutsideBackdrop {
                // Re-shown while a fade-out was still running:
                // just fade back in.
                UIView.animate(withDuration: 0.3) { backdrop.alpha = 1 }
            } else {
                let backdrop = UIView(frame: windowHostingView.bounds)
                backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                // Same 0.10 black as the per-window scrims — and
                // the tint is load-bearing: clear views do not
                // claim touches in this window stack.
                backdrop.backgroundColor = UIColor(white: 0, alpha: 0.10)
                backdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapOutsideBackdropTapped)))
                // Fade in with the dock's expansion instead of
                // snapping on: an instant full-screen dim reads
                // as a black flash (Ann 2026-11-22).
                backdrop.alpha = 0
                windowHostingView.insertSubview(backdrop, at: 0)
                tapOutsideBackdrop = backdrop
                UIView.animate(withDuration: 0.3) { backdrop.alpha = 1 }
            }
        } else if let backdrop = tapOutsideBackdrop {
            tapOutsideBackdrop = nil
            UIView.animate(withDuration: 0.25, animations: {
                backdrop.alpha = 0
            }, completion: { _ in
                backdrop.removeFromSuperview()
            })
        }
    }

    @objc private func tapOutsideBackdropTapped() {
        toggleDockCollapse()
    }

    // MARK: - Frame Calculation Helpers

    private func calculateTargetDockHeight(forWidth width: CGFloat) -> CGFloat {
        if isCollapsed {
            // No height floor here: one would break the perfect
            // circle at narrow widths (see collapsedDockHeight).
            return collapsedDockHeight(for: width)
        } else {
            let currentIconSize = calculateIconSize(for: width)
            return expandedDockHeight(for: width, iconSize: currentIconSize)
        }
    }

    func calculateTargetX(isDockHidden: Bool, isOnRightSide: Bool, dockWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {

        let safeInsets = self.safeAreaInsets
        var ans : CGFloat
        if isOnRightSide {
            ans = screenWidth - dockWidth
            if self.hostingController?.view.window?.windowScene?.interfaceOrientation == UIInterfaceOrientation.landscapeLeft {
                ans -= safeInsets.right
            }

            if isDockHidden {
                ans += Constants.dockHiddenOffset
            }
        } else {
            ans = 0
            if self.hostingController?.view.window?.windowScene?.interfaceOrientation == UIInterfaceOrientation.landscapeRight {
                ans += safeInsets.left
            }
            if isDockHidden {
                ans -= Constants.dockHiddenOffset
            }
        }

        return ans;

    }

    private func calculateTargetY(for currentFrame: CGRect, dockHeight: CGFloat, screenHeight: CGFloat) -> CGFloat {
        let safeAreaMinY = self.safeAreaInsets.top + Constants.dockVerticalMargin
        let safeAreaMaxY = screenHeight - self.safeAreaInsets.bottom - dockHeight - Constants.dockVerticalMargin
        
        if currentFrame.height > 0 {
            let desiredY = currentFrame.midY - dockHeight / 2
            return max(safeAreaMinY, min(safeAreaMaxY, desiredY))
        } else {
            let safeAreaCenterY = safeAreaMinY + (safeAreaMaxY - safeAreaMinY) / 2
            return max(safeAreaMinY, min(safeAreaMaxY, safeAreaCenterY - dockHeight / 2))
        }
    }

    private func applyNewFrame(_ newFrame: CGRect, for hostingController: UIHostingController<AnyView>, animated: Bool) {
        if animated {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.standardSpringDamping,
                initialSpringVelocity: Constants.standardSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.frame = newFrame
            }
        } else {
            hostingController.view.frame = newFrame
        }
    }
    
    @objc public func addRunningApp(_ appName: String, appUUID: String, view: UIView?) {
        let appInfo = AppInfoProvider.shared.findAppInfo(appName: appName, dataUUID: appUUID)
        addRunningAppWithInfo(appInfo, appUUID: appUUID, view: view)
    }
    
    @objc public func removeRunningApp(_ appUUID: String) {
        guard isDockEnabled() else { return }
        
        DispatchQueue.main.async {
            self.noteDockInteraction()
            self.apps.removeAll { $0.appUUID == appUUID }
            
            if self.apps.isEmpty {
                self.hideDock()
            } else if self.isVisible {
                self.updateDockFrame()
            }
            self.updateStatusBarFix()
        }
    }
    
    @objc public func showDock() {
        guard isDockEnabled() else { return }
        guard !isVisible, let hostingController = hostingController else { return }
        
        guard let keyWindow = self.keyWindow else { return }
        
        DispatchQueue.main.async {
            self.isVisible = true
            // A fresh multitask session always starts from the collapsed
            // button, even if the previous session ended expanded.
            self.isCollapsed = true
            self.noteDockInteraction()

            let screenBounds = keyWindow.bounds
            let currentDockWidth = self.dockWidth
            let initialHeight = Constants.initialDockShowHeight
            
            // If not already in view hierarchy, add it
            if hostingController.view.superview == nil {
                keyWindow.addSubview(hostingController.view)
                hostingController.view.frame = CGRect(
                    x: screenBounds.width - currentDockWidth,
                    y: (screenBounds.height - initialHeight) / 2,
                    width: currentDockWidth,
                    height: initialHeight
                )
            }
            
            self.updateDockFrame(animated: false)
            
            self.setupEdgeGestureRecognizers()

            
            hostingController.view.alpha = 0
            hostingController.view.transform = CGAffineTransform(scaleX: Constants.showHideScale, y: Constants.showHideScale)

            UIView.animate(
                withDuration: Constants.showAnimationDuration,
                delay: 0,
                options: .curveEaseOut
            ) {
                hostingController.view.alpha = 1
                hostingController.view.transform = .identity
            }
        }
    }
    
    @objc public func hideDock() {
        guard isVisible, let hostingController = hostingController else { return }

        DispatchQueue.main.async {
            // Fade out in place (Ann 2026-11-23): the old exit also
            // shrank to 0.8 and slid the dock off-screen mid-fade —
            // motion nobody could see, plus a frame jump to undo on
            // the next show. At alpha 0 the view takes no touches,
            // and showDock re-frames before fading back in anyway.
            UIView.animate(
                withDuration: Constants.hideAnimationDuration,
                delay: 0,
                options: .curveEaseIn
            ) {
                hostingController.view.alpha = 0
                hostingController.view.transform = CGAffineTransform(scaleX: Constants.showHideScale, y: Constants.showHideScale)
            } completion: { _ in
                self.isVisible = false
                // The next session starts collapsed again (see showDock).
                self.isCollapsed = true
                hostingController.view.transform = .identity
                self.syncTapOutsideScrim()
            }
        }
    }

    // Toggle dock hide/show state (hide-to-side). 微珠's multitask
    // takeover probes these @objc methods by name and hooks them;
    // their signatures must stay exactly as they are.
    @objc public func toggleDockVisibility() {
        DispatchQueue.main.async {
            self.isDockHidden.toggle()
            self.updateDockFrame()
        }
    }

    @objc public func showDockFromHidden() {
        DispatchQueue.main.async {
            self.isDockHidden = false
            self.updateDockFrame()
            self.setupEdgeGestureRecognizers()
        }
    }

    @objc public func hideDockToSide() {
        DispatchQueue.main.async {
            self.isDockHidden = true
            self.updateDockFrame()
            self.setupEdgeGestureRecognizers()
        }
    }

    // Add edge gesture recognition areas when dock is hidden
    private func setupEdgeGestureRecognizers() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let keyWindow = windowScene.windows.first else { return }

        keyWindow.gestureRecognizers?.removeAll { gesture in
            return gesture is UITapGestureRecognizer || gesture is UIScreenEdgePanGestureRecognizer
        }

        if isDockHidden {
            let leftEdgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
            leftEdgeGesture.edges = .left
            keyWindow.addGestureRecognizer(leftEdgeGesture)

            let rightEdgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
            rightEdgeGesture.edges = .right
            keyWindow.addGestureRecognizer(rightEdgeGesture)
        }
    }

    @objc private func handleEdgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard isDockHidden, gesture.state == .began || gesture.state == .changed else {
            return
        }

        let translation = gesture.translation(in: gesture.view)
        let swipeDistance = abs(translation.x)

        if swipeDistance > Constants.edgeSwipeThreshold {
            showDockFromHidden()
        }
    }

    @objc public func animateFrame(to finalFrame: CGRect) {
        guard let hostingController = self.hostingController else { return }
        
        UIView.animate(
            withDuration: Constants.standardAnimationDuration,
            delay: 0,
            usingSpringWithDamping: Constants.standardSpringDamping,
            initialSpringVelocity: Constants.standardSpringVelocity,
            options: .curveEaseOut
        ) {
            hostingController.view.frame = finalFrame
        }
    }

    @objc public func updateFrameAfterAnimation(finalOffset: CGSize) {
        guard let hostingController = self.hostingController else { return }
        
        let newFrame = hostingController.view.frame.offsetBy(dx: finalOffset.width, dy: finalOffset.height)
        
        hostingController.view.frame = newFrame
    }

    // Check if gesture is for cross-screen movement (left to right or vice versa)
    func handleSwipeToHideOrShowGesture(for originalFrame: CGRect, translation: CGSize) -> Bool {
        let screenWidth = keyWindow!.bounds.width
        let isOnRightSide = originalFrame.origin.x > screenWidth / 2
        let isSwipingAway = (isOnRightSide && translation.width > 0) || (!isOnRightSide && translation.width < 0)

        if isSwipingAway {
            guard !self.isDockHidden else { return false }
            self.hideDockToSide()
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
            return true
        } else {
            guard self.isDockHidden else { return false }
            self.showDockFromHidden()
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred()
            return true
        }
    }

    // Check if gesture is for cross-screen movement (left to right or vice versa)
    func isPositionChangeGesture(for originalFrame: CGRect, translation: CGSize) -> Bool {
        let horizontalDistance = abs(translation.width)
        let verticalDistance = abs(translation.height)

        guard !self.isDockHidden, horizontalDistance > verticalDistance else {
            return false
        }
        
        let screenWidth = keyWindow!.bounds.width
        let isOnRightSide = originalFrame.origin.x > screenWidth / 2
        
        let isMovingToOtherSide = (isOnRightSide && translation.width < 0) || (!isOnRightSide && translation.width > 0)
        guard isMovingToOtherSide else { return false }
        
        let draggedX = originalFrame.origin.x + translation.width
        let screenCenter = screenWidth / 2
        
        if isOnRightSide {
            return draggedX < screenCenter
        } else {
            return (draggedX + originalFrame.width) > screenCenter
        }
    }
    
    // Find and bring corresponding multitask view to front. When the
    // caller knows which icon was tapped (dock icon, grid cell, banner),
    // it passes that icon's frame in window coordinates and the window
    // grows out of it, iOS-style (Ann 2026-11-23).
    func bringMultitaskViewToFront(uuid: String, from sourceRect: CGRect? = nil) -> Bool {
        noteDockInteraction()
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return false
        }

        for window in windowScene.windows {
            if let targetView = findMultitaskView(in: window, withUUID: uuid) {
                passURLSchemeToView(targetView)
                animateViewAppearance(targetView, from: sourceRect, in: window)
                updateStatusBarFix()
                return true
            }
        }
        
        return false
    }

    private func passURLSchemeToView(_ view: UIView) {
        if let launchUrl = UserDefaults.standard.string(forKey: "launchAppUrlScheme") {
            UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
            if let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController {
                decoratedVC.appSceneVC.openURLScheme(launchUrl)
            }
        }
    }

    private func animateViewAppearance(_ view: UIView, from sourceRect: CGRect?, in window: UIWindow) {
        let isHidden = view.isHidden || view.alpha < 0.1
        let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController
        let isMaximized = decoratedVC?.isMaximized ?? false
        
        // when a fullscreen multitask app is brought to front, optionally hide other windows
        if UserDefaults.lcShared().bool(forKey: "LCMaxOneAppOnStage") && isMaximized {
            MultitaskDockManager.shared.minimizeAllWindows(except: decoratedVC)
        }
        
        if isHidden {
            view.layer.removeAllAnimations()
            view.isHidden = true
            view.transform = .identity
            let origFrame = view.frame
            let origCornerRadius = view.layer.cornerRadius
            let pipManager = PiPManager.shared!
            // iOS 式入场（Ann 2026-11-23 定）：窗口从一个方框里长
            // 出来——起点的位置和大小与方框一致、圆角先取图标圆
            // 角，弹簧放大到最终帧的同时把圆角收回窗口自己的。
            // 方框的来源按顺序：调用方带的被点图标；没带时退到悬
            // 浮坞的位置（URL 启动、模型层等没有图标可点的路径
            // ——正在运行的多任务 App 必然在坞里，从坞长出来位置
            // 上说得通，也免了原版压方块的别扭缩放）；坞不在场时
            // 才沿用原来的方块入场。
            let dockRect = dockHomeRect()
            let effectiveRect = sourceRect ?? (dockRect == .zero ? nil : dockRect)
            var zoomsFromRect = false
            if let decoratedVC = view._viewDelegate(), pipManager.isPiP(withDecoratedVC: decoratedVC) {
                pipManager.stopPiP()
            } else if let effectiveRect, let superview = view.superview {
                zoomsFromRect = true
                let startRect = superview.convert(effectiveRect, from: window)
                view.frame = startRect
                view.layer.cornerRadius = startRect.height * 0.22
                view.alpha = 1.0
                view.isHidden = false
            } else {
                view.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
                view.isHidden = false
                let smaller = min(view.frame.size.width, view.frame.size.height)
                view.frame.size = CGSize(width: smaller, height: smaller)
            }
            
            self.bringViewToFront(view, in: window)
            UIView.animate(
                withDuration: zoomsFromRect ? 0.45 : Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: zoomsFromRect ? 0.85 : 1.0,
                initialSpringVelocity: 0,
                options: .curveEaseInOut,
                animations: {
                    view.alpha = 1.0
                    view.transform = .identity
                    view.frame = origFrame
                    view.layer.cornerRadius = origCornerRadius
                }
            )
        } else {
            // 已经在台上的窗口切到前台不做任何缩放（Ann 2026-11-23
            // 定）：原来有个 1.02 倍的放大脉冲，iOS 切换 App 时没
            // 有这种缩放，看着别扭。直接置前，和系统一致。
            bringViewToFront(view, in: window)
        }
    }

    private func bringViewToFront(_ view: UIView, in window: UIWindow) {
        if let superview = view.superview {
            superview.bringSubviewToFront(view)
        }
        if let windowSuperview = window.superview {
            windowSuperview.bringSubviewToFront(window)
        }
    }
    
    // Recursively find multitask view
    private func findMultitaskView(in view: UIView, withUUID uuid: String) -> UIView? {
        apps.first { $0.appUUID == uuid }?.view
    }
    
    // Get view's dataUUID property through reflection
    private func getDataUUID(from view: UIView) -> String? {
        let mirror = Mirror(reflecting: view)
        
        if let child = (mirror.children.first { $0.label == "dataUUID" })?.value as? String {
            return child
        }
        
        if view.responds(to: NSSelectorFromString("dataUUID")) {
            return view.value(forKey: "dataUUID") as? String
        }
        
        return nil
    }
    
    @objc public func addRunningAppWithInfo(_ appInfo: LCAppInfo?, appUUID: String, view: UIView?) {
        guard isDockEnabled() else { return }
        
        if apps.contains(where: { $0.appUUID == appUUID }) {
            return
        }
        
        let appName = appInfo?.displayName() ?? "Unknown App"
        let appModel = DockAppModel(appName: appName, appUUID: appUUID, appInfo: appInfo, view: view)
        
        DispatchQueue.main.async {
            self.noteDockInteraction()
            self.apps.append(appModel)
            
            if self.apps.count == 1 {
                self.showDock()
            } else if self.isVisible {
                self.updateDockFrame()
            }
            self.updateStatusBarFix()
        }
    }
    
    /// The dock's home rect in window coordinates: where a
    /// minimizing window flies to (Ann 2026-11-23: the exit mirrors
    /// the iOS-style entrance and shrinks into the dock), and where
    /// a window with no icon source — a previous-app jump, a
    /// model-level launch — grows out of.
    /// Collapsed, the dock's frame IS the orb's frame. Expanded, aim
    /// at the square at the capsule's center — where the orb sits
    /// when collapsed. Zero when the dock isn't up, so minimize
    /// falls back to the old shrink-in-place animation.
    @objc func dockHomeRect() -> CGRect {
        guard isVisible, let dockView = hostingController?.view, keyWindow != nil else {
            return .zero
        }
        let frame = dockView.frame
        if isCollapsed {
            return frame
        }
        let side = min(frame.width, frame.height)
        return CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
    }
    
    @objc public func minimizeAllWindows(except: DecoratedAppSceneViewController? = nil) {
        noteDockInteraction()
        DispatchQueue.main.async {
            self.apps.forEach { app in
                if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
                   vc != except {
                    app.view?.layer.removeAllAnimations()
                    vc.minimizeWindow()
                }
            }
        }
    }
    
    @objc public func toggleDockCollapse() {
        noteDockInteraction()
        DispatchQueue.main.async {
            self.isCollapsed.toggle()
            self.updateDockFrame()
        }
    }

    // MARK: - Front app & cycle

    /// The app currently in front: among the dock's app windows, the
    /// visible one with the highest z-order in their shared host view.
    /// Nil when every window is minimized (the user is on the LC home
    /// screen, or all apps are in the background).
    private func frontAppIndex() -> Int? {
        var best: (index: Int, zOrder: Int)?
        for (index, app) in apps.enumerated() {
            guard let view = app.view, !view.isHidden, view.alpha >= 0.1,
                  let superview = view.superview,
                  let zOrder = superview.subviews.firstIndex(of: view) else { continue }
            if best == nil || zOrder > best!.zOrder {
                best = (index, zOrder)
            }
        }
        return best?.index
    }

    /// Status bar fix (状态栏修复): while the front multitask app has
    /// the per-app fix enabled and its window is maximized, hide the
    /// host status bar so it cannot cover the app's top controls. A
    /// windowed window needs no fix: its own window bar sits above the
    /// app content, so the status bar never reaches the app's controls.
    /// The guest already lays out edge-to-edge (LC sends
    /// statusBarDisabled with zero metrics), so hiding the host bar is
    /// the only missing piece; this mirrors the compatibility switch in
    /// 微珠. Flip-only: the private override is applied solely when the
    /// desired state changes, and it is restored as soon as another app
    /// comes to front, everything minimizes to the LC home screen, or
    /// the window closes.
    @objc public func updateStatusBarFix() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.updateStatusBarFix() }
            return
        }
        var hide = false
        var frontUUID: String? = nil
        if let index = frontAppIndex() {
            let app = apps[index]
            frontUUID = app.appUUID
            if let info = app.appInfo, info.statusBarFix,
               let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
                hide = vc.isMaximized
            }
        }
        if frontAppUUID != frontUUID {
            // Any departure from an app records it as the
            // previous one: app -> app keeps the one we left,
            // app -> home keeps the last app, so the orb's long
            // press can also resume it from the home screen.
            if let old = frontAppUUID {
                previousAppUUID = old
            }
            frontAppUUID = frontUUID
        }
        if hide != statusBarFixApplied,
           LCStatusBarManager.lc_setOverridingStatusBarHidden(hide) {
            statusBarFixApplied = hide
        }
    }

    /// Orb long press: jump straight back to the previous app —
    /// the two-app bounce (chat <-> browser) without opening the
    /// dock (Ann 2026-11-23; going home moved to the expanded
    /// dock's home button the same evening, and the cycle button
    /// this method used to serve is gone — blind flipping made
    /// no sense once every icon is visible). Grows out of the
    /// dock like every other switch. Returns whether there was
    /// somewhere to go, so the caller can skip its haptic when
    /// there was not.
    @discardableResult
    @objc public func switchToPreviousApp() -> Bool {
        noteDockInteraction()
        guard let prev = previousAppUUID, prev != frontAppUUID,
              apps.contains(where: { $0.appUUID == prev }) else { return false }
        return bringMultitaskViewToFront(uuid: prev, from: dockHomeRect())
    }

    /// Toggle a window between maximized and windowed, through the
    /// very same action as the window bar's maximize button. Used by
    /// the double-tap on the front app's dock icon.
    @objc public func toggleMaximized(uuid: String) {
        guard let app = apps.first(where: { $0.appUUID == uuid }),
              let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController else { return }
        vc.maximizeWindow()
    }

    /// Close every multitask app, through the same per-app path as
    /// the red X. The dock empties and hides itself through the
    /// usual running-apps notifications.
    @objc public func closeAllApps() {
        for app in apps {
            _ = MultitaskManager.terminateApp(container: app.appUUID)
        }
    }

    // MARK: - Multitask Mode Check
    private func isDockEnabled() -> Bool {
        let multitaskMode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        return multitaskMode == .virtualWindow
    }
}

// MARK: - SwiftUI Dock View
@available(iOS 16.0, *)
public struct MultitaskDockSwiftView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    @State private var dragOffset = CGSize.zero
    @State private var isMoving: Bool = false
    @State private var homeLongPressTriggered = false
    @State private var collapsedLongPressTriggered = false
    @AppStorage("LCHideCollapsedDock", store: LCUtils.appGroupUserDefault) var hideCollapsedDock: Bool = false
    @State private var showCloseAllConfirm = false
    
    // Calculate dynamic padding based on user settings
    private var dynamicPadding: CGFloat {
        let basePadding: CGFloat = 4
        let extraPadding = (dockManager.dockWidth - MultitaskDockManager.Constants.defaultDockWidth) * 0.2
        return max(basePadding, basePadding + extraPadding)
    }

    /// How one expanded-dock element (icon, home button) comes
    /// and goes when the dock expands or collapses: in with a
    /// fade and a slight grow, out with a plain fade. Together
    /// with the capsule clip on the dock body this turns the old
    /// pop-in swap into a reveal (Ann 2026-11-23: the expand
    /// animation felt disjointed — icons appeared instantly at
    /// their final spots and poked outside the pill while its
    /// frame was still growing).
    private var dockElementTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.85)),
            removal: .opacity)
    }

    /// Stagger delay for one expanded-dock element. The pill
    /// grows from its center (the orb's seat), so elements
    /// cascade outward from the middle of the stack: the delay
    /// grows with the distance from the center element. Only
    /// applied while expanding (see the call sites).
    private func staggerDelay(for index: Int, total: Int) -> Double {
        let center = Double(total - 1) / 2
        return abs(Double(index) - center) * 0.04
    }
    
    public var body: some View {
        GeometryReader { g in
            VStack(spacing: 8) {
                if dockManager.isCollapsed {
                    // Two gestures on the floating button (Ann
                    // 2026-11-23, plan A — the old mapping was
                    // top-heavy: the lightest gesture did the
                    // heaviest thing): single tap expands — the
                    // most-used, zero-risk action, and instant now
                    // that no double tap has to be waited out; long
                    // press jumps back to the previous app — the
                    // one quick switch worth doing blind, because
                    // where "back" lands is predictable (it briefly
                    // went home instead, until the expanded dock
                    // got its own home button the same evening).
                    // Double tap (blind cycling) is gone: switching
                    // happens in the expanded dock, where the
                    // target is visible. The long press's flag
                    // keeps its release from also firing the tap.
                    CollapsedDockView()
                        .transition(.opacity.combined(with: .scale(scale: 0.7)))
                        .onTapGesture {
                            if collapsedLongPressTriggered {
                                collapsedLongPressTriggered = false
                                return
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            dockManager.toggleDockCollapse()
                        }
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in
                                    collapsedLongPressTriggered = true
                                    if dockManager.switchToPreviousApp() {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    }
                                }
                        )
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(dockManager.apps.enumerated()), id: \.element.id) { pair in
                            AppIconView(app: pair.element)
                                .transition(dockElementTransition)
                                .animation(.spring(response: MultitaskDockManager.Constants.standardAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping).delay(dockManager.isCollapsed ? 0 : staggerDelay(for: pair.offset, total: dockManager.apps.count + 1)), value: dockManager.isCollapsed)
                        }

                        // Home button (Ann 2026-11-23, replacing
                        // the cycle button — with every icon
                        // visible, blind flipping was dead weight):
                        // tap goes home (minimize every window and
                        // collapse the dock); long-press asks to
                        // close every app instead (with a
                        // confirmation, like Weizhu's close-all).
                        HomeButtonView()
                            .onTapGesture {
                                // A long-press already fired; the
                                // release must not also go home.
                                if homeLongPressTriggered {
                                    homeLongPressTriggered = false
                                    return
                                }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                dockManager.minimizeAllWindows()
                                if !dockManager.isCollapsed {
                                    dockManager.toggleDockCollapse()
                                }
                            }
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.5)
                                    .onEnded { _ in
                                        homeLongPressTriggered = true
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        showCloseAllConfirm = true
                                    }
                            )
                            .transition(dockElementTransition)
                            .animation(.spring(response: MultitaskDockManager.Constants.standardAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping).delay(dockManager.isCollapsed ? 0 : staggerDelay(for: dockManager.apps.count, total: dockManager.apps.count + 1)), value: dockManager.isCollapsed)

                    }
                }
            }
            .padding(.horizontal, dynamicPadding)
            // Expanded, the pill's curved ends need extra room at
            // the top and bottom so the end icons stay inside the
            // glass (see dockEndExtra); collapsed stays a circle.
            .padding(.vertical, dockManager.isCollapsed ? dynamicPadding : dynamicPadding + dockManager.dockEndExtra(for: dockManager.dockWidth))
            .alert("lc.multitask.closeAllTitle".loc, isPresented: $showCloseAllConfirm) {
                Button("lc.common.no".loc, role: .cancel) {}
                Button("lc.multitask.closeAllConfirm".loc, role: .destructive) {
                    dockManager.closeAllApps()
                }
            }
            // Pill-shaped dock (Ann 2026-11-22): a capsule reads as
            // one floating control, not a panel — collapsed it is a
            // plain circle around the orb glyph, expanded a vertical
            // capsule around the icons.
            .modifier { content in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    content.glassEffect(.regular, in: .capsule)
                } else {
                    content.background(
                        Capsule()
                            .fill(Color.black.opacity(dockManager.isDockHidden ? 0.3 : 0.7))
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(dockManager.isDockHidden ? 0.1 : 0.3), lineWidth: 1)
                            )
                    )
                }
            }
            // Clip everything to the pill: while the frame grows
            // or shrinks, elements are only visible inside the
            // capsule, so the expansion reads as a reveal instead
            // of icons poking out of the glass (Ann 2026-11-23).
            .clipShape(Capsule())
            .scaleEffect(dockManager.isVisible ? 1.0 : 0.8)
            // Collapsed button: 60% opacity, dimming to 20% after 3s
            // idle. Expanded dock: fully opaque. Hidden to the side:
            // the remaining sliver dims to 0.4, or to 0.01 (nearly
            // invisible) when the "hide collapsed dock" setting is on.
            .opacity(dockManager.isDockHidden ? (hideCollapsedDock && dockManager.isCollapsed ? 0.01 : 0.4) : (dockManager.isCollapsed ? (dockManager.isDockIdleDimmed ? 0.2 : 0.6) : 1.0))
            .animation(.easeInOut(duration: 0.35), value: dockManager.isDockIdleDimmed)
            .animation(.easeInOut(duration: 0.35), value: dockManager.isDockHidden)
            // The padding rides the same spring as the rest of
            // the collapse change — it used to ease on its own
            // 0.35 s curve, a third clock next to the UIKit frame
            // spring and the layout spring (Ann 2026-11-23).
            .animation(.spring(response: MultitaskDockManager.Constants.standardAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.isCollapsed)
            .offset(dragOffset)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }



        .ignoresSafeArea()
        .gesture(
            DragGesture(minimumDistance: 5)
            .onChanged { value in
                dockManager.noteDockInteraction()
                self.isMoving = true
                self.dragOffset = value.translation
            }
            .onEnded { value in
                self.isMoving = true

                let hcFrame = dockManager.hostingController?.view.frame ?? .zero
                
                let currentPhysicalFrame = hcFrame.offsetBy(dx: self.dragOffset.width, dy: self.dragOffset.height)
                
                if dockManager.isPositionChangeGesture(for: hcFrame, translation: value.translation) {
                    let screenBounds = dockManager.keyWindow!.bounds
                    let targetX = dockManager.calculateTargetX(isDockHidden: dockManager.isDockHidden, isOnRightSide: currentPhysicalFrame.midX > screenBounds.width / 2, dockWidth: dockManager.dockWidth, screenWidth: screenBounds.width)
                    
                    let safeAreaInsets = dockManager.safeAreaInsets
                    let dockVerticalMargin = MultitaskDockManager.Constants.dockVerticalMargin
                    let minY = safeAreaInsets.top + dockVerticalMargin
                    let maxY = screenBounds.height - safeAreaInsets.bottom - currentPhysicalFrame.height - dockVerticalMargin
                    let targetY = max(minY, min(maxY, currentPhysicalFrame.origin.y))
                    
                    let finalPhysicalPosition = CGPoint(x: targetX, y: targetY)
                    
                    let newOffset = CGSize(
                        width: finalPhysicalPosition.x - hcFrame.origin.x,
                        height: finalPhysicalPosition.y - hcFrame.origin.y
                    )
                    
                    let animationDuration = MultitaskDockManager.Constants.longAnimationDuration
                    
                    withAnimation(.spring(response: animationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping)) {
                        self.dragOffset = newOffset
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                        dockManager.updateFrameAfterAnimation(finalOffset: newOffset)
                        
                        self.dragOffset = .zero
                        
                        self.isMoving = false
                    }
                    return
                }
                
                if dockManager.handleSwipeToHideOrShowGesture(for: hcFrame, translation: value.translation) {
                    withAnimation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping)) {
                        self.dragOffset = .zero
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + MultitaskDockManager.Constants.longAnimationDuration) {
                        self.isMoving = false
                    }
                    return
                }

                let screenBounds = dockManager.keyWindow!.bounds
                let safeAreaInsets = dockManager.safeAreaInsets
                let dockVerticalMargin = MultitaskDockManager.Constants.dockVerticalMargin
                let minY = safeAreaInsets.top + dockVerticalMargin
                let maxY = screenBounds.height - safeAreaInsets.bottom - currentPhysicalFrame.height - dockVerticalMargin
                let targetY = max(minY, min(maxY, currentPhysicalFrame.origin.y))
                
                let targetX: CGFloat

                let isOnRightSide = hcFrame.origin.x > screenBounds.width / 2
                targetX = dockManager.calculateTargetX(isDockHidden: dockManager.isDockHidden, isOnRightSide: isOnRightSide, dockWidth: currentPhysicalFrame.width, screenWidth: screenBounds.width)
                
                let finalPhysicalPosition = CGPoint(x: targetX, y: targetY)
                
                let newOffset = CGSize(
                    width: finalPhysicalPosition.x - hcFrame.origin.x,
                    height: finalPhysicalPosition.y - hcFrame.origin.y
                )
                
                let animationDuration = MultitaskDockManager.Constants.longAnimationDuration
                
                withAnimation(.spring(response: animationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping)) {
                    self.dragOffset = newOffset
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                    dockManager.updateFrameAfterAnimation(finalOffset: newOffset)
                    
                    self.dragOffset = .zero
                    
                    self.isMoving = false
                }
            }
        )
        .animation(.spring(response: MultitaskDockManager.Constants.standardAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.isCollapsed)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.dockWidth)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.settingsChanged)
    }
    
    public init() {}
}

// MARK: - Collapsed Dock View
@available(iOS 16.0, *)
struct CollapsedDockView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    @State private var breathing = false

    var body: some View {
        ZStack {
            // Breathing with Weizhu's exact pulse parameters
            // (FMApplyOrbLineAnimation): opacity only, 0.38 -> 1,
            // 1.15s ease-in-out, autoreversing. Animating a single
            // property is what makes it feel smooth; the glyph is the
            // theme text color, like Weizhu's glyphs on glass.
            Image(systemName: "square.grid.2x2.fill")
                .foregroundStyle(.primary)
                // Sized off the dock width, not adaptiveIconSize:
                // the orb keeps its exact pre-0.68 glyph size
                // (0.375 x width) — only the expanded icons shrank.
                .font(.system(size: dockManager.dockWidth * 0.375, weight: .bold))
                .opacity(breathing ? 1.0 : 0.38)
                .animation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: breathing)
                .onAppear { breathing = true }
        }
        .frame(width: dockManager.dockWidth * 0.75, height: dockManager.dockWidth * 0.75)
        // No tile of its own (Ann 2026-11-22): the glyph sits
        // directly on the dock's glass, like a system toolbar
        // glyph. The glyph is slightly larger than the tiled
        // version to keep its optical weight in the slot.
        .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.adaptiveIconSize)
    }
}

// MARK: - Home Button View
@available(iOS 16.0, *)
struct HomeButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager

    var body: some View {
        ZStack {
            // A tile like the app icons' (Ann 2026-11-23, reversing
            // the 2026-11-22 bare-glyph call): the bare glyph filled
            // under half its slot, so the visible gaps around it
            // (26 pt above, ~43 below) broke the column's rhythm —
            // the bottom read as an empty tray holding a small
            // glyph. Same corner ratio as IconImageView's clip.
            RoundedRectangle(cornerRadius: dockManager.adaptiveIconSize * 0.2667)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: dockManager.adaptiveIconSize * 0.2667)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
            Image(systemName: "house.fill")
                .foregroundColor(.primary)
                .font(.system(size: dockManager.adaptiveIconSize * 0.5, weight: .semibold))
        }
        .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.adaptiveIconSize)
    }
}

// MARK: - Icon Cache Manager
class IconCacheManager {
    static let shared = IconCacheManager()
    private var cache: [String: UIImage] = [:]
    private let cacheQueue = DispatchQueue(label: "icon.cache.queue", attributes: .concurrent)
    
    private init() {}
    
    func getIcon(for key: String) -> UIImage? {
        return cacheQueue.sync {
            return cache[key]
        }
    }
    
    func setIcon(_ icon: UIImage, for key: String) {
        cacheQueue.async(flags: .barrier) {
            self.cache[key] = icon
        }
    }
    
    func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.cache.removeAll()
        }
    }
}
// MARK: - Front App Marker
/// Breathing green dot on the icon of the app currently in front,
/// ported from Weizhu's running light (FMMakeRunningLight): a solid
/// core over a soft halo whose opacity pulses 0.18 -> 0.78 over
/// 1.85s.
@available(iOS 16.0, *)
private struct FrontAppMarkerView: View {
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green)
                .frame(width: 13, height: 13)
                .blur(radius: 2)
                .opacity(breathing ? 0.78 : 0.18)
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
        }
        .animation(.easeInOut(duration: 1.85).repeatForever(autoreverses: true), value: breathing)
        .onAppear { breathing = true }
    }
}

// MARK: - App Icon View
@available(iOS 16.0, *)
struct AppIconView: View {
    let app: DockAppModel
    @State private var isPressed = false
    @State private var closeTriggered = false
    /// 上次点当前 App 图标的时间：双击切最大化靠它判定（单击
    /// 不做任何事，见 handleFrontAppTap）。
    @State private var lastFrontTapTime: Date?
    @State private var appIcon: UIImage?
    @State private var isLoading = true
    @EnvironmentObject var dockManager: MultitaskDockManager
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    
    private var iconSize: CGFloat {
        return dockManager.adaptiveIconSize
    }
    
    var body: some View {
        Group {
            if isLoading && appIcon == nil {
                LoadingIconView()
            } else if let icon = appIcon {
                IconImageView(icon: icon)
            } else {
                RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.3))
            }
        }
        .frame(width: iconSize, height: iconSize)
        .overlay {
            DockIconTouchObserver(
                onBegan: {
                    isPressed = true
                },
                onMoved: { inside in
                    if isPressed != inside {
                        isPressed = inside
                    }
                },
                onEnded: { inside, iconRect, movedDistance in
                    isPressed = false
                    // A long-press already closed this app; the
                    // release must not also bring it to the front.
                    if closeTriggered {
                        closeTriggered = false
                        return
                    }
                    // Released off the icon after sliding across the
                    // dock, or the touch turned into a dock drag:
                    // cancelled, like a home-screen icon.
                    guard inside, movedDistance < 12 else { return }
                    // Tapping the front app's own icon is not a
                    // switch: re-presenting its scene replays a
                    // bring-to-front animation and shifts the app's
                    // UI down for a moment (Ann 2026-11-22). It has
                    // its own handling: single tap does nothing,
                    // double tap toggles maximized/windowed. The
                    // tap haptic lives with the actions themselves:
                    // it used to fire here for every tap, so the
                    // front icon buzzed even when nothing happened
                    // (and twice on a double tap) — Ann noticed
                    // (2026-11-23). Only a real action buzzes now.
                    if app.appUUID == dockManager.frontAppUUID {
                        handleFrontAppTap()
                        return
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    let brought = dockManager.bringMultitaskViewToFront(uuid: app.appUUID, from: iconRect)
                    // Switching to an app finishes the dock's job:
                    // collapse it (Ann's 保底 collapse — covers the
                    // case where tap-outside never fires). The cycle
                    // button deliberately stays expanded for repeated
                    // flipping; a direct icon tap does not.
                    if brought && !dockManager.isCollapsed {
                        dockManager.toggleDockCollapse()
                    }
                },
                onCancelled: {
                    isPressed = false
                }
            )
        }
        .overlay(alignment: .bottomTrailing) {
            if dockManager.frontAppUUID == app.appUUID {
                FrontAppMarkerView()
                    .offset(x: 3, y: 3)
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 3)
        .scaleEffect(isPressed ? 1.15 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .animation(.easeInOut(duration: MultitaskDockManager.Constants.standardAnimationDuration), value: dockManager.settingsChanged)
        .onAppear {
            loadAppIcon()
        }
        // Long-press closes the app, through the very same path as the
        // red X (terminateApp closes the window without the exit
        // animation), with a medium haptic when it fires. Simultaneous,
        // so it only observes alongside the press tracking above.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    closeTriggered = true
                    let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                    impactFeedback.impactOccurred()
                    _ = MultitaskManager.terminateApp(container: app.appUUID)
                }
        )
        .contentShape(Rectangle())
    }
    
    /// Taps on the front app's own icon (never a switch — see
    /// onEnded). Single tap collapses the dock, delayed 0.3s so a
    /// second tap can preempt it: a double-tap toggles the window
    /// between maximized and windowed instead (Ann 2026-11-22).
    /// Only the front app's icon behaves this way; other icons
    /// switch on the first tap, which collapses the dock before
    /// any second tap could land.
    private func handleFrontAppTap() {
        // 单击当前 App 的图标什么都不做（Ann 2026-11-23 定）：
        // 收起悬浮坞已经有点外收起承担，不必让单击再背一个——
        // 之前它背着的时候，点当前图标要等 0.3 秒的双击判定窗
        // 口才收起，显得肉。双击保留：切最大化/窗口化，然后
        // 收起坞。
        let now = Date()
        if let last = lastFrontTapTime, now.timeIntervalSince(last) < 0.3 {
            lastFrontTapTime = nil
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            dockManager.toggleMaximized(uuid: app.appUUID)
            if !dockManager.isCollapsed {
                dockManager.toggleDockCollapse()
            }
            return
        }
        lastFrontTapTime = now
    }

    private func loadAppIcon() {
        let cacheKey = "\(app.appName)_\(app.appUUID)"
        
        if let cachedIcon = IconCacheManager.shared.getIcon(for: cacheKey) {
            self.appIcon = cachedIcon
            self.isLoading = false
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var finalIcon: UIImage?
            
            if let appInfo = self.app.appInfo {
                finalIcon = appInfo.iconIsDarkIcon(darkModeIcon)
            } else {
                if let foundAppInfo = AppInfoProvider.shared.findAppInfo(appName: self.app.appName, dataUUID: self.app.appUUID) {
                    finalIcon = foundAppInfo.iconIsDarkIcon(darkModeIcon)
                }
            }
            
            DispatchQueue.main.async {
                self.isLoading = false
                if let icon = finalIcon {
                    self.appIcon = icon
                    IconCacheManager.shared.setIcon(icon, for: cacheKey)
                }
            }
        }
    }
}

// MARK: - Dock Icon Touch Tracking
/// UIKit touch tracking for a dock icon, following the finger:
/// sliding off the icon cancels the press (and the release), exactly
/// like a home-screen icon. The previous implementation observed a
/// DragGesture and acted on the release wherever the finger ended
/// up, so sliding across icons still activated the first one
/// touched. This layer installs no gesture recognizers and does not
/// override hit testing, so the dock's own drag and the long-press
/// close keep working as before; it only observes (the same pattern
/// as the app grid's LCGridTouchObserver).
private final class DockIconTouchView: UIView {
    var onBegan: (() -> Void)?
    var onMoved: ((Bool) -> Void)?
    var onEnded: ((Bool, CGRect, CGFloat) -> Void)?
    var onCancelled: (() -> Void)?
    private var startLocation: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first {
            startLocation = touch.location(in: self)
        }
        onBegan?()
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first {
            onMoved?(bounds.contains(touch.location(in: self)))
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first {
            let location = touch.location(in: self)
            let inside = bounds.contains(location)
            // The switch animation grows out of the icon's own rect,
            // in window coordinates.
            let iconRect = convert(bounds, to: nil)
            let moved = hypot(location.x - startLocation.x, location.y - startLocation.y)
            onEnded?(inside, iconRect, moved)
        }
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        onCancelled?()
        super.touchesCancelled(touches, with: event)
    }
}

private struct DockIconTouchObserver: UIViewRepresentable {
    var onBegan: () -> Void
    var onMoved: (Bool) -> Void
    var onEnded: (Bool, CGRect, CGFloat) -> Void
    var onCancelled: () -> Void

    func makeUIView(context: Context) -> DockIconTouchView {
        let view = DockIconTouchView()
        wire(view)
        return view
    }

    func updateUIView(_ uiView: DockIconTouchView, context: Context) {
        wire(uiView)
    }

    private func wire(_ view: DockIconTouchView) {
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.onCancelled = onCancelled
    }
}

// MARK: - Loading Icon View
struct LoadingIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.3))
            
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.2)
        }
    }
}
