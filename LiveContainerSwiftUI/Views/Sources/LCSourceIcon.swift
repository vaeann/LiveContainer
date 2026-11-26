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
final class SourceIconCache {
    static let shared = SourceIconCache()

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
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = UIImage(data: data) else {
                    return nil
                }
                try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                return image
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

    static func clearAll() {
        shared.memoryCache.removeAllObjects()
        shared.lock.lock()
        shared.failedAt.removeAll()
        shared.lock.unlock()
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
        .task(id: url) {
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
