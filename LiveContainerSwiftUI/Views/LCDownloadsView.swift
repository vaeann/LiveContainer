//
//  LCDownloadsView.swift
//  LiveContainerSwiftUI
//
//  The downloads library page — third segment of the sources
//  page (Ann 2026-11-24). Every package LiveContainer downloads
//  or imports is kept here: a finished package installs again
//  from its button (any kept version — old versions are never
//  overwritten), swipe left to delete it or right to share
//  it, and an interrupted download resumes from its button.
//  The card body itself deliberately has no tap (Ann
//  2026-11-27): one less gesture arbitrating against the
//  row's swipe, and install-via-button is unambiguous.
//
//  This segment rides the shared segment shell
//  (LCSegmentShell) — the picker as first row, so all
//  three segments share one geometry by construction
//  (until the 2026-11-26 stage-3 refactor this segment
//  was a List while the others were scroll views, which
//  put its picker lower and narrower than theirs).
//  The swipe actions are LCSwipeActionsRow (List-only
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
    /// The one row whose swipe actions are currently
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
                VStack(spacing: 12) {
                    // Total size and clear-all, merged
                    // into one full-width capsule in the
                    // updates segment's update-all style
                    // (Ann 2026-11-26): the size rides in
                    // the button's label, and the tap still
                    // lands on the clear-all confirmation.
                    Button {
                        showClearAllConfirm = true
                    } label: {
                        Text("lc.downloads.clearAll".loc + " · " + "lc.downloads.totalSize %@".localizeWithFormat(Self.formatSize(store.totalSize)))
                            .bold()
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .modifier { content in
                                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                                    content
                                        .glassEffect(.regular.interactive(true), in: .capsule)
                                } else {
                                    content
                                        .foregroundColor(.white)
                                        .background(Capsule().fill(Color("FontColor")))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)

                    // One card per package, in the
                    // sources segment's card style.
                    VStack(spacing: 12) {
                        ForEach(store.packages) { record in
                            LCSwipeActionsRow(rowID: record.id, openRowID: $openRowID, canShare: record.isComplete, onShare: {
                                packageToShare = record
                            }, onDelete: {
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

    /// Installing asks first (Ann 2026-11-26).
    private func requestInstall(_ record: LCDownloadedPackage) {
        packageToInstall = record
        showInstallConfirm = true
    }

    private func performInstall(_ record: LCDownloadedPackage) {
        NotificationCenter.default.post(name: NSNotification.InstallLocalFileNotification, object: store.fileURL(for: record))
    }

    /// Deleting a kept package asks first too (Ann
    /// 2026-11-26): the swipe button and the full swipe
    /// both land here; "Clear all" already had its own
    /// confirmation.
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
        // date format, and the install capsule. Only the
        // capsule acts — the card body has no tap of its
        // own (Ann 2026-11-27).
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
        // No tap, no long-press menu on the card body
        // (Ann 2026-11-27): install / resume live on the
        // capsule alone, share and delete on the swipe —
        // and with no gesture of its own on the body, the
        // row's swipe has nothing left to arbitrate
        // against but the scroll view itself.
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

/// A downloads row with swipe actions on both sides —
/// the scroll-view stand-in for List's .swipeActions
/// (stage-3 refactor, Ann approved the plan 2026-11-26):
/// swipe left for delete, swipe right for share (Ann
/// 2026-11-27; share is only offered on complete
/// packages — a partial file has nothing to share). Both
/// buttons are the same liquid-glass circle, trash on
/// the right, share glyph on the left — no red block
/// (Ann 2026-11-27: the red rectangle is gone, and with
/// it the need to clip the row so the block's corners
/// looked round). The card's long-press menu went away
/// the same day: the swipes carry its actions now.
///
/// The drag claims the row only when it is clearly
/// horizontal (width past 1.5× the height), so vertical
/// scrolling keeps the row; the row only ever settles
/// open on a side or shut — nothing fires from the swipe
/// itself (Ann 2026-11-27: the hard-swipe full swipe
/// went, it was too easy to trigger by accident) — and
/// tapping an open row closes it instead of acting.
///
/// The sliding layer's offset is a single stored value
/// driven directly by the drag (Ann 2026-11-27: the old
/// computed offset — base + delta, re-derived from
/// isOpen whenever the drag state flipped — jumped when
/// the drag was claimed and snapped instead of springing
/// on release, so the card felt like it was not
/// following the finger). The drag now runs simultaneous
/// with the scroll view's pan, the translation at claim
/// time is subtracted so motion starts from zero, and
/// settling animates the same stored offset the finger
/// was driving.
private struct LCSwipeActionsRow<Content: View>: View {
    let rowID: LCDownloadedPackage.ID
    @Binding var openRowID: LCDownloadedPackage.ID?
    let canShare: Bool
    let onShare: () -> Void
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    /// The sliding layer's live x offset: 0 closed,
    /// +actionWidth open on the share side, -actionWidth
    /// on the delete side. The one source of truth, while
    /// dragging and while settled alike.
    @State private var offset: CGFloat = 0
    private enum DragIntent {
        case undecided, horizontal, vertical
    }
    @State private var dragIntent: DragIntent = .undecided
    /// Offset the current drag started from (0 or
    /// ±actionWidth — simply the settled offset, since
    /// the stored offset IS the settled position),
    /// captured when the drag is claimed.
    @State private var dragStartOffset: CGFloat = 0
    /// Finger travel at claim time: subtracted from the
    /// live translation so the card starts moving from
    /// exactly where it sits instead of jumping by the
    /// claim distance.
    @State private var dragClaimDelta: CGFloat = 0

    private let actionWidth: CGFloat = 78

    private var isOpen: Bool {
        openRowID == rowID
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if canShare {
                    actionButton(systemImage: "square.and.arrow.up", glyphColor: .primary) {
                        onShare()
                        close()
                    }
                }
                Spacer()
                actionButton(role: .destructive, systemImage: "trash", glyphColor: .red) {
                    onDelete()
                    // Reset on tap like the share button
                    // does (Ann 2026-11-27, on device: the
                    // row used to hang open behind the delete
                    // confirmation and only reset once the
                    // alert was answered — a leftover
                    // asymmetry, not a design). Confirming
                    // removes the row anyway; cancelling
                    // leaves it closed.
                    close()
                }
            }

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
            // here the action buttons sit behind the card
            // and bled straight through until the sliding
            // layer carried the page's own color
            // (Ann 2026-11-26, on device).
            .background(Color(uiColor: UIColor.systemBackground))
            .offset(x: offset)
            .simultaneousGesture(rowDrag)
        }
        .onChange(of: openRowID) { newValue in
            // Another row opened (or the open state was
            // cleared elsewhere): glide shut instead of
            // snapping.
            if newValue != rowID, offset != 0 {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    offset = 0
                }
            }
        }
    }

    /// One glass-circle action button, 54pt in a
    /// full-height 78pt cell — the same on both sides.
    private func actionButton(role: ButtonRole? = nil, systemImage: String, glyphColor: Color, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            ZStack {
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    Circle()
                        .fill(Color.clear)
                        .glassEffect(.regular.interactive(true), in: Circle())
                } else {
                    Circle()
                        .fill(Color(uiColor: UIColor.secondarySystemBackground))
                }
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(glyphColor)
            }
            .frame(width: 54, height: 54)
        }
        .buttonStyle(.plain)
        .frame(width: actionWidth)
        .frame(maxHeight: .infinity)
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            offset = 0
            openRowID = nil
        }
    }

    private var rowDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragIntent == .undecided {
                    let w = abs(value.translation.width)
                    let h = abs(value.translation.height)
                    if w > 6, w > h * 1.5 {
                        dragIntent = .horizontal
                        dragStartOffset = offset
                        dragClaimDelta = value.translation.width
                    } else if h > 6, h > w {
                        dragIntent = .vertical
                    }
                }
                guard dragIntent == .horizontal else { return }
                let traveled = dragStartOffset + value.translation.width - dragClaimDelta
                // The pull stops a short elastic tail past
                // the open position (Ann 2026-11-27): with
                // no full swipe out there to reach for, the
                // travel ends where the button is.
                offset = min(max(traveled, -actionWidth - 14), canShare ? actionWidth + 14 : 0)
            }
            .onEnded { value in
                defer { dragIntent = .undecided }
                guard dragIntent == .horizontal else { return }
                // Settle by where the finger was HEADED
                // (Ann 2026-11-27, shorter travel): the
                // drag's predicted end, run through the
                // same start-offset math and clamp as the
                // live offset. A slow drag predicts about
                // its own position — past half the button
                // stays open, as before. A quick flick
                // predicts well ahead of the finger, so a
                // short flick opens (or closes) the row
                // without travelling the whole distance.
                // The prediction may only reinforce the
                // side the row is already on — never pull
                // it across to the other side by itself.
                let predicted = min(max(dragStartOffset + value.predictedEndTranslation.width - dragClaimDelta, -actionWidth - 14), canShare ? actionWidth + 14 : 0)
                let decision: CGFloat
                if offset <= 0, predicted <= 0 {
                    decision = min(offset, predicted)
                } else if offset >= 0, predicted >= 0 {
                    decision = max(offset, predicted)
                } else {
                    decision = offset
                }
                let target: CGFloat
                if decision < -actionWidth / 2 {
                    target = -actionWidth
                } else if canShare, decision > actionWidth / 2 {
                    target = actionWidth
                } else {
                    target = 0
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    offset = target
                }
                openRowID = target != 0 ? rowID : nil
            }
    }
}
