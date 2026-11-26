//
//  LCSourceAppBanner.swift
//  LiveContainerSwiftUI
//
//  Split out of LCAltStoreSourcesView.swift (2026-11-26 refactor,
//  stage 4: pure move; the two structs lose `private` because
//  LCSourcesView now lives in another file).
//

import Foundation
import SwiftUI
import UIKit

struct AltStoreSourceSectionHeaderView: View {
    let item: AltStoreSourcesViewModel.SourceItem
    let isExpanded: Bool
    let sortMode: LCSourceAppSort
    let onSortModeChange: (LCSourceAppSort) -> Void
    let onRefresh: () -> Void
    let onRemove: () -> Void
    let toggleExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.secondary)
                        SourceIconView(url: item.primaryIconURL)
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(item.source?.name ?? item.displayName)
                            .font(.system(.title2).bold())
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if item.isLoading {
                    ProgressView()
                } else {
                    HStack(spacing: 14) {
                        if item.source != nil {
                            LCSourceSortMenuButton(
                                sortMode: sortMode,
                                onSortModeChange: onSortModeChange
                            )
                        }
                        Menu {
                            Button("lc.sources.refresh".loc, systemImage: "arrow.clockwise", action: onRefresh)
                            Button("lc.sources.removeSource".loc, systemImage: "trash", role: .destructive, action: onRemove)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .imageScale(.large)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            if let subtitle = item.source?.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if item.source == nil, let host = item.url.host {
                Text(host)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
        }
    }
}

struct LCSourceAppBanner: View {
    let app: AltStoreSourceApp
    let source: AltStoreSource
    /// Search results are flat across sources, so the row
    /// carries its source's name next to the app name
    /// (Ann 2026-11-26); grouped browsing already shows it
    /// in the section header.
    var showsSourceName: Bool = false
    let buttonState: LCSourceAppButtonState
    let action: () -> Void
    let copyAction: () -> Void
    let ignoreAction: (() -> Void)?
    let installVersionAction: (AltStoreSourceAppVersion) -> Void

    @AppStorage("dynamicColors") private var dynamicColors = true
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject private var downloadHelper: DownloadHelper
    @State private var showDetail = false
    @State private var copied = false
    @State private var textHeight: CGFloat = 0

    /// The icon grows with the text block (Ann 2026-11-26):
    /// the four-line row is taller than the old three-line
    /// one and the fixed 60pt icon looked small in it, so
    /// the icon tracks the measured text height — never
    /// below the old 60, capped at 88.
    private var iconSize: CGFloat { min(max(textHeight, 60), 88) }

    private var primaryColor: Color {
        guard dynamicColors else { return Color("FontColor") }
        return app.tintColor ?? source.tintColor ?? Color("FontColor")
    }

    private var textColor: Color {
        _ = colorScheme == .dark // trigger refresh
        let color = dynamicColors ? primaryColor : Color("FontColor")
        return color.readableTextColor()
    }

    private var backgroundColor: Color {
        dynamicColors ? primaryColor.opacity(0.5) : Color("AppBannerBG")
    }

    // 第二行 = 更新日期（Ann 2026-11-26，四行版式）：只读
    // versions 的 date 标准字段。没有日期的行不占这一行。
    private var dateText: String? {
        guard let date = app.latestVersion?.releaseDate else { return nil }
        return Self.metadataDateFormatter.string(from: date)
    }

    // 第三行 = 版本号 + 安装包大小（Ann 2026-11-26）：读
    // versions 的 version/build/size 标准字段；源里没有
    // 版本信息时回退到 bundle ID（详情页也有一份）。
    private var versionSizeText: String {
        guard let latest = app.latestVersion else {
            return app.bundleIdentifier
        }
        var text = latest.version
        if let build = latest.buildVersion, !build.isEmpty {
            text += " (\(build))"
        }
        if let size = latest.size, size > 0 {
            text += " • " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        return text
    }

    private static let metadataDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var subtitleText: String {
        if let subtitle = app.subtitle, !subtitle.isEmpty {
            return subtitle
        }
        if let developer = app.developerName, !developer.isEmpty {
            return developer
        }
        return ""
    }

    var body: some View {
        HStack {
            HStack(alignment: .center, spacing: 12) {
                SourceIconView(url: app.iconURL)
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.2))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.system(size: 16)).bold()
                            .lineLimit(1)
                        if showsSourceName {
                            Text(source.name)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(textColor)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                        if app.isBeta {
                            Text("lc.sources.badge.beta".loc.uppercased())
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.orange))
                        }
                    }
                    // Four lines (Ann 2026-11-26): name /
                    // release date / version + size / intro.
                    // While installing, the status text takes
                    // the version line's place, as on the
                    // detail page.
                    if let dateText = dateText {
                        Text(dateText)
                            .font(.system(size: 12))
                            .foregroundColor(textColor)
                            .lineLimit(1)
                    }
                    if let phase = downloadHelper.sourceInstallStates[app.bundleIdentifier] {
                        Text(lcSourceInstallStatusText(phase: phase, bundleID: app.bundleIdentifier, helper: downloadHelper))
                            .font(.system(size: 12))
                            .foregroundColor(textColor)
                            .lineLimit(1)
                    } else {
                        Text(versionSizeText)
                            .font(.system(size: 12))
                            .foregroundColor(textColor)
                            .lineLimit(1)
                    }
                    if !subtitleText.isEmpty {
                        Text(subtitleText)
                            .font(.system(size: 11))
                            .foregroundColor(textColor)
                            .lineLimit(1)
                    }
                }
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { textHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { textHeight = $0 }
                })
            }
            .allowsHitTesting(false)
            Spacer()
            Button {
                copyAction()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14))
                    .foregroundColor(textColor)
                    .frame(width: 28, height: 32)
            }
            .buttonStyle(.plain)
            LCSourceInstallButton(
                app: app,
                buttonState: buttonState,
                tint: dynamicColors ? primaryColor : Color("FontColor"),
                action: action
            )
        }
        .padding()
        .background {
            RoundedRectangle(cornerSize: CGSize(width: 22, height: 22))
                .fill(backgroundColor)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            showDetail = true
        }
        .contextMenu {
            Button {
                showDetail = true
            } label: {
                Label("lc.sources.detail".loc, systemImage: "info.circle")
            }
            if let phase = downloadHelper.sourceInstallStates[app.bundleIdentifier] {
                if phase == .queued {
                    Button {
                        NotificationCenter.default.post(name: NSNotification.InstallPrioritizeJobNotification, object: app.bundleIdentifier)
                    } label: {
                        Label("lc.sources.action.prioritize".loc, systemImage: "arrow.up.to.line")
                    }
                }
                if phase == .queued || phase == .downloading {
                    Button(role: .destructive) {
                        let bundleID = app.bundleIdentifier
                        lcConfirmCancelDownload {
                            NotificationCenter.default.post(name: NSNotification.InstallCancelJobNotification, object: bundleID)
                        }
                    } label: {
                        Label("lc.sources.action.cancelDownload".loc, systemImage: "xmark.circle")
                    }
                }
            }
            if let ignoreAction {
                Button {
                    ignoreAction()
                } label: {
                    Label("lc.sources.ignoreVersion".loc, systemImage: "bell.slash")
                }
            }
        }
        .background {
            NavigationLink(isActive: $showDetail) {
                LCSourceAppDetailView(
                    app: app,
                    source: source,
                    buttonState: buttonState,
                    action: action,
                    copyAction: copyAction,
                    installVersionAction: installVersionAction
                )
            } label: {
                EmptyView()
            }
            .hidden()
        }
    }
}
