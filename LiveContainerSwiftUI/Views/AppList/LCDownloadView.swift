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
                    Text(sizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if helper.totalSize > 0 {
                    ProgressView(value: clampedProgress, total: 1)
                    Text("\("lc.download.downloading".loc) \(Int(clampedProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("lc.download.downloading".loc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: cancelDownload) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color(UIColor.tertiarySystemFill)))
            }
            .buttonStyle(.plain)
        }
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

    private var clampedProgress: Float {
        min(max(helper.downloadProgress, 0), 1)
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

public struct DownloadCapsuleModifier: ViewModifier {
    @ObservedObject var helper : DownloadHelper
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State var show = false

    public func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if show {
                    DownloadCapsule(helper: helper)
                        .padding(.horizontal, 12)
                        .offset(y: -capsuleBottomOffset)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: helper.isDownloading) { newVal in
                withAnimation(.easeInOut(duration: 0.25)) {
                    show = newVal
                }
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
}
