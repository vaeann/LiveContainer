//
//  LCDownloadView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2025/1/22.
//

import SwiftUI

public final class DownloadHelper : ObservableObject {
    @Published var downloadProgress : Float = 0.0
    @Published var downloadedSize : Int64 = 0
    @Published var totalSize : Int64 = 0
    @Published var isDownloading = false
    @Published var cancelled = false
    /// What the floating progress capsule shows for the current
    /// download; set by the install flow right before it starts.
    @Published var downloadName : String? = nil
    @Published var downloadIconURL : URL? = nil
    /// Serial-install session state, driven by the app list's
    /// queue processor so the capsule can stay on screen for the
    /// whole session instead of vanishing between the download
    /// and install phases of every job (Ann 2026-11-24).
    @Published var isInstallSessionActive = false
    @Published var isInstallingPhase = false
    @Published var queuedInstallCount = 0
    /// Real decompress/sign progress of the install phase (moved
    /// here from the app list's view state so the capsule reads
    /// the same value the installer writes).
    @Published var installProgressPercentage : Float = 0.0
    /// Success card shown in the capsule's place when an install
    /// session ends (Ann 2026-11-24): set by the app list's
    /// session report, cleared by the capsule modifier after a
    /// few seconds unless the card is persistent (batch with
    /// failures — tapping it opens the failure summary).
    @Published var installCompletion : InstallCompletion? = nil
    private var downloadTask: URLSessionDownloadTask?
    private var continuation: UnsafeContinuation<(), Never>?
    
    func download(url: URL, to: URL) async throws {
        var ansError: Error? = nil

        await MainActor.run {
            cancelled = false
            
            downloadProgress = 0.0
            downloadedSize = 0
            totalSize = 0
            
            isDownloading = true
        }
        
        await withUnsafeContinuation { c in
            continuation = c
            
            let bgConfig = URLSessionConfiguration.background(withIdentifier: "com.livecontainer.download.\(UUID().uuidString)")
            let session = URLSession(configuration: bgConfig, delegate: DownloadDelegate(progressCallback: { progress, downloaded, total in
                Task{ await MainActor.run {
                    self.downloadProgress = progress
                    self.downloadedSize = downloaded
                    self.totalSize = total
                }}
            }, completeCallback: {tempFileURL, error in
                Task{ await MainActor.run {
                    self.isDownloading = false
                }}
                if let error {
                    print(error)
                    ansError = error
                }
                if let tempFileURL {
                    do {
                        let fm = FileManager.default
                        print(to)
                        try fm.moveItem(at: tempFileURL, to: to)
                    } catch {
                        ansError = error
                    }
                }
                if self.continuation != nil {
                    c.resume()
                }

            }), delegateQueue: .main)

            downloadTask = session.downloadTask(with: url)
            downloadTask?.resume()
        }
        if let ansError {
            throw ansError
        }
    }
    
    func cancel() {
        if let continuation {
            continuation.resume()
        }
        cancelled = true
        continuation = nil
        downloadTask?.cancel()
        isDownloading = false
        // Cancelling a download also cancels every install still
        // waiting in the serial install queue (Ann 2026-11-24: the
        // capsule's x means stop everything, not just this one).
        // The app list observes this and drains its pending jobs;
        // the running job aborts itself via the cancelled flag.
        NotificationCenter.default.post(name: NSNotification.InstallCancelAllNotification, object: nil)
    }
}

// Floating download progress capsule (Ann 2026-11-24, plan A):
// replaces the old full-screen DownloadAlert, whose dim layer
// swallowed every touch and froze the whole app for the length of
// a download. The capsule floats above the tab bar and is the
// only touchable surface it adds — everything behind it stays
// fully usable while a download runs.
struct DownloadCapsule : View {
    @ObservedObject var helper : DownloadHelper
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let iconURL = helper.downloadIconURL {
                    SourceIconView(url: iconURL)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(UIColor.tertiarySystemFill))
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(helper.downloadName ?? "")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if helper.isDownloading {
                        Text(sizeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if helper.isDownloading {
                    if helper.totalSize > 0 {
                        ProgressView(value: clampedProgress, total: 1)
                        Text("\("lc.download.downloading".loc) \(Int(clampedProgress * 100))%\(remainingSuffix)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                        Text("lc.download.downloading".loc + remainingSuffix)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // Install phase of the current job: the capsule
                    // stays up with the real decompress/sign
                    // progress instead of disappearing until the
                    // next download starts.
                    ProgressView(value: min(max(helper.installProgressPercentage, 0), 1), total: 1)
                    Text("lc.download.installing".loc + remainingSuffix)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if helper.isDownloading || helper.queuedInstallCount > 0 {
                Button(action: cancelDownload) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color(UIColor.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
            }
        }
        .downloadCapsuleChrome()
    }

    private var clampedProgress: Float {
        min(max(helper.downloadProgress, 0), 1)
    }

    /// " · 还剩 N 个" while more jobs are waiting behind this one.
    private var remainingSuffix: String {
        helper.queuedInstallCount > 0
            ? " · " + "lc.download.queuedRemaining %lld".localizeWithFormat(helper.queuedInstallCount)
            : ""
    }

    private var sizeText: String {
        if helper.totalSize > 0 {
            return "\(formatBytes(helper.downloadedSize)) / \(formatBytes(helper.totalSize))"
        }
        return formatBytes(helper.downloadedSize)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB] // Allow KB, MB, and GB
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func cancelDownload() {
        helper.cancel()
    }
}

/// Content of the capsule's success card. Fresh installs and
/// updates deliberately look different (Ann 2026-11-24, as drawn):
/// a green check for a new install, a blue up-arrow for an update,
/// and one counts card for a whole batch.
struct InstallCompletion: Equatable {
    enum Kind: Equatable {
        case installed
        case updated
        case batch
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var subtitle: String
    /// When set, the card shows an Open button launching this app.
    var bundleID: String? = nil
    /// Batch-with-failures cards stay until tapped.
    var persistent: Bool = false
    var hasFailures: Bool = false

    static func single(name: String, isUpdate: Bool, version: String?, bundleID: String?) -> InstallCompletion {
        if isUpdate {
            return InstallCompletion(
                kind: .updated,
                title: "lc.download.updatedTitle".loc,
                subtitle: version != nil
                    ? "lc.download.updatedTo %@ %@".localizeWithFormat(name, version!)
                    : "lc.download.updated %@".localizeWithFormat(name),
                bundleID: bundleID)
        }
        return InstallCompletion(
            kind: .installed,
            title: "lc.download.completedTitle".loc,
            subtitle: "lc.download.installed %@".localizeWithFormat(name),
            bundleID: bundleID)
    }

    static func batch(done: Int, failed: Int, updates: Int, installs: Int) -> InstallCompletion {
        let counts = "lc.download.batchCounts %lld %lld".localizeWithFormat(updates, installs)
        if failed > 0 {
            return InstallCompletion(
                kind: .batch,
                title: "lc.download.batchPartial %lld %lld".localizeWithFormat(done, failed),
                subtitle: counts,
                persistent: true,
                hasFailures: true)
        }
        return InstallCompletion(
            kind: .batch,
            title: "lc.download.batchCompletedTitle".loc,
            subtitle: counts)
    }
}

/// The success card that replaces the progress capsule in place
/// when an install session ends.
struct CompletionCapsule: View {
    @ObservedObject var helper: DownloadHelper
    let completion: InstallCompletion

    var body: some View {
        Group {
            if completion.hasFailures {
                Button(action: openSummary) {
                    cardContent
                }
                .buttonStyle(.plain)
            } else {
                cardContent
                    .onTapGesture { dismiss() }
            }
        }
        .downloadCapsuleChrome()
    }

    private var cardContent: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 30))
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(completion.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(completion.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let bundleID = completion.bundleID {
                Button {
                    NotificationCenter.default.post(name: NSNotification.OpenInstalledAppNotification, object: bundleID)
                    dismiss()
                } label: {
                    Text("lc.sources.action.open".loc)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(UIColor.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
            }
            if completion.hasFailures {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var iconName: String {
        if completion.hasFailures {
            return "exclamationmark.circle.fill"
        }
        switch completion.kind {
        case .installed, .batch:
            return "checkmark.circle.fill"
        case .updated:
            return "arrow.up.circle.fill"
        }
    }

    private var iconColor: Color {
        if completion.hasFailures {
            return .orange
        }
        switch completion.kind {
        case .installed, .batch:
            return .green
        case .updated:
            return .blue
        }
    }

    private func openSummary() {
        NotificationCenter.default.post(name: NSNotification.ShowInstallSummaryNotification, object: nil)
        dismiss()
    }

    private func dismiss() {
        withAnimation(.easeInOut(duration: 0.25)) {
            helper.installCompletion = nil
        }
    }
}

public struct DownloadCapsuleModifier: ViewModifier {
    @ObservedObject var helper : DownloadHelper
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State var show = false

    public func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if show {
                    Group {
                        if let completion = helper.installCompletion, !helper.isInstallSessionActive {
                            CompletionCapsule(helper: helper, completion: completion)
                        } else {
                            DownloadCapsule(helper: helper)
                        }
                    }
                    .padding(.horizontal, 12)
                    .offset(y: -capsuleBottomOffset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: helper.isDownloading) { _ in
                refreshShow()
            }
            .onChange(of: helper.isInstallSessionActive) { _ in
                refreshShow()
            }
            .onChange(of: helper.installCompletion) { completion in
                refreshShow()
                guard let completion else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                // Non-persistent cards dismiss themselves after a
                // few seconds; the batch-with-failures card stays
                // until tapped.
                guard !completion.persistent else { return }
                let cardID = completion.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if helper.installCompletion?.id == cardID {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            helper.installCompletion = nil
                        }
                    }
                }
            }
    }

    // The capsule lives for the whole install session — downloads
    // and the install phases in between — and then hands its
    // place to the success card when the session report sets one.
    private func refreshShow() {
        withAnimation(.easeInOut(duration: 0.25)) {
            show = helper.isDownloading || helper.isInstallSessionActive || helper.installCompletion != nil
        }
    }

    // Tab bar height (49) + bottom safe area + a small gap, so the
    // capsule floats just above the tab bar on any device.
    private var capsuleBottomOffset: CGFloat {
        49 + (sceneDelegate.window?.safeAreaInsets.bottom ?? 0) + 10
    }
}

class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressCallback: (Float, Int64, Int64) -> Void
    let completeCallback: (URL?, Error?) -> Void

    init(progressCallback: @escaping (Float, Int64, Int64) -> Void,
         completeCallback: @escaping (URL?, Error?) -> Void) {
        self.progressCallback = progressCallback
        self.completeCallback = completeCallback
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
        progressCallback(progress, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let httpResponse = downloadTask.response as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode

            // Check if the status code is in the 2xx range
            if (200...299).contains(statusCode) {
                completeCallback(location, nil)
            } else {
                completeCallback(location, NSError(domain: "", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP Error: \(statusCode)"]))
            }
        } else {
            completeCallback(location, NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
        }
        

    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completeCallback(nil, error)
        } else {

        }
    }
}

extension View {
    public func downloadCapsule(helper: DownloadHelper) -> some View {
        self.modifier(DownloadCapsuleModifier(helper: helper))
    }

    /// The shared material-card look of the progress capsule and
    /// its success card.
    func downloadCapsuleChrome() -> some View {
        self
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 22)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(Color(UIColor.separator), lineWidth: 0.5)
            }
    }
}
