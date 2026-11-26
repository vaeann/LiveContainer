//
//  AltStoreSourcesViewModel.swift
//  LiveContainerSwiftUI
//
//  Split out of LCAltStoreSourcesView.swift (2026-11-26 refactor,
//  stage 1: pure move, no code changes).
//

import Foundation
import SwiftUI
import UIKit
import CryptoKit

private struct AltStoreSourceResponse: Decodable {
    let name: String?
    let identifier: String?
    let subtitle: String?
    let description: String?
    let iconURL: String?
    let headerURL: String?
    let tintColor: String?
    let website: String?
    let apps: [AltStoreSourceAppResponse]?
}

private struct AltStoreSourceAppResponse: Decodable {
    let beta: Bool?
    let name: String?
    let bundleIdentifier: String?
    let developerName: String?
    let subtitle: String?
    let version: String?
    let versionDate: String?
    let versionDescription: String?
    let downloadURL: String?
    let localizedDescription: String?
    let iconURL: String?
    let tintColor: String?
    let screenshotURLs: [String]?
    let versions: [AltStoreSourceAppVersionResponse]?
    
    enum CodingKeys: String, CodingKey {
        case beta
        case name
        case bundleIdentifier
        case developerName
        case subtitle
        case version
        case versionDate
        case versionDescription
        case downloadURL
        case localizedDescription
        case iconURL
        case tintColor
        case screenshotURLs
        case versions
    }
}

private struct AltStoreSourceAppVersionResponse: Decodable {
    let version: String?
    let buildVersion: String?
    let date: String?
    let localizedDescription: String?
    let downloadURL: String?
    let size: Int64?
    
    enum CodingKeys: String, CodingKey {
        case version
        case buildVersion = "buildNumber"
        case date
        case localizedDescription
        case downloadURL
        case size
    }
}

@MainActor
final class AltStoreSourcesViewModel: ObservableObject {
    struct SourceItem: Identifiable, Hashable {
        let id: URL
        let url: URL
        var source: AltStoreSource?
        var isLoading: Bool
        var error: String?
        
        init(url: URL, isLoading: Bool = false, source: AltStoreSource? = nil, error: String? = nil) {
            self.url = url
            self.id = url
            self.isLoading = isLoading
            self.source = source
            self.error = error
        }
        
        var displayName: String {
            if let source {
                return source.name
            }
            if let host = url.host, !host.isEmpty {
                return host
            }
            return url.absoluteString
        }
        
        var primaryIconURL: URL? {
            if let icon = source?.iconURL {
                return icon
            }
            if let appIcon = source?.apps.first(where: { $0.iconURL != nil })?.iconURL {
                return appIcon
            }
            return nil
        }
    }
    
    @Published private(set) var sources: [SourceItem] = []
    @Published var isRefreshingAll = false
    /// Sources the user switched off in Manage Sources
    /// (Ann 2026-11-26): a switched-off source is paused,
    /// not deleted — refresh-all and the auto-refresh skip
    /// it, and the sources / updates segments, search and
    /// the tab badge all ignore it. Its row stays in
    /// Manage Sources (name / icon / app count come from
    /// the on-disk source cache, no fetch needed), and
    /// switching it back on refreshes it once. Persisted
    /// as the sources' absolute URL strings.
    @Published private(set) var disabledSourceURLs: Set<String> = []
    private static let disabledSourcesKey = "LCDisabledSourceURLs"
    /// Per-source badge colors (hex by source URL),
    /// assigned once when a source first appears and
    /// then fixed (Ann 2026-11-26): a random palette
    /// color no other current source holds. Removing a
    /// source frees its color, so re-adding rolls again.
    private var sourceBadgeColorHex: [String: String] = [:]
    private static let badgeColorsKey = "LCSourceBadgeColors"
    private let defaultsKey = "LCAltStoreSourceURLs"
    /// Built-in source (Ann's own AltSource collection): seeded into
    /// the stored list once, so it comes preinstalled on fresh and
    /// existing installs alike. The seed flag is set when the seed
    /// runs — if the user later removes the source, it stays removed.
    private static let builtInSourceURLString = "https://raw.githubusercontent.com/vaeann/AltSource/main/apps-all.json"
    private static let builtInSourceSeededKey = "LCBuiltInSourceSeededV1"
    /// When the last full refresh ran (any path: initial load, manual,
    /// auto). Persisted so the auto-refresh throttle survives the view
    /// being recreated — see autoRefreshSourcesIfNeeded.
    static let lastFullRefreshKey = "LCLastSourceFullRefreshDate"

    private let cacheDirectoryName = "AltStoreSourceCache"
    private var hasLoadedSources = false

    init() {
        disabledSourceURLs = Set(UserDefaults.standard.stringArray(forKey: Self.disabledSourcesKey) ?? [])
        sourceBadgeColorHex = UserDefaults.standard.dictionary(forKey: Self.badgeColorsKey) as? [String: String] ?? [:]
    }

    /// The source's badge color, assigned on first sight
    /// and persisted. Stamped onto the decoded source so
    /// every row can reach it.
    private func badgeColorHex(for url: URL) -> String {
        let key = url.absoluteString
        if let existing = sourceBadgeColorHex[key] {
            return existing
        }
        // Twelve hues around the wheel in the card
        // colors' S/L family; unclaimed ones first, and
        // once all twelve are taken, the least-held.
        let palette = (0..<12).map { i -> String in
            let rgb = lcHSLToRGB(hue: Double(i) * 30 + 15, saturation: 0.62, lightness: 0.42)
            return String(format: "#%02X%02X%02X", Int(rgb.r * 255), Int(rgb.g * 255), Int(rgb.b * 255))
        }
        let used = Set(sourceBadgeColorHex.values)
        let pick: String
        if let free = palette.filter({ !used.contains($0) }).randomElement() {
            pick = free
        } else {
            let counts = Dictionary(grouping: sourceBadgeColorHex.values.filter { palette.contains($0) }, by: { $0 }).mapValues(\.count)
            pick = palette.min(by: { (counts[$0] ?? 0) < (counts[$1] ?? 0) })!
        }
        sourceBadgeColorHex[key] = pick
        UserDefaults.standard.set(sourceBadgeColorHex, forKey: Self.badgeColorsKey)
        return pick
    }

    private func stampedWithBadgeColor(_ source: AltStoreSource, url: URL) -> AltStoreSource {
        var stamped = source
        stamped.badgeColorHex = badgeColorHex(for: url)
        return stamped
    }

    func isSourceEnabled(_ item: SourceItem) -> Bool {
        !disabledSourceURLs.contains(item.url.absoluteString)
    }

    /// The sources the browsing UI works with — everything
    /// except the switched-off ones.
    var enabledSources: [SourceItem] {
        sources.filter { isSourceEnabled($0) }
    }

    func isBuiltInSource(_ item: SourceItem) -> Bool {
        item.url.absoluteString == Self.builtInSourceURLString
    }

    func setSourceEnabled(_ item: SourceItem, _ enabled: Bool) {
        if enabled {
            disabledSourceURLs.remove(item.url.absoluteString)
        } else {
            disabledSourceURLs.insert(item.url.absoluteString)
        }
        UserDefaults.standard.set(Array(disabledSourceURLs), forKey: Self.disabledSourcesKey)
        if enabled {
            // Catch up right away (Ann 2026-11-26): a source
            // that was off may be stale.
            Task { await refreshSource(item) }
        }
    }
    
    func loadSourcesIfNeeded() {
        guard !hasLoadedSources else { return }
        hasLoadedSources = true
        loadStoredSources()
        Task {
            await refreshAllSources()
        }
    }
    
    func addSource(from rawValue: String) async -> String? {
        guard let normalizedURL = normalizeSourceURL(from: rawValue) else {
            return "lc.sources.error.invalidUrl".loc
        }
        
        if sources.contains(where: { $0.url == normalizedURL }) {
            return "lc.sources.error.duplicate".loc
        }
        
        sources.append(SourceItem(url: normalizedURL, isLoading: true))
        persistSources()
        await refreshSource(url: normalizedURL)
        return nil
    }
    
    func removeSource(_ item: SourceItem) {
        sources.removeAll { $0.id == item.id }
        if disabledSourceURLs.contains(item.url.absoluteString) {
            disabledSourceURLs.remove(item.url.absoluteString)
            UserDefaults.standard.set(Array(disabledSourceURLs), forKey: Self.disabledSourcesKey)
        }
        if sourceBadgeColorHex.removeValue(forKey: item.url.absoluteString) != nil {
            UserDefaults.standard.set(sourceBadgeColorHex, forKey: Self.badgeColorsKey)
        }
        persistSources()
        removeCache(for: item.url)
    }
    
    func refreshSource(_ item: SourceItem) async {
        await refreshSource(url: item.url)
    }
    
    func refreshAllSources() async {
        guard !sources.isEmpty else {
            return
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastFullRefreshKey)
        isRefreshingAll = true
        // Switched-off sources are skipped (Ann 2026-11-26):
        // off means paused, no fetching.
        for url in sources.filter({ isSourceEnabled($0) }).map({ $0.url }) {
            await refreshSource(url: url)
        }
        isRefreshingAll = false
    }
    
    private func refreshSource(url: URL) async {
        guard let index = sources.firstIndex(where: { $0.url == url }) else {
            return
        }
        sources[index].isLoading = true
        sources[index].error = nil
        let previousData = cachedData(for: url)
        do {
            let (source, data) = try await AltStoreSourceLoader.load(from: url)
            guard let sourceIndex = sources.firstIndex(where: { $0.url == url }) else {
                return
            }
            if let previousData, previousData == data {
                sources[sourceIndex].isLoading = false
                return
            }
            sources[sourceIndex].source = stampedWithBadgeColor(source, url: url)
            sources[sourceIndex].isLoading = false
            storeCache(data, for: url)
        } catch {
            if let sourceIndex = sources.firstIndex(where: { $0.url == url }) {
                sources[sourceIndex].error = error.localizedDescription
                sources[sourceIndex].isLoading = false
            }
        }
    }
    
    private func seedBuiltInSourceIfNeeded(_ stored: [String]) -> [String] {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.builtInSourceSeededKey) else { return stored }
        defaults.set(true, forKey: Self.builtInSourceSeededKey)
        guard !stored.contains(Self.builtInSourceURLString) else { return stored }
        var seeded = stored
        seeded.insert(Self.builtInSourceURLString, at: 0)
        defaults.set(seeded, forKey: defaultsKey)
        return seeded
    }
    
    private func loadStoredSources() {
        let defaults = UserDefaults.standard
        let stored = seedBuiltInSourceIfNeeded(defaults.array(forKey: defaultsKey) as? [String] ?? [])
        let urls = stored.compactMap { URL(string: $0) }
        self.sources = urls.map { SourceItem(url: $0, isLoading: false) }
        for index in sources.indices {
            let url = sources[index].url
            if let data = cachedData(for: url),
               let cachedSource = try? AltStoreSourceLoader.decode(from: data, baseURL: url) {
                sources[index].source = stampedWithBadgeColor(cachedSource, url: url)
            }
        }
    }
    
    private func persistSources() {
        let urls = sources.map { $0.url.absoluteString }
        UserDefaults.standard.set(urls, forKey: defaultsKey)
    }
    
    private func normalizeSourceURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }
        if let httpsURL = URL(string: "https://\(trimmed)") {
            return httpsURL
        }
        return nil
    }
}

private extension AltStoreSourcesViewModel {
    func cachedData(for url: URL) -> Data? {
        guard let fileURL = cacheFileURL(for: url) else { return nil }
        return try? Data(contentsOf: fileURL)
    }
    
    func storeCache(_ data: Data, for url: URL) {
        guard let fileURL = cacheFileURL(for: url) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Ignore cache write errors
        }
    }
    
    func cacheFileURL(for url: URL) -> URL? {
        guard let directory = ensureCacheDirectory() else { return nil }
        let fileName = cacheFileName(for: url)
        return directory.appendingPathComponent(fileName)
    }
    
    func ensureCacheDirectory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent(cacheDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return directory
    }
    
    func cacheFileName(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).json"
    }
    
    func removeCache(for url: URL) {
        guard let fileURL = cacheFileURL(for: url) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            // Ignore cache removal errors
        }
    }
}

enum AltStoreSourceLoader {
    static func load(from url: URL) async throws -> (AltStoreSource, Data) {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw NSError(domain: "AltStoreSource", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"])
        }
        let source = try decode(from: data, baseURL: url)
        return (source, data)
    }
    
    static func decode(from data: Data, baseURL: URL) throws -> AltStoreSource {
        try decodeSource(from: data, baseURL: baseURL)
    }
    
    private static func decodeSource(from data: Data, baseURL: URL) throws -> AltStoreSource {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom({ decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if let isoDate = ISO8601DateFormatter().date(from: rawValue) {
                return isoDate
            }
            let shortFormatter = DateFormatter()
            shortFormatter.dateFormat = "yyyy-MM-dd"
            if let shortDate = shortFormatter.date(from: rawValue) {
                return shortDate
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(rawValue)")
        })
        
        let response = try decoder.decode(AltStoreSourceResponse.self, from: data)
        guard let name = response.name else {
            throw NSError(domain: "AltStoreSource", code: 0, userInfo: [NSLocalizedDescriptionKey: "lc.sources.error.malformed".loc])
        }
        let apps = (response.apps ?? []).compactMap { appResponse in
            buildApp(from: appResponse, baseURL: baseURL, fallbackTint: response.tintColor)
        }
        return AltStoreSource(
            name: name,
            identifier: response.identifier,
            subtitle: response.subtitle,
            description: response.description,
            iconURL: url(for: response.iconURL, baseURL: baseURL),
            headerURL: url(for: response.headerURL, baseURL: baseURL),
            tintColor: color(from: response.tintColor),
            website: url(for: response.website, baseURL: baseURL),
            apps: apps
        )
    }
    
    private static func buildApp(from response: AltStoreSourceAppResponse, baseURL: URL, fallbackTint: String?) -> AltStoreSourceApp? {
        guard let name = response.name,
              let bundleIdentifier = response.bundleIdentifier else {
            return nil
        }
        
        let versions = buildVersions(from: response, baseURL: baseURL)
        let latest = versions.first ?? buildLegacyVersion(from: response, baseURL: baseURL)
        
        return AltStoreSourceApp(
            name: name,
            bundleIdentifier: bundleIdentifier,
            developerName: response.developerName,
            subtitle: response.subtitle,
            description: response.localizedDescription ?? response.versionDescription,
            iconURL: url(for: response.iconURL, baseURL: baseURL),
            tintColor: color(from: response.tintColor ?? fallbackTint),
            screenshots: (response.screenshotURLs ?? []).compactMap { url(for: $0, baseURL: baseURL) },
            versions: versions,
            latestVersion: latest,
            isBeta: response.beta ?? false
        )
    }
    
    private static func buildVersions(from response: AltStoreSourceAppResponse, baseURL: URL) -> [AltStoreSourceAppVersion] {
        guard let versions = response.versions else { return [] }
        return versions.compactMap { version in
            guard let versionString = version.version,
                  let downloadURLString = version.downloadURL,
                  let downloadURL = url(for: downloadURLString, baseURL: baseURL) else {
                return nil
            }
            return AltStoreSourceAppVersion(
                version: versionString,
                buildVersion: version.buildVersion,
                releaseDate: parseDate(version.date),
                localizedDescription: version.localizedDescription,
                downloadURL: downloadURL,
                size: version.size
            )
        }
    }
    
    private static func buildLegacyVersion(from response: AltStoreSourceAppResponse, baseURL: URL) -> AltStoreSourceAppVersion? {
        guard let versionString = response.version,
              let downloadURLString = response.downloadURL,
              let downloadURL = url(for: downloadURLString, baseURL: baseURL) else {
            return nil
        }
        return AltStoreSourceAppVersion(
            version: versionString,
            buildVersion: nil,
            releaseDate: parseDate(response.versionDate),
            localizedDescription: response.versionDescription ?? response.localizedDescription,
            downloadURL: downloadURL,
            size: nil
        )
    }
    
    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let isoDate = ISO8601DateFormatter().date(from: value) {
            return isoDate
        }
        let shortFormatter = DateFormatter()
        shortFormatter.dateFormat = "yyyy-MM-dd"
        return shortFormatter.date(from: value)
    }
    
    private static func url(for string: String?, baseURL: URL) -> URL? {
        guard let string = string, !string.isEmpty else { return nil }
        if let absoluteURL = URL(string: string), absoluteURL.scheme != nil {
            return absoluteURL
        }
        return URL(string: string, relativeTo: baseURL)?.absoluteURL
    }
    
    private static func color(from hex: String?) -> Color? {
        guard let hex = hex else { return nil }
        return Color(hexString: hex)
    }
}

private extension Color {
    init?(hexString: String) {
        var cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "#", with: "")
        
        if cleaned.count == 3 {
            var expanded = ""
            for character in cleaned {
                expanded.append(character)
                expanded.append(character)
            }
            cleaned = expanded
        }
        
        if cleaned.count == 6 {
            cleaned.append("FF")
        }
        
        guard cleaned.count == 8,
              let value = UInt64(cleaned, radix: 16) else {
            return nil
        }
        
        let red = Double((value & 0xFF00_0000) >> 24) / 255.0
        let green = Double((value & 0x00FF_0000) >> 16) / 255.0
        let blue = Double((value & 0x0000_FF00) >> 8) / 255.0
        let alpha = Double(value & 0x0000_00FF) / 255.0
        
        self = Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}
