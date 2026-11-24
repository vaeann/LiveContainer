//
//  LCDownloadStore.swift
//  LiveContainerSwiftUI
//
//  The downloaded-packages library behind the sources page's
//  third segment (Ann 2026-11-24): every IPA the app downloads
//  (source installs, updates, manual URL) or imports (file
//  picker, share sheet) is kept here instead of being deleted
//  after install, so any package can be installed again later.
//  Different versions of the same app coexist — an old version
//  is never overwritten by a newer one; only re-downloading the
//  SAME version replaces that version's copy. Interrupted
//  downloads also live here as incomplete records carrying
//  resume data, so they can continue where they left off.
//

import Foundation

struct LCDownloadedPackage: Identifiable, Codable, Equatable {
    var id: String
    /// File name inside the store folder (complete packages).
    var fileName: String
    var appName: String
    var bundleID: String?
    var version: String?
    /// Extracted icon PNG inside the store folder, if any.
    var iconFileName: String?
    /// Remote icon URL from the source payload, if any.
    var iconURL: String?
    /// Where the package was downloaded from (nil for imports);
    /// needed to restart a download that has no resume data.
    var sourceURL: String?
    /// Bytes of the kept package file (complete packages).
    var size: Int64
    var savedAt: Date
    var isComplete: Bool
    /// Progress bookkeeping for incomplete downloads.
    var downloadedBytes: Int64
    var totalBytes: Int64
    /// Resume data is stored in a sidecar file `<id>.resumedata`.
    var hasResumeData: Bool
}

final class LCDownloadStore: ObservableObject {
    static let shared = LCDownloadStore()

    @Published private(set) var packages: [LCDownloadedPackage] = []

    var folderURL: URL {
        LCPath.docPath.appendingPathComponent("Downloads")
    }
    private var indexURL: URL {
        folderURL.appendingPathComponent("index.json")
    }

    private init() {
        loadFromDisk()
    }

    // MARK: - Persistence

    func loadFromDisk() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        var loaded: [LCDownloadedPackage] = []
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([LCDownloadedPackage].self, from: data) {
            loaded = decoded
        }
        // Drop records whose package file is gone (deleted
        // outside the app); incomplete records have no file yet
        // and are kept so they can resume.
        loaded = loaded.filter { record in
            !record.isComplete || fm.fileExists(atPath: fileURL(for: record).path)
        }
        packages = loaded.sorted { $0.savedAt > $1.savedAt }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(packages) {
            try? data.write(to: indexURL, options: [.atomic])
        }
    }

    private func upsert(_ record: LCDownloadedPackage) {
        if let idx = packages.firstIndex(where: { $0.id == record.id }) {
            packages[idx] = record
        } else {
            packages.append(record)
        }
        packages.sort { $0.savedAt > $1.savedAt }
        persist()
    }

    // MARK: - File locations

    func fileURL(for record: LCDownloadedPackage) -> URL {
        folderURL.appendingPathComponent(record.fileName)
    }

    func resumeDataURL(for record: LCDownloadedPackage) -> URL {
        folderURL.appendingPathComponent("\(record.id).resumedata")
    }

    func iconURL(for record: LCDownloadedPackage) -> URL? {
        guard let iconFileName = record.iconFileName else { return nil }
        return folderURL.appendingPathComponent(iconFileName)
    }

    /// Deterministic store file name: one file per app version,
    /// so versions coexist and the same version maps to the
    /// same file. Falls back to the suggested (URL/file) name
    /// when the app identity is unknown, uniquified on collision
    /// with a different app's file.
    private func makeFileName(bundleID: String?, version: String?, suggested: String) -> String {
        let fm = FileManager.default
        if let bundleID, !bundleID.isEmpty {
            let base = version.map { "\(bundleID)_\($0)" } ?? bundleID
            return "\(base).ipa".sanitizedStoreFileName()
        }
        var candidate = suggested.isEmpty ? "package.ipa" : suggested
        if !candidate.lowercased().hasSuffix(".ipa") && !candidate.lowercased().hasSuffix(".tipa") {
            candidate += ".ipa"
        }
        candidate = candidate.sanitizedStoreFileName()
        let stem = (candidate as NSString).deletingPathExtension
        let ext = (candidate as NSString).pathExtension
        var attempt = candidate
        var counter = 2
        while fm.fileExists(atPath: folderURL.appendingPathComponent(attempt).path),
              !packages.contains(where: { $0.fileName == attempt }) {
            attempt = "\(stem)-\(counter).\(ext)"
            counter += 1
        }
        return attempt
    }

    // MARK: - Records

    /// Creates (or refreshes) the record for a download that is
    /// about to start, and returns it together with the file URL
    /// the finished download must be moved to.
    @discardableResult
    func beginDownload(sourceURL: String, name: String?, bundleID: String?, version: String?, iconURL: URL?) -> LCDownloadedPackage {
        // Re-downloading the same source updates its record.
        if var existing = packages.first(where: { $0.sourceURL == sourceURL && $0.bundleID == bundleID && $0.version == version }) {
            existing.isComplete = false
            existing.downloadedBytes = 0
            existing.totalBytes = 0
            existing.hasResumeData = false
            existing.savedAt = Date()
            if let name { existing.appName = name }
            upsert(existing)
            return existing
        }
        let suggested = URL(string: sourceURL)?.lastPathComponent ?? "package.ipa"
        let record = LCDownloadedPackage(
            id: UUID().uuidString,
            fileName: makeFileName(bundleID: bundleID, version: version, suggested: suggested),
            appName: name ?? suggested,
            bundleID: bundleID,
            version: version,
            iconFileName: nil,
            iconURL: iconURL?.absoluteString,
            sourceURL: sourceURL,
            size: 0,
            savedAt: Date(),
            isComplete: false,
            downloadedBytes: 0,
            totalBytes: 0,
            hasResumeData: false
        )
        upsert(record)
        return record
    }

    /// Registers a local file that is being imported (file
    /// picker / share sheet): copies it into the store first so
    /// the copy survives whatever the install does with the
    /// original, and returns the record. Metadata is filled in
    /// after the install parses the IPA (updateMetadata).
    @discardableResult
    func beginImport(sourceFileURL: URL) -> LCDownloadedPackage? {
        let fm = FileManager.default
        try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let fileName = makeFileName(bundleID: nil, version: nil, suggested: sourceFileURL.lastPathComponent)
        let destination = folderURL.appendingPathComponent(fileName)
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: sourceFileURL, to: destination)
        } catch {
            return nil
        }
        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        let record = LCDownloadedPackage(
            id: UUID().uuidString,
            fileName: fileName,
            appName: sourceFileURL.lastPathComponent,
            bundleID: nil,
            version: nil,
            iconFileName: nil,
            iconURL: nil,
            sourceURL: nil,
            size: size,
            savedAt: Date(),
            isComplete: true,
            downloadedBytes: size,
            totalBytes: size,
            hasResumeData: false
        )
        upsert(record)
        return record
    }

    /// Mutates the store's current copy of a record. All state
    /// changes go through here by id — callers hold snapshots
    /// that go stale the moment another change lands.
    private func mutate(_ id: String, _ change: (inout LCDownloadedPackage) -> Void) {
        guard var current = packages.first(where: { $0.id == id }) else { return }
        change(&current)
        upsert(current)
    }

    /// Marks a download finished: the file is already at its
    /// store location. Enforces Ann's version rule — a completed
    /// package replaces only a record of the SAME app version;
    /// other versions are kept.
    func markCompleted(_ record: LCDownloadedPackage) {
        let fm = FileManager.default
        if let bundleID = record.bundleID, let version = record.version {
            for other in packages where other.id != record.id && other.bundleID == bundleID && other.version == version {
                removeFiles(of: other)
                packages.removeAll { $0.id == other.id }
            }
        }
        mutate(record.id) { updated in
            updated.size = (try? fm.attributesOfItem(atPath: fileURL(for: updated).path)[.size] as? NSNumber)?.int64Value ?? updated.size
            updated.isComplete = true
            updated.downloadedBytes = updated.size
            updated.totalBytes = updated.size
            updated.hasResumeData = false
            updated.savedAt = Date()
        }
        if let current = packages.first(where: { $0.id == record.id }) {
            try? fm.removeItem(at: resumeDataURL(for: current))
        }
    }

    /// Id-based entry points for the download engine, which
    /// tracks records by id across relaunches.
    func markCompleted(id: String) {
        guard let current = packages.first(where: { $0.id == id }) else { return }
        markCompleted(current)
    }

    func markPartial(id: String, downloadedBytes: Int64, totalBytes: Int64, resumeData: Data?) {
        guard let current = packages.first(where: { $0.id == id }) else { return }
        markPartial(current, downloadedBytes: downloadedBytes, totalBytes: totalBytes, resumeData: resumeData)
    }

    /// Progress-only refresh for a running download (no other
    /// field changes, savedAt untouched).
    func updateProgress(id: String, downloadedBytes: Int64, totalBytes: Int64) {
        mutate(id) { updated in
            updated.downloadedBytes = downloadedBytes
            if totalBytes > 0 {
                updated.totalBytes = totalBytes
            }
        }
    }

    /// Marks a download interrupted, keeping whatever progress
    /// and resume data the system produced so the downloads page
    /// can offer to continue it.
    func markPartial(_ record: LCDownloadedPackage, downloadedBytes: Int64, totalBytes: Int64, resumeData: Data?) {
        if let resumeData {
            try? resumeData.write(to: resumeDataURL(for: record), options: [.atomic])
        }
        mutate(record.id) { updated in
            updated.isComplete = false
            updated.downloadedBytes = downloadedBytes
            updated.totalBytes = totalBytes
            if resumeData != nil {
                updated.hasResumeData = true
            }
        }
    }

    /// Fills in app identity after an install parsed the IPA,
    /// and applies the same-version replacement rule (an import
    /// of a version already kept replaces that version's copy).
    func updateMetadata(_ record: LCDownloadedPackage, appName: String, bundleID: String, version: String?) {
        if let version {
            for other in packages where other.id != record.id && other.bundleID == bundleID && other.version == version && other.isComplete {
                // Our own file may sit under a generic name; the
                // other record is the duplicate to drop.
                removeFiles(of: other)
                packages.removeAll { $0.id == other.id }
            }
        }
        mutate(record.id) { updated in
            updated.appName = appName
            updated.bundleID = bundleID
            updated.version = version
        }
    }

    /// Copies an extracted app icon into the store so the row
    /// keeps its icon even after the app is uninstalled.
    func attachIcon(_ record: LCDownloadedPackage, fromIconFile source: URL) {
        let iconName = "\(record.id)-icon.png"
        let destination = folderURL.appendingPathComponent(iconName)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            mutate(record.id) { updated in
                updated.iconFileName = iconName
            }
        } catch {
            // Icon is decoration; never fail the flow over it.
        }
    }

    // MARK: - Removal

    private func removeFiles(of record: LCDownloadedPackage) {
        let fm = FileManager.default
        try? fm.removeItem(at: fileURL(for: record))
        try? fm.removeItem(at: resumeDataURL(for: record))
        if let icon = iconURL(for: record) {
            try? fm.removeItem(at: icon)
        }
    }

    func remove(_ record: LCDownloadedPackage) {
        removeFiles(of: record)
        packages.removeAll { $0.id == record.id }
        persist()
    }

    func removeAll() {
        for record in packages {
            removeFiles(of: record)
        }
        packages = []
        persist()
    }

    // MARK: - Totals

    var totalSize: Int64 {
        packages.filter { $0.isComplete }.reduce(0) { $0 + $1.size }
    }

    var count: Int {
        packages.count
    }
}

private extension String {
    /// File-name safe form for store files: path separators and
    /// other hostile characters become underscores.
    func sanitizedStoreFileName() -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return components(separatedBy: bad).joined(separator: "_")
    }
}
