//
//  LCAppGridView.swift
//  LiveContainerSwiftUI
//
//  Native grid layout for the app list. It renders the very same app models,
//  in the very same order, as the banner list in LCAppListView — only the
//  arrangement differs. All actions are delegated back to LCAppListView via
//  LCAppGridActions so both layouts share one implementation.
//

import SwiftUI
import UIKit

struct LCAppGridActions {
    // The rect is the tapped cell icon's frame in window coordinates:
    // a running app's window grows out of it (iOS-style entrance).
    let onLaunch: (LCAppModel, CGRect?) -> Void
    let onLaunchMultitaskToggle: (LCAppModel) -> Void
    let onOpenSettings: (LCAppModel) -> Void
    let onOpenDataFolder: (LCAppModel) -> Void
    let onCopyLaunchUrl: (LCAppModel) -> Void
    let onSaveIcon: (LCAppModel) async -> Void
    let onCreateAppClip: (LCAppModel) async -> Void
    let onUninstall: (LCAppModel, Bool) async -> Void
    let onError: (String) -> Void
    let isRunning: (LCAppModel) -> Bool
    let onCloseRunning: (LCAppModel) -> Void
}

struct LCAppGridView: View {
    let apps: [LCAppModel]
    let columns: Int
    let iconSize: Int
    let darkModeIcon: Bool
    let actions: LCAppGridActions

    @State private var uninstallTarget: LCAppModel?
    @State private var deleteDataTarget: LCAppModel?

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: columns)
    }

    private var iconScale: CGFloat {
        switch iconSize {
        case 1: return 0.85
        case 2: return 0.7
        default: return 1.0
        }
    }

    /// The app list is full-width with .padding() (16pt) around the collection
    /// and 16pt inter-column spacing, so the cell width can be derived from
    /// the screen width without a GeometryReader (which misbehaves in grids).
    private var cellIconSize: CGFloat {
        let screenWidth = UIScreen.main.bounds.width
        let cellWidth = (screenWidth - 32 - CGFloat(columns - 1) * 16) / CGFloat(columns)
        return max(min(cellWidth * iconScale, cellWidth), 44)
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: 12) {
            ForEach(apps, id: \.self) { app in
                LCAppGridCell(
                    app: app,
                    iconSize: cellIconSize,
                    darkModeIcon: darkModeIcon,
                    actions: actions,
                    onUninstall: { uninstallTarget = app }
                )
            }
        }
        .confirmationDialog(
            "lc.appBanner.confirmUninstallTitle".loc,
            isPresented: Binding(
                get: { uninstallTarget != nil },
                set: { if !$0 { uninstallTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: uninstallTarget
        ) { app in
            Button("lc.appBanner.uninstall".loc, role: .destructive) {
                uninstallTarget = nil
                if app.appInfo.containers.isEmpty {
                    Task { await actions.onUninstall(app, false) }
                } else {
                    deleteDataTarget = app
                }
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                uninstallTarget = nil
            }
        } message: { app in
            Text("lc.appBanner.confirmUninstallMsg %@".localizeWithFormat(app.displayName))
        }
        .confirmationDialog(
            "lc.appBanner.deleteDataTitle".loc,
            isPresented: Binding(
                get: { deleteDataTarget != nil },
                set: { if !$0 { deleteDataTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteDataTarget
        ) { app in
            Button("lc.common.delete".loc, role: .destructive) {
                deleteDataTarget = nil
                Task { await actions.onUninstall(app, true) }
            }
            Button("lc.common.no".loc) {
                deleteDataTarget = nil
                Task { await actions.onUninstall(app, false) }
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                deleteDataTarget = nil
            }
        } message: { app in
            Text("lc.appBanner.deleteDataMsg %@".localizeWithFormat(app.displayName))
        }
    }
}

/// The grid cell's icon as ONE UIKit view (Ann 2026-11-25,
/// approved after three SwiftUI arrangements failed): the icon,
/// the status ribbon and the running close badge all live inside
/// this single view, and a UIContextMenuInteraction on it provides
/// the long-press menu. That is what finally lets the badge and
/// the menu coexist — the badge is a real UIButton (its taps
/// always land), the menu's targeted preview snapshots this whole
/// view (badge included, nothing clipped by the platter, nothing
/// left floating at the cell's old spot), and tap / double-tap /
/// long-press arbitration is UIKit's own, exactly like the home
/// screen. The SwiftUI attempts each broke one leg of that tripod:
/// a badge inside the menu's source view rendered but never fired
/// its tap, a badge outside it stayed behind during the lift, and
/// hiding it via the preview's lifecycle was unreliable.
///
/// The view is a quarter-badge wider and taller than the icon so
/// the badge (whose center sits a quarter of its diameter inside
/// the icon's top-right corner) fits fully inside its bounds; the
/// cell compensates the layout so the icon itself lands exactly
/// where it always did.
private final class LCGridIconHostView: UIView, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
    struct RibbonSpec: Equatable {
        var shared = false
        var jit = false
        var is32 = false
        var locked = false
        var visible: Bool { shared || jit || is32 || locked }
    }

    private let iconContainer = UIView()
    private let iconImageView = UIImageView()
    private let ribbonView = UIView()
    private var ribbonBackground: UIView?
    private let ribbonStack = UIStackView()
    private let badgeButton = UIButton(type: .custom)

    private var iconSize: CGFloat = 0
    private var showBadge = false
    private var ribbonSpec = RibbonSpec()
    private var lastIcon: UIImage?
    private var isPressed = false
    private var isLaunching = false
    private var inMenu = false
    private var clearWorkItem: DispatchWorkItem?

    private var onLaunch: ((CGRect?) -> Void)?
    private var onOpenSettings: (() -> Void)?
    private var onClose: (() -> Void)?
    private var menuProvider: (() -> UIMenu)?

    private var badgeSize: CGFloat { min(max(iconSize * 0.4, 18), 34) }
    private var overhang: CGFloat { badgeSize * 0.25 }
    private var ribbonHeight: CGFloat { iconSize * 0.28 }
    private var ribbonGlyphSize: CGFloat { iconSize * 0.16 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        iconImageView.contentMode = .scaleAspectFit
        iconImageView.isUserInteractionEnabled = false
        iconContainer.clipsToBounds = true
        iconContainer.addSubview(iconImageView)

        ribbonView.clipsToBounds = true
        ribbonView.isUserInteractionEnabled = false
        ribbonStack.axis = .horizontal
        ribbonStack.alignment = .center
        ribbonView.addSubview(ribbonStack)
        iconContainer.addSubview(ribbonView)
        addSubview(iconContainer)

        badgeButton.backgroundColor = .red
        badgeButton.tintColor = .white
        badgeButton.layer.shadowColor = UIColor.black.withAlphaComponent(0.25).cgColor
        badgeButton.layer.shadowRadius = 2
        badgeButton.layer.shadowOffset = CGSize(width: 0, height: 1)
        badgeButton.layer.shadowOpacity = 1
        badgeButton.addTarget(self, action: #selector(handleBadgeTap), for: .touchUpInside)
        addSubview(badgeButton)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.delegate = self
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(icon: UIImage, iconSize: CGFloat, showBadge: Bool, ribbon: RibbonSpec,
                   isLaunching: Bool,
                   onLaunch: @escaping (CGRect?) -> Void,
                   onOpenSettings: @escaping () -> Void,
                   onClose: @escaping () -> Void,
                   menuProvider: @escaping () -> UIMenu) {
        self.onLaunch = onLaunch
        self.onOpenSettings = onOpenSettings
        self.onClose = onClose
        self.menuProvider = menuProvider
        self.isLaunching = isLaunching
        if self.iconSize != iconSize {
            self.iconSize = iconSize
            lastIcon = nil
            ribbonSpec = RibbonSpec()
        }
        if lastIcon !== icon {
            lastIcon = icon
            iconImageView.image = icon
        }
        if self.showBadge != showBadge {
            self.showBadge = showBadge
        }
        if ribbonSpec != ribbon {
            ribbonSpec = ribbon
            rebuildRibbon()
        }
        applyDim()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        iconContainer.frame = CGRect(x: 0, y: overhang, width: iconSize, height: iconSize)
        iconContainer.layer.cornerRadius = iconSize * 0.2667
        iconImageView.frame = iconContainer.bounds
        ribbonView.frame = CGRect(x: 0, y: iconSize - ribbonHeight, width: iconSize, height: ribbonHeight)
        ribbonView.isHidden = !ribbonSpec.visible
        // The glass is drawn 6pt taller than the band and the band
        // clips the overflow, so the glass's bright top rim lands
        // above the visible area (Ann 2026-11-24).
        ribbonBackground?.frame = CGRect(x: 0, y: -6, width: iconSize, height: ribbonHeight + 6)
        ribbonStack.spacing = iconSize * 0.07
        // The glyph row hugs its content and sits centered in the
        // band, like the SwiftUI HStack it replaces.
        let stackSize = ribbonStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        ribbonStack.frame = CGRect(x: (iconSize - stackSize.width) / 2,
                                   y: (ribbonHeight - stackSize.height) / 2,
                                   width: stackSize.width, height: stackSize.height)
        let badgeCenter = CGPoint(x: iconSize - overhang, y: overhang * 2)
        badgeButton.frame = CGRect(x: badgeCenter.x - badgeSize / 2, y: badgeCenter.y - badgeSize / 2,
                                   width: badgeSize, height: badgeSize)
        badgeButton.layer.cornerRadius = badgeSize / 2
        badgeButton.setImage(UIImage(systemName: "xmark",
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: badgeSize * 0.5, weight: .bold)),
                             for: .normal)
        badgeButton.isHidden = !showBadge
    }

    private func rebuildRibbon() {
        ribbonBackground?.removeFromSuperview()
        ribbonBackground = nil
        if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
            let effect = UIGlassEffect(style: .regular)
            effect.tintColor = UIColor.black.withAlphaComponent(0.3)
            let glass = UIVisualEffectView(effect: effect)
            ribbonView.insertSubview(glass, at: 0)
            ribbonBackground = glass
        } else {
            let band = UIView()
            band.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            ribbonView.insertSubview(band, at: 0)
            ribbonBackground = band
        }
        for subview in ribbonStack.arrangedSubviews {
            ribbonStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        func glyph(_ systemName: String) {
            let config = UIImage.SymbolConfiguration(pointSize: ribbonGlyphSize, weight: .bold)
            let imageView = UIImageView(image: UIImage(systemName: systemName, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal))
            imageView.contentMode = .center
            ribbonStack.addArrangedSubview(imageView)
        }
        // Banner order: shared, JIT, 32, lock ("32" replaces the
        // bolt for 32-bit apps — the two never show together).
        if ribbonSpec.shared { glyph("arrowshape.turn.up.left.fill") }
        if ribbonSpec.jit { glyph("bolt.fill") }
        if ribbonSpec.is32 {
            let label = UILabel()
            label.text = "32"
            label.font = .systemFont(ofSize: ribbonGlyphSize * 0.92, weight: .bold)
            label.textColor = .white
            ribbonStack.addArrangedSubview(label)
        }
        if ribbonSpec.locked { glyph("lock.fill") }
        setNeedsLayout()
    }

    // MARK: Press feedback (mirrors the banner's and the home
    // screen's: the icon just dims to 0.7, no shrink, and stays
    // dimmed for the whole launch).

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        clearWorkItem?.cancel()
        clearWorkItem = nil
        setPressed(true)
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // The single tap only fires once the double tap has failed
        // (~0.3s after the finger lifts), and only then does the
        // launch state take over the dimming. Hold the press dim
        // for that disambiguation window so a quick tap flows
        // straight from press dim into launch dim with no gap.
        let work = DispatchWorkItem { [weak self] in self?.setPressed(false) }
        clearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A scroll or the context menu taking over cancels the
        // touch: clear immediately, no linger.
        clearWorkItem?.cancel()
        clearWorkItem = nil
        setPressed(false)
        super.touchesCancelled(touches, with: event)
    }

    private func setPressed(_ pressed: Bool) {
        isPressed = pressed
        applyDim()
    }

    private func applyDim() {
        let dim: CGFloat = (isPressed || isLaunching) && !inMenu ? 0.7 : 1
        iconContainer.alpha = dim
        badgeButton.alpha = dim
    }

    // MARK: Taps

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Taps that land on the close badge belong to the badge
        // alone: no launch, no settings, whatever the tap count.
        if showBadge, badgeButton.frame.contains(touch.location(in: self)) {
            return false
        }
        return true
    }

    @objc private func handleSingleTap() {
        // The tapped icon's frame in window coordinates: a running
        // app's window grows out of it (iOS-style entrance).
        let rect = iconContainer.convert(iconContainer.bounds, to: nil)
        onLaunch?(rect)
    }

    @objc private func handleDoubleTap() {
        onOpenSettings?()
    }

    @objc private func handleBadgeTap() {
        onClose?()
    }

    // MARK: Context menu

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menuProvider?()
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        // The lift shows this view undimmed even if it was pressed
        // (or mid-launch) when the hold began.
        inMenu = true
        applyDim()
        return targetedPreview()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        targetedPreview()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                willEndFor configuration: UIContextMenuConfiguration,
                                animator: UIContextMenuInteractionAnimating?) {
        inMenu = false
        applyDim()
    }

    private func targetedPreview() -> UITargetedPreview {
        // The visible shape is the icon's rounded rect plus the
        // badge's circle — exactly what is on screen, so the
        // platter has nothing extra to show or clip.
        let params = UIPreviewParameters()
        let path = UIBezierPath(roundedRect: iconContainer.frame, cornerRadius: iconSize * 0.2667)
        if showBadge {
            path.append(UIBezierPath(ovalIn: badgeButton.frame))
        }
        params.visiblePath = path
        params.backgroundColor = .clear
        return UITargetedPreview(view: self, parameters: params)
    }
}

/// SwiftUI wrapper for LCGridIconHostView; also builds the
/// long-press menu as a UIMenu with the same items, in the same
/// order, as the banner's context menu.
private struct LCGridIconHost: UIViewRepresentable {
    let app: LCAppModel
    let iconSize: CGFloat
    let darkModeIcon: Bool
    let isRunning: Bool
    let actions: LCAppGridActions
    let onUninstall: () -> Void

    func makeUIView(context: Context) -> LCGridIconHostView {
        let view = LCGridIconHostView()
        configure(view)
        return view
    }

    func updateUIView(_ uiView: LCGridIconHostView, context: Context) {
        configure(uiView)
    }

    private func configure(_ view: LCGridIconHostView) {
        view.configure(
            icon: app.appInfo.iconIsDarkIcon(darkModeIcon),
            iconSize: iconSize,
            showBadge: isRunning,
            ribbon: .init(shared: app.uiIsShared,
                          jit: app.uiIsJITNeeded && !app.uiIs32bit,
                          is32: app.uiIs32bit,
                          locked: app.uiIsLocked && !app.uiIsHidden),
            isLaunching: app.isAppRunning,
            onLaunch: { rect in actions.onLaunch(app, rect) },
            onOpenSettings: { actions.onOpenSettings(app) },
            onClose: { actions.onCloseRunning(app) },
            menuProvider: { Self.buildMenu(app: app, actions: actions, onUninstall: onUninstall) }
        )
    }

    private static func buildMenu(app: LCAppModel, actions: LCAppGridActions, onUninstall: @escaping () -> Void) -> UIMenu {
        var rest: [UIMenuElement] = []
        if !app.uiIsShared, app.uiSelectedContainer != nil {
            rest.append(UIAction(title: "lc.appBanner.openDataFolder".loc,
                                 image: UIImage(systemName: "folder")) { _ in
                actions.onOpenDataFolder(app)
            })
        }
        if #available(iOS 16.0, *) {
            rest.append(UIAction(
                title: app.shouldLaunchInMultitaskMode ? "lc.appBanner.run".loc : "lc.appBanner.multitask".loc,
                image: UIImage(systemName: app.shouldLaunchInMultitaskMode ? "play.fill" : "macwindow.badge.plus")
            ) { _ in
                actions.onLaunchMultitaskToggle(app)
            })
        }
        rest.append(UIMenu(title: "lc.appBanner.addToHomeScreen".loc,
                           image: UIImage(systemName: "plus.app"),
                           children: [
                            UIAction(title: "lc.appBanner.copyLaunchUrl".loc,
                                     image: UIImage(systemName: "link")) { _ in
                                actions.onCopyLaunchUrl(app)
                            },
                            UIAction(title: "lc.appBanner.saveAppIcon".loc,
                                     image: UIImage(systemName: "square.and.arrow.down")) { _ in
                                Task { await actions.onSaveIcon(app) }
                            },
                            UIAction(title: "lc.appBanner.createAppClip".loc,
                                     image: UIImage(systemName: "appclip")) { _ in
                                Task { await actions.onCreateAppClip(app) }
                            },
                           ]))
        rest.append(UIAction(title: "lc.tabView.settings".loc,
                             image: UIImage(systemName: "gear")) { _ in
            actions.onOpenSettings(app)
        })
        if !app.uiIsShared {
            rest.append(UIAction(title: "lc.appBanner.uninstall".loc,
                                 image: UIImage(systemName: "trash"),
                                 attributes: .destructive) { _ in
                onUninstall()
            })
        }
        if app.uiContainers.count > 1 {
            let containers = UIMenu(title: "Containers", children: app.uiContainers.map { container in
                UIAction(title: container.name,
                         state: container == app.uiSelectedContainer ? .on : .off) { _ in
                    app.uiSelectedContainer = container
                }
            })
            // An inline group renders with separators around it —
            // the UIMenu form of the SwiftUI menu's Divider below
            // the Containers submenu.
            return UIMenu(children: [containers, UIMenu(title: "", options: .displayInline, children: rest)])
        }
        return UIMenu(children: rest)
    }
}

private struct LCAppGridCell: View {
    @ObservedObject var app: LCAppModel
    let iconSize: CGFloat
    let darkModeIcon: Bool
    let actions: LCAppGridActions
    let onUninstall: () -> Void

    // Close-badge diameter, scaled with the icon (0.4x, clamped).
    private var badgeSize: CGFloat {
        min(max(iconSize * 0.4, 18), 34)
    }
    // The UIKit icon host is a quarter-badge larger than the icon
    // on the top and right so the badge fits inside it; the offset
    // below puts the icon itself back on the exact spot it occupied
    // before the host existed, and the reduced spacing keeps the
    // icon-to-name gap at its old 6pt.
    private var hostSize: CGFloat { iconSize + badgeSize * 0.25 }

    var body: some View {
        VStack(spacing: 6 - badgeSize * 0.125) {
            LCGridIconHost(app: app,
                           iconSize: iconSize,
                           darkModeIcon: darkModeIcon,
                           isRunning: actions.isRunning(app),
                           actions: actions,
                           onUninstall: onUninstall)
                .frame(width: hostSize, height: hostSize)
                .offset(x: badgeSize * 0.125, y: -badgeSize * 0.125)

            Text(app.displayName)
                .font(.footnote)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }
}

struct LCAppGridSkeletonCell: View {
    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.gray.opacity(0.3))
                .aspectRatio(1, contentMode: .fit)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.3))
                .frame(height: 12)
                .padding(.horizontal, 8)
        }
    }
}

// MARK: - Grid settings

struct LCAppGridSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("LCAppGridColumns", store: LCUtils.appGroupUserDefault) private var gridColumns = 5
    @AppStorage("LCAppGridIconSize", store: LCUtils.appGroupUserDefault) private var gridIconSize = 0

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("lc.appGrid.columns".loc, selection: $gridColumns) {
                        Text("3").tag(3)
                        Text("4").tag(4)
                        Text("5").tag(5)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("lc.appGrid.columns".loc)
                }

                Section {
                    Picker("lc.appGrid.iconSize".loc, selection: $gridIconSize) {
                        Text("lc.appGrid.iconSize.large".loc).tag(0)
                        Text("lc.appGrid.iconSize.medium".loc).tag(1)
                        Text("lc.appGrid.iconSize.small".loc).tag(2)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("lc.appGrid.iconSize".loc)
                }
            }
            .navigationTitle("lc.appList.gridSettings".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("lc.common.done".loc) {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Icon export helper

/// Presents a document picker to export a generated app icon, mirroring what
/// the banner view controller does for "Save App Icon".
final class LCIconExportHelper: NSObject, UIDocumentPickerDelegate {
    private static let shared = LCIconExportHelper()
    private var temporaryDirectory: URL?

    static func exportPNG(imageData: Data, fileName: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(fileName)
        try imageData.write(to: fileURL, options: .atomic)
        shared.temporaryDirectory = directory

        DispatchQueue.main.async {
            guard let presenter = Self.topViewController(), presenter.presentedViewController == nil else {
                shared.cleanup()
                return
            }
            let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
            picker.delegate = shared
            presenter.present(picker, animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        var controller = keyWindow?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    private func cleanup() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        cleanup()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cleanup()
    }
}
