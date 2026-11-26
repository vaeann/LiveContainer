//
//  LCDownloadsView.swift
//  LiveContainerSwiftUI
//
//  The downloads library page — third segment of the sources
//  page (Ann 2026-11-24). Every package LiveContainer downloads
//  or imports is kept here: tap a finished package to install
//  it again (any kept version — old versions are never
//  overwritten), swipe or long-press to share/delete it, and
//  tap an interrupted download to resume it.
//
//  This segment rides the shared segment shell
//  (LCSegmentShell) — the picker as first row, so all
//  three segments share one geometry by construction
//  (until the 2026-11-26 stage-3 refactor this segment
//  was a List while the others were scroll views, which
//  put its picker lower and narrower than theirs).
//  Swipe-to-delete is LCSwipeToDeleteRow (List-only
//  .swipeActions does not exist on a scroll view). Each
//  package is a card in the sources segment's card
//  style — same tint recipe, 56pt icon, install capsule
//  — minus the source-badge and intro lines a kept
//  package does not have (Ann 2026-11-26); the info
//  line keeps its version · size · date format. Tapping
//  install asks first ("Install X?" — Ann 2026-11-26).
//  No search bar here: Ann removed the updates
//  and downloads bars on 2026-11-26 — little in those
//  lists worth searching; only the sources segment
//  searches.
//

import SwiftUI

/// File scope, not a static property of the view: static
/// stored properties are not supported in generic types,
/// and LCDownloadsView is generic over its picker row.
private let lcDownloadsDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
}()

struct LCDownloadsView<SegmentPicker: View>: View {
    private let segmentPicker: SegmentPicker

    @ObservedObject private var store = LCDownloadStore.shared
    @EnvironmentObject private var sharedModel: SharedModel
    @EnvironmentObject private var downloadHelper: DownloadHelper
    @AppStorage("dynamicColors") private var dynamicColors = true
    @Environment(\.colorScheme) private var colorScheme
    @State private var showClearAllConfirm = false
    @State private var packageToShare: LCDownloadedPackage?
    /// The package whose install is waiting on the
    /// confirmation alert (Ann 2026-11-26).
    @State private var packageToInstall: LCDownloadedPackage?
    @State private var showInstallConfirm = false
    /// The package whose deletion is waiting on its
    /// confirmation alert — deleting asks too (Ann
    /// 2026-11-26, right after the install confirm).
    @State private var packageToDelete: LCDownloadedPackage?
    @State private var showDeleteConfirm = false
    /// The one row whose delete action is currently
    /// revealed; opening one row closes the others.
    @State private var openRowID: LCDownloadedPackage.ID?

    init(@ViewBuilder segmentPicker: () -> SegmentPicker) {
        self.segmentPicker = segmentPicker()
    }

    var body: some View {
        LCSegmentShell {
            segmentPicker
        } content: {
            if store.packages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("lc.downloads.empty".loc)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .padding(.top, 48)
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                VStack(spacing: 8) {
                    HStack {
                        Text("lc.downloads.totalSize %@".localizeWithFormat(Self.formatSize(store.totalSize)))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("lc.downloads.clearAll".loc) {
                            showClearAllConfirm = true
                        }
                        .foregroundStyle(.red)
                    }
                    .font(.footnote)
                    .padding(.horizontal)

                    // One card per package, in the
                    // sources segment's card style.
                    VStack(spacing: 12) {
                        ForEach(store.packages) { record in
                            LCSwipeToDeleteRow(rowID: record.id, openRowID: $openRowID, onDelete: {
                                requestDelete(record)
                            }) {
                                card(for: record)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .alert("lc.downloads.confirmInstall %@".localizeWithFormat(packageToInstall?.appName ?? ""), isPresented: $showInstallConfirm) {
            Button("lc.common.yes".loc) {
                if let record = packageToInstall {
                    performInstall(record)
                }
                packageToInstall = nil
            }
            Button("lc.common.no".loc, role: .cancel) {
                packageToInstall = nil
            }
        }
        .alert("lc.downloads.confirmDelete %@".localizeWithFormat(packageToDelete?.appName ?? ""), isPresented: $showDeleteConfirm) {
            Button("lc.common.yes".loc) {
                if let record = packageToDelete {
                    store.remove(record)
                }
                packageToDelete = nil
            }
            Button("lc.common.no".loc, role: .cancel) {
                packageToDelete = nil
            }
        }
        .alert("lc.downloads.clearAll".loc, isPresented: $showClearAllConfirm) {
            Button("lc.common.cancel".loc, role: .cancel) { }
            Button("lc.downloads.clearAll".loc, role: .destructive) {
                store.removeAll()
            }
        } message: {
            Text("lc.downloads.clearAllMessage".loc)
        }
        .sheet(item: $packageToShare) { record in
            ActivityViewController(activityItems: [store.fileURL(for: record)])
        }
    }

    // MARK: - Cards

    /// Every install entry point (card tap, Install
    /// button, context menu) asks first (Ann 2026-11-26).
    private func requestInstall(_ record: LCDownloadedPackage) {
        packageToInstall = record
        showInstallConfirm = true
    }

    private func performInstall(_ record: LCDownloadedPackage) {
        NotificationCenter.default.post(name: NSNotification.InstallLocalFileNotification, object: store.fileURL(for: record))
    }

    /// Deleting a kept package asks first too (Ann
    /// 2026-11-26): swipe, full swipe and the context
    /// menu all land here; "Clear all" already had its
    /// own confirmation.
    private func requestDelete(_ record: LCDownloadedPackage) {
        packageToDelete = record
        showDeleteConfirm = true
    }

    /// The sources cards' tint recipe, keyed by bundle id
    /// (name when a package somehow has none).
    private func cardTint(for record: LCDownloadedPackage) -> Color {
        lcCardColor(forKey: record.bundleID ?? record.appName)
    }

    private func cardTextColor(for record: LCDownloadedPackage) -> Color {
        _ = colorScheme == .dark // trigger refresh
        let color = dynamicColors ? cardTint(for: record) : Color("FontColor")
        return color.readableTextColor()
    }

    @ViewBuilder
    private func card(for record: LCDownloadedPackage) -> some View {
        // The sources segment's card, minus the badge and
        // intro lines (Ann 2026-11-26): 56pt icon, name,
        // the info line in its existing version · size ·
        // date format, and the install capsule. Not a
        // row-wide Button: the capsule consumes its own
        // taps; the card body acts via a tap gesture.
        let tint = cardTint(for: record)
        let textColor = cardTextColor(for: record)
        HStack(spacing: 12) {
            iconView(for: record)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 56 * 0.2))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.appName)
                    .font(.system(size: 15)).bold()
                    .foregroundColor(textColor)
                    .lineLimit(1)
                Text(detailText(for: record))
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                if !record.isComplete && record.totalBytes > 0 {
                    ProgressView(value: Double(record.downloadedBytes), total: Double(record.totalBytes))
                        .progressViewStyle(.linear)
                        .tint(textColor)
                }
            }
            Spacer()
            if record.isComplete {
                Button {
                    requestInstall(record)
                } label: {
                    Text("lc.downloads.install".loc)
                        .bold()
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(Capsule().fill(dynamicColors ? tint : Color("FontColor")))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    downloadHelper.resumeDownload(record: record)
                } label: {
                    Text("lc.downloads.resume".loc)
                        .bold()
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(Capsule().fill(dynamicColors ? tint : Color("FontColor")))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerSize: CGSize(width: 22, height: 22))
                .fill(dynamicColors ? tint.opacity(0.5) : Color("AppBannerBG"))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if record.isComplete {
                requestInstall(record)
            } else {
                downloadHelper.resumeDownload(record: record)
            }
        }
        .contextMenu {
            if record.isComplete {
                Button("lc.downloads.install".loc) {
                    requestInstall(record)
                }
                Button("lc.downloads.share".loc) {
                    packageToShare = record
                }
            } else {
                Button("lc.downloads.resume".loc) {
                    downloadHelper.resumeDownload(record: record)
                }
            }
            Button("lc.downloads.delete".loc, role: .destructive) {
                requestDelete(record)
            }
        }
    }

    @ViewBuilder
    private func iconView(for record: LCDownloadedPackage) -> some View {
        if let iconFile = store.iconURL(for: record),
           let image = UIImage(contentsOfFile: iconFile.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if let bundleID = record.bundleID,
                  let app = (sharedModel.apps + sharedModel.hiddenApps).first(where: { $0.appInfo.bundleIdentifier() == bundleID }) {
            Image(uiImage: app.appInfo.iconIsDarkIcon(false) ?? UIImage())
                .resizable()
                .scaledToFill()
        } else if let iconURLString = record.iconURL, let url = URL(string: iconURLString) {
            SourceIconView(url: url)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(UIColor.tertiarySystemFill))
                Image(systemName: "app")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detailText(for record: LCDownloadedPackage) -> String {
        if record.isComplete {
            var parts: [String] = []
            if let version = record.version, !version.isEmpty {
                parts.append("v\(version)")
            }
            parts.append(Self.formatSize(record.size))
            parts.append(lcDownloadsDateFormatter.string(from: record.savedAt))
            return parts.joined(separator: " · ")
        }
        if record.totalBytes > 0 {
            return "lc.downloads.progressOfTotal %@ %@".localizeWithFormat(Self.formatSize(record.downloadedBytes), Self.formatSize(record.totalBytes))
        }
        return "lc.downloads.incomplete".loc
    }

    // MARK: - Formatting

    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A downloads row that reveals a destructive delete
/// button on a left swipe — the scroll-view stand-in for
/// List's .swipeActions (stage-3 refactor, Ann approved
/// the plan 2026-11-26). The drag claims the row only
/// when it is clearly horizontal (width past 1.5× the
/// height), so vertical scrolling keeps the row; past
/// the button's width the row stays open, a hard swipe
/// (180pt) deletes outright like a full swipe in a List,
/// and tapping an open row closes it instead of acting.
private struct LCSwipeToDeleteRow<Content: View>: View {
    let rowID: LCDownloadedPackage.ID
    @Binding var openRowID: LCDownloadedPackage.ID?
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var dragOffset: CGFloat = 0
    @State private var dragIsHorizontal: Bool?
    /// Offset the current drag started from (0 or
    /// -actionWidth), captured when the drag is claimed:
    /// openRowID — and with it isOpen — only settles when
    /// the drag ends, so the live offset must be computed
    /// from this, not from isOpen.
    @State private var dragBase: CGFloat = 0

    private let actionWidth: CGFloat = 78

    private var isOpen: Bool {
        openRowID == rowID
    }

    private var displayOffset: CGFloat {
        if dragIsHorizontal == true {
            return dragBase + dragOffset
        }
        return isOpen ? -actionWidth : 0
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(.white)
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
            }
            .background(Color.red)

            ZStack {
                content()
                if isOpen {
                    // An open row's next tap closes it; it
                    // must not fall through to the row's own
                    // install / resume action.
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                }
            }
            // Opaque, and it slides WITH the card: the
            // card's tint is a 50% wash — on the sources
            // page that blends with the page behind it, but
            // here the red delete button sits behind the
            // card and bled straight through until the
            // sliding layer carried the page's own color
            // (Ann 2026-11-26, on device).
            .background(Color(uiColor: UIColor.systemBackground))
            .offset(x: displayOffset)
            .gesture(rowDrag)
        }
        // The row clips to the card's own radius: at rest
        // the corners show the page through them, and
        // swiped open the red button's outer corners come
        // out rounded like the card's instead of square
        // (Ann 2026-11-26).
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            openRowID = nil
        }
    }

    private var rowDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if dragIsHorizontal == nil {
                    let w = abs(value.translation.width)
                    let h = abs(value.translation.height)
                    if w > h * 1.5 && w > 8 {
                        dragIsHorizontal = true
                        dragBase = isOpen ? -actionWidth : 0
                    } else if h > 12 {
                        dragIsHorizontal = false
                    }
                }
                guard dragIsHorizontal == true else { return }
                let total = dragBase + value.translation.width
                dragOffset = min(max(total, -actionWidth - 24), 0) - dragBase
            }
            .onEnded { value in
                defer { dragIsHorizontal = nil }
                guard dragIsHorizontal == true else { return }
                let total = dragBase + value.translation.width
                if value.translation.width < -180 {
                    onDelete()
                    return
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    dragOffset = 0
                    openRowID = total < -actionWidth / 2 ? rowID : nil
                }
            }
    }
}
