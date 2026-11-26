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
//  put its picker lower and narrower than theirs). The
//  List's inset-grouped card is reproduced by hand
//  below, and swipe-to-delete by LCSwipeToDeleteRow
//  (List-only .swipeActions does not exist on a scroll
//  view). No search bar here: Ann removed the updates
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
    @State private var showClearAllConfirm = false
    @State private var packageToShare: LCDownloadedPackage?
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

                    // The inset-grouped card, by hand: one
                    // rounded stack, dividers inset past the
                    // icons, rows sliding over it to delete.
                    VStack(spacing: 0) {
                        ForEach(store.packages) { record in
                            if record.id != store.packages.first?.id {
                                Divider()
                                    .padding(.leading, 68)
                            }
                            LCSwipeToDeleteRow(rowID: record.id, openRowID: $openRowID, onDelete: {
                                store.remove(record)
                            }) {
                                row(for: record)
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(uiColor: UIColor.secondarySystemBackground)))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal)
                }
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

    // MARK: - Rows

    @ViewBuilder
    private func row(for record: LCDownloadedPackage) -> some View {
        // Not a row-wide Button: the row carries its own explicit
        // install / resume button on the right (Ann 2026-11-24),
        // and a Button inside a Button label would not receive
        // its taps. The row body keeps the same tap action via a
        // tap gesture; the trailing button consumes its own taps.
        HStack(spacing: 12) {
            iconView(for: record)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.appName)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detailText(for: record))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !record.isComplete && record.totalBytes > 0 {
                    ProgressView(value: Double(record.downloadedBytes), total: Double(record.totalBytes))
                        .progressViewStyle(.linear)
                }
            }
            Spacer()
            if record.isComplete {
                Button("lc.downloads.install".loc) {
                    NotificationCenter.default.post(name: NSNotification.InstallLocalFileNotification, object: store.fileURL(for: record))
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
            } else {
                Button("lc.downloads.resume".loc) {
                    downloadHelper.resumeDownload(record: record)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            if record.isComplete {
                NotificationCenter.default.post(name: NSNotification.InstallLocalFileNotification, object: store.fileURL(for: record))
            } else {
                downloadHelper.resumeDownload(record: record)
            }
        }
        .contextMenu {
            if record.isComplete {
                Button("lc.downloads.install".loc) {
                    NotificationCenter.default.post(name: NSNotification.InstallLocalFileNotification, object: store.fileURL(for: record))
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
                store.remove(record)
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
            .background(Color(uiColor: UIColor.secondarySystemBackground))
            .offset(x: displayOffset)
            .gesture(rowDrag)
        }
        .clipped()
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
