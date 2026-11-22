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
    let onLaunch: (LCAppModel) -> Void
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

/// Transparent UIKit layer that reports raw touch-down / touch-up on the
/// grid icon, mirroring how LCAppBannerViewController tracks touches for
/// the list's press feedback. It installs no gesture recognizers and does
/// not override hit testing, so it never competes with the cell's taps,
/// context menu or the scroll view — it only observes the touches that
/// land on it and forwards them up the responder chain untouched.
private struct LCGridTouchObserver: UIViewRepresentable {
    @Binding var isPressed: Bool
    /// Side of the top-trailing corner square reserved for the close
    /// badge (0 when the badge is not shown); see LCGridTouchView.
    var badgeExclusion: CGFloat = 0

    func makeUIView(context: Context) -> LCGridTouchView {
        let view = LCGridTouchView()
        view.badgeExclusion = badgeExclusion
        view.onPressChange = { [self] pressed in
            if isPressed != pressed {
                isPressed = pressed
            }
        }
        return view
    }

    func updateUIView(_ uiView: LCGridTouchView, context: Context) {
        uiView.badgeExclusion = badgeExclusion
        uiView.onPressChange = { [self] pressed in
            if isPressed != pressed {
                isPressed = pressed
            }
        }
    }
}

private final class LCGridTouchView: UIView {
    var onPressChange: ((Bool) -> Void)?
    var badgeExclusion: CGFloat = 0
    private var clearWorkItem: DispatchWorkItem?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // This view is a real UIView spread over the whole icon, and
        // UIKit hit-tests it before the SwiftUI-drawn close badge that
        // overlaps the icon's top-trailing corner — the badge rendered
        // on top but its touches landed here and were forwarded up the
        // responder chain as ordinary cell touches. Carve the badge's
        // corner out so those touches reach the badge instead.
        if badgeExclusion > 0,
           point.x >= bounds.width - badgeExclusion, point.y <= badgeExclusion {
            return nil
        }
        return super.hitTest(point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        clearWorkItem?.cancel()
        clearWorkItem = nil
        onPressChange?(true)
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // The cell's single tap only fires once the double tap has
        // failed (~0.3s after the finger lifts), and only then does the
        // launch state take over the dimming. Hold the press dim for
        // that disambiguation window so a quick tap flows straight from
        // press dim into launch dim with no undimmed gap in between.
        let work = DispatchWorkItem { [weak self] in
            self?.onPressChange?(false)
        }
        clearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A scroll or the context menu taking over cancels the touch:
        // clear immediately, no linger.
        clearWorkItem?.cancel()
        clearWorkItem = nil
        onPressChange?(false)
        super.touchesCancelled(touches, with: event)
    }
}

private struct LCAppGridCell: View {
    @ObservedObject var app: LCAppModel
    let iconSize: CGFloat
    let darkModeIcon: Bool
    let actions: LCAppGridActions
    let onUninstall: () -> Void
    @State private var isPressed = false

    // Close-badge diameter, scaled with the icon (0.4x, clamped).
    private var badgeSize: CGFloat {
        min(max(iconSize * 0.4, 18), 34)
    }

    var body: some View {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    IconImageView(icon: app.appInfo.iconIsDarkIcon(darkModeIcon))
                        .frame(width: iconSize, height: iconSize)

                    // UIKit touch tracking for the press feedback — the
                    // same mechanism as the banner's touchesBegan/Ended,
                    // which works. The earlier simultaneous DragGesture
                    // observer never fired on device once the composed
                    // tap gesture and the context menu competed in the
                    // same cell. This transparent layer sits above the
                    // icon but below the badge and only observes: it has
                    // no gesture recognizers, so taps, double-taps, the
                    // context menu and scrolling all work as before, and
                    // a scroll cancels the touch (and the press) exactly
                    // like on the home screen. The badge's corner is
                    // carved out of its hit area (see LCGridTouchView):
                    // the close badge lives in the cell's overlay, and
                    // this UIKit layer would otherwise claim its touches.
                    LCGridTouchObserver(isPressed: $isPressed,
                                        badgeExclusion: actions.isRunning(app) ? badgeSize : 0)
                }
                .frame(width: iconSize, height: iconSize)
                // Feedback identical to the iOS home screen (and to
                // the list banner's icon): no shrink, no animation —
                // the icon just dims to 0.7 the moment it is pressed
                // and stays dimmed for the whole launch.
                .opacity(isPressed || app.isAppRunning ? 0.7 : 1)

                Text(app.displayName)
                    .font(.footnote)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)

                if hasBadges {
                    HStack(spacing: 3) {
                        if app.uiIsShared {
                            badge(systemName: "arrowshape.turn.up.left.fill", color: .orange)
                        }
                        if app.uiIsJITNeeded && !app.uiIs32bit {
                            badge(systemName: "bolt.fill", color: .purple)
                        }
                        if app.uiIs32bit {
                            Text("32")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.blue))
                        }
                        if app.uiIsLocked && !app.uiIsHidden {
                            badge(systemName: "lock.fill", color: .orange)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        // Single/double tap as ONE composed gesture: the double tap takes
        // priority and the single tap fires only when the double tap fails
        // (the SwiftUI equivalent of UIKit's require(toFail:)). Two
        // independent .onTapGesture modifiers have no such dependency, and
        // on device the taps never reached the actions once the context
        // menu's long-press competed in the same cell — this composed form
        // is what the zh fork's grid uses for the same banner behavior.
        .gesture(
            TapGesture(count: 2)
                .onEnded {
                    actions.onOpenSettings(app)
                }
                .exclusively(before: TapGesture(count: 1)
                    .onEnded {
                        actions.onLaunch(app)
                    })
        )
        .contextMenu {
            contextMenuItems
        }
        // The running close badge lives in an overlay, outside the
        // gesture-carrying cell — the same structure as the list, whose
        // badge overlays the banner and works. Inside the cell it
        // rendered but never fired: the cell's composed tap gesture
        // competes for the same touches, and the UIKit touch observer
        // over the icon claims them at the UIKit level first. The
        // spacer matches the icon's frame and the overlay is top-
        // centered like the icon, so top-trailing alignment plus the
        // quarter-diameter offset put the badge's center a quarter of
        // its diameter inside the icon's top-right corner, like the
        // iOS home screen's numeric badges.
        .overlay(alignment: .top) {
            if actions.isRunning(app) {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                        .allowsHitTesting(false)
                    LCRunningCloseBadge(size: badgeSize) {
                        actions.onCloseRunning(app)
                    }
                    .offset(x: badgeSize * 0.25, y: -badgeSize * 0.25)
                }
                .frame(width: iconSize, height: iconSize)
            }
        }
    }

    private var hasBadges: Bool {
        app.uiIsShared
            || (app.uiIsJITNeeded && !app.uiIs32bit)
            || app.uiIs32bit
            || (app.uiIsLocked && !app.uiIsHidden)
    }

    private func badge(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        // Same items, in the same order, as the banner's context menu.
        if app.uiContainers.count > 1 {
            Menu("Containers") {
                ForEach(app.uiContainers, id: \.self) { container in
                    Button {
                        app.uiSelectedContainer = container
                    } label: {
                        if container == app.uiSelectedContainer {
                            Label(container.name, systemImage: "checkmark")
                        } else {
                            Text(container.name)
                        }
                    }
                }
            }
            Divider()
        }

        if !app.uiIsShared, app.uiSelectedContainer != nil {
            Button {
                actions.onOpenDataFolder(app)
            } label: {
                Label("lc.appBanner.openDataFolder".loc, systemImage: "folder")
            }
        }

        if #available(iOS 16.0, *) {
            Button {
                actions.onLaunchMultitaskToggle(app)
            } label: {
                Label(
                    app.shouldLaunchInMultitaskMode ? "lc.appBanner.run".loc : "lc.appBanner.multitask".loc,
                    systemImage: app.shouldLaunchInMultitaskMode ? "play.fill" : "macwindow.badge.plus"
                )
            }
        }

        Menu {
            Button {
                actions.onCopyLaunchUrl(app)
            } label: {
                Label("lc.appBanner.copyLaunchUrl".loc, systemImage: "link")
            }
            Button {
                Task { await actions.onSaveIcon(app) }
            } label: {
                Label("lc.appBanner.saveAppIcon".loc, systemImage: "square.and.arrow.down")
            }
            Button {
                Task { await actions.onCreateAppClip(app) }
            } label: {
                Label("lc.appBanner.createAppClip".loc, systemImage: "appclip")
            }
        } label: {
            Label("lc.appBanner.addToHomeScreen".loc, systemImage: "plus.app")
        }

        Button {
            actions.onOpenSettings(app)
        } label: {
            Label("lc.tabView.settings".loc, systemImage: "gear")
        }

        if !app.uiIsShared {
            Button(role: .destructive) {
                onUninstall()
            } label: {
                Label("lc.appBanner.uninstall".loc, systemImage: "trash")
            }
        }
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
                        Text("6").tag(6)
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
