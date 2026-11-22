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

    /// The app currently in front in multitask (nil when every window
    /// is minimized, i.e. the user is on the LC home screen). The dock
    /// marks its icon with a breathing green dot. Maintained by
    /// updateStatusBarFix(), which already runs on every front-app
    /// change.
    @Published var frontAppUUID: String?

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
    internal var hostingController: UIHostingController<AnyView>?

    public struct Constants {
        // MARK: - Layout & Sizing
        static let defaultDockWidth: CGFloat = 90.0
        static let minAdaptiveDockWidth: CGFloat = 50.0
        static let minAdaptiveIconSize: CGFloat = 10.0
        static let maxIconSize: CGFloat = 100.0
        static let minCollapsedHeight: CGFloat = 60.0
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
        static let iconToWidthRatio: CGFloat = 0.75
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
        static let shortAnimationDuration1: TimeInterval = 0.15
        static let shortAnimationDuration2: TimeInterval = 0.1
        
        static let standardSpringDamping: CGFloat = 0.8
        static let showHideSpringDamping: CGFloat = 0.7
        static let standardSpringVelocity: CGFloat = 0.3
        static let showHideSpringVelocity: CGFloat = 0.5
        
        static let initialScale: CGFloat = 0.8
        static let bringToFrontScale: CGFloat = 1.02
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

    private func expandedDockBaseHeight(for width: CGFloat, buttonSize: CGFloat) -> CGFloat {
        // Expanded dock contents: the app icons and the cycle button
        // at the bottom — (apps.count + 1) items, apps.count gaps
        // between them, and one button-height allowance. (The
        // collapse button that used to sit on top is gone: tapping
        // outside the dock collapses it now, both on the LC home
        // screen and from inside the front guest.)
        let spacingCount = max(self.apps.count, 0)
        let totalSpacingHeight = CGFloat(spacingCount) * Constants.dockContentSpacing
        return Constants.dockVerticalPadding + buttonSize + totalSpacingHeight
    }

    private func expandedDockHeight(for width: CGFloat, iconSize: CGFloat) -> CGFloat {
        let buttonSize = calculateButtonSize(for: width)
        let baseHeight = expandedDockBaseHeight(for: width, buttonSize: buttonSize)
        let iconHeight = CGFloat(self.apps.count) * iconSize
        return baseHeight + iconHeight
    }

    private func collapsedDockHeight(for width: CGFloat) -> CGFloat {
        let buttonSize = calculateButtonSize(for: width)
        return Constants.dockVerticalPadding + buttonSize
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
    }

    // MARK: - Frame Calculation Helpers

    private func calculateTargetDockHeight(forWidth width: CGFloat) -> CGFloat {
        if isCollapsed {
            let collapsedHeight = collapsedDockHeight(for: width)
            return max(Constants.minCollapsedHeight, collapsedHeight)
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
            let initialScale = Constants.initialScale
            hostingController.view.transform = CGAffineTransform(scaleX: initialScale, y: initialScale)
            
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.showHideSpringDamping,
                initialSpringVelocity: Constants.showHideSpringVelocity,
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
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.showHideSpringDamping,
                initialSpringVelocity: Constants.showHideSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.alpha = 0
                let finalScale = Constants.initialScale
                hostingController.view.transform = CGAffineTransform(scaleX: finalScale, y: finalScale)
                // Move off-screen to hide, but keep in view hierarchy
                let screenBounds = self.keyWindow!.bounds
                let currentDockWidth = self.dockWidth
                let targetX = hostingController.view.frame.midX > screenBounds.width / 2 ? screenBounds.width : -currentDockWidth
                let targetY = hostingController.view.frame.origin.y // Keep current Y
                hostingController.view.frame.origin = CGPoint(x: targetX, y: targetY)
            } completion: { _ in
                self.isVisible = false
                // The next session starts collapsed again (see showDock).
                self.isCollapsed = true
                hostingController.view.transform = .identity
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
    
    // Find and bring corresponding multitask view to front
    func bringMultitaskViewToFront(uuid: String, from center: CGPoint? = nil) -> Bool {
        noteDockInteraction()
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return false
        }

        for window in windowScene.windows {
            if let targetView = findMultitaskView(in: window, withUUID: uuid) {
                passURLSchemeToView(targetView)
                animateViewAppearance(targetView, from: center, in: window)
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

    private func animateViewAppearance(_ view: UIView, from center: CGPoint?, in window: UIWindow) {
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
            let pipManager = PiPManager.shared!
            if let decoratedVC = view._viewDelegate(), pipManager.isPiP(withDecoratedVC: decoratedVC) {
                pipManager.stopPiP()
            } else {
                view.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
                view.isHidden = false
                let smaller = min(view.frame.size.width, view.frame.size.height)
                view.frame.size = CGSize(width: smaller, height: smaller)
                if let center { view.center = center }
            }
            
            self.bringViewToFront(view, in: window)
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: 1.0,
                initialSpringVelocity: 0,
                options: .curveEaseInOut,
                animations: {
                    view.alpha = 1.0
                    view.transform = .identity
                    view.frame = origFrame
                }
            )
        } else {
            bringViewToFront(view, in: window)
            
            UIView.animate(withDuration: Constants.shortAnimationDuration1, animations: {
                let scale = Constants.bringToFrontScale
                view.transform = CGAffineTransform(scaleX: scale, y: scale)
            }) { _ in
                UIView.animate(withDuration: Constants.shortAnimationDuration2) {
                    view.transform = .identity
                }
            }
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
            self.notifyDockCollapseChanged()
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
            frontAppUUID = frontUUID
        }
        if hide != statusBarFixApplied,
           LCStatusBarManager.lc_setOverridingStatusBarHidden(hide) {
            statusBarFixApplied = hide
        }
    }

    /// Cycle button: bring the next app in dock order to the front,
    /// keeping the dock expanded so it can be tapped repeatedly to flip
    /// through apps. With fewer than two apps there is nothing to cycle
    /// to — a warning haptic says so instead.
    @objc public func cycleToNextApp() {
        noteDockInteraction()
        guard apps.count > 1 else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        let nextIndex = ((frontAppIndex() ?? -1) + 1) % apps.count
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        _ = bringMultitaskViewToFront(uuid: apps[nextIndex].appUUID)
    }

    /// Close every multitask app, through the same per-app path as
    /// the red X. The dock empties and hides itself through the
    /// usual running-apps notifications.
    @objc public func closeAllApps() {
        for app in apps {
            _ = MultitaskManager.terminateApp(container: app.appUUID)
        }
    }

    @objc public func notifyDockCollapseChanged() {
        self.updateDockFrame()
        // find fullscreen apps and hide its UINavigationBar
        self.apps.forEach { app in
            if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController, vc.isMaximized {
                vc.updateVerticalConstraints()
            }
        }
    }
    
    // MARK: - Tap-outside collapse via sendEvent
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
    @State private var cycleLongPressTriggered = false
    @State private var collapsedLongPressTriggered = false
    @AppStorage("LCHideCollapsedDock", store: LCUtils.appGroupUserDefault) var hideCollapsedDock: Bool = false
    @State private var showCloseAllConfirm = false
    
    // Calculate dynamic padding based on user settings
    private var dynamicPadding: CGFloat {
        let basePadding: CGFloat = 4
        let extraPadding = (dockManager.dockWidth - MultitaskDockManager.Constants.defaultDockWidth) * 0.2
        return max(basePadding, basePadding + extraPadding)
    }
    
    public var body: some View {
        GeometryReader { g in
            VStack(spacing: 8) {
                if dockManager.isCollapsed {
                    // Three gestures on the floating button: single tap
                    // goes home (minimize all windows), double tap
                    // cycles to the next app — the expanded dock's
                    // cycle button, feedback included — and long press
                    // expands. The taps form one composed gesture, as
                    // in the app grid: the double tap takes priority
                    // and the single tap fires only when it fails, so
                    // the single tap lands ~0.3s late — acceptable for
                    // going home. The long press runs alongside; its
                    // flag keeps the release from also firing a tap.
                    CollapsedDockView()
                        .gesture(
                            TapGesture(count: 2)
                                .onEnded {
                                    if collapsedLongPressTriggered {
                                        collapsedLongPressTriggered = false
                                        return
                                    }
                                    dockManager.cycleToNextApp()
                                }
                                .exclusively(before: TapGesture(count: 1)
                                    .onEnded {
                                        if collapsedLongPressTriggered {
                                            collapsedLongPressTriggered = false
                                            return
                                        }
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        dockManager.minimizeAllWindows()
                                    })
                        )
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in
                                    collapsedLongPressTriggered = true
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    dockManager.toggleDockCollapse()
                                }
                        )
                } else {
                    VStack(spacing: 8) {
                        ForEach(dockManager.apps) { app in
                            AppIconView(app: app)
                        }

                        // Cycle button: tap flips to the next app in
                        // dock order without collapsing; long-press
                        // asks to close every app instead (with a
                        // confirmation, like Weizhu's close-all).
                        CycleButtonView()
                            .onTapGesture {
                                // A long-press already fired; the
                                // release must not also cycle.
                                if cycleLongPressTriggered {
                                    cycleLongPressTriggered = false
                                    return
                                }
                                dockManager.cycleToNextApp()
                            }
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.5)
                                    .onEnded { _ in
                                        cycleLongPressTriggered = true
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        showCloseAllConfirm = true
                                    }
                            )

                    }
                }
            }
            .padding(dynamicPadding)
            .alert("lc.multitask.closeAllTitle".loc, isPresented: $showCloseAllConfirm) {
                Button("lc.common.no".loc, role: .cancel) {}
                Button("lc.multitask.closeAllConfirm".loc, role: .destructive) {
                    dockManager.closeAllApps()
                }
            }
            .modifier { content in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    content.glassEffect(.regular, in: .rect(cornerRadius: 15))
                } else {
                    content.background(
                        RoundedRectangle(cornerRadius: 15)
                            .fill(Color.black.opacity(dockManager.isDockHidden ? 0.3 : 0.7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(Color.white.opacity(dockManager.isDockHidden ? 0.1 : 0.3), lineWidth: 1)
                            )
                    )
                }
            }
            .scaleEffect(dockManager.isVisible ? 1.0 : 0.8)
            // Collapsed button: 60% opacity, dimming to 20% after 3s
            // idle. Expanded dock: fully opaque. Hidden to the side:
            // the remaining sliver dims to 0.4, or to 0.01 (nearly
            // invisible) when the "hide collapsed dock" setting is on.
            .opacity(dockManager.isDockHidden ? (hideCollapsedDock && dockManager.isCollapsed ? 0.01 : 0.4) : (dockManager.isCollapsed ? (dockManager.isDockIdleDimmed ? 0.2 : 0.6) : 1.0))
            .animation(.easeInOut(duration: 0.35), value: dockManager.isDockIdleDimmed)
            .animation(.easeInOut(duration: 0.35), value: dockManager.isDockHidden)
            .animation(.easeInOut(duration: 0.35), value: dockManager.isCollapsed)
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
                .font(.system(size: dockManager.adaptiveIconSize * 0.42, weight: .bold))
                .opacity(breathing ? 1.0 : 0.38)
                .animation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: breathing)
                .onAppear { breathing = true }
        }
        .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
        .modifier { content in
            if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                content.glassEffect(.regular, in: .rect(cornerRadius: 8))
            } else {
                content.background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.blue.opacity(0.6)]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                        )
                )
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.adaptiveIconSize)
    }
}

// The Weizhu single-column compact tile: a translucent white rounded
// plate (corner radius 26% of the tile, thin white border, soft shadow).
// Crucially, Weizhu tints the glyph with its theme TEXT color, not fixed
// white — a white glyph on the translucent white plate vanishes over
// light app content. The buttons below therefore use Color.primary
// (black in light mode, white in dark mode) for their glyphs. The plate
// here is noticeably stronger than Weizhu's: on LC's iOS 26 liquid
// glass the original translucency washed out completely, and the two
// dock buttons became hard to tell apart from the glass and each
// other.
@available(iOS 16.0, *)
private struct DockCompactTileBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let size: CGFloat

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        return content.background(
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Color.white.opacity(dark ? 0.30 : 0.32))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .stroke(Color.white.opacity(dark ? 0.6 : 0.45), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(dark ? 0.2 : 0.12), radius: 3, x: 0, y: 1)
        )
    }
}

// MARK: - Cycle Button View
@available(iOS 16.0, *)
struct CycleButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager

    var body: some View {
        ZStack {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundColor(.primary)
                .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
        }
        .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
        .modifier(DockCompactTileBackground(size: dockManager.adaptiveIconSize))
        // The same drop shadow the app icons carry, so the button
        // lifts off the glass like they do.
        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 3)
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
                onEnded: { inside, center, movedDistance in
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
                    let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                    impactFeedback.impactOccurred()
                    let _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID, from: center)
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
    var onEnded: ((Bool, CGPoint, CGFloat) -> Void)?
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
            // The switch animation grows from the icon's center, in
            // window coordinates.
            let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
            let moved = hypot(location.x - startLocation.x, location.y - startLocation.y)
            onEnded?(inside, center, moved)
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
    var onEnded: (Bool, CGPoint, CGFloat) -> Void
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
