//
//  LCSourcesView.swift
//  LiveContainerSwiftUI
//
//  Created by Stephen B on 2025/2/15 as LCAltStoreSourcesView.swift;
//  renamed in the 2026-11-26 refactor once everything else had
//  moved out — this file is now just the sources page itself.
//

import Foundation
import SwiftUI
import UIKit
import CryptoKit

struct LCSourcesView: View {
    @StateObject private var viewModel = AltStoreSourcesViewModel()
    @State private var errorMessage: String?
    @State private var sourcePendingRemoval: AltStoreSourcesViewModel.SourceItem?
    // Must be StateObjects, not ObservedObjects with default
    // instances: the tab view re-creates this view whenever the badge
    // count is published, and an ObservedObject gets swapped for the
    // fresh instance each time — which reset the search query to ""
    // while typing (device report 2026-11-22). A StateObject is
    // created once per view identity and ignores later initializers.
    // The sources segment's search context (Ann 2026-11-26:
    // it is the only segment that searches — the updates and
    // downloads bars were removed the same day, there is
    // little in those lists worth searching). It lives here
    // rather than in the segment view because the segment
    // view is destroyed when another segment shows, and its
    // state would go with it — the query must survive
    // segment switches.
    @StateObject private var sourcesSearchContext = SearchContext()
    @State private var expandedSources: Set<URL> = []
    @State private var isManagingSources = false
    @State private var selectedSegment = 0
    @State private var ignoreTick = 0

    @EnvironmentObject private var sharedModel : SharedModel
    @ObservedObject private var downloadStore = LCDownloadStore.shared

    /// Total number of apps across all sources (the sources tab's count).
    private var totalSourceAppsCount: Int {
        viewModel.sources.reduce(0) { $0 + ($1.source?.apps.count ?? 0) }
    }

    @State private var isViewAppeared = false

    var body: some View {
        NavigationView {
            Group {
                if selectedSegment == 2 {
                    LCDownloadsView {
                        segmentPicker
                    }
                } else if selectedSegment == 1 {
                    updatesScrollView
                } else {
                    sourcesScrollView
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
            // No .searchable at this level, and no fixed
            // picker above the segments (Ann 2026-11-26,
            // settled after four attempts): each segment's
            // scroll view is the navigation view's direct
            // content — the App page's geometry — with the
            // picker as its first row and its own drawer
            // search bar on the scroll view itself. Anything
            // between the navigation view and the scroll view
            // (a VStack, a fixed picker) breaks the link the
            // drawer's hide mechanism needs and pins the bar.
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

    /// The segment picker, riding as the first row of
    /// whichever segment is showing (see the note in body).
    @ViewBuilder
    private var segmentPicker: some View {
        if !viewModel.sources.isEmpty || downloadStore.count > 0 {
            Picker("lc.sources.segment".loc, selection: $selectedSegment) {
                Text("lc.sources.segment.sourcesWithCount".localizeWithFormat(totalSourceAppsCount)).tag(0)
                Text("lc.sources.segment.updatesWithCount".localizeWithFormat(updatableApps.count)).tag(1)
                Text("lc.sources.segment.downloadsWithCount".localizeWithFormat(downloadStore.count)).tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    /// Shown in the sources and updates segments when no
    /// source has been added yet.
    private var emptySourcesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("lc.sources.empty".loc)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Sources tab (flattened, lazily loaded)

    /// The sources segment, on the shared segment shell
    /// (LCSegmentShell carries the geometry rules and the
    /// four-attempt history behind them). While this
    /// segment's query is non-empty the rows swap to flat
    /// cross-source results — the same scroll view, so the
    /// bar's geometry never changes. In browse mode the
    /// section headers and app rows are direct children of
    /// the LazyVStack, so rows and icons load as they scroll
    /// into view and there is no per-source app cap.
    private var sourcesScrollView: some View {
        LCSegmentShell(searchContext: sourcesSearchContext) {
            segmentPicker
        } content: {
            if viewModel.sources.isEmpty {
                emptySourcesView
                    .padding(.top, 48)
            } else if isFiltering(sourcesSearchContext) {
                sourcesSearchResultsRows
            } else {
                ForEach(viewModel.sources, id: \.id) { item in
                    let apps = displayedApps(item.source?.apps ?? [], for: item)
                    AltStoreSourceSectionHeaderView(
                        item: item,
                        isExpanded: expandedSources.contains(item.id),
                        sortMode: sortMode(for: item),
                        onSortModeChange: { setSortMode($0, for: item) },
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
                    } else if let source = item.source, expandedSources.contains(item.id) {
                        if apps.isEmpty {
                            Text("lc.sources.section.noApps".loc)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
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

                if totalSourceAppsCount == 0 {
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
        }
    }

    /// Flat cross-source results while the sources segment
    /// is filtering; each row is tagged with its source.
    @ViewBuilder
    private var sourcesSearchResultsRows: some View {
        let results = sourcesSearchResults
        if results.isEmpty {
            Text("lc.sources.search.noResults".loc)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .padding(.horizontal)
        } else {
            ForEach(results, id: \.app.id) { pair in
                sourceAppBanner(app: pair.app, source: pair.source, inUpdatesTab: false, showsSourceName: true)
                    .padding(.horizontal)
            }
        }
    }

    // MARK: - Updates tab

    /// The updates segment, on the shared segment shell.
    /// No search bar (Ann 2026-11-26: little here worth
    /// searching) — the list is always the whole list, so
    /// the update-all button always shows.
    private var updatesScrollView: some View {
        LCSegmentShell {
            segmentPicker
        } content: {
            if viewModel.sources.isEmpty {
                emptySourcesView
                    .padding(.top, 48)
            } else if updatableApps.isEmpty {
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
    }

    // MARK: - Row construction

    @ViewBuilder
    private func sourceAppBanner(app: AltStoreSourceApp, source: AltStoreSource, inUpdatesTab: Bool, showsSourceName: Bool = false) -> some View {
        let installed = installedModel(for: app.bundleIdentifier)
        let update = hasUpdate(for: app)
        let ignored = LCSourceUpdateIgnore.isIgnored(app: app)
        let state: LCSourceAppButtonState = installed == nil ? .get : (update && (inUpdatesTab || !ignored) ? .update : .open)
        LCSourceAppBanner(
            app: app,
            source: source,
            showsSourceName: showsSourceName,
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
    /// Deliberately unfiltered: the badge count and update-all act
    /// on the whole list, and the updates segment shows it as-is.
    var updatableApps: [(source: AltStoreSource, app: AltStoreSourceApp)] {
        _ = ignoreTick
        var bestByBundle: [String: (source: AltStoreSource, app: AltStoreSourceApp)] = [:]
        var order: [String] = []
        for item in viewModel.sources {
            guard let source = item.source else { continue }
            for app in source.apps {
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
        // Stays on the updates page like a single install (Ann
        // 2026-11-25): every row's ring shows its own progress.
        NotificationCenter.default.post(name: NSNotification.InstallAppQueueNotification, object: ["items": items])
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

    // MARK: - Per-source sort

    /// Session overrides for the per-source sort modes;
    /// the persisted values live in LCSourceAppSort.
    @State private var sourceSortModes: [String: LCSourceAppSort] = [:]

    private func sortMode(for item: AltStoreSourcesViewModel.SourceItem) -> LCSourceAppSort {
        sourceSortModes[item.url.absoluteString] ?? LCSourceAppSort.storedMode(for: item.url)
    }

    private func setSortMode(_ mode: LCSourceAppSort, for item: AltStoreSourcesViewModel.SourceItem) {
        sourceSortModes[item.url.absoluteString] = mode
        LCSourceAppSort.storeMode(mode, for: item.url)
    }

    /// A source's apps in the order its header menu
    /// currently asks for. The sort is stable, so apps
    /// sharing a date keep source order.
    private func displayedApps(_ apps: [AltStoreSourceApp], for item: AltStoreSourcesViewModel.SourceItem) -> [AltStoreSourceApp] {
        let result = apps
        switch sortMode(for: item) {
        case .sourceOrder:
            return result
        case .recentlyUpdated:
            return result.sorted { a, b in
                (a.latestVersion?.releaseDate ?? .distantPast) > (b.latestVersion?.releaseDate ?? .distantPast)
            }
        }
    }

    // MARK: - Search filtering

    /// Whether the given segment's search is active (its own
    /// query, debounced — Ann 2026-11-26: each segment
    /// searches only itself and keeps its own query).
    private func isFiltering(_ context: SearchContext) -> Bool {
        !context.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func appMatches(_ app: AltStoreSourceApp, lowercasedQuery: String) -> Bool {
        if app.name.lowercased().contains(lowercasedQuery) {
            return true
        }
        if app.bundleIdentifier.lowercased().contains(lowercasedQuery) {
            return true
        }
        if let developer = app.developerName?.lowercased(), developer.contains(lowercasedQuery) {
            return true
        }
        if let subtitle = app.subtitle?.lowercased(), subtitle.contains(lowercasedQuery) {
            return true
        }
        return false
    }

    private func appsMatching(_ apps: [AltStoreSourceApp], context: SearchContext) -> [AltStoreSourceApp] {
        let query = context.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return apps
        }
        let lower = query.lowercased()
        return apps.filter { appMatches($0, lowercasedQuery: lower) }
    }

    /// Flat cross-source results for the sources segment's
    /// search, in source order.
    private var sourcesSearchResults: [(source: AltStoreSource, app: AltStoreSourceApp)] {
        var results: [(source: AltStoreSource, app: AltStoreSourceApp)] = []
        for item in viewModel.sources {
            guard let source = item.source else { continue }
            for app in appsMatching(source.apps, context: sourcesSearchContext) {
                results.append((source: source, app: app))
            }
        }
        return results
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
        // No tab jump and no delay (Ann 2026-11-25): the install
        // queue runs fine from any tab, the replace prompt is a
        // global UIKit alert now, and the row's own button turns
        // into the progress ring — the user stays on the source.
        var payload: [String: Any] = ["url": downloadURL, "autoReplace": autoReplace, "name": app.name, "bundleID": app.bundleIdentifier]
        if let iconURL = app.iconURL {
            payload["iconURL"] = iconURL
        }
        if let versionString = (version ?? app.latestVersion)?.version {
            payload["version"] = versionString
        }
        NotificationCenter.default.post(name: NSNotification.InstallAppNotification, object: payload)
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
