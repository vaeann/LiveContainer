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

    /// Whether the dock is currently parked off-screen with
    /// only its handle on the edge (hide-to-side). Since the
    /// handle became the dock's only collapsed form (Ann
    /// 2026-11-25, later: the orb is deleted), collapsed and
    /// hidden are the same resting state: isCollapsed says
    /// "not expanded", isDockHidden says the pill itself is
    /// off-screen and the handle is showing. 微珠's multitask
    /// takeover probes the @objc methods that drive this
    /// state (showDockFromHidden, toggleDockVisibility,
    /// hideDockToSide) by name.
    @Published var isDockHidden: Bool = false

    /// Status bar fix state: whether the host status bar override is
    /// currently applied.
    private var statusBarFixApplied = false

    /// The app currently in front in multitask (nil when every window
    /// is minimized, i.e. the user is on the LC home screen). The dock
    /// marks its icon with a breathing green dot. Maintained by
    /// updateStatusBarFix(), which already runs on every front-app
    /// change.
    @Published var frontAppUUID: String?
    /// The app that was in front before the current one — or
    /// the last one before everything went home: the handle's
    /// long press jumps back to it.
    var previousAppUUID: String?

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
        static let maxHeightRatioOfAvailableArea: CGFloat = 0.85
        
        // MARK: - Animation & Interaction


        static let standardAnimationDuration: TimeInterval = 0.3
        static let longAnimationDuration: TimeInterval = 0.4
        
        static let standardSpringDamping: CGFloat = 0.8
        static let standardSpringVelocity: CGFloat = 0.3

        // Hide (Ann 2026-11-23): a calm dematerialize, not a
        // performance — the exit fades in place at a small
        // scale on a plain ease curve. (The matching entrance
        // animation is gone: a session now starts on the
        // handle, whose own fadeIn is the entrance.)
        static let showHideScale: CGFloat = 0.92
        static let hideAnimationDuration: TimeInterval = 0.18

        // Collapse/expand morph (Ann 2026-11-24): ONE physical
        // spring drives the UIKit frame, the SwiftUI morph
        // progress and the root fades, so the dock stretches into
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
            let baseHeight = expandedDockBaseHeight(for: userWidth, iconSize: iconSize)
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

    private func expandedDockBaseHeight(for width: CGFloat, iconSize: CGFloat) -> CGFloat {
        // Expanded dock contents: (apps.count + 1) equal tiles —
        // the app icons and the home tile at the bottom, which is
        // icon-sized like the rest — with apps.count gaps between
        // them. The pill's curved ends add their own allowance on
        // top of the vertical padding, mirrored by the layout's
        // vertical padding. (Until 2026-11-26 the home tile's
        // allowance used the deleted collapse button's size
        // formula — 0.7 ratio, 44–80 clamp — leaving up to ~10pt
        // of phantom height at narrow dock widths.)
        let spacingCount = max(self.apps.count, 0)
        let totalSpacingHeight = CGFloat(spacingCount) * Constants.dockContentSpacing
        return Constants.dockVerticalPadding + iconSize + totalSpacingHeight + 2 * dockEndExtra(for: width)
    }

    private func expandedDockHeight(for width: CGFloat, iconSize: CGFloat) -> CGFloat {
        let baseHeight = expandedDockBaseHeight(for: width, iconSize: iconSize)
        let iconHeight = CGFloat(self.apps.count) * iconSize
        return baseHeight + iconHeight
    }

    private func collapsedDockHeight(for width: CGFloat) -> CGFloat {
        // 收起帧高直接等于宽（Ann 2026-11-23 定）：收起帧是个
        // 正方形——把手取这个高度，展开/收起的压扁也以它为
        // 纵向目标。旧公式（留白 30 + 按钮尺寸）是收起态还有
        // 按钮瓷砖时代的遗留。
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
            // Recall (or dismissal): the handle fades out as the
            // dock springs back in, instead of popping out of
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
            handle.onExpand = { [weak self] in self?.expandDockFromHidden() }
            handle.onLongPress = { [weak self] in
                self?.switchToPreviousApp() ?? false
            }
            handle.onMoveEnd = { [weak self] centerY, isOnRightSide in self?.moveHiddenDock(centerY: centerY, isOnRightSide: isOnRightSide) }
            hiddenHandle = handle
        }
        if handle.superview !== parent {
            parent.addSubview(handle)
            handle.fadeIn()
        }
        handle.isOnRightSide = isOnRightSide
        handle.dragVerticalMargin = Constants.dockVerticalMargin
        handle.useLiquidGlass = SharedModel.isLiquidGlassEnabled
        // The handle is the collapsed dock (Ann 2026-11-25):
        // the collapsed height, only the width is squeezed —
        // and it follows the dock's size when that is resized.
        let handleHeight = collapsedDockHeight(for: dockWidth)
        let handleWidth = LCHiddenDockHandleView.handleWidth(forDockWidth: dockWidth)
        handle.pillWidth = handleWidth
        // The frame is the body plus the flare space at
        // both ends; the body stays centered on the dock's
        // mid-height. The clamp is on the BODY (same as the
        // drag's), so the sync after a snap leaves the
        // handle exactly where it landed.
        let flare = LCHiddenDockHandleView.flareLength(forPillWidth: handleWidth)
        let frameHeight = handleHeight + 2 * flare
        let screenBounds = keyWindow?.bounds ?? dockFrame
        let minY = safeAreaInsets.top + Constants.dockVerticalMargin - flare
        let maxY = screenBounds.height - safeAreaInsets.bottom - Constants.dockVerticalMargin - frameHeight + flare
        let y = min(max(dockFrame.midY - frameHeight / 2, minY), maxY)
        let x = isOnRightSide ? screenBounds.width - handleWidth : 0
        handle.frame = CGRect(x: x, y: y, width: handleWidth, height: frameHeight)
        handle.setNeedsLayout()
    }

    /// The handle was dropped and snapped to an edge: plant
    /// the hidden dock at the dropped height on the dropped
    /// side. updateDockFrame reads the side from the current
    /// frame, so the frame is first planted on the target
    /// half; it then normalizes x to that side's hidden
    /// position and clamps y with the same margins the
    /// handle dragged within, so the sync that follows
    /// leaves the handle exactly where its snap landed it.
    private func moveHiddenDock(centerY: CGFloat, isOnRightSide: Bool) {
        guard isDockHidden, let hostingController else { return }
        let frame = hostingController.view.frame
        let screenWidth = keyWindow?.bounds.width ?? frame.width
        let plantedX = isOnRightSide ? screenWidth - frame.width : 0
        hostingController.view.frame = CGRect(x: plantedX, y: centerY - frame.height / 2,
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
            // A fresh multitask session always starts collapsed,
            // even if the previous session ended expanded — and
            // collapsed means the handle now (the orb is gone):
            // the dock starts parked off-screen and the handle
            // fades in at the edge.
            self.isCollapsed = true
            self.isDockHidden = true

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

            // No entrance animation on the hosting view: it is
            // parked off-screen, and the handle's own fadeIn is
            // the entrance.
            hostingController.view.alpha = 1
            hostingController.view.transform = .identity
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
                hostingController.view.transform = .identity
                self.syncTapOutsideScrim()
                // A dismissed dock leaves no handle behind either.
                self.hiddenHandle?.removeFromSuperview()
                self.hiddenHandle = nil
            }
        }
    }

    /// Where the handle sits inside the dock's own frame, in
    /// frame-local points: the morph's convergence point (Ann
    /// 2026-11-26). The icons used to gather at the pill's
    /// center — the deleted orb's seat; they gather at the
    /// handle now: horizontally the handle's center (half a
    /// handle's width in from the dock's edge), vertically the
    /// collapsed frame's center, which is where the handle is
    /// centered.
    func convergencePoint(in size: CGSize) -> CGPoint {
        guard let view = hostingController?.view else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let frame = view.frame
        let collapsedHeight = collapsedDockHeight(for: dockWidth)
        let screenHeight = keyWindow?.bounds.height ?? frame.maxY
        let collapsedMidY = calculateTargetY(for: frame, dockHeight: collapsedHeight, screenHeight: screenHeight)
            + collapsedHeight / 2
        let handleHalf = LCHiddenDockHandleView.handleWidth(forDockWidth: dockWidth) / 2
        let x = dockIsOnRightSide(view) ? size.width - handleHalf : handleHalf
        return CGPoint(x: x, y: collapsedMidY - frame.minY)
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
            if self.isCollapsed {
                if self.isDockHidden {
                    self.expandDockFromHidden()
                } else {
                    self.isCollapsed = false
                    self.updateDockFrame()
                }
            } else {
                self.hideDockToSide()
            }
        }
    }

    /// Probed compat entry: "show the dock from hidden" used
    /// to restore the orb; with the orb gone it grows the
    /// dock out of the handle instead — the same motion as
    /// tapping the handle.
    @objc public func showDockFromHidden() {
        expandDockFromHidden()
    }

    /// Tapping the handle expands the dock directly (Ann
    /// 2026-11-25): the handle is the dock's collapsed form.
    /// The motion is the collapse run backwards (Ann
    /// 2026-11-26: sync the expand to the collapse's
    /// animation): no transform squash — the frame morphs
    /// from the hidden collapsed frame up to the expanded
    /// frame on the morph spring while the content morph
    /// runs in reverse and the icons emerge from the
    /// handle's spot. One spring, both directions.
    @objc public func expandDockFromHidden() {
        DispatchQueue.main.async {
            guard self.isDockHidden, self.isVisible,
                  self.hostingController?.view != nil else { return }
            self.isDockHidden = false
            self.isCollapsed = false
            self.updateDockFrame()
        }
    }

    @objc public func hideDockToSide() {
        DispatchQueue.main.async {
            // Collapsing IS hiding (Ann 2026-11-25, later):
            // the handle is the dock's only collapsed form.
            // The motion is the previous build's collapse,
            // restored at Ann's word (2026-11-26: that one was
            // perfect): NO transform squash — the frame morphs
            // to the hidden collapsed frame on the morph
            // spring while the content morph converges the
            // icons onto the handle's spot, and the handle
            // fades in where the dock lands. The two-axis
            // squash the single-form build tried stacked a
            // second, rubbery deformation on top of the morph
            // and squashed toward the frame's center instead
            // of the handle; it is gone.
            self.isCollapsed = true
            self.isDockHidden = true
            self.updateDockFrame()
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
    /// Collapsed, that square IS the dock's frame. Expanded, aim
    /// at the square at the capsule's center — where the collapsed
    /// dock sits. Zero when the dock isn't up, so minimize
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
        DispatchQueue.main.async {
            if self.isCollapsed {
                // Collapsed rests on the handle: expanding
                // grows out of it. (A collapsed-but-visible
                // dock is only a mid-animation state now; a
                // call landing there simply expands in place.)
                if self.isDockHidden {
                    self.expandDockFromHidden()
                } else {
                    self.isCollapsed = false
                    self.updateDockFrame()
                }
            } else {
                self.hideDockToSide()
            }
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
            // Whoever just left the front becomes the
            // "previous app" for the handle's long press —
            // including going home: the app just left is
            // where the jump goes.
            if let leaving = frontAppUUID {
                previousAppUUID = leaving
            }
            frontAppUUID = frontUUID
        }
        if hide != statusBarFixApplied,
           LCStatusBarManager.lc_setOverridingStatusBarHidden(hide) {
            statusBarFixApplied = hide
        }
    }

    /// Handle long press: jump back to the app that was in
    /// front before the current one. Returns whether a jump
    /// happened, so the caller ticks only on a real switch.
    @discardableResult
    @objc public func switchToPreviousApp() -> Bool {
        guard let prev = previousAppUUID, prev != frontAppUUID,
              apps.contains(where: { $0.appUUID == prev }) else { return false }
        // From the handle, the window grows out of the
        // handle's own frame at the edge; otherwise out of
        // the dock's home rect.
        let from = isDockHidden ? (hiddenHandle?.frame ?? dockHomeRect()) : dockHomeRect()
        return bringMultitaskViewToFront(uuid: prev, from: from)
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
    @State private var showCloseAllConfirm = false

    /// Morph progress for the collapse/expand animation: 0 is
    /// collapsed, 1 the full capsule. A single spring-animated
    /// value drives the icons' travel and the end padding, so
    /// the morph is one motion (Ann 2026-11-24).
    /// isCollapsed stays the logical state (frame size, hit
    /// testing); this is its animated shadow.
    @State private var morphProgress: CGFloat = 0

    private var morphSpring: Animation {
        .spring(response: MultitaskDockManager.Constants.morphSpringResponse, dampingFraction: MultitaskDockManager.Constants.morphSpringDamping)
    }

    /// Offset that pulls an expanded element back onto the
    /// stack's center at morphProgress 0; as the spring runs,
    /// every element rides it out to its own slot — past it,
    /// briefly, when the jelly spring overshoots. The stack
    /// itself is then shifted so that gathering center lands
    /// on the handle (see convergenceShift).
    private func morphOffset(for index: Int, total: Int) -> CGFloat {
        let center = Double(total - 1) / 2
        let slot = (Double(index) - center) * Double(dockManager.adaptiveIconSize + 8)
        return CGFloat(-slot) * (1 - morphProgress)
    }

    /// The uniform shift that moves the morph's gathering
    /// point from the frame's center to the handle's spot
    /// (Ann 2026-11-26): at progress 0 every element sits
    /// exactly on the handle; at 1 the shift is zero and
    /// every slot is exact.
    private func convergenceShift(in size: CGSize) -> CGSize {
        let point = dockManager.convergencePoint(in: size)
        let rest = 1 - morphProgress
        return CGSize(
            width: (point.x - size.width / 2) * rest,
            height: (point.y - size.height / 2) * rest
        )
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
            // the morph is the icons travelling from the
            // collapsed seat out to their slots on a single
            // spring (see morphProgress / morphOffset) — no
            // content swap, no per-element transitions, no
            // stagger delays left.
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
                // collapsed dock into a pill (Ann 2026-11-24,
                // first jelly build). Its layout height rides
                // the morph — zero while collapsed, full at the
                // capsule — while the icons themselves overflow
                // the small layout frame on their offsets and
                // are revealed by the capsule clip as it grows.
                .frame(height: (CGFloat(dockManager.apps.count + 1) * dockManager.adaptiveIconSize + CGFloat(dockManager.apps.count) * 8) * morphProgress)
                // The icons reach full opacity early in the
                // morph (progress 0.2, while they are still near
                // the collapsed spot and the growing glass clips
                // their travel); the same function of progress
                // runs in reverse on collapse.
                .opacity(Double(min(1, morphProgress * 5)))
                .allowsHitTesting(!dockManager.isCollapsed)
                .offset(convergenceShift(in: g.size))
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
            // glass (see dockEndExtra); collapsed there is none.
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
            // one floating control, not a panel. (This tree only
            // renders while expanded or mid-morph; the collapsed
            // resting visual is the handle.)
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
            // isCollapsed-keyed values ride the morph spring
            // like everything else in the collapse change.
            .animation(morphSpring, value: dockManager.isCollapsed)
            .offset(dragOffset)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }



        .ignoresSafeArea()
        .gesture(
            DragGesture(minimumDistance: 0)
            .onChanged { value in
                self.isMoving = true
                // The drag only moves the dock (Ann 2026-11-25,
                // later: the finger-scrubbed squeeze that shared
                // this drag is deleted — form switching is the
                // long press's job now, both ways). It follows
                // the finger 1:1 from the first point: the old
                // 5pt minimum distance held the opening movement
                // back and then delivered it in one lump (the
                // orb ignored small drags, then jumped), and the
                // old outward third-rate resistance went with
                // the squeeze — repositioning is a free drag
                // now, and the release snaps it back to its
                // edge (the Weizhu bead's model).
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

                    // The magnetic snap (Ann 2026-11-25: clean
                    // and crisp, Weizhu's orb snap as the
                    // reference — its 0.34s / 0.78 damping,
                    // taken a touch firmer): a short, nearly
                    // critically damped spring, no float, no
                    // wobble. The frame bake below keeps the
                    // old longer deadline so it lands after
                    // the spring's visible life.
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                        self.dragOffset = newOffset
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                        dockManager.updateFrameAfterAnimation(finalOffset: newOffset)
                        
                        self.dragOffset = .zero
                        
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

                // Same magnetic snap as the position-change
                // branch above.
                withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
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
/// tints the dock's breathing light — the hidden handle's
/// grip, its "I am here" signal while the dock rests on the
/// handle — in a color picked from a few presets chosen to
/// stay distinguishable on any background. Stored by raw
/// value under LCBreathingLightColor in the app-group
/// defaults.
enum LCBreathingLightColor: String, CaseIterable {
    case standard, red, orange, green, blue, purple, pink

    static var current: LCBreathingLightColor {
        LCBreathingLightColor(rawValue: LCUtils.appGroupUserDefault.string(forKey: "LCBreathingLightColor") ?? "") ?? .standard
    }

    /// nil for the standard preset: the grip then keeps its
    /// platform default (the dark line drawn for its light bar).
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
/// edge-swipe recognizers): a thin glass bar in the dock's own
/// top layer, so it stays touchable even while a guest app fills
/// the screen — guest touches are routed straight to the guest
/// process and never reached the old window recognizers anywhere
/// except on the sliver itself. Since later the same day it is
/// the dock's only collapsed form (the orb is deleted): the
/// dock squashes flat into it (collapsed height, squeezed
/// width), a tap expands the dock directly, a long press jumps
/// back to the previous app, and a drag moves it freely — on
/// release it snaps to the nearest screen edge, taking the
/// hidden dock with it. It dims when idle and brightens under
/// the finger. Its material matches the expanded dock's:
/// liquid glass where the dock uses it, the frosted blur
/// otherwise (Ann 2026-11-25, later: the two read as different
/// materials side by side).
private final class LCHiddenDockHandleView: UIView, UIGestureRecognizerDelegate {
    /// The handle's width is a fixed share of the dock's width
    /// (Ann 2026-11-25): resize the dock and the handle follows
    /// — and the collapse squash, which compresses the dock to
    /// exactly this width, lands on it at any dock size.
    static let handleWidthRatio: CGFloat = 16.0 / 90.0
    static func handleWidth(forDockWidth dockWidth: CGFloat) -> CGFloat {
        min(max(dockWidth * handleWidthRatio, 12), 26)
    }
    // No fixed height: the manager sizes the handle to the
    // dock's collapsed height — the handle IS the dock squashed
    // flat (Ann 2026-11-25), so the two states share one
    // height and one center line.

    /// A tap: expand the dock directly from the handle.
    var onExpand: (() -> Void)?
    /// A long press: jump back to the previous app. Reports
    /// whether a jump happened, so the tick fires only on a
    /// real switch.
    var onLongPress: (() -> Bool)?
    /// The handle was dropped and snapped: it rests at this
    /// center Y, on this side of the screen.
    var onMoveEnd: ((CGFloat, Bool) -> Void)?

    /// The vertical margin the drag is clamped to, mirroring
    /// the dock's own clamp. The manager feeds it in: this
    /// view predates the multitask availability boundary and
    /// cannot read the manager's constants directly.
    var dragVerticalMargin: CGFloat = 30

    var isOnRightSide = true {
        didSet { setNeedsLayout() }
    }

    /// Whether the dock renders in liquid glass, fed by the
    /// manager (this view predates the multitask availability
    /// boundary — same arrangement as dragVerticalMargin).
    var useLiquidGlass = false {
        didSet { if useLiquidGlass != oldValue { applyMaterial() } }
    }

    /// True while a drag has the handle off its edge: the
    /// outline is the plain pill then; the root flares grow
    /// back as the snap lands it on an edge.
    private var isFloating = false {
        didSet { if isFloating != oldValue { setNeedsLayout() } }
    }

    private let blurView = UIVisualEffectView()
    private let tintView = UIView()

    /// The plain wrapper the outline mask sits on (the
    /// Weizhu handle's structure): the mask goes on THIS
    /// view's layer, never on the effect view's own — a
    /// mask set directly on the glass effect view was
    /// ignored on device and the handle rendered as a
    /// plain rectangle (Ann 2026-11-26).
    private let clipView = UIView()
    private let shapeMask = CAShapeLayer()
    /// A hairline tracing the outline: native glass puts
    /// its own edge highlight on a rectangular boundary,
    /// so a custom silhouette draws its own rim.
    private let rimLayer = CAShapeLayer()

    /// The pill's width (the frame's width), fed by the
    /// manager like the other values it owns. Every outline
    /// proportion derives from it: the dome radius is half
    /// of it, the root flares run three quarters of it
    /// along the wall.
    var pillWidth: CGFloat = 16 {
        didSet { if pillWidth != oldValue { setNeedsLayout() } }
    }

    /// How far the docked outline's root flares reach along
    /// the wall, above and below the body. The frame always
    /// reserves this much room at both ends; the flares
    /// grow into it as the handle docks.
    static func flareLength(forPillWidth width: CGFloat) -> CGFloat { width * 0.75 }
    private var flareLength: CGFloat { Self.flareLength(forPillWidth: pillWidth) }

    /// The handle's material: the expanded dock's recipe,
    /// exactly (Ann 2026-11-26) — where the dock uses liquid
    /// glass it is plain .regular with NO tint; a black 0.3
    /// tint borrowed from the grid ribbon made the handle
    /// visibly darker than the dock and not like glass at
    /// all. The frosted blur below is only the pre-glass
    /// fallback.
    private func applyMaterial() {
        if #available(iOS 26.0, *), useLiquidGlass {
            blurView.effect = UIGlassEffect(style: .regular)
            tintView.backgroundColor = .clear
        } else {
            blurView.effect = UIBlurEffect(style: .systemUltraThinMaterialLight)
            tintView.backgroundColor = UIColor.white.withAlphaComponent(0.35)
        }
    }
    /// The handle's outline: ONE closed path of fixed
    /// structure (M C C L C C Z, cubics only, so any two
    /// states interpolate cleanly under CABasicAnimation).
    /// A pill body whose wall-side corners, when docked,
    /// grow concave root flares that run along the screen
    /// edge and melt the body into the wall — the pill and
    /// the flares are a single outline, drawn in one go,
    /// so there is no seam to see (the Weizhu handle's
    /// recipe, in the proportions Ann picked 2026-11-26:
    /// our pill, plus the flares). `flare` is the growth
    /// amount: 0 is the plain pill (while dragging), 1 the
    /// docked silhouette. The dome's inner half is the
    /// same in both states, so the morph reads as the
    /// roots growing out of the pill, not the whole shape
    /// swimming. Built for a right-hand dock; every x is
    /// mirrored for the left.
    private func outlinePath(flare t: CGFloat) -> CGPath {
        let w = bounds.width, h = bounds.height
        let r = pillWidth / 2
        let bodyTop = flareLength
        let bodyBottom = h - flareLength
        let k: CGFloat = 0.5523 // quarter-circle cubic factor
        func mx(_ x: CGFloat) -> CGFloat { isOnRightSide ? x : w - x }
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        let path = CGMutablePath()
        // Wall side, top: the flare's tip on the wall (the
        // plain pill starts lower, where its right edge
        // meets the dome).
        path.move(to: CGPoint(x: mx(w), y: lerp(bodyTop + r, 0)))
        // The root flare (docked) / the dome's wall quarter
        // (pill): one curve into the dome's apex either way.
        path.addCurve(to: CGPoint(x: mx(w / 2), y: bodyTop),
                      control1: CGPoint(x: mx(w), y: lerp(bodyTop + r - k * r, bodyTop * 0.45)),
                      control2: CGPoint(x: mx(lerp(w / 2 + k * r, w / 2 + r * 0.4)), y: bodyTop))
        // The dome's inner quarter — identical in both
        // states, the morph's anchor.
        path.addCurve(to: CGPoint(x: mx(0), y: bodyTop + r),
                      control1: CGPoint(x: mx(w / 2 - k * r), y: bodyTop),
                      control2: CGPoint(x: mx(0), y: bodyTop + r - k * r))
        path.addLine(to: CGPoint(x: mx(0), y: bodyBottom - r))
        path.addCurve(to: CGPoint(x: mx(w / 2), y: bodyBottom),
                      control1: CGPoint(x: mx(0), y: bodyBottom - r + k * r),
                      control2: CGPoint(x: mx(w / 2 - k * r), y: bodyBottom))
        // The bottom flare, mirroring the top.
        path.addCurve(to: CGPoint(x: mx(w), y: lerp(bodyBottom - r, h)),
                      control1: CGPoint(x: mx(lerp(w / 2 + k * r, w / 2 + r * 0.4)), y: bodyBottom),
                      control2: CGPoint(x: mx(w), y: lerp(bodyBottom - r + k * r, h - bodyTop * 0.45)))
        // The wall itself closes the outline.
        path.closeSubpath()
        return path
    }

    /// Morph the outline (mask, rim and shadow together)
    /// between the pill and the docked silhouette.
    private func animateOutline(toDocked docked: Bool, duration: TimeInterval) {
        guard bounds.width > 0 else { return }
        let target = outlinePath(flare: docked ? 1 : 0)
        func morph(_ layer: CALayer, _ keyPath: String, from: CGPath?, apply: (CGPath) -> Void) {
            let anim = CABasicAnimation(keyPath: keyPath)
            anim.fromValue = from
            anim.toValue = target
            anim.duration = duration
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            apply(target)
            layer.add(anim, forKey: "outlineMorph")
        }
        morph(shapeMask, "path", from: (shapeMask.presentation() as? CAShapeLayer)?.path ?? shapeMask.path) { shapeMask.path = $0 }
        morph(rimLayer, "path", from: (rimLayer.presentation() as? CAShapeLayer)?.path ?? rimLayer.path) { rimLayer.path = $0 }
        morph(layer, "shadowPath", from: layer.presentation()?.shadowPath ?? layer.shadowPath) { layer.shadowPath = $0 }
    }

    /// The grip: two short segments in a column, breathing
    /// together inside this container (Ann 2026-11-25) — the
    /// old orb glyph's two rows, its columns merged by the
    /// squash.
    private let gripView = UIView()
    private let gripTopSegment = UIView()
    private let gripBottomSegment = UIView()
    private var idleTimer: Timer?
    private var dragStartCenter: CGPoint = .zero
    private var dragMode: Int = 0 // 0 undecided, 2 move

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)

        applyMaterial()
        blurView.contentView.addSubview(tintView)
        for segment in [gripTopSegment, gripBottomSegment] {
            segment.backgroundColor = UIColor.black.withAlphaComponent(0.4)
            segment.layer.cornerRadius = 2.5
            gripView.addSubview(segment)
        }
        blurView.contentView.addSubview(gripView)
        clipView.addSubview(blurView)
        clipView.layer.mask = shapeMask
        rimLayer.fillColor = UIColor.clear.cgColor
        rimLayer.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
        rimLayer.lineWidth = 1
        clipView.layer.addSublayer(rimLayer)
        addSubview(clipView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        // Long press jumps back to the previous app (Ann
        // 2026-11-25, later). The recognizer's default 10pt
        // movement allowance keeps it a genuine press-and-hold:
        // any real move fails it first (a move needs more
        // travel than the allowance), so the two never overlap.
        // The tap waits for it to fail, which a quick tap does
        // at touch-up, so taps stay instant.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        addGestureRecognizer(longPress)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.require(toFail: pan)
        tap.require(toFail: longPress)
        addGestureRecognizer(tap)

        // Suspension strips layer animations: rebuild the
        // grip pulse when the app becomes active again. Off
        // screen this changes nothing visible; fadeIn rebuilds
        // it on appearance anyway.
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
        clipView.frame = bounds
        blurView.frame = bounds
        // Keep the outline on the current bounds in the
        // current state; state CHANGES morph it through
        // animateOutline instead of snapping it here.
        shapeMask.frame = bounds
        rimLayer.frame = bounds
        if shapeMask.animation(forKey: "outlineMorph") == nil {
            let outline = outlinePath(flare: isFloating ? 0 : 1)
            shapeMask.path = outline
            rimLayer.path = outline
            layer.shadowPath = outline
        }
        tintView.frame = bounds
        // The segments keep the old orb glyph's proportions
        // (device feedback, Ann 2026-11-25: the first cut —
        // 38pt span, 8pt gap, 5pt wide — read as two unrelated
        // dashes, not as the glyph). The glyph spanned 0.375
        // of the orb's height, its cells took 0.44 of that
        // span each with a 0.12 gap between them; squashed, a
        // cell keeps its height and shrinks to a slim
        // 3.5pt-wide segment (scaled with the dock size),
        // ends fully rounded.
        let glyphSpan = bounds.height * 0.375
        let cellHeight = glyphSpan * 0.44
        let cellGap = glyphSpan * 0.12
        let segmentWidth = min(max(3.5 * bounds.height / 90, 2.5), 5)
        gripView.frame = CGRect(x: (bounds.width - segmentWidth) / 2, y: (bounds.height - glyphSpan) / 2, width: segmentWidth, height: glyphSpan)
        gripTopSegment.frame = CGRect(x: 0, y: 0, width: segmentWidth, height: cellHeight)
        gripBottomSegment.frame = CGRect(x: 0, y: cellHeight + cellGap, width: segmentWidth, height: cellHeight)
        gripTopSegment.layer.cornerRadius = segmentWidth / 2
        gripBottomSegment.layer.cornerRadius = segmentWidth / 2
    }

    func fadeIn() {
        applyGripStyle()
        // A fresh appearance is docked by definition: never
        // come back wearing the floating corners.
        isFloating = false
        shapeMask.removeAnimation(forKey: "outlineMorph")
        rimLayer.removeAnimation(forKey: "outlineMorph")
        layer.removeAnimation(forKey: "outlineMorph")
        setNeedsLayout()
        alpha = 0
        UIView.animate(withDuration: 0.25) { self.alpha = 0.85 }
        restartIdleTimer()
    }

    /// The grip is a breathing light (Ann 2026-11-25): the
    /// shared breathing-light color, on the same
    /// layer-committed CABasicAnimation Weizhu's orb line
    /// uses. Re-read every time the handle appears, so a
    /// color picked in Settings applies the next time the
    /// dock hides.
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
        // down to 0.45 — opacity +10 over the old 3s / 0.35.
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

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        // The tick fires only when a jump actually happened
        // (no previous app, no tick).
        if onLongPress?() == true {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// The pan moves the handle freely (Ann 2026-11-25,
    /// later): with the inward pull gone, the handle follows
    /// the finger in every direction, inside the same
    /// vertical bounds the dock itself is clamped to — where
    /// it can be dragged is exactly where it can land, so the
    /// sync after the drop never shifts it. On release it
    /// snaps magnetically to the nearest screen edge, and
    /// only the landed snap is reported.
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: superview)
        switch gesture.state {
        case .began:
            dragStartCenter = center
            dragMode = 0
        case .changed:
            if dragMode == 0, hypot(translation.x, translation.y) > 8 {
                dragMode = 2
                isFloating = true
                // Leaving the edge: the root flares melt
                // back into the pill.
                animateOutline(toDocked: false, duration: 0.2)
            }
            if dragMode == 2, let superview {
                let margin = dragVerticalMargin
                // The clamp is on the BODY: the frame's
                // center is the body's center, but the frame
                // is taller than the body by the two flare
                // spaces at its ends.
                let bodyHeight = bounds.height - 2 * flareLength
                let minY = superview.safeAreaInsets.top + margin + bodyHeight / 2
                let maxY = superview.bounds.height - superview.safeAreaInsets.bottom - margin - bodyHeight / 2
                center = CGPoint(
                    x: min(max(dragStartCenter.x + translation.x, bounds.width / 2), superview.bounds.width - bounds.width / 2),
                    y: min(max(dragStartCenter.y + translation.y, minY), maxY)
                )
            }
        case .ended, .cancelled, .failed:
            if dragMode == 2 {
                snapToNearestEdge(gesture)
            }
            restartIdleTimer()
        default:
            break
        }
    }

    /// The magnetic snap (Ann 2026-11-25: clean and crisp,
    /// Weizhu's orb snap as the reference — its 0.34s and
    /// release-velocity feed, damping taken firmer than its
    /// 0.78): the handle flies to its edge and the hidden
    /// dock is planted there only once it has landed.
    private func snapToNearestEdge(_ gesture: UIPanGestureRecognizer) {
        guard let superview else { isFloating = false; return }
        let toRight = center.x > superview.bounds.width / 2
        isOnRightSide = toRight
        // The flares grow as the handle flies home: the
        // outline morph runs the same 0.34s as the snap, so
        // the roots reach the wall exactly when the handle
        // lands (Ann 2026-11-26: the corners appear WITH
        // the animation, grown out of the pill itself).
        animateOutline(toDocked: true, duration: 0.34)
        let targetX = toRight ? superview.bounds.width - bounds.width / 2 : bounds.width / 2
        let distance = targetX - center.x
        let velocityX = gesture.velocity(in: superview).x
        let springVelocity = distance != 0 ? min(max(velocityX / distance, -3), 3) : 0
        UIView.animate(withDuration: 0.34, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: springVelocity, options: [.beginFromCurrentState, .curveEaseOut]) {
            self.center.x = targetX
        } completion: { finished in
            // A new drag interrupting the snap owns the
            // handle now; only a landed snap reports.
            guard finished else { return }
            // Landed: flush against the edge; report.
            self.isFloating = false
            self.onMoveEnd?(self.center.y, toRight)
        }
    }
}
