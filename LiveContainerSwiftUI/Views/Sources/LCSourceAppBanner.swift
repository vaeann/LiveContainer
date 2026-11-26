//
//  LCSourceAppBanner.swift
//  LiveContainerSwiftUI
//
//  Split out of LCAltStoreSourcesView.swift (2026-11-26 refactor,
//  stage 4: pure move). The old per-source section header that
//  shared this file was deleted the same evening, when the
//  sources segment switched to filter chips + flat cards
//  (Ann 2026-11-26, second redesign round).
//

import Foundation
import SwiftUI
import UIKit

struct LCSourceAppBanner: View {
    let app: AltStoreSourceApp
    let source: AltStoreSource
    /// Flat lists (all-sources browsing, search results)
    /// carry the source's name on its own badge line under
    /// the app name (Ann 2026-11-26); a single source's own
    /// list already says which source it is via the chip.
    var showsSourceName: Bool = false
    /// The sources segment's card layout (Ann 2026-11-26,
    /// second redesign round): fixed 56pt icon, compressed
    /// four-line stack (name / source badge / date · size /
    /// intro) and the version under the install button
    /// instead of in the text. The updates segment keeps
    /// the original layout (false).
    var cardLayout: Bool = false
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
    /// below the old 60, capped at 88. The card layout
    /// instead fixes the icon at 56 (Ann: shrink it a bit
    /// and squeeze the row tighter).
    private var iconSize: CGFloat {
        cardLayout ? 56 : min(max(textHeight, 60), 88)
    }

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

    // 卡片版式第三行 = 日期 · 大小（Ann 2026-11-26 第二轮）：
    // 版本号挪去按钮下面，这一行只剩日期和大小；两样都没有
    // 时回退 bundle ID（与旧版式无版本信息时的回退一致）。
    private var dateSizeText: String {
        var parts: [String] = []
        if let dateText {
            parts.append(dateText)
        }
        if let size = app.latestVersion?.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.isEmpty ? app.bundleIdentifier : parts.joined(separator: " · ")
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
                if cardLayout {
                    cardTextStack
                } else {
                    legacyTextStack
                }
            }
            .allowsHitTesting(false)
            Spacer()
            copyButton
            if cardLayout {
                // The version sits under the button (Ann
                // 2026-11-26, second round): it belongs to
                // the action — "GET, and this is the version
                // you get". Overlong versions truncate at
                // the column's width.
                VStack(spacing: 4) {
                    installButton
                    if let version = app.latestVersion?.version {
                        Text(version)
                            .font(.system(size: 10))
                            .foregroundColor(textColor)
                            .lineLimit(1)
                            .frame(width: 70)
                    }
                }
            } else {
                installButton
            }
        }
        .padding(cardLayout ? 12 : 16)
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

    // MARK: - Pieces

    private var copyButton: some View {
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
    }

    private var installButton: some View {
        LCSourceInstallButton(
            app: app,
            buttonState: buttonState,
            tint: dynamicColors ? primaryColor : Color("FontColor"),
            action: action
        )
    }

    private var sourceTag: some View {
        Text(source.name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(textColor)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private var betaBadge: some View {
        Text("lc.sources.badge.beta".loc.uppercased())
            .font(.system(size: 9, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange))
    }

    /// The original stack (updates segment): name (+ source
    /// tag) + beta / date / version + size — or the install
    /// status in the version line's place / intro. Carries
    /// the text-height measurement the adaptive icon feeds
    /// on.
    private var legacyTextStack: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(app.name)
                    .font(.system(size: 16)).bold()
                    .lineLimit(1)
                if showsSourceName {
                    sourceTag
                }
                if app.isBeta {
                    betaBadge
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

    /// The card stack (sources segment, Ann 2026-11-26
    /// second round): name + beta / source badge alone /
    /// date · size — or the install status in that line's
    /// place / intro. Squeezed (spacing 3, name 15) to sit
    /// with the fixed 56pt icon; the version moved under
    /// the install button.
    private var cardTextStack: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(app.name)
                    .font(.system(size: 15)).bold()
                    .lineLimit(1)
                if app.isBeta {
                    betaBadge
                }
            }
            if showsSourceName {
                sourceTag
            }
            if let phase = downloadHelper.sourceInstallStates[app.bundleIdentifier] {
                Text(lcSourceInstallStatusText(phase: phase, bundleID: app.bundleIdentifier, helper: downloadHelper))
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .lineLimit(1)
            } else {
                Text(dateSizeText)
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
    }
}
