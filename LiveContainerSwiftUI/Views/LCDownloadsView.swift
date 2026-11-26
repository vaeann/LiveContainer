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
//  Search (Ann 2026-11-26): like the other two segments, this
//  segment's list is the navigation view's direct content
//  with the segment picker as its first row and its own
//  drawer search bar, filtering only this library by app
//  name / bundle id and keeping its own query.
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
    @ObservedObject var searchContext: SearchContext
    private let segmentPicker: SegmentPicker

    @ObservedObject private var store = LCDownloadStore.shared
    @EnvironmentObject private var sharedModel: SharedModel
    @EnvironmentObject private var downloadHelper: DownloadHelper
    @State private var showClearAllConfirm = false
    @State private var packageToShare: LCDownloadedPackage?
    @State private var listViewportHeight: CGFloat = 0

    init(searchContext: SearchContext, @ViewBuilder segmentPicker: () -> SegmentPicker) {
        self.searchContext = searchContext
        self.segmentPicker = segmentPicker()
    }

    private var isFiltering: Bool {
        !searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredPackages: [LCDownloadedPackage] {
        let query = searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return store.packages
        }
        let lower = query.lowercased()
        return store.packages.filter { record in
            if record.appName.lowercased().contains(lower) {
                return true
            }
            if let bundleID = record.bundleID, bundleID.lowercased().contains(lower) {
                return true
            }
            return false
        }
    }

    /// The drawer search bar can only hide when the list can
    /// scroll — the same physics as the sources page. A short
    /// library leaves the list shorter than the screen, so a
    /// clear tail row pads the content to a hair past the
    /// viewport. The estimate must err LOW: the spacer tops
    /// the content up by (viewport + 1 − estimate), so an
    /// estimate higher than the real content (rows run about
    /// 60pt, the picker and headers about 100) still leaves
    /// the list short of the screen and the bar pinned, while
    /// a low estimate only adds invisible tail.
    private var tailSpacerHeight: CGFloat {
        let estimatedContent = 60 + CGFloat(filteredPackages.count) * 56
        return max(0, listViewportHeight + 1 - estimatedContent)
    }

    var body: some View {
        Group {
            if store.packages.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        segmentPicker
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
                    }
                }
            } else {
                List {
                    Section {
                        segmentPicker
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    if isFiltering && filteredPackages.isEmpty {
                        Section {
                            Text("lc.sources.search.noResults".loc)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section {
                            ForEach(filteredPackages) { record in
                                row(for: record)
                            }
                        } header: {
                            // Total size and clear-all describe
                            // the whole library; over a filtered
                            // list they would mislead, so the
                            // header steps aside while filtering.
                            if !isFiltering {
                                HStack {
                                    Text("lc.downloads.totalSize %@".localizeWithFormat(Self.formatSize(store.totalSize)))
                                    Spacer()
                                    Button("lc.downloads.clearAll".loc) {
                                        showClearAllConfirm = true
                                    }
                                    .font(.footnote)
                                    .textCase(nil)
                                }
                            }
                        }
                    }

                    if tailSpacerHeight > 0 {
                        Section {
                            Color.clear
                                .frame(height: tailSpacerHeight)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .searchable(text: $searchContext.query)
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { listViewportHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { listViewportHeight = $0 }
                })
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
        .onChange(of: store.packages.isEmpty) { isEmpty in
            // A query that outlives the last package would
            // silently filter the next download that lands
            // here — the search it belonged to is gone.
            if isEmpty {
                searchContext.query = ""
            }
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
        .contentShape(Rectangle())
        .onTapGesture {
            if record.isComplete {
                NotificationCenter.default.post(name: NSNotification.InstallLocalFileNotification, object: store.fileURL(for: record))
            } else {
                downloadHelper.resumeDownload(record: record)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("lc.downloads.delete".loc, role: .destructive) {
                store.remove(record)
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
