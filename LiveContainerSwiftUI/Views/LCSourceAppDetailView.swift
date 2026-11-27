//
//  LCSourceAppDetailView.swift
//  LiveContainerSwiftUI
//
//  Detail page for an app listed in a source: description, screenshots,
//  version history, per-version detail and installing a specific version.
//

import Foundation
import SwiftUI
import UIKit

struct LCSourceAppDetailView: View {
    let app: AltStoreSourceApp
    let source: AltStoreSource
    /// Asked fresh on every render — the button state
    /// from when this page was opened goes stale the
    /// moment the app is installed from here (it kept
    /// saying Get, and tapping installed it again).
    /// Observing the shared model below is what makes
    /// the page re-render when an install lands.
    let stateProvider: () -> LCSourceAppButtonState
    let action: () -> Void
    let copyAction: () -> Void
    let installVersionAction: (AltStoreSourceAppVersion) -> Void

    @State private var copied = false
    @State private var headerTextHeight: CGFloat = 0
    @EnvironmentObject private var downloadHelper: DownloadHelper
    @EnvironmentObject private var sharedModel: SharedModel
    @AppStorage("dynamicColors") private var dynamicColors = true

    private var liveButtonState: LCSourceAppButtonState {
        stateProvider()
    }

    /// 与列表行完全同款的按钮颜色（Ann 2026-11-26）：列表用 App 的
    /// 主题色，详情页之前写死 FontColor，同一个按钮两个颜色不协调。
    /// 主题色现由客户端按 bundle id 定（lcCardColor），两边共用。
    private var primaryColor: Color {
        guard dynamicColors else { return Color("FontColor") }
        return app.lcCardColor
    }

    /// 头部图标边长：跟文字栈一样高（Ann 2026-11-26：图标大小看
    /// 情况缩放）——四行时随四行长高，行数少时回落，下限是原来的
    /// 72、上限 108 防失控。
    private var headerIconSize: CGFloat {
        min(max(headerTextHeight, 72), 108)
    }

    private var descriptionText: String? {
        if let description = app.description, !description.isEmpty {
            return description
        }
        return app.latestVersion?.localizedDescription
    }

    var body: some View {
        List {
            Section {
                // 头部一行排完（Ann 2026-11-26）：图标 + 名字信息 +
                // 复制图标 + 与列表同款的安装按钮（不再用宽按钮那行）；
                // 安装中时版本行让位给状态文字，和列表行同款逻辑。
                HStack(alignment: .center, spacing: 14) {
                    SourceIconView(url: app.iconURL)
                        .frame(width: headerIconSize, height: headerIconSize)
                        .clipShape(RoundedRectangle(cornerRadius: headerIconSize * 16 / 72))
                    // 头部四行（Ann 2026-11-26）：名字 / 开发者 / 版本
                    // （安装中让位给状态文字）/ 大小。量出文字栈高度
                    // 喂给图标，图标随行数缩放。
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.headline)
                        if let developer = app.developerName, !developer.isEmpty {
                            Text(developer)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let phase = downloadHelper.sourceInstallStates[app.bundleIdentifier] {
                            Text(lcSourceInstallStatusText(phase: phase, bundleID: app.bundleIdentifier, helper: downloadHelper))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if let latest = app.latestVersion {
                            Text(versionOnlyText(latest))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let size = app.latestVersion?.size {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { headerTextHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { headerTextHeight = $0 }
                        }
                    )
                    Spacer()
                    // Same rule as the row (Ann 2026-11-27
                    // audit): no download URL, no copy
                    // button.
                    if app.latestVersion?.downloadURL != nil {
                        Button {
                            copyAction()
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copied = false
                            }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                    }
                    LCSourceInstallButton(
                        app: app,
                        buttonState: liveButtonState,
                        tint: primaryColor,
                        action: action
                    )
                }
                .padding(.vertical, 4)
            }

            if let descriptionText {
                Section {
                    Text(descriptionText)
                        .font(.body)
                } header: {
                    Text("lc.sources.detail.description".loc)
                }
            }

            // 包名单独一段放在介绍下面（Ann 2026-11-26 定版）：段标题
            // 就是 Bundle ID，里面只写包名本身。在头部试过几版都
            // 格格不入，这里最顺眼。
            Section {
                Text(app.bundleIdentifier)
            } header: {
                Text("lc.sources.detail.bundleId".loc)
            }

            if !app.screenshots.isEmpty {
                Section {
                    // screenshots scroller
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(app.screenshots, id: \.self) { url in
                                LCSourceScreenshotView(url: url)
                                    .frame(height: 280)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    Text("lc.sources.detail.screenshots".loc)
                }
            }

            if !app.versions.isEmpty {
                Section {
                    // version history rows
                    ForEach(app.versions) { version in
                        NavigationLink {
                            LCSourceAppVersionDetailView(
                                app: app,
                                version: version,
                                installAction: { installVersionAction(version) }
                            )
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(versionTitle(version))
                                        .font(.body)
                                    Text(versionSubtitle(version))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    installVersionAction(version)
                                } label: {
                                    Text("lc.common.install".loc)
                                        .font(.subheadline).bold()
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                } header: {
                    Text("lc.sources.detail.versions".loc)
                }
            }
        }
        // 顶部导航栏不显示 App 名字（Ann 2026-11-26）：名字在头部卡片里有
    }

    private func versionOnlyText(_ version: AltStoreSourceAppVersion) -> String {
        if let build = version.buildVersion, !build.isEmpty {
            return "\(version.version) (\(build))"
        }
        return version.version
    }

    private func versionTitle(_ version: AltStoreSourceAppVersion) -> String {
        if let build = version.buildVersion, !build.isEmpty {
            return "\(version.version) (\(build))"
        }
        return version.version
    }

    private func versionSubtitle(_ version: AltStoreSourceAppVersion) -> String {
        var parts: [String] = []
        if let date = version.releaseDate {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        if let size = version.size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.joined(separator: " • ")
    }
}

struct LCSourceAppVersionDetailView: View {
    let app: AltStoreSourceApp
    let version: AltStoreSourceAppVersion
    let installAction: () -> Void

    @State private var copied = false

    var body: some View {
        List {
            Section {
                HStack(alignment: .center, spacing: 14) {
                    SourceIconView(url: app.iconURL)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.headline)
                        Text(versionTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if let date = version.releaseDate {
                    HStack {
                        Text("lc.sources.detail.releaseDate".loc)
                        Spacer()
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(.secondary)
                    }
                }
                if let size = version.size {
                    HStack {
                        Text("lc.sources.detail.size".loc)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let notes = version.localizedDescription, !notes.isEmpty {
                Section {
                    Text(notes)
                        .font(.body)
                } header: {
                    Text("lc.sources.detail.releaseNotes".loc)
                }
            }

            Section {
                // 分隔线的起点是跟着行里文字的左缘走的：这两个
                // 按钮的文字居中，左缘被顶到行中间，行下面的分
                // 隔线就只剩右半截（Ann 2026-11-23 真机）。把分
                // 隔线的对齐点钉回行首，和普通行一致。
                Button {
                    installAction()
                } label: {
                    Text("lc.sources.detail.installVersion".loc)
                        .bold()
                        .frame(maxWidth: .infinity)
                        .modifier(ListRowSeparatorLeadingFix())
                }
                Button {
                    UIPasteboard.general.string = version.downloadURL.absoluteString
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "lc.common.copied".loc : "lc.sources.detail.copyDownloadURL".loc,
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                        .modifier(ListRowSeparatorLeadingFix())
                }
            }
        }
        .navigationTitle(versionTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var versionTitle: String {
        if let build = version.buildVersion, !build.isEmpty {
            return "\(version.version) (\(build))"
        }
        return version.version
    }
}

/// 把列表分隔线的对齐点钉回行首（用在居中文字的按钮行上，
/// 见 LCSourceAppVersionDetailView 的按钮区）。分隔线对齐
/// API 是 iOS 16 的，本工程最低 iOS 15：低版本保持原样
/// （分隔线半截，纯外观，不影响功能）。
private struct ListRowSeparatorLeadingFix: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        } else {
            content
        }
    }
}
