//
//  LCAltStoreSourcesView.swift
//  LiveContainerSwiftUI
//
//  Created by Stephen B on 2025/2/15.
//

import Foundation
import SwiftUI
import UIKit
import CryptoKit

struct AltStoreSourceAppVersion: Identifiable, Hashable {
    let id = UUID()
    let version: String
    let buildVersion: String?
    let releaseDate: Date?
    let localizedDescription: String?
    let downloadURL: URL
    let size: Int64?
}

struct AltStoreSourceApp: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let subtitle: String?
    let description: String?
    let iconURL: URL?
    let tintColor: Color?
    let screenshots: [URL]
    let versions: [AltStoreSourceAppVersion]
    let latestVersion: AltStoreSourceAppVersion?
    let isBeta: Bool
}

struct AltStoreSource: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let identifier: String?
    let subtitle: String?
    let description: String?
    let iconURL: URL?
    let headerURL: URL?
    let tintColor: Color?
    let website: URL?
    let apps: [AltStoreSourceApp]
}

/// Segment-wise numeric version comparison (1.10 > 1.9); non-numeric
/// segments count as 0.
func lcIsVersion(_ a: String, newerThan b: String) -> Bool {
    let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
    let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
    let count = max(aParts.count, bParts.count)
    for i in 0..<count {
        let av = i < aParts.count ? aParts[i] : 0
        let bv = i < bParts.count ? bParts[i] : 0
        if av != bv { return av > bv }
    }
    return false
}

/// "Ignore this version" storage: per bundle id, the source version the
/// user chose to stop being reminded about. Ignoring only silences the
/// reminder (the sources-page row and the badge count); the app stays in
/// the Updates tab and in "Update All". A newer source version no longer
/// matches the stored one and reminds again.
enum LCSourceUpdateIgnore {
    private static func key(for bundleIdentifier: String) -> String {
        "LCIgnoredSourceUpdate-\(bundleIdentifier)"
    }

    static func ignoredVersion(for bundleIdentifier: String) -> String? {
        UserDefaults.standard.string(forKey: key(for: bundleIdentifier))
    }

    static func setIgnoredVersion(_ version: String?, for bundleIdentifier: String) {
        if let version {
            UserDefaults.standard.set(version, forKey: key(for: bundleIdentifier))
        } else {
            UserDefaults.standard.removeObject(forKey: key(for: bundleIdentifier))
        }
    }

    static func isIgnored(app: AltStoreSourceApp) -> Bool {
        guard let latest = app.latestVersion else { return false }
        return ignoredVersion(for: app.bundleIdentifier) == latest.version
    }
}

/// What the single action button on a source app row offers.
enum LCSourceAppButtonState {
    case get
    case open
    case update

    var title: String {
        switch self {
        case .get: return "lc.sources.action.get".loc
        case .open: return "lc.sources.action.open".loc
        case .update: return "lc.sources.action.update".loc
        }
    }
}

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
        for url in sources.map({ $0.url }) {
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
            sources[sourceIndex].source = source
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
                sources[index].source = cachedSource
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

struct LCSourcesView: View {
    @StateObject private var viewModel = AltStoreSourcesViewModel()
    @State private var errorMessage: String?
    @State private var sourcePendingRemoval: AltStoreSourcesViewModel.SourceItem?
    // Must be a StateObject, not an ObservedObject with a default
    // instance: the tab view re-creates this view whenever the badge
    // count is published, and an ObservedObject gets swapped for the
    // fresh instance each time — which reset the search query to ""
    // while typing (device report 2026-11-22). A StateObject is
    // created once per view identity and ignores later initializers.
    @StateObject private var searchContext = SearchContext()
    @State private var expandedSources: Set<URL> = []
    @State private var isManagingSources = false
    @State private var selectedSegment = 0
    @State private var ignoreTick = 0

    @EnvironmentObject private var sharedModel : SharedModel

    /// Total number of apps across all sources (the sources tab's count).
    private var totalSourceAppsCount: Int {
        viewModel.sources.reduce(0) { $0 + ($1.source?.apps.count ?? 0) }
    }

    @State private var isViewAppeared = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if !viewModel.sources.isEmpty {
                    Picker("lc.sources.segment".loc, selection: $selectedSegment) {
                        Text("lc.sources.segment.sourcesWithCount".localizeWithFormat(totalSourceAppsCount)).tag(0)
                        Text("lc.sources.segment.updatesWithCount".localizeWithFormat(updatableApps.count)).tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                Group {
                    if viewModel.sources.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "link.badge.plus")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text("lc.sources.empty".loc)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else if selectedSegment == 1 {
                        updatableContent
                    } else {
                        sourcesContent
                    }
                }
            }
            .navigationTitle("lc.tabView.sources".loc)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if viewModel.isRefreshingAll {
                        ProgressView()
                    } else {
                        Button("lc.sources.refreshAll".loc, systemImage: "arrow.clockwise") {
                            Task { await viewModel.refreshAllSources() }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.sources.addSource".loc, systemImage: "plus") {
                        isManagingSources = true
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .alert("lc.common.error".loc, isPresented: Binding<Bool>(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
        ) {
            Button("lc.common.ok".loc, role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("lc.sources.removeConfirmation.title".loc, isPresented: Binding(
            get: { sourcePendingRemoval != nil },
            set: { if !$0 { sourcePendingRemoval = nil } })
        ) {
            Button("lc.common.remove".loc, role: .destructive) {
                if let sourcePendingRemoval {
                    viewModel.removeSource(sourcePendingRemoval)
                }
                sourcePendingRemoval = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                sourcePendingRemoval = nil
            }
        } message: {
            if let name = sourcePendingRemoval?.displayName {
                Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(name))
            } else {
                Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(""))
            }
        }
        .sheet(isPresented: $isManagingSources) {
            if #available(iOS 16.0, *) {
                ManageSourcesSheet(
                    viewModel: viewModel,
                    isPresented: $isManagingSources,
                    onAdd: { rawValue in
                        await handleAddSource(rawValue)
                    }
                )
                .presentationDetents([.large])
            } else {
                ManageSourcesSheet(
                    viewModel: viewModel,
                    isPresented: $isManagingSources,
                    onAdd: { rawValue in
                        await handleAddSource(rawValue)
                    }
                )
            }
        }
        .searchable(text: $searchContext.query, placement: .navigationBarDrawer(displayMode: .always))

        // 页面可能在已经显示的状态下被重建（角标发布会让标签
        // 页重跑一遍并重建本页）：新实例的 onAppear 和标签切换
        // 事件可能都已经错过，数据源就永远等不到加载、整页停
        // 在空状态（Ann 2026-11-23 真机：装完 App 切回软件源
        // 偶尔整页空白，连源都看不见）。 .task 跟着视图实例
        // 走、重建必重跑，在这里补上加载；loadSourcesIfNeeded
        // 本身防重入，重复调用没有副作用。
        .task {
            viewModel.loadSourcesIfNeeded()
            autoRefreshSourcesIfNeeded()
        }
        .onAppear {
            if sharedModel.selectedTab == .sources {
                viewModel.loadSourcesIfNeeded()
                autoRefreshSourcesIfNeeded()
            }
            publishBadgeCount()
            // Expansion state deliberately survives tab switches
            // (Ann 2026-11-24: re-collapsing every source on each
            // return to this page was a nuisance). Stale entries
            // for removed sources are pruned by the sources
            // onChange below.
            if !isViewAppeared {
                guard sharedModel.selectedTab == .sources, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: sharedModel.selectedTab) { tab in
            if tab == .sources {
                viewModel.loadSourcesIfNeeded()
                autoRefreshSourcesIfNeeded()
                publishBadgeCount()
            }
        }
        .onChange(of: updateBadgeCount) { _ in
            publishBadgeCount()
        }
        .onChange(of: viewModel.sources) { newSources in
            let newSet = Set(newSources.map { $0.id })
            expandedSources = expandedSources.intersection(newSet)
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .sources, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
    }

    // MARK: - Sources tab (flattened, lazily loaded)

    /// Section headers and app rows are direct children of one LazyVStack,
    /// so rows and icons load as they scroll into view and there is no
    /// per-source app cap.
    private var sourcesContent: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(viewModel.sources, id: \.id) { item in
                    let apps = filteredApps(for: item)
                    AltStoreSourceSectionHeaderView(
                        item: item,
                        isExpanded: expandedSources.contains(item.id),
                        onRefresh: { Task { await viewModel.refreshSource(item) } },
                        onRemove: { sourcePendingRemoval = item },
                        toggleExpanded: { toggleExpansion(for: item.id) }
                    )
                    .padding(.horizontal)

                    if let error = item.error {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("lc.sources.section.error".loc)
                                .font(.subheadline)
                                .bold()
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("lc.sources.refresh".loc) {
                                Task { await viewModel.refreshSource(item) }
                            }
                            .font(.footnote)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(Color(uiColor: UIColor.secondarySystemBackground))
                        )
                        .padding(.horizontal)
                    } else if let source = item.source, expandedSources.contains(item.id) || isFiltering {
                        if apps.isEmpty {
                            if source.apps.isEmpty || isFiltering {
                                Text("lc.sources.section.noApps".loc)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal)
                            }
                        } else {
                            ForEach(apps) { app in
                                sourceAppBanner(app: app, source: source, inUpdatesTab: false)
                                    .padding(.horizontal)
                            }
                        }
                    }
                    // 加载中不显示任何指示器（Ann 2026-11-22 晚定：
                    // 原来的转圈 +「加载中」占着内容区碍眼，删了）。
                }

                if totalFilteredAppCount == 0 {
                    VStack(spacing: 8) {
                        Text("lc.sources.section.noApps".loc)
                            .foregroundStyle(.gray)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 160, alignment: .center)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }

    // MARK: - Updates tab

    private var updatableContent: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if updatableApps.isEmpty {
                    Text("lc.sources.updates.empty".loc)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    Button {
                        updateAll()
                    } label: {
                        Text("lc.sources.updateAll %lld".localizeWithFormat(updatableApps.count))
                            .bold()
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .modifier { content in
                                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                                    content
                                        .glassEffect(.regular.interactive(true), in: .capsule)
                                } else {
                                    content
                                        .foregroundColor(.white)
                                        .background(Capsule().fill(Color("FontColor")))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)

                    ForEach(updatableApps, id: \.app.id) { pair in
                        sourceAppBanner(app: pair.app, source: pair.source, inUpdatesTab: true)
                            .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
    }

    // MARK: - Row construction

    @ViewBuilder
    private func sourceAppBanner(app: AltStoreSourceApp, source: AltStoreSource, inUpdatesTab: Bool) -> some View {
        let installed = installedModel(for: app.bundleIdentifier)
        let update = hasUpdate(for: app)
        let ignored = LCSourceUpdateIgnore.isIgnored(app: app)
        let state: LCSourceAppButtonState = installed == nil ? .get : (update && (inUpdatesTab || !ignored) ? .update : .open)
        LCSourceAppBanner(
            app: app,
            source: source,
            buttonState: state,
            action: {
                switch state {
                case .open:
                    launchInstalledApp(app)
                case .get, .update:
                    install(app: app)
                }
            },
            copyAction: { copyLatestDownloadURL(app) },
            ignoreAction: (update && !ignored) ? { ignoreUpdate(for: app) } : nil,
            installVersionAction: { version in install(app: app, version: version) }
        )
    }

    // MARK: - Update detection

    func installedModel(for bundleIdentifier: String) -> LCAppModel? {
        (sharedModel.apps + sharedModel.hiddenApps).first {
            $0.appInfo.bundleIdentifier() == bundleIdentifier
        }
    }

    func hasUpdate(for app: AltStoreSourceApp) -> Bool {
        guard let latest = app.latestVersion,
              let installed = installedModel(for: app.bundleIdentifier) else {
            return false
        }
        return lcIsVersion(latest.version, newerThan: installed.version)
    }

    /// Installed apps whose source offers a newer version, across all
    /// sources. One entry per bundle id (the newest offer wins), in
    /// first-appearance order. Ignored versions stay in this list.
    var updatableApps: [(source: AltStoreSource, app: AltStoreSourceApp)] {
        _ = ignoreTick
        var bestByBundle: [String: (source: AltStoreSource, app: AltStoreSourceApp)] = [:]
        var order: [String] = []
        for item in viewModel.sources {
            guard let source = item.source else { continue }
            for app in filteredApps(for: item) {
                guard hasUpdate(for: app), let latest = app.latestVersion else { continue }
                if let existing = bestByBundle[app.bundleIdentifier],
                   let existingLatest = existing.app.latestVersion {
                    if lcIsVersion(latest.version, newerThan: existingLatest.version) {
                        bestByBundle[app.bundleIdentifier] = (source, app)
                    }
                } else {
                    bestByBundle[app.bundleIdentifier] = (source, app)
                    order.append(app.bundleIdentifier)
                }
            }
        }
        return order.compactMap { bestByBundle[$0] }
    }

    /// The red badge number: updatable apps the user has not ignored.
    var updateBadgeCount: Int {
        updatableApps.filter { !LCSourceUpdateIgnore.isIgnored(app: $0.app) }.count
    }

    func ignoreUpdate(for app: AltStoreSourceApp) {
        guard let version = app.latestVersion?.version else { return }
        LCSourceUpdateIgnore.setIgnoredVersion(version, for: app.bundleIdentifier)
        ignoreTick += 1
    }

    // MARK: - Row actions

    private func launchInstalledApp(_ app: AltStoreSourceApp) {
        guard let model = installedModel(for: app.bundleIdentifier),
              let relativePath = model.appInfo.relativeBundlePath,
              let url = URL(string: "livecontainer://livecontainer-launch?bundle-name=\(relativePath)") else {
            return
        }
        sharedModel.deepLink = url
        withAnimation {
            sharedModel.selectedTab = .apps
        }
    }

    private func copyLatestDownloadURL(_ app: AltStoreSourceApp) {
        if let url = app.latestVersion?.downloadURL {
            UIPasteboard.general.string = url.absoluteString
        }
    }

    private func updateAll() {
        let items: [[String: Any]] = updatableApps.compactMap { entry in
            guard let downloadURL = entry.app.latestVersion?.downloadURL else { return nil }
            var item: [String: Any] = ["url": downloadURL, "name": entry.app.name, "bundleID": entry.app.bundleIdentifier]
            if let iconURL = entry.app.iconURL {
                item["iconURL"] = iconURL
            }
            if let versionString = entry.app.latestVersion?.version {
                item["version"] = versionString
            }
            return item
        }
        guard !items.isEmpty else { return }
        withAnimation {
            DataManager.shared.model.selectedTab = .apps
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: NSNotification.InstallAppQueueNotification, object: ["items": items])
        }
    }

    /// Refresh all sources in the background at most once per
    /// 30 minutes when the sources page is shown (Ann 2026-11-22:
    /// was 5 minutes). The throttle reads the persisted last-refresh
    /// time stamped by refreshAllSources itself — the previous
    /// @State-based clock did not survive this view being recreated,
    /// so the page silently refreshed on every visit.
    private func autoRefreshSourcesIfNeeded() {
        guard sharedModel.selectedTab == .sources, !viewModel.isRefreshingAll else { return }
        let last = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: AltStoreSourcesViewModel.lastFullRefreshKey))
        guard Date().timeIntervalSince(last) > 1800 else { return }
        Task { await viewModel.refreshAllSources() }
    }

    private func publishBadgeCount() {
        // 只在真的变了时才写：写这个键会让标签页重跑并重建
        // 本页面，没变化时反复写只是白白增加撞上重建竞态的
        // 机会（整页空白问题的一半在触发端）。
        let count = updateBadgeCount
        guard UserDefaults.standard.integer(forKey: "LCSourceUpdateBadgeCount") != count else { return }
        UserDefaults.standard.set(count, forKey: "LCSourceUpdateBadgeCount")
    }

    private var isFiltering: Bool {
        !searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var totalFilteredAppCount: Int {
        viewModel.sources.reduce(0) { partialResult, item in
            partialResult + filteredApps(for: item).count
        }
    }
    
    private func filteredApps(for item: AltStoreSourcesViewModel.SourceItem) -> [AltStoreSourceApp] {
        guard let source = item.source else { return [] }
        let query = searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return source.apps
        }
        return source.apps.filter { app in
            let lower = query.lowercased()
            if app.name.lowercased().contains(lower) {
                return true
            }
            if app.bundleIdentifier.lowercased().contains(lower) {
                return true
            }
            if let developer = app.developerName?.lowercased(), developer.contains(lower) {
                return true
            }
            if let subtitle = app.subtitle?.lowercased(), subtitle.contains(lower) {
                return true
            }
            return false
        }
    }
    
    @MainActor
    private func handleAddSource(_ rawValue: String) async -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let error = await viewModel.addSource(from: trimmed)
        if let error {
            errorMessage = error
            return false
        }
        return true
    }
    
    @MainActor
    private func install(app: AltStoreSourceApp, version: AltStoreSourceAppVersion? = nil) {
        guard let downloadURL = (version ?? app.latestVersion)?.downloadURL else {
            errorMessage = "lc.sources.error.missingDownload".loc
            return
        }
        // Installing over an installed app is an update: replace in place
        // without the which-bundle prompt.
        let autoReplace = installedModel(for: app.bundleIdentifier) != nil
        withAnimation {
            DataManager.shared.model.selectedTab = .apps
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            var payload: [String: Any] = ["url": downloadURL, "autoReplace": autoReplace, "name": app.name, "bundleID": app.bundleIdentifier]
            if let iconURL = app.iconURL {
                payload["iconURL"] = iconURL
            }
            if let versionString = (version ?? app.latestVersion)?.version {
                payload["version"] = versionString
            }
            NotificationCenter.default.post(name: NSNotification.InstallAppNotification, object: payload)
        }
    }
    
    private func toggleExpansion(for id: URL) {
        withAnimation(.easeInOut) {
            if expandedSources.contains(id) {
                expandedSources.remove(id)
            } else {
                expandedSources.insert(id)
            }
        }
    }
    
    func handleURL(url : URL) {
        if url.host == "source" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var sourceUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        sourceUrl = installUrl1
                    }
                }
                if let sourceUrl {
                    DataManager.shared.model.selectedTab = .sources
                    Task { await handleAddSource(sourceUrl) }
                }
            }
        }
    }
}

private struct ManageSourcesSheet: View {
    @ObservedObject var viewModel: AltStoreSourcesViewModel
    @Binding var isPresented: Bool
    let onAdd: (String) async -> Bool
    
    @State private var manualSourceValue = ""
    @State private var isAddingManual = false
    @State private var sourcePendingRemoval: AltStoreSourcesViewModel.SourceItem?
    @FocusState private var isManualFieldFocused: Bool
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    if viewModel.sources.isEmpty {
                        Text("lc.sources.empty".loc)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.sources, id: \.id) { item in
                            HStack(alignment: .top, spacing: 12) {
                                SourceIconView(url: resolvedIconURL(for: item))
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayName)
                                        .bold()
                                    Text(item.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    sourcePendingRemoval = item
                                } label: {
                                    Label("lc.sources.removeSource".loc, systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("lc.sources.manage.current".loc)
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("https://example.com/source.json", text: $manualSourceValue)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .focused($isManualFieldFocused)
                        
                        Button {
                            attemptManualAdd()
                        } label: {
                            if isAddingManual {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("lc.sources.addSource".loc)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualSourceValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingManual)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("lc.sources.manage.manual".loc)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("lc.sources.addSource".loc)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.close".loc) {
                        isPresented = false
                    }
                }
            }
        }
        .confirmationDialog(
            "lc.sources.removeConfirmation.title".loc,
            isPresented: Binding<Bool>(
                get: { sourcePendingRemoval != nil },
                set: { if !$0 { sourcePendingRemoval = nil } }
            ),
            presenting: sourcePendingRemoval
        ) { item in
            Button("lc.common.remove".loc, role: .destructive) {
                viewModel.removeSource(item)
                sourcePendingRemoval = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                sourcePendingRemoval = nil
            }
        } message: { item in
            Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(item.displayName))
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private func resolvedIconURL(for item: AltStoreSourcesViewModel.SourceItem) -> URL? {
        if let icon = item.primaryIconURL {
            return icon
        }
        if let existing = viewModel.sources.first(where: { $0.url == item.url }) {
            if let icon = existing.primaryIconURL {
                return icon
            }
        }
        return nil
    }
    
    private func attemptManualAdd() {
        let trimmed = manualSourceValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAddingManual else { return }
        isAddingManual = true
        Task {
            let success = await onAdd(trimmed)
            if success {
                manualSourceValue = ""
                isManualFieldFocused = false
            }
            isAddingManual = false
        }
    }
}

private struct AltStoreSourceSectionHeaderView: View {
    let item: AltStoreSourcesViewModel.SourceItem
    let isExpanded: Bool
    let onRefresh: () -> Void
    let onRemove: () -> Void
    let toggleExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.secondary)
                        SourceIconView(url: item.primaryIconURL)
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(item.source?.name ?? item.displayName)
                            .font(.system(.title2).bold())
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if item.isLoading {
                    ProgressView()
                } else {
                    Menu {
                        Button("lc.sources.refresh".loc, systemImage: "arrow.clockwise", action: onRefresh)
                        Button("lc.sources.removeSource".loc, systemImage: "trash", role: .destructive, action: onRemove)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .imageScale(.large)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if let subtitle = item.source?.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if item.source == nil, let host = item.url.host {
                Text(host)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
        }
    }
}

private struct LCSourceAppBanner: View {
    let app: AltStoreSourceApp
    let source: AltStoreSource
    let buttonState: LCSourceAppButtonState
    let action: () -> Void
    let copyAction: () -> Void
    let ignoreAction: (() -> Void)?
    let installVersionAction: (AltStoreSourceAppVersion) -> Void

    @AppStorage("dynamicColors") private var dynamicColors = true
    @Environment(\.colorScheme) var colorScheme
    @State private var showDetail = false
    @State private var copied = false

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

    private var metadataText: String {
        guard let latest = app.latestVersion else {
            return app.bundleIdentifier
        }
        if let build = latest.buildVersion, !build.isEmpty {
            return "\(latest.version) (\(build)) • \(app.bundleIdentifier)"
        }
        return "\(latest.version) • \(app.bundleIdentifier)"
    }

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
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.system(size: 16)).bold()
                        if app.isBeta {
                            Text("lc.sources.badge.beta".loc.uppercased())
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.orange))
                        }
                    }
                    Text(metadataText)
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                    if !subtitleText.isEmpty {
                        Text(subtitleText)
                            .font(.system(size: 11))
                            .foregroundColor(textColor)
                            .lineLimit(1)
                    }
                }
            }
            .allowsHitTesting(false)
            Spacer()
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
            Button {
                action()
            } label: {
                Text(buttonState.title)
                    .bold()
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .frame(height: 32)
                    .minimumScaleFactor(0.1)
            }
            .buttonStyle(BasicButtonStyle())
            .padding()
            .frame(idealWidth: 70)
            .frame(height: 32)
            .fixedSize()
            .background(
                Capsule().fill(dynamicColors ? primaryColor : Color("FontColor"))
            )
            .clipShape(Capsule())
        }
        .padding()
        .frame(height: 88)
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
}

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
