//
//  LCSourceInstallButton.swift
//  LiveContainerSwiftUI
//
//  Split out of LCAltStoreSourcesView.swift (2026-11-26 refactor,
//  stage 1: pure move, no code changes).
//

import Foundation
import SwiftUI
import UIKit

/// Status line for a source row whose app is in the install
/// pipeline (Ann 2026-11-25): replaces the version line while a
/// progress ring is showing. Byte counts come from the helper
/// and only belong to the one active download.
func lcSourceInstallStatusText(phase: LCSourceInstallPhase, bundleID: String, helper: DownloadHelper) -> String {
    switch phase {
    case .queued:
        return "lc.sources.status.queued".loc
    case .installing:
        return "lc.sources.status.installing".loc
    case .downloading:
        let isActive = helper.activeSourceBundleID == bundleID
        let base = (isActive && helper.isPaused) ? "lc.sources.status.paused".loc : "lc.sources.status.downloading".loc
        if isActive, helper.totalSize > 0 {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            formatter.countStyle = .file
            return base + " · \(formatter.string(fromByteCount: helper.downloadedSize)) / \(formatter.string(fromByteCount: helper.totalSize))"
        }
        return base
    }
}

/// The action control of a source app row / detail header (Ann
/// 2026-11-25, App Store model). Three forms:
/// - a job for this app is in the pipeline: a progress ring —
///   the arc is the download progress and the centre pauses /
///   resumes the active download; a dimmed ring while queued; a
///   full ring with a spinner while installing;
/// - the exact version already sits completed in the downloads
///   library while the app is not installed (or outdated): the
///   cloud button, which installs the kept package directly;
/// - otherwise the classic GET / UPDATE / OPEN capsule.
struct LCSourceInstallButton: View {
    let app: AltStoreSourceApp
    let buttonState: LCSourceAppButtonState
    let tint: Color
    var wide: Bool = false
    let action: () -> Void

    @EnvironmentObject private var downloadHelper: DownloadHelper
    @ObservedObject private var store = LCDownloadStore.shared

    private var phase: LCSourceInstallPhase? {
        downloadHelper.sourceInstallStates[app.bundleIdentifier]
    }

    private var isActiveHere: Bool {
        phase == .downloading && downloadHelper.activeSourceBundleID == app.bundleIdentifier
    }

    /// The kept package for the version this button would install.
    private var storedPackage: LCDownloadedPackage? {
        // The Ignored button is a toggle, not an install
        // path: it must not be pre-empted by the cloud
        // button (Ann 2026-11-27).
        guard buttonState == .get || buttonState == .update, let version = app.latestVersion?.version else { return nil }
        return store.packages.first { $0.isComplete && $0.bundleID == app.bundleIdentifier && $0.version == version }
    }

    var body: some View {
        if let phase {
            if wide {
                HStack(spacing: 10) {
                    ring(phase: phase, size: 32)
                    Text(lcSourceInstallStatusText(phase: phase, bundleID: app.bundleIdentifier, helper: downloadHelper))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: 36)
            } else {
                ring(phase: phase, size: 30)
            }
        } else if let storedPackage {
            cloudButton(package: storedPackage)
        } else {
            capsuleButton
        }
    }

    @ViewBuilder
    private func ring(phase: LCSourceInstallPhase, size: CGFloat) -> some View {
        Button {
            // Only the active download's ring is tappable:
            // pause / resume, App Store style.
            guard phase == .downloading, isActiveHere else { return }
            if downloadHelper.isPaused {
                downloadHelper.resumePausedDownload()
            } else {
                downloadHelper.pauseDownload()
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
                switch phase {
                case .queued:
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                case .downloading:
                    Circle()
                        .trim(from: 0, to: CGFloat(min(max(downloadHelper.downloadProgress, 0), 1)))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: (isActiveHere && downloadHelper.isPaused) ? "play.fill" : "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                case .installing:
                    Circle()
                        .stroke(tint, lineWidth: 2.5)
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(phase != .downloading)
    }

    private func cloudButton(package: LCDownloadedPackage) -> some View {
        Button {
            NotificationCenter.default.post(name: NSNotification.InstallLocalFileNotification, object: store.fileURL(for: package))
        } label: {
            Group {
                if wide {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                } else {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 64, height: 32)
                }
            }
            .background(Capsule().fill(Color(UIColor.tertiarySystemFill)))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var capsuleButton: some View {
        Button {
            action()
        } label: {
            // The Ignored state rests grey (Ann 2026-11-27):
            // it is a toggle waiting to be lifted, not a
            // call to action, so it does not wear the tint.
            Text(buttonState.title)
                .bold()
                .foregroundColor(buttonState == .ignored ? .secondary : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.1)
                .padding(.horizontal, wide ? 0 : 18)
                .frame(maxWidth: wide ? .infinity : nil)
                .frame(height: wide ? 36 : 32)
                .background(Capsule().fill(buttonState == .ignored ? Color(UIColor.tertiarySystemFill) : tint))
                .clipShape(Capsule())
        }
        .buttonStyle(BasicButtonStyle())
    }
}
