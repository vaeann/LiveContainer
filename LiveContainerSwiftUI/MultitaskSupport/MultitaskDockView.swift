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
    /// opacity and dims to 30% after 5 seconds without interaction
    /// (the hidden handle dims on the same 5-second clock).
    @Published var isDockIdleDimmed: Bool = false

    /// Whether the dock is currently slid to the screen edge
    /// (hide-to-side). 微珠's multitask takeover probes the @objc
    /// methods that drive this state (showDockFromHidden,
    /// toggleDockVisibility, hideDockToSide) by name.
    @Published var isDockHidden: Bool = false

    /// Which collapsed form the dock rests in (Ann 2026-11-25):
    /// the orb, or the handle — the same orb squashed flat
    /// against the screen edge, at the orb's own height. Hiding
    /// the orb squashes it into the handle and sets this;
    /// pulling the handle back out restores the orb and clears
    /// it. Expanding straight from the handle keeps it set, so
    /// the next collapse squashes back into the handle instead
    /// of stopping at the orb (see toggleDockCollapse).
    var collapsedFormIsHandle: Bool = false
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
            // 5 seconds, in sync with the hidden handle's idle
            // fade (Ann 2026-11-25): the two collapsed forms are
            // one object and dim on the same clock.
            self.dockIdleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
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

        // Collapse/expand morph (Ann 2026-11-24): ONE physical
        // spring drives the UIKit frame, the SwiftUI morph
        // progress and the root fades, so the orb stretches into
        // the capsule as a single motion. She first picked the
        // jelly tuning (response 0.6, damping 0.60) from the
        // demos, then found it wobbled too much on device and
        // asked for the calm unified spring instead — response
        // 0.55, damping 0.86: essentially no overshoot, just a
        // fluid settle. Before all this, the frame ran a 0.3 s
        // duration spring, the layout a response-0.3 spring
        // (different curve, same-looking numbers) and each icon
        // had its own delayed pop-in — three clocks, and the
        // expansion read as disjointed no matter how they were
        // tuned.
        static let morphSpringResponse: Double = 0.35
        static let morphSpringDamping: Double = 1.0
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
        syncHiddenHandle(dockFrame: newFrame, isOnRightSide: isOnRightSide)
    }

    // MARK: - Hidden handle

    private var hiddenHandle: LCHiddenDockHandleView?

    /// The handle is the only thing a hidden dock leaves on
    /// screen (Ann 2026-11-25): it lives in the same superview as
    /// the dock itself (the top layer, above every guest window),
    /// on the dock's own edge, centered on the dock's height.
    /// Synced from updateDockFrame so every path that moves or
    /// hides the dock keeps it correct.
    private func syncHiddenHandle(dockFrame: CGRect, isOnRightSide: Bool) {
        guard isDockHidden, isVisible, let parent = hostingController?.view.superview else {
            // A pull-from-handle in flight owns the handle: it
            // fades with the pull, and only the pull's own end
            // decides whether it is removed or restored.
            if handlePullInProgress { return }
            // Recall (or dismissal): the handle fades out as the
            // orb springs back in, instead of popping out of
            // existence mid-handoff.
            if let handle = hiddenHandle {
                hiddenHandle = nil
                UIView.animate(withDuration: 0.18, animations: {
                    handle.alpha = 0
                }, completion: { _ in
                    handle.removeFromSuperview()
                })
            }
            return
        }
        let handle: LCHiddenDockHandleView
        if let existing = hiddenHandle {
            handle = existing
        } else {
            handle = LCHiddenDockHandleView()
            handle.onPullBegan = { [weak self] in self?.beginPullFromHandle() }
            handle.onPullChanged = { [weak self] progress in self?.updatePullFromHandle(progress: progress) }
            handle.onPullEnded = { [weak self] commit in self?.endPullFromHandle(commit: commit) }
            handle.onExpand = { [weak self] in self?.expandDockFromHidden() }
            handle.onMoveEnd = { [weak self] centerY in self?.moveHiddenDock(centerY: centerY) }
            hiddenHandle = handle
        }
        if handle.superview !== parent {
            parent.addSubview(handle)
            handle.fadeIn()
        }
        handle.isOnRightSide = isOnRightSide
        // The handle is the orb squashed flat (Ann 2026-11-25):
        // same height as the orb, only the width is squeezed —
        // and both follow the orb's size when it is resized.
        let handleHeight = collapsedDockHeight(for: dockWidth)
        let handleWidth = LCHiddenDockHandleView.handleWidth(forOrbWidth: dockWidth)
        let screenBounds = keyWindow?.bounds ?? dockFrame
        let minY = safeAreaInsets.top + Constants.dockVerticalMargin
        let maxY = screenBounds.height - safeAreaInsets.bottom - Constants.dockVerticalMargin - handleHeight
        let y = min(max(dockFrame.midY - handleHeight / 2, minY), maxY)
        let x = isOnRightSide ? screenBounds.width - handleWidth : 0
        handle.frame = CGRect(x: x, y: y, width: handleWidth, height: handleHeight)
        handle.setNeedsLayout()
    }

    /// The handle was dragged vertically: move the hidden dock
    /// (and with it the handle, via the frame sync) so the orb
    /// returns at the new height.
    private func moveHiddenDock(centerY: CGFloat) {
        guard isDockHidden, let hostingController else { return }
        let frame = hostingController.view.frame
        hostingController.view.frame = CGRect(x: frame.origin.x, y: centerY - frame.height / 2,
                                              width: frame.width, height: frame.height)
        updateDockFrame()
    }

    /// Keep the tap-outside scrim in step with the dock: present on
    /// every visible guest window only while the dock is visible,
    /// expanded and not hidden to the side.
    private func syncTapOutsideScrim() {
        let shouldShow = isVisible && !isCollapsed && !isDockHidden
        for app in apps {
            guard let view = app.view,
                  let vc = view._viewDelegate() as? DecoratedAppSceneViewController else { continue }
            // Turning scrims OFF must reach every window, visible
            // or not: a window minimized while its scrim was on
            // used to be skipped by the visibility check, kept the
            // scrim, and brought it back when reopened — the first
            // tap on it then toggled the dock (the orb "expanded
            // by itself") instead of reaching the app (Ann
            // 2026-11-24, reproduced on device: two apps open,
            // back to LC home, reopen one). Turning them ON still
            // only concerns visible windows; a window that appears
            // later re-syncs as it comes to the front (see
            // bringMultitaskViewToFront).
            if !shouldShow {
                vc.setTapOutsideScrimVisible(false)
            } else if !view.isHidden, view.alpha >= 0.1 {
                vc.setTapOutsideScrimVisible(true)
            }
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
                // Fully out (Ann 2026-11-25): a hidden dock no
                // longer leaves a sliver of itself behind — the
                // handle (see LCHiddenDockHandleView) is what
                // stays on the edge instead.
                ans += dockWidth + 2
            }
        } else {
            ans = 0
            if self.hostingController?.view.window?.windowScene?.interfaceOrientation == UIInterfaceOrientation.landscapeRight {
                ans += safeInsets.left
            }
            if isDockHidden {
                ans -= dockWidth + 2
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
            if hostingController.view.frame.size != newFrame.size {
                // A size change is the collapse/expand morph (or
                // an icon arriving/leaving): run the frame on
                // the morph spring — UIKit's duration + damping
                // ratio is the same physical spring SwiftUI's
                // response + dampingFraction describes — so the
                // glass and the content it carries stay in step
                // (Ann 2026-11-24).
                UIView.animate(
                    withDuration: Constants.morphSpringResponse,
                    delay: 0,
                    usingSpringWithDamping: CGFloat(Constants.morphSpringDamping),
                    initialSpringVelocity: 0,
                    options: [.beginFromCurrentState, .curveEaseOut]
                ) {
                    hostingController.view.frame = newFrame
                }
            } else {
                UIView.animate(
                    withDuration: Constants.standardAnimationDuration,
                    delay: 0,
                    usingSpringWithDamping: Constants.standardSpringDamping,
                    initialSpringVelocity: Constants.standardSpringVelocity,
                    options: .curveEaseOut
                ) {
                    hostingController.view.frame = newFrame
                }
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
            // …and from the orb form, whatever form the last
            // session ended in.
            self.collapsedFormIsHandle = false
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
                self.isDockHidden = false
                self.collapsedFormIsHandle = false
                hostingController.view.transform = .identity
                self.syncTapOutsideScrim()
                // A dismissed dock leaves no handle behind either.
                self.hiddenHandle?.removeFromSuperview()
                self.hiddenHandle = nil
            }
        }
    }

    /// Move a view's layer anchor point without letting the
    /// view jump on screen (the standard compensation: shift the
    /// position by the anchor delta, in transformed coordinates).
    /// Used to pin the dock to its screen-edge side while it
    /// squashes into — or grows out of — the hidden handle.
    private func setDockAnchorPoint(_ point: CGPoint, for view: UIView) {
        var newPoint = CGPoint(x: view.bounds.size.width * point.x,
                               y: view.bounds.size.height * point.y)
        var oldPoint = CGPoint(x: view.bounds.size.width * view.layer.anchorPoint.x,
                               y: view.bounds.size.height * view.layer.anchorPoint.y)
        newPoint = newPoint.applying(view.transform)
        oldPoint = oldPoint.applying(view.transform)
        var position = view.layer.position
        position.x -= oldPoint.x
        position.x += newPoint.x
        position.y -= oldPoint.y
        position.y += newPoint.y
        view.layer.position = position
        view.layer.anchorPoint = point
    }

    /// The hosting view's horizontal squash when it poses as the
    /// handle: the handle's width over the orb's width.
    private var handleSquashScale: CGFloat {
        LCHiddenDockHandleView.handleWidth(forOrbWidth: dockWidth) / max(dockWidth, 1)
    }

    private func dockIsOnRightSide(_ view: UIView) -> Bool {
        let screenWidth = view.superview?.bounds.width ?? view.frame.maxX * 2
        return view.frame.midX > screenWidth / 2
    }

    // Toggle dock hide/show state (hide-to-side). 微珠's multitask
    // takeover probes these @objc methods by name and hooks them;
    // their signatures must stay exactly as they are.
    @objc public func toggleDockVisibility() {
        DispatchQueue.main.async {
            self.isDockHidden.toggle()
            self.collapsedFormIsHandle = self.isDockHidden
            self.updateDockFrame()
        }
    }

    // MARK: - Finger-scrubbed squash (orb <-> handle)

    /// The orb→handle squeeze follows the finger (Ann
    /// 2026-11-25, preview-approved): dragging the collapsed
    /// orb outward deforms it against its own edge — drag
    /// distance maps linearly onto the squash, released past
    /// halfway it settles into the handle, short of that it
    /// springs back. Like Weizhu's droplet pull, the shape is
    /// scrubbed by the drag itself; no timed squash plays
    /// after the fact and nothing snaps in or out.
    private let squashFullDragDistance: CGFloat = 70
    private(set) var dockSquashProgress: CGFloat = 0
    private var dockSquashAnchorApplied = false

    /// A drag translation's outward component: positive when
    /// the drag heads off the dock's own edge.
    func dockOutwardDistance(_ translation: CGSize) -> CGFloat {
        guard let frame = hostingController?.view.frame,
              let screenWidth = keyWindow?.bounds.width else { return 0 }
        return frame.origin.x > screenWidth / 2 ? translation.width : -translation.width
    }

    func scrubDockSquash(outwardDistance: CGFloat) {
        guard isCollapsed, !isDockHidden, let view = hostingController?.view else { return }
        if !dockSquashAnchorApplied {
            let anchorX: CGFloat = dockIsOnRightSide(view) ? 1 : 0
            setDockAnchorPoint(CGPoint(x: anchorX, y: 0.5), for: view)
            dockSquashAnchorApplied = true
        }
        let s = min(max(outwardDistance / squashFullDragDistance, 0), 1)
        dockSquashProgress = s
        // The droplet press from the approved preview: mid-press
        // the orb bulges slightly taller; at full squash its
        // height is the orb's own again, exactly where the
        // handle (same height) takes over.
        view.transform = CGAffineTransform(
            scaleX: 1 + (handleSquashScale - 1) * s,
            y: 1 + 0.10 * sin(s * .pi)
        )
    }

    /// The drag ended (or turned away) without committing to
    /// the handle: spring the orb back to shape.
    func releaseDockSquash() {
        guard dockSquashAnchorApplied, let view = hostingController?.view else { return }
        dockSquashAnchorApplied = false
        dockSquashProgress = 0
        UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            view.transform = .identity
        } completion: { _ in
            self.setDockAnchorPoint(CGPoint(x: 0.5, y: 0.5), for: view)
        }
    }

    // MARK: - Handle pull (scrubbed recall)

    /// While a pull is in flight, syncHiddenHandle leaves the
    /// handle alone (see its guard branch): the pull fades it
    /// and decides its fate at the end.
    private var handlePullInProgress = false
    private var pullHandleBaseAlpha: CGFloat = 0.85

    func beginPullFromHandle() {
        guard isDockHidden, isVisible, let view = hostingController?.view else { return }
        handlePullInProgress = true
        pullHandleBaseAlpha = hiddenHandle?.alpha ?? 0.85
        collapsedFormIsHandle = false
        isDockHidden = false
        // The orb's frame, wearing the full squash — the pull
        // relaxes it from here. updateDockFrame's syncs are
        // safe to run in this state: collapsed means no scrim,
        // and handlePullInProgress keeps the handle in place.
        UIView.performWithoutAnimation {
            updateDockFrame(animated: false)
            let anchorX: CGFloat = dockIsOnRightSide(view) ? 1 : 0
            setDockAnchorPoint(CGPoint(x: anchorX, y: 0.5), for: view)
            view.transform = CGAffineTransform(scaleX: handleSquashScale, y: 1)
        }
    }

    func updatePullFromHandle(progress: CGFloat) {
        guard handlePullInProgress, let view = hostingController?.view else { return }
        let p = min(max(progress, 0), 1)
        // The same droplet curve as the squeeze, run backwards:
        // the bulge peaks halfway out.
        view.transform = CGAffineTransform(
            scaleX: handleSquashScale + (1 - handleSquashScale) * p,
            y: 1 + 0.10 * sin((1 - p) * .pi)
        )
        hiddenHandle?.alpha = pullHandleBaseAlpha * (1 - p)
    }

    func endPullFromHandle(commit: Bool) {
        guard handlePullInProgress, let view = hostingController?.view else { return }
        if commit {
            UIView.animate(
                withDuration: 0.3,
                delay: 0,
                usingSpringWithDamping: 0.8,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .curveEaseOut]
            ) {
                view.transform = .identity
            } completion: { _ in
                self.setDockAnchorPoint(CGPoint(x: 0.5, y: 0.5), for: view)
                self.handlePullInProgress = false
                self.updateDockFrame()
            }
        } else {
            UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
                view.transform = CGAffineTransform(scaleX: self.handleSquashScale, y: 1)
            } completion: { _ in
                // Same rule as the hide: identity and the center
                // anchor are restored BEFORE the hidden frame is
                // taken, in one unrendered pass; the handle's
                // alpha comes back in the same pass.
                UIView.performWithoutAnimation {
                    view.transform = .identity
                    self.setDockAnchorPoint(CGPoint(x: 0.5, y: 0.5), for: view)
                    self.isDockHidden = true
                    self.handlePullInProgress = false
                    self.hiddenHandle?.alpha = self.pullHandleBaseAlpha
                    self.updateDockFrame(animated: false)
                }
            }
        }
    }

    /// Pulling the handle back out restores the orb (Ann
    /// 2026-11-25): the squashed dock is placed at the orb's
    /// frame still wearing the handle's width, then springs
    /// back to full width around its edge-side anchor — the
    /// reverse of the hide squash in hideDockToSide.
    @objc public func showDockFromHidden() {
        DispatchQueue.main.async {
            guard self.isDockHidden else {
                self.updateDockFrame()
                return
            }
            self.collapsedFormIsHandle = false
            self.isDockHidden = false
            self.updateDockFrame(animated: false)
            guard let view = self.hostingController?.view else { return }
            let anchorX: CGFloat = self.dockIsOnRightSide(view) ? 1 : 0
            self.setDockAnchorPoint(CGPoint(x: anchorX, y: 0.5), for: view)
            view.transform = CGAffineTransform(scaleX: self.handleSquashScale, y: 1)
            UIView.animate(
                withDuration: Constants.morphSpringResponse,
                delay: 0,
                usingSpringWithDamping: 0.8,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .curveEaseOut]
            ) {
                view.transform = .identity
            } completion: { _ in
                self.setDockAnchorPoint(CGPoint(x: 0.5, y: 0.5), for: view)
            }
        }
    }

    /// Tapping the handle expands the dock directly (Ann
    /// 2026-11-25): orb and handle are two collapsed forms of
    /// the same dock, and a tap on either one expands it. The
    /// form memory stays on the handle (collapsedFormIsHandle),
    /// so collapsing afterwards squashes back into the handle
    /// rather than stopping at the orb. The growth is ONE
    /// continuous motion (Ann 2026-11-25, later: an earlier
    /// two-stage version visibly paused at the orb on its way
    /// out — a sequencing artifact of the frame/transform fix,
    /// not the intent): the final expanded frame is placed
    /// first, at identity, then a two-axis squash about the
    /// handle's own spot makes it LOOK like the handle, and a
    /// single spring back to identity grows it straight into
    /// the expanded dock — passing through the orb's shape
    /// without stopping there — while the content runs its
    /// ordinary expand morph on the same clock.
    @objc public func expandDockFromHidden() {
        DispatchQueue.main.async {
            guard self.isDockHidden, self.isVisible,
                  let view = self.hostingController?.view else { return }
            let anchorX: CGFloat = self.dockIsOnRightSide(view) ? 1 : 0
            // The hidden frame's midY is the orb's center; the
            // handle is centered on it too.
            let orbMidY = view.frame.midY
            self.isDockHidden = false
            self.isCollapsed = false
            UIView.performWithoutAnimation {
                self.updateDockFrame(animated: false)
                let expanded = view.frame
                guard expanded.height > 0 else { return }
                // Anchor at the handle's spot inside the final
                // frame: the edge horizontally, the orb's center
                // vertically. The dock's width is the same in
                // both forms, so handleSquashScale is the exact
                // horizontal squash here too; vertically the
                // expanded height squashes down to the orb's.
                let anchorY = min(max((orbMidY - expanded.minY) / expanded.height, 0), 1)
                self.setDockAnchorPoint(CGPoint(x: anchorX, y: anchorY), for: view)
                view.transform = CGAffineTransform(
                    scaleX: self.handleSquashScale,
                    y: self.collapsedDockHeight(for: self.dockWidth) / expanded.height
                )
            }
            UIView.animate(
                withDuration: Constants.morphSpringResponse,
                delay: 0,
                usingSpringWithDamping: CGFloat(Constants.morphSpringDamping),
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .curveEaseOut]
            ) {
                view.transform = .identity
            } completion: { _ in
                self.setDockAnchorPoint(CGPoint(x: 0.5, y: 0.5), for: view)
            }
        }
    }

    @objc public func hideDockToSide() {
        DispatchQueue.main.async {
            // Hiding is a collapsed-orb state (Ann 2026-11-25):
            // an expanded dock shoved out of the way collapses
            // first. The orb then squashes flat into the handle
            // (Ann 2026-11-25, later): same height, squeezed
            // width, pinned to its own edge — one object changing
            // shape, not a swap for a different part. Only once
            // the squash lands does the dock take its off-screen
            // hidden frame and the handle take its place.
            self.isCollapsed = true
            self.collapsedFormIsHandle = true
            guard self.isVisible, !self.isDockHidden,
                  let view = self.hostingController?.view else {
                self.isDockHidden = true
                self.updateDockFrame()
                return
            }
            let anchorX: CGFloat = self.dockIsOnRightSide(view) ? 1 : 0
            self.setDockAnchorPoint(CGPoint(x: anchorX, y: 0.5), for: view)
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
                view.transform = CGAffineTransform(scaleX: self.handleSquashScale, y: 1)
            } completion: { _ in
                // Never set a frame while a transform is live
                // (device bug, Ann 2026-11-25: the frame setter
                // bakes the squash into the bounds, and clearing
                // the transform afterwards left a bloated orb
                // sitting on screen after the dock had hidden).
                // Restore identity and the center anchor first,
                // then take the hidden frame — all in one
                // unrendered pass, so nothing flashes.
                UIView.performWithoutAnimation {
                    view.transform = .identity
                    self.setDockAnchorPoint(CGPoint(x: 0.5, y: 0.5), for: view)
                    self.dockSquashProgress = 0
                    self.dockSquashAnchorApplied = false
                    self.isDockHidden = true
                    self.updateDockFrame(animated: false)
                }
            }
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

    /// The drag offset actually shown while dragging (Ann
    /// 2026-11-25): movement AWAY from the screen's center — the
    /// direction that would hide the dock — follows the finger at
    /// only a third of the distance, so the dock feels stuck to
    /// its edge and an accidental outward drift during a vertical
    /// reposition barely moves it. Every other direction (inward,
    /// vertical, and the inward pull that recalls a hidden dock)
    /// follows 1:1.
    func resistedDragTranslation(_ translation: CGSize) -> CGSize {
        guard let originalFrame = hostingController?.view.frame,
              let screenWidth = keyWindow?.bounds.width else { return translation }
        let isOnRightSide = originalFrame.origin.x > screenWidth / 2
        let outward = isOnRightSide ? translation.width : -translation.width
        guard outward > 0 else { return translation }
        let resisted = outward / 3
        return CGSize(width: isOnRightSide ? resisted : -resisted, height: translation.height)
    }

    // Check if gesture is for cross-screen movement (left to right or vice versa)
    func handleSwipeToHideOrShowGesture(for originalFrame: CGRect, translation: CGSize) -> Bool {
        let screenWidth = keyWindow!.bounds.width
        let isOnRightSide = originalFrame.origin.x > screenWidth / 2
        // A horizontal value's outward component: positive = away
        // from the screen's center, off the dock's own edge.
        func outward(_ dx: CGFloat) -> CGFloat { isOnRightSide ? dx : -dx }

        if isDockHidden {
            // Recall stays effortless (Ann 2026-11-25): any
            // inward-leaning release brings the dock back.
            guard outward(translation.width) < 0 else { return false }
            self.showDockFromHidden()
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred()
            return true
        }

        // Hiding by drag is the squeeze, and only the squeeze
        // (Ann 2026-11-25, later: the fling tests are deleted —
        // a flick whose predicted landing flew out, or a shove
        // that pushed the dock's center off the screen, used to
        // hide it too). The orb has been deforming under the
        // finger the whole way out, so a mainly-horizontal
        // release past halfway through the squash simply lets
        // it land as the handle; anything else falls through
        // and the dock settles back onto its edge.
        guard isCollapsed, abs(translation.width) > abs(translation.height),
              outward(translation.width) >= squashFullDragDistance / 2 else { return false }
        self.hideDockToSide()
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()
        return true
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
                // Every reopen path funnels through here (home
                // grid, banner, dock icon, previous-app jump):
                // re-derive the window's scrim from the dock's
                // current state at the moment it appears, so a
                // scrim left over from an earlier expanded phase
                // can never ride back in with it (Ann 2026-11-24).
                syncTapOutsideScrim()
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
            // Collapsing a dock whose collapsed form is the
            // handle (it was expanded straight from the handle)
            // goes all the way back to the handle (Ann
            // 2026-11-25): the frame morph shrinks it to orb
            // height while it slides out, and the handle takes
            // its place at the same height.
            if self.isCollapsed, self.collapsedFormIsHandle {
                self.isDockHidden = true
            }
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
    @State private var showCloseAllConfirm = false

    /// Morph progress for the collapse/expand animation: 0 is
    /// the orb, 1 the full capsule. A single spring-animated
    /// value drives the icons' travel, the end padding and the
    /// glyph fade, so the morph is one motion (Ann 2026-11-24).
    /// isCollapsed stays the logical state (frame size, hit
    /// testing); this is its animated shadow.
    @State private var morphProgress: CGFloat = 0

    private var morphSpring: Animation {
        .spring(response: MultitaskDockManager.Constants.morphSpringResponse, dampingFraction: MultitaskDockManager.Constants.morphSpringDamping)
    }

    /// Offset that pulls an expanded element back onto the
    /// stack's center (the orb's seat) at morphProgress 0; as
    /// the spring runs, every element rides it out to its own
    /// slot — past it, briefly, when the jelly spring
    /// overshoots.
    private func morphOffset(for index: Int, total: Int) -> CGFloat {
        let center = Double(total - 1) / 2
        let slot = (Double(index) - center) * Double(dockManager.adaptiveIconSize + 8)
        return CGFloat(-slot) * (1 - morphProgress)
    }
    
    // Calculate dynamic padding based on user settings
    private var dynamicPadding: CGFloat {
        let basePadding: CGFloat = 4
        let extraPadding = (dockManager.dockWidth - MultitaskDockManager.Constants.defaultDockWidth) * 0.2
        return max(basePadding, basePadding + extraPadding)
    }

    
    public var body: some View {
        GeometryReader { g in
            // One stack, always in the tree (Ann 2026-11-24):
            // the morph is the icons travelling from the orb's
            // seat out to their slots on a single spring (see
            // morphProgress / morphOffset), with the glyph
            // fading on the same value — no content swap, no
            // per-element transitions, no stagger delays left.
            ZStack {
                VStack(spacing: 8) {
                    ForEach(Array(dockManager.apps.enumerated()), id: \.element.id) { pair in
                        AppIconView(app: pair.element)
                            .offset(y: morphOffset(for: pair.offset, total: dockManager.apps.count + 1))
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
                        .offset(y: morphOffset(for: dockManager.apps.count, total: dockManager.apps.count + 1))
                }
                // The stack must not size the dock while it is
                // collapsed: the glass hugs the container, so a
                // full-height stack in the tree stretched the
                // orb into a pill (Ann 2026-11-24, first jelly
                // build). Its layout height rides the morph —
                // zero at the orb (the glyph alone sizes the
                // container, exactly the pre-morph geometry),
                // full at the capsule — while the icons
                // themselves overflow the small layout frame on
                // their offsets and are revealed by the capsule
                // clip as it grows.
                .frame(height: (CGFloat(dockManager.apps.count + 1) * dockManager.adaptiveIconSize + CGFloat(dockManager.apps.count) * 8) * morphProgress)
                // Staggered fades (Ann 2026-11-25, optimized morph):
                // the icons reach full opacity early (progress 0.2,
                // while they are still near the orb and the growing
                // glass clips their travel), and the glyph below
                // only starts fading once the icons are solid. The
                // old curves crossed mid-fade (icons full at 0.45,
                // glyph gone at 0.4) and the whole dock read as
                // transparent for an instant; now some element is
                // solid at every point of the morph, both ways —
                // the same functions of progress run in reverse on
                // collapse.
                .opacity(Double(min(1, morphProgress * 5)))
                .allowsHitTesting(!dockManager.isCollapsed)

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
                    // Delayed fade (see the icons' note above): the
                    // glyph holds until progress 0.15 — the icons
                    // are solid by then — and is gone by 0.4.
                    .opacity(Double(1 - min(1, max(0, (morphProgress - 0.15) * 4))))
                    .allowsHitTesting(dockManager.isCollapsed)
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
            }
            .onChange(of: dockManager.isCollapsed) { collapsed in
                withAnimation(morphSpring) {
                    morphProgress = collapsed ? 0 : 1
                }
            }
            .onAppear {
                morphProgress = dockManager.isCollapsed ? 0 : 1
            }
            .padding(.horizontal, dynamicPadding)
            // Expanded, the pill's curved ends need extra room at
            // the top and bottom so the end icons stay inside the
            // glass (see dockEndExtra); collapsed stays a circle.
            // The morph progress interpolates it, so the ends
            // grow out with the same spring as everything else.
            .padding(.vertical, dynamicPadding + dockManager.dockEndExtra(for: dockManager.dockWidth) * morphProgress)
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
            // idle. Expanded dock: fully opaque. (A hidden dock is
            // fully off-screen now; its handle carries the visual.)
            .opacity(dockManager.isCollapsed ? (dockManager.isDockIdleDimmed ? 0.3 : 0.6) : 1.0)
            .animation(.easeInOut(duration: 0.35), value: dockManager.isDockIdleDimmed)
            // The remaining isCollapsed-keyed values (the root
            // opacity above) ride the morph spring like
            // everything else in the collapse change — they used
            // to run on two other curves besides (Ann 2026-11-24).
            .animation(morphSpring, value: dockManager.isCollapsed)
            .offset(dragOffset)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }



        .ignoresSafeArea()
        .gesture(
            DragGesture(minimumDistance: 5)
            .onChanged { value in
                dockManager.noteDockInteraction()
                self.isMoving = true
                // Finger-scrubbed squeeze (Ann 2026-11-25): an
                // outward, mainly-horizontal drag on the
                // collapsed orb no longer pokes it off its edge
                // at a resisted rate — the orb stays pinned and
                // squashes toward the handle under the finger,
                // while only the drag's vertical component
                // still travels with it.
                let outward = dockManager.dockOutwardDistance(value.translation)
                if dockManager.isCollapsed, !dockManager.isDockHidden,
                   outward > 0, abs(value.translation.width) > abs(value.translation.height) {
                    dockManager.scrubDockSquash(outwardDistance: outward)
                    self.dragOffset = CGSize(width: 0, height: value.translation.height)
                } else {
                    dockManager.releaseDockSquash()
                    self.dragOffset = dockManager.resistedDragTranslation(value.translation)
                }
            }
            .onEnded { value in
                self.isMoving = true

                let hcFrame = dockManager.hostingController?.view.frame ?? .zero
                
                let currentPhysicalFrame = hcFrame.offsetBy(dx: self.dragOffset.width, dy: self.dragOffset.height)
                
                if dockManager.isPositionChangeGesture(for: hcFrame, translation: value.translation) {
                    dockManager.releaseDockSquash()
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

                // No hide: any squeeze the drag built up springs
                // back with the settle.
                dockManager.releaseDockSquash()
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
        .animation(morphSpring, value: dockManager.isCollapsed)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.dockWidth)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.settingsChanged)
    }
    
    public init() {}
}

// MARK: - Collapsed Dock View
@available(iOS 16.0, *)
struct CollapsedDockView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    @AppStorage("LCBreathingLightColor", store: LCUtils.appGroupUserDefault) var breathingLightColorRaw: String = LCBreathingLightColor.standard.rawValue

    var body: some View {
        ZStack {
            // The glyph breathes the way Weizhu's orb line does
            // (FMApplyOrbLineAnimation): a CABasicAnimation
            // committed to the glyph's layer — see
            // BreathingGlyphView for why it lives there.
            BreathingGlyphView(
                // Sized off the dock width, not adaptiveIconSize:
                // the orb keeps its exact pre-0.68 glyph size
                // (0.375 x width) — only the expanded icons shrank.
                pointSize: dockManager.dockWidth * 0.375,
                tint: (LCBreathingLightColor(rawValue: breathingLightColorRaw) ?? .standard).uiColor ?? .label
            )
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

/// The orb's glyph with Weizhu's breathing mechanism
/// (FMApplyOrbLineAnimation in the module this fork replaces):
/// a CABasicAnimation on the layer's opacity — 0.38 <-> 1,
/// 1.15s ease-in-out, autoreversing, forever. The mechanism is
/// the lesson (Ann 2026-11-25: two SwiftUI attempts still
/// flashed). A layer animation runs in the render server: it
/// interpolates at full frame rate no matter what the app
/// thread is busy with, and no SwiftUI re-render of the dock
/// (front-app changes, morph state, published updates) can
/// restart it mid-cycle or drop its frames — both things a
/// view-level `.animation` pulse and a TimelineView pulse
/// visibly suffered from.
private struct BreathingGlyphView: UIViewRepresentable {
    var pointSize: CGFloat
    var tint: UIColor

    func makeUIView(context: Context) -> BreathingGlyphUIView {
        BreathingGlyphUIView()
    }

    func updateUIView(_ uiView: BreathingGlyphUIView, context: Context) {
        uiView.apply(pointSize: pointSize, tint: tint)
    }
}

private final class BreathingGlyphUIView: UIView {
    private let imageView = UIImageView()
    private var pointSize: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .center
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// While the app sits in the background, iOS snapshots it
    /// and the snapshot drops layer animations; nothing in the
    /// passive re-assert points (apply / layout / window /
    /// superview) runs on a plain foreground return, so the
    /// orb sat frozen until a tap forced a re-render — and the
    /// handle, left showing, froze the same way (Ann
    /// 2026-11-25, both verified on device). On activation,
    /// rebuild the pulse outright instead of trusting the
    /// alive-check: the same rebuild-on-appearance the handle
    /// has always done in fadeIn.
    @objc private func appDidBecomeActive() {
        layer.removeAnimation(forKey: "breathing")
        startPulseIfNeeded()
    }

    func apply(pointSize: CGFloat, tint: UIColor) {
        imageView.tintColor = tint
        if self.pointSize != pointSize {
            self.pointSize = pointSize
            let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            imageView.image = UIImage(systemName: "square.grid.2x2.fill", withConfiguration: config)?
                .withRenderingMode(.alwaysTemplate)
        }
        setNeedsLayout()
        startPulseIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        // Layout passes are the most frequent lifecycle the
        // dock guarantees (every morph step runs one), so the
        // pulse is re-asserted here too — the guard keeps it a
        // no-op while the animation is alive.
        startPulseIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        startPulseIfNeeded()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        startPulseIfNeeded()
    }

    /// The pulse lives on this container's layer, not the
    /// image view's (device finding, Ann 2026-11-25: with the
    /// pulse on the UIImageView's layer and started only from
    /// didMoveToWindow, the orb sat still while the handle —
    /// whose pulse sits on a plain container view and is
    /// re-applied every time it appears — breathed fine).
    /// Same structure as the handle's grip, and the start is
    /// re-asserted from apply(), which SwiftUI calls on every
    /// update while the dock is on screen; the guard keeps it
    /// a no-op while the animation is alive.
    private func startPulseIfNeeded() {
        guard layer.animation(forKey: "breathing") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.38
        pulse.toValue = 1.0
        pulse.duration = 1.15
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "breathing")
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
/// as the app grid icon host's press tracking).
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

/// Breathing-light color presets (Ann 2026-11-25): one setting
/// tints every breathing light the dock has — the collapsed
/// orb's glyph and the hidden handle's grip — so the dock's two
/// states share one "I am here" signal, in a color picked from
/// a few presets chosen to stay distinguishable on any
/// background. Stored by raw value under LCBreathingLightColor
/// in the app-group defaults.
enum LCBreathingLightColor: String, CaseIterable {
    case standard, red, orange, green, blue, purple, pink

    static var current: LCBreathingLightColor {
        LCBreathingLightColor(rawValue: LCUtils.appGroupUserDefault.string(forKey: "LCBreathingLightColor") ?? "") ?? .standard
    }

    /// nil for the standard preset: each surface then keeps its
    /// platform default (the orb glyph is Color.primary; the
    /// handle's grip is the dark line drawn for its light bar).
    var uiColor: UIColor? {
        switch self {
        case .standard: return nil
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        }
    }

    var color: Color {
        uiColor.map { Color($0) } ?? .primary
    }

    var labelKey: String {
        "lc.settings.breathingLightColor.\(rawValue)"
    }
}

/// The handle a hidden dock leaves on the screen edge (Ann
/// 2026-11-25, replacing the slid-out sliver and the window-level
/// edge-swipe recognizers): a thin frosted bar in the dock's own
/// top layer, so it stays touchable even while a guest app fills
/// the screen — guest touches are routed straight to the guest
/// process and never reached the old window recognizers anywhere
/// except on the sliver itself. Since later the same day it is
/// the orb's second collapsed form, not a separate part: the
/// orb squashes flat into it (same height, squeezed width), a
/// tap expands the dock directly, an inward drag pulls it back
/// out into the orb, and a vertical drag moves the hidden
/// dock's height. It dims when idle and brightens under the
/// finger, like the orb itself.
private final class LCHiddenDockHandleView: UIView, UIGestureRecognizerDelegate {
    /// The handle's width is a fixed share of the orb's width
    /// (Ann 2026-11-25): resize the orb and the handle follows
    /// — and the hide squash, which compresses the orb to
    /// exactly this width, lands on it at any orb size.
    static let handleWidthRatio: CGFloat = 16.0 / 90.0
    static func handleWidth(forOrbWidth orbWidth: CGFloat) -> CGFloat {
        min(max(orbWidth * handleWidthRatio, 12), 26)
    }
    // No fixed height: the manager sizes the handle to the
    // collapsed orb's height — the handle IS the orb squashed
    // flat (Ann 2026-11-25), so the two collapsed forms share
    // one height and one center line.

    /// An inward drag pulls the handle back out into the orb,
    /// scrubbed by the finger (Ann 2026-11-25): the manager is
    /// told when the pull starts, how far it has got (0...1),
    /// and whether it ended past the commit point.
    var onPullBegan: (() -> Void)?
    var onPullChanged: ((CGFloat) -> Void)?
    var onPullEnded: ((Bool) -> Void)?
    /// A tap: expand the dock directly from the handle.
    var onExpand: (() -> Void)?
    /// The handle finished a vertical drag at this center Y.
    var onMoveEnd: ((CGFloat) -> Void)?

    var isOnRightSide = true {
        didSet { setNeedsLayout() }
    }

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialLight))
    private let tintView = UIView()
    /// The grip is the orb's 2×2 glyph squashed with the orb:
    /// the two columns merge into one, the two rows stay two —
    /// two short segments in a column, breathing together
    /// inside this container (Ann 2026-11-25).
    private let gripView = UIView()
    private let gripTopSegment = UIView()
    private let gripBottomSegment = UIView()
    private var idleTimer: Timer?
    private var dragStartCenterY: CGFloat = 0
    private var dragMode: Int = 0 // 0 undecided, 1 pull, 2 move

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)

        tintView.backgroundColor = UIColor.white.withAlphaComponent(0.35)
        blurView.contentView.addSubview(tintView)
        for segment in [gripTopSegment, gripBottomSegment] {
            segment.backgroundColor = UIColor.black.withAlphaComponent(0.4)
            segment.layer.cornerRadius = 2.5
            gripView.addSubview(segment)
        }
        blurView.contentView.addSubview(gripView)
        addSubview(blurView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.require(toFail: pan)
        addGestureRecognizer(tap)

        // Suspension strips layer animations (see the orb's
        // glyph for the full story): rebuild the grip pulse
        // when the app becomes active again. Off screen this
        // changes nothing visible; fadeIn rebuilds it on
        // appearance anyway.
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)

        alpha = 0.85
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appDidBecomeActive() {
        applyGripStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        blurView.frame = bounds
        // Only the corners facing the screen's middle are round;
        // the edge side sits flush against the screen edge.
        blurView.layer.cornerRadius = bounds.width / 2
        blurView.layer.maskedCorners = isOnRightSide
            ? [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        blurView.clipsToBounds = true
        tintView.frame = bounds
        // The segments copy the orb glyph's own proportions
        // (device feedback, Ann 2026-11-25: the first cut —
        // 38pt span, 8pt gap, 5pt wide — read as two unrelated
        // dashes, not as the glyph). The glyph spans 0.375 of
        // the orb, its cells take 0.44 of that span each with a
        // 0.12 gap between them; squashed, a cell keeps its
        // height and shrinks to a slim 3.5pt-wide segment
        // (scaled with the orb), ends fully rounded.
        let glyphSpan = bounds.height * 0.375
        let cellHeight = glyphSpan * 0.44
        let cellGap = glyphSpan * 0.12
        let segmentWidth = min(max(3.5 * bounds.height / 90, 2.5), 5)
        gripView.frame = CGRect(x: (bounds.width - segmentWidth) / 2, y: (bounds.height - glyphSpan) / 2, width: segmentWidth, height: glyphSpan)
        gripTopSegment.frame = CGRect(x: 0, y: 0, width: segmentWidth, height: cellHeight)
        gripBottomSegment.frame = CGRect(x: 0, y: cellHeight + cellGap, width: segmentWidth, height: cellHeight)
        gripTopSegment.layer.cornerRadius = segmentWidth / 2
        gripBottomSegment.layer.cornerRadius = segmentWidth / 2
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.width / 2).cgPath
    }

    func fadeIn() {
        applyGripStyle()
        alpha = 0
        UIView.animate(withDuration: 0.25) { self.alpha = 0.85 }
        restartIdleTimer()
    }

    /// The grip is a breathing light too (Ann 2026-11-25): the
    /// shared breathing-light color, breathing with the orb's
    /// own animation — the same layer-committed CABasicAnimation
    /// Weizhu's orb line uses (see BreathingGlyphView).
    /// Re-read every time the handle appears, so a color picked
    /// in Settings applies the next time the dock hides.
    private func applyGripStyle() {
        // The color lands on the two segments; the pulse itself
        // sits on their container, so both segments breathe as
        // one squashed glyph.
        let gripColor = LCBreathingLightColor.current.uiColor
            ?? UIColor.black.withAlphaComponent(0.4)
        gripTopSegment.backgroundColor = gripColor
        gripBottomSegment.backgroundColor = gripColor
        gripView.layer.removeAnimation(forKey: "breathing")
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.38
        pulse.toValue = 1.0
        pulse.duration = 1.15
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gripView.layer.add(pulse, forKey: "breathing")
    }

    // MARK: Idle dim (bright under the finger, dim when left alone)

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        // Idle fade (Ann 2026-11-25): 5 seconds untouched, then
        // down to 0.45 — opacity +10 over the old 3s / 0.35, and
        // in sync with the orb's own idle dim (same 5s wait in
        // noteDockInteraction, likewise +10 there).
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self else { return }
            UIView.animate(withDuration: 0.6) { self.alpha = 0.45 }
        }
    }

    private func brighten() {
        idleTimer?.invalidate()
        UIView.animate(withDuration: 0.15) { self.alpha = 1 }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        brighten()
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        restartIdleTimer()
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        restartIdleTimer()
        super.touchesCancelled(touches, with: event)
    }

    // MARK: Gestures

    @objc private func handleTap() {
        onExpand?()
    }

    /// The pull's progress for an inward distance: the first
    /// 12pt only prove intent (the mode decision below), the
    /// pull itself is measured from there over the next 68pt.
    private func pullProgress(forInward inward: CGFloat) -> CGFloat {
        min(max((inward - 12) / 68, 0), 1)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: superview)
        let inward = isOnRightSide ? -translation.x : translation.x
        switch gesture.state {
        case .began:
            dragStartCenterY = center.y
            dragMode = 0
        case .changed:
            if dragMode == 0 {
                // Inward wins over vertical: a drag that leans
                // toward the screen's center by 12pt starts a
                // pull, anything mainly vertical is a height
                // move.
                if inward > 12, abs(translation.x) > abs(translation.y) {
                    dragMode = 1
                    onPullBegan?()
                } else if abs(translation.y) > 8, abs(translation.y) > abs(translation.x) {
                    dragMode = 2
                }
            }
            if dragMode == 1 {
                onPullChanged?(pullProgress(forInward: inward))
            }
            if dragMode == 2, let superview {
                let minY = superview.safeAreaInsets.top + bounds.height / 2 + 8
                let maxY = superview.bounds.height - superview.safeAreaInsets.bottom - bounds.height / 2 - 8
                center.y = min(max(dragStartCenterY + translation.y, minY), maxY)
            }
        case .ended:
            if dragMode == 1 {
                // Past halfway the pull lands as the orb;
                // short of it the handle takes the dock back.
                onPullEnded?(pullProgress(forInward: inward) > 0.5)
            }
            if dragMode == 2 {
                onMoveEnd?(center.y)
            }
            restartIdleTimer()
        case .cancelled, .failed:
            if dragMode == 1 {
                onPullEnded?(false)
            }
            if dragMode == 2 {
                // Settle back to the dock's own height.
                onMoveEnd?(center.y)
            }
            restartIdleTimer()
        default:
            break
        }
    }
}
