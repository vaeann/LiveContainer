//
//  LCSourceIcon.swift
//  LiveContainerSwiftUI
//
//  Split out of LCAltStoreSourcesView.swift (2026-11-26 refactor,
//  stage 1: pure move, no code changes).
//

import Foundation
import SwiftUI
import UIKit
import CryptoKit

/// Disk + memory cache for source app icons. AsyncImage alone went
/// back to the network on nearly every refresh; icons are now kept
/// in the app-group container, keyed by a hash of the icon URL, and
/// served from memory or disk first. Cleared together with the app
/// icon caches from Data Management (the clear icon cache button).
final class SourceIconCache: ObservableObject {
    static let shared = SourceIconCache()

    /// Bumped whenever the failure list is cleared (a manual
    /// refresh, or the Data Management cache clear). Icon
    /// views key their load task on it, so a bump makes every
    /// icon on screen try again right away instead of sitting
    /// on its placeholder until the view happens to be
    /// recreated.
    @Published private(set) var retryGeneration = 0

    private let memoryCache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// Negative cache (Ann 2026-11-24): when an icon URL failed,
    /// when it failed — dead URLs are not retried for an hour
    /// instead of on every scroll-in.
    private var failedAt: [String: Date] = [:]
    private let lock = NSLock()

    private var cacheDirectory: URL {
        LCPath.lcGroupDocPath.appendingPathComponent("SourceIconCache", isDirectory: true)
    }

    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(name)
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let image = memoryCache.object(forKey: key) {
            return image
        }
        let file = fileURL(for: url)
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memoryCache.setObject(image, forKey: key)
            return image
        }
        lock.lock()
        let recentlyFailed = failedAt[url.absoluteString].map { Date().timeIntervalSince($0) < 3600 } ?? false
        lock.unlock()
        if recentlyFailed {
            return nil
        }
        // Share one download between rows asking for the same icon.
        let task: Task<UIImage?, Never>
        lock.lock()
        if let existing = inFlight[url.absoluteString] {
            task = existing
        } else {
            let created = Task<UIImage?, Never> { [self] in
                // Up to five attempts with a short, growing
                // pause between them (Ann 2026-11-26): one
                // network hiccup must not cost an icon its
                // hour in the failure list below — only five
                // straight failures earn that.
                for attempt in 0..<5 {
                    if attempt > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    }
                    guard let (data, response) = try? await URLSession.shared.data(from: url) else {
                        continue
                    }
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        continue
                    }
                    guard let image = UIImage(data: data) else {
                        continue
                    }
                    try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                    try? data.write(to: file, options: .atomic)
                    return image
                }
                return nil
            }
            inFlight[url.absoluteString] = created
            task = created
        }
        lock.unlock()
        let image = await task.value
        lock.lock()
        inFlight[url.absoluteString] = nil
        if image == nil {
            failedAt[url.absoluteString] = Date()
        } else {
            failedAt.removeValue(forKey: url.absoluteString)
        }
        lock.unlock()
        if let image {
            memoryCache.setObject(image, forKey: key)
        }
        return image
    }

    /// Forget every recorded failure (Ann 2026-11-26): a
    /// manual source refresh calls this, so an icon that
    /// failed earlier the same hour is downloaded again
    /// instead of waiting out its hour. Successful icons
    /// are untouched — only the failure list is erased.
    /// The generation bump makes icons already on screen
    /// retry immediately.
    func clearFailures() {
        lock.lock()
        failedAt.removeAll()
        lock.unlock()
        retryGeneration += 1
    }

    static func clearAll() {
        shared.memoryCache.removeAllObjects()
        shared.lock.lock()
        shared.failedAt.removeAll()
        shared.lock.unlock()
        shared.retryGeneration += 1
        try? FileManager.default.removeItem(at: shared.cacheDirectory)
    }

    /// Total bytes the cached source icons take on disk.
    static func cacheSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: shared.cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}

struct SourceIconView: View {
    let url: URL?
    @State private var image: UIImage?
    @ObservedObject private var cache = SourceIconCache.shared

    /// The load task's identity: the URL, plus the cache's
    /// retry generation, so clearing the failure list
    /// re-runs the load for icons already on screen.
    private struct LoadID: Hashable {
        let url: URL?
        let generation: Int
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: LoadID(url: url, generation: cache.retryGeneration)) {
            image = nil
            guard let url else { return }
            image = await SourceIconCache.shared.image(for: url)
        }
    }

    private var placeholder: some View {
        Image("DefaultIcon")
            .resizable()
            .scaledToFill()
    }
}
