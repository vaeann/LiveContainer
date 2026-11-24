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

import SwiftUI

struct LCDownloadsView: View {
    @ObservedObject private var store = LCDownloadStore.shared
    @EnvironmentObject private var sharedModel: SharedModel
    @EnvironmentObject private var downloadHelper: DownloadHelper
    @State private var showClearAllConfirm = false
    @State private var packageToShare: LCDownloadedPackage?

    var body: some View {
        Group {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List {
                    Section {
                        ForEach(store.packages) { record in
                            row(for: record)
                        }
                    } header: {
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
                .listStyle(.insetGrouped)
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
        Button {
            if record.isComplete {
                NotificationCenter.default.post(name: NSNotification.InstallLocalFileNotification, object: store.fileURL(for: record))
            } else {
                downloadHelper.resumeDownload(record: record)
            }
        } label: {
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
                if !record.isComplete {
                    Text("lc.downloads.resume".loc)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            parts.append(Self.dateFormatter.string(from: record.savedAt))
            return parts.joined(separator: " · ")
        }
        if record.totalBytes > 0 {
            return "lc.downloads.progressOfTotal %@ %@".localizeWithFormat(Self.formatSize(record.downloadedBytes), Self.formatSize(record.totalBytes))
        }
        return "lc.downloads.incomplete".loc
    }

    // MARK: - Formatting

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
