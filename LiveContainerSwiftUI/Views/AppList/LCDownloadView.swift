//
//  LCDownloadView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2025/1/22.
//

import SwiftUI

/// Per-app install phase shown on a source row (Ann 2026-11-25):
/// tapping GET no longer jumps to the apps tab — the row's button
/// turns into an App Store-style progress ring driven by this
/// state, published per bundle ID by the install pipeline. The
/// paused sub-state is not a phase: it is isPaused below, and it
/// can only apply to the one active download.
enum LCSourceInstallPhase: Equatable {
    case queued
    case downloading
    case installing
}

public final class DownloadHelper : NSObject, ObservableObject {
    @Published var downloadProgress : Float = 0.0
    @Published var downloadedSize : Int64 = 0
    @Published var totalSize : Int64 = 0
    @Published var isDownloading = false
    @Published var cancelled = false
    /// Pause state of the active download (Ann 2026-11-24: the
    /// capsule gets a pause button next to its close button, and
    /// the button turns into a resume button while paused).
    /// isDownloading stays true while paused — the download
    /// session is still in progress, just not transferring.
    @Published var isPaused = false
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
    /// Source-row install states by bundle ID (Ann 2026-11-25):
    /// set when a URL job is queued, advanced by the install
    /// flow, cleared when the job ends. Rows with an entry show
    /// the progress ring instead of the GET capsule.
    @Published var sourceInstallStates: [String: LCSourceInstallPhase] = [:]
    /// Bundle ID of the job whose download currently owns the
    /// single transfer slot (progress/pause readouts belong to
    /// it); nil while a library-page resume owns the slot.
    var activeSourceBundleID: String? = nil
    /// Set by cancelCurrentJob(): the running job — and only it —
    /// was cancelled from its source row. The queue processor
    /// consumes the flag and counts the job as aborted, then
    /// carries on with the rest of the queue (unlike `cancelled`,
    /// which drains everything).
    private(set) var currentJobCancelled = false
    private var downloadTask: URLSessionDownloadTask?
    private var continuation: UnsafeContinuation<(), Never>?
    private var activeError: Error? = nil
    /// Downloads-library record the active task belongs to, and
    /// the file the finished download must land at. Set for both
    /// install-flow downloads and library-page resumes.
    private var activeRecordID: String? = nil
    private var activeDestination: URL? = nil
    /// Resume data of the most recent interrupted download,
    /// captured from the completion error; the install flow
    /// stores it on the record when it marks it partial.
    private(set) var lastResumeData: Data? = nil
    private var lastProgressPersist = Date.distantPast
    /// Pause bookkeeping: pauseRequested marks the completion
    /// that the pause's cancel produces (so it is not mistaken
    /// for a finish or an error), pausedResumeData restarts the
    /// transfer where it stopped, and activeURL restarts it from
    /// scratch when the server gave no resume data.
    private var pauseRequested = false
    private var pausedResumeData: Data? = nil
    private var activeURL: URL? = nil

    /// One background session with a FIXED identifier (Ann
    /// 2026-11-24, resumable downloads): the old code created a
    /// throwaway session with a random UUID per download, so a
    /// download whose app exited could never be reattached. With
    /// a stable identifier the system keeps the transfer going
    /// while LiveContainer is gone and delivers the outcome to
    /// this delegate when the session is recreated at launch.
    static let backgroundSessionIdentifier = "com.livecontainer.download"
    /// Completion handler handed over by the app delegate for
    /// background-session events; called and cleared once the
    /// session has delivered everything after a relaunch.
    static var backgroundEventsCompletionHandler: (() -> Void)? = nil

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    override init() {
        super.init()
        reattachToRunningTask()
    }

    /// If a download from a previous launch is still running in
    /// the background session (LiveContainer was killed or
    /// restarted mid-download), adopt it: its record stays
    /// "downloading" and the completion lands in the library.
    private func reattachToRunningTask() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            guard self.downloadTask == nil,
                  let task = tasks.compactMap({ $0 as? URLSessionDownloadTask }).first else { return }
            self.downloadTask = task
            self.isDownloading = true
            self.cancelled = false
            self.downloadedSize = task.countOfBytesReceived
            self.totalSize = task.countOfBytesExpectedToReceive
            if self.totalSize > 0 {
                self.downloadProgress = Float(self.downloadedSize) / Float(self.totalSize)
            }
            if let urlStr = task.originalRequest?.url?.absoluteString,
               let record = LCDownloadStore.shared.packages.first(where: { !$0.isComplete && $0.sourceURL == urlStr }) {
                self.activeRecordID = record.id
                self.activeDestination = LCDownloadStore.shared.fileURL(for: record)
                self.downloadName = record.appName
                self.downloadIconURL = record.iconURL.flatMap { URL(string: $0) }
            }
        }
    }

    func download(url: URL, to: URL, recordID: String? = nil) async throws {
        // A task adopted at launch may still be running; stop it
        // (its record stays partial and resumable) before the new
        // download takes over the single active slot.
        if let stale = downloadTask {
            stale.cancel()
            downloadTask = nil
            activeRecordID = nil
            activeDestination = nil
        }
        activeError = nil
        lastResumeData = nil
        activeRecordID = recordID
        activeDestination = to
        activeURL = url
        pauseRequested = false
        pausedResumeData = nil
        currentJobCancelled = false

        await MainActor.run {
            cancelled = false
            isPaused = false

            downloadProgress = 0.0
            downloadedSize = 0
            totalSize = 0

            isDownloading = true
        }

        await withUnsafeContinuation { c in
            continuation = c
            downloadTask = session.downloadTask(with: url)
            downloadTask?.resume()
        }
        if let activeError {
            throw activeError
        }
    }

    /// Continues an interrupted library download (from the
    /// downloads page): resume data when the system provided
    /// some, otherwise a fresh request for the same URL. Nobody
    /// waits on a continuation here — completion only registers
    /// the package in the library, nothing installs on its own.
    func resumeDownload(record: LCDownloadedPackage) {
        // The single active slot is also occupied while a queue
        // download is merely paused (its waiter is still pending).
        guard downloadTask == nil, continuation == nil else { return }
        let store = LCDownloadStore.shared
        activeError = nil
        lastResumeData = nil
        activeRecordID = record.id
        activeDestination = store.fileURL(for: record)
        activeURL = record.sourceURL.flatMap { URL(string: $0) }
        pauseRequested = false
        pausedResumeData = nil
        isPaused = false
        cancelled = false
        downloadName = record.appName
        downloadIconURL = record.iconURL.flatMap { URL(string: $0) }
        downloadedSize = record.downloadedBytes
        totalSize = record.totalBytes
        downloadProgress = record.totalBytes > 0 ? Float(record.downloadedBytes) / Float(record.totalBytes) : 0
        isDownloading = true
        if record.hasResumeData,
           let data = try? Data(contentsOf: store.resumeDataURL(for: record)) {
            downloadTask = session.downloadTask(withResumeData: data)
        } else if let sourceURL = record.sourceURL, let url = URL(string: sourceURL) {
            downloadTask = session.downloadTask(with: url)
        }
        downloadTask?.resume()
    }

    /// Pauses the active download: the task is cancelled in the
    /// resume-data-producing way, but unlike cancel() the waiter
    /// is NOT unblocked and the session stays alive — the
    /// completion handler recognizes the pause (pauseRequested),
    /// parks the resume data, and resumePausedDownload() later
    /// recreates the task from it. The library record is marked
    /// partial right away, so even if the app exits while paused
    /// the downloads page can continue the transfer.
    func pauseDownload() {
        guard isDownloading, !isPaused, let downloadTask else { return }
        pauseRequested = true
        isPaused = true
        downloadTask.cancel(byProducingResumeData: { [weak self] data in
            if let data {
                self?.pausedResumeData = data
                self?.lastResumeData = data
            }
        })
    }

    /// Restarts a paused download from its resume data, or from
    /// the original URL when the server provided none (a plain
    /// restart in that case). The pending waiter from download()
    /// simply sees the new task's completion.
    func resumePausedDownload() {
        guard isPaused else { return }
        isPaused = false
        pauseRequested = false
        if let pausedResumeData {
            downloadTask = session.downloadTask(withResumeData: pausedResumeData)
        } else if let activeURL {
            downloadTask = session.downloadTask(with: activeURL)
        }
        pausedResumeData = nil
        downloadTask?.resume()
    }

    // MARK: - Source-row install states (Ann 2026-11-25)

    func setSourceInstallState(_ bundleID: String, _ phase: LCSourceInstallPhase) {
        sourceInstallStates[bundleID] = phase
    }

    func clearSourceInstallState(_ bundleID: String) {
        sourceInstallStates[bundleID] = nil
        if activeSourceBundleID == bundleID {
            activeSourceBundleID = nil
        }
    }

    func clearAllSourceInstallStates() {
        sourceInstallStates = [:]
        activeSourceBundleID = nil
    }

    /// Cancels ONLY the job whose download is running (or paused)
    /// — the rest of the queue is untouched. Mirrors cancel()'s
    /// two shapes: a live task is cancelled producing resume data
    /// (the interrupted package stays resumable in the library),
    /// and a paused download's parked waiter is resumed directly.
    /// The install flow sees currentJobCancelled where it checks
    /// the cancelled flag and stops this job without an error.
    func cancelCurrentJob() {
        guard isDownloading || continuation != nil else { return }
        currentJobCancelled = true
        isPaused = false
        pauseRequested = false
        if let downloadTask {
            downloadTask.cancel(byProducingResumeData: { [weak self] data in
                if let data {
                    self?.lastResumeData = data
                }
            })
        } else if let continuation {
            continuation.resume()
            self.continuation = nil
        }
        isDownloading = false
    }

    /// Reads and resets the per-job cancel flag (queue processor,
    /// once per finished job).
    func consumeCurrentJobCancelled() -> Bool {
        defer { currentJobCancelled = false }
        return currentJobCancelled
    }

    func cancel() {
        cancelled = true
        isPaused = false
        pauseRequested = false
        clearAllSourceInstallStates()
        if let downloadTask {
            // Producing resume data lets the downloads page offer
            // to continue this download later; the completion
            // callback below captures it and unblocks the waiter.
            downloadTask.cancel(byProducingResumeData: { [weak self] data in
                if let data {
                    self?.lastResumeData = data
                }
            })
        } else if let continuation {
            continuation.resume()
            self.continuation = nil
        }
        isDownloading = false
        // Cancelling a download also cancels every install still
        // waiting in the serial install queue (Ann 2026-11-24: the
        // capsule's x means stop everything, not just this one).
        // The app list observes this and drains its pending jobs;
        // the running job aborts itself via the cancelled flag.
        NotificationCenter.default.post(name: NSNotification.InstallCancelAllNotification, object: nil)
    }
}

extension DownloadHelper: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard downloadTask == self.downloadTask else { return }
        downloadedSize = totalBytesWritten
        totalSize = totalBytesExpectedToWrite
        downloadProgress = totalBytesExpectedToWrite > 0 ? Float(totalBytesWritten) / Float(totalBytesExpectedToWrite) : 0
        // Keep the library record's progress roughly current so
        // an interrupted download shows real numbers (throttled:
        // the index file is rewritten on every persist).
        if let activeRecordID, Date().timeIntervalSince(lastProgressPersist) > 1 {
            lastProgressPersist = Date()
            LCDownloadStore.shared.updateProgress(id: activeRecordID, downloadedBytes: totalBytesWritten, totalBytes: totalBytesExpectedToWrite)
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard downloadTask == self.downloadTask, let destination = activeDestination else { return }
        // HTTP errors are failures even though a body arrived.
        if let httpResponse = downloadTask.response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            activeError = NSError(domain: "", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP Error: \(httpResponse.statusCode)"])
            return
        }
        // The temp file is deleted when this callback returns —
        // move it into the library synchronously.
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
        } catch {
            activeError = error
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let finishedTask = task as? URLSessionDownloadTask, finishedTask == downloadTask else { return }
        // The completion a pause produces: park the transfer
        // instead of finishing the download. The waiter stays
        // pending, the record is marked partial with the resume
        // data, and resumePausedDownload() recreates the task.
        // (error == nil means the download had already finished
        // before the pause landed — fall through and complete
        // normally; cancelled means the close button overtook
        // the pause — also normal processing.)
        if pauseRequested, !cancelled, let error {
            if let resumeData = (error as NSError).userInfo["NSURLSessionDownloadTaskResumeData"] as? Data {
                pausedResumeData = resumeData
                lastResumeData = resumeData
            }
            downloadTask = nil
            if let activeRecordID {
                LCDownloadStore.shared.markPartial(id: activeRecordID, downloadedBytes: downloadedSize, totalBytes: totalSize, resumeData: lastResumeData)
            }
            return
        }
        pauseRequested = false
        pausedResumeData = nil
        isPaused = false
        isDownloading = false
        downloadTask = nil
        let recordID = activeRecordID
        activeRecordID = nil
        activeDestination = nil
        activeURL = nil

        if let error {
            let nsError = error as NSError
            // The userInfo key's bridged Swift constant is not
            // visible in this SDK; its string value is stable.
            if let resumeData = nsError.userInfo["NSURLSessionDownloadTaskResumeData"] as? Data {
                lastResumeData = resumeData
            }
            if cancelled {
                // User cancel is not an error for the waiter;
                // the install flow sees the cancelled flag.
            } else if currentJobCancelled {
                // Same for a per-job cancel from a source row:
                // not an error; the flow sees the flag.
            } else if activeError == nil {
                activeError = error
            }
            // Nobody waiting (page resume / reattached task):
            // record the interruption right here.
            if continuation == nil, let recordID {
                LCDownloadStore.shared.markPartial(id: recordID, downloadedBytes: downloadedSize, totalBytes: totalSize, resumeData: lastResumeData)
            }
        } else if activeError == nil {
            // Finished cleanly with nobody waiting: register it.
            if continuation == nil, let recordID {
                LCDownloadStore.shared.markCompleted(id: recordID)
            }
        } else if continuation == nil, let recordID {
            // e.g. an HTTP error body "downloaded" fine.
            LCDownloadStore.shared.markPartial(id: recordID, downloadedBytes: downloadedSize, totalBytes: totalSize, resumeData: nil)
        }

        if let continuation {
            continuation.resume()
            self.continuation = nil
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let handler = Self.backgroundEventsCompletionHandler {
            Self.backgroundEventsCompletionHandler = nil
            handler()
        }
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
                        Text("\(helper.isPaused ? "lc.download.paused".loc : "lc.download.downloading".loc) \(Int(clampedProgress * 100))%\(remainingSuffix)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                        Text((helper.isPaused ? "lc.download.paused".loc : "lc.download.downloading".loc) + remainingSuffix)
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

            if helper.isDownloading {
                // Pause / resume (Ann 2026-11-24): pauses the
                // transfer where it stands; while paused the
                // button becomes the start button.
                Button(action: togglePause) {
                    Image(systemName: helper.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color(UIColor.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
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

    func togglePause() {
        if helper.isPaused {
            helper.resumePausedDownload()
        } else {
            helper.pauseDownload()
        }
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

    /// A picked IPA file was not downloaded from anywhere, so it
    /// gets its own title (Ann 2026-11-24) over the same green
    /// check and "installed" line.
    static func localFile(name: String) -> InstallCompletion {
        return InstallCompletion(
            kind: .installed,
            title: "lc.download.installCompleteTitle".loc,
            subtitle: "lc.download.installed %@".localizeWithFormat(name))
    }

    static func batch(done: Int, failed: Int, updates: Int, installs: Int) -> InstallCompletion {
        // Only name the kinds that actually happened: a plain
        // update-all session is all updates, a queue of fresh
        // installs is all new — "0 of the other kind" is noise.
        // A mixed line-up only occurs when the user queues more
        // installs while a session is already running.
        let counts: String
        if updates > 0 && installs > 0 {
            counts = "lc.download.batchCounts %lld %lld".localizeWithFormat(updates, installs)
        } else if updates > 0 {
            counts = "lc.download.batchUpdatesOnly %lld".localizeWithFormat(updates)
        } else if installs > 0 {
            counts = "lc.download.batchInstallsOnly %lld".localizeWithFormat(installs)
        } else {
            counts = ""
        }
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
                if !completion.subtitle.isEmpty {
                    Text(completion.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
    @ObservedObject var sharedModel: SharedModel
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
            .onAppear {
                refreshShow()
            }
            .onChange(of: helper.isDownloading) { _ in
                refreshShow()
            }
            .onChange(of: helper.isInstallSessionActive) { _ in
                refreshShow()
            }
            .onChange(of: sharedModel.selectedTab) { _ in
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
    // While the sources tab is on screen the PROGRESS form stays
    // hidden (Ann 2026-11-25): each row's button is the progress
    // ring there, so the capsule would only duplicate it and
    // cover the list. Leaving the tab hands progress back to the
    // capsule. Result cards (success / batch failures) show on
    // every tab — they are outcomes, not progress.
    private func refreshShow() {
        let resultCard = helper.installCompletion != nil && !helper.isInstallSessionActive
        let progress = (helper.isDownloading || helper.isInstallSessionActive)
            && sharedModel.selectedTab != .sources
        withAnimation(.easeInOut(duration: 0.25)) {
            show = resultCard || progress
        }
    }

    // Tab bar height (49) + bottom safe area + a small gap, so the
    // capsule floats just above the tab bar on any device.
    private var capsuleBottomOffset: CGFloat {
        49 + (sceneDelegate.window?.safeAreaInsets.bottom ?? 0) + 10
    }
}

extension View {
    // Internal, not public: SharedModel is an internal type, so
    // a public signature cannot name it (build error caught
    // 2026-11-25). The only caller is in this module anyway.
    func downloadCapsule(helper: DownloadHelper, sharedModel: SharedModel) -> some View {
        self.modifier(DownloadCapsuleModifier(helper: helper, sharedModel: sharedModel))
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
