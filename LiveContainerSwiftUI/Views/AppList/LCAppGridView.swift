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

private struct LCAppGridCell: View {
    @ObservedObject var app: LCAppModel
    let iconSize: CGFloat
    let darkModeIcon: Bool
    let actions: LCAppGridActions
    let onUninstall: () -> Void

    var body: some View {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    IconImageView(icon: app.appInfo.iconIsDarkIcon(darkModeIcon))
                        .frame(width: iconSize, height: iconSize)

                    if app.isSigningInProgress {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)
                            ProgressView(value: app.signProgress)
                                .progressViewStyle(.circular)
                        }
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.2667))
                    } else if app.isAppRunning {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.2667))
                    }

                    if actions.isRunning(app) {
                        // Badge diameter scales with the icon (0.4x, clamped).
                        // The ZStack aligns the badge's top-trailing corner
                        // with the icon's; shifting by half the badge size
                        // centers it exactly on the icon's top-right corner,
                        // treating the icon as a square.
                        let badgeSize = min(max(iconSize * 0.4, 18), 34)
                        LCRunningCloseBadge(size: badgeSize) {
                            actions.onCloseRunning(app)
                        }
                        .offset(x: badgeSize / 2, y: -badgeSize / 2)
                    }
                }
                .frame(width: iconSize, height: iconSize)

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
        .onTapGesture(count: 2) {
            actions.onOpenSettings(app)
        }
        .onTapGesture(count: 1) {
            actions.onLaunch(app)
        }
        .contextMenu {
            contextMenuItems
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
