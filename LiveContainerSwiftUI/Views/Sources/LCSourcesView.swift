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
    /// The little reminder bar's current showing (Ann
    /// 2026-11-27): ignore / unignore / prioritize /
    /// cancel-download confirm themselves up here, the
    /// operations whose own rows barely change when they
    /// land. One at a time; a new one replaces the old
    /// and restarts the three-second clock.
    @State private var activeToast: LCSourceToastData?
    @State private var toastDismissTask: Task<Void, Never>?
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
    /// The sources segment's filter chip (Ann 2026-11-26,
    /// second redesign round): nil shows every source's
    /// apps flat; a source's URL shows only that source.
    /// Session-only — the segment opens on all sources.
    @State private var selectedSourceChip: URL?
    /// The all-sources flat list's own sort (the sort
    /// button edits this while the all chip is active;
    /// a single source's list uses its per-source mode).
    @AppStorage("LCSourceAppSortAll") private var allSourcesSortRaw: String = LCSourceAppSort.sourceOrder.rawValue
    @State private var isManagingSources = false
    @State private var selectedSegment = 0
    @State private var ignoreTick = 0

    @EnvironmentObject private var sharedModel : SharedModel
    @EnvironmentObject private var downloadHelper: DownloadHelper
    @ObservedObject private var downloadStore = LCDownloadStore.shared

    /// Downloads-segment count, matching what the downloads
    /// page shows: the in-flight record is hidden there (Ann
    /// 2026-11-27), so it is not counted here either.
    private var visibleDownloadCount: Int {
        downloadStore.packages.filter { record in
            !(downloadHelper.isDownloading && record.id == downloadHelper.activeRecordID)
        }.count
    }

    /// Total number of apps across all enabled sources
    /// (the sources tab's count; switched-off sources
    /// don't count, Ann 2026-11-26).
    private var totalSourceAppsCount: Int {
        viewModel.enabledSources.reduce(0) { $0 + ($1.source?.apps.count ?? 0) }
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
                    if viewModel.isRefreshingAll || (refreshTargetItem?.isLoading ?? false) {
                        ProgressView()
                    } else if let item = refreshTargetItem {
                        Button("lc.sources.refresh".loc, systemImage: "arrow.clockwise") {
                            Task { await viewModel.refreshSource(item) }
                        }
                    } else {
                        Button("lc.sources.refreshAll".loc, systemImage: "arrow.clockwise") {
                            Task { await viewModel.refreshAllSources() }
                        }
                    }
                }
                // The tweaks page's top-right pair, copied
                // over (Ann 2026-11-27: she compared the
                // two pages on device — the tweaks pair
                // renders at the standard size she wants,
                // while this page's add button read larger
                // in the shared pill — so the pair's whole
                // construction moves here, with the sort
                // menu standing in the signature button's
                // slot). Same shape as LCTweaksView: two
                // separate trailing items, each a Label-
                // labelled control at the default size,
                // system spacing, no shared pill. The sort
                // item mirrors the signature item's inside
                // conditional too: it only has content on
                // the sources segment — updates and
                // downloads have nothing to sort, leaving
                // the add button alone. The toolbar never
                // scrolls, so the menu's anchor stays out
                // of the scroll flow and cannot drift.
                ToolbarItem(placement: .topBarTrailing) {
                    if selectedSegment == 0, !viewModel.enabledSources.isEmpty {
                        sortMenuButton
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isManagingSources = true
                    } label: {
                        Label("lc.sources.addSource".loc, systemImage: "plus")
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
            // A removed source's chip falls back to all.
            if let selectedSourceChip,
               !newSources.contains(where: { $0.id == selectedSourceChip }) {
                self.selectedSourceChip = nil
            }
        }
        .onChange(of: viewModel.disabledSourceURLs) { _ in
            // A switched-off source's chip falls back to all.
            if let selectedSourceChip,
               !viewModel.enabledSources.contains(where: { $0.id == selectedSourceChip }) {
                self.selectedSourceChip = nil
            }
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .sources, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallPrioritizeJobNotification)) { obj in
            // The row menu posts this to the queue; the
            // reminder answers it here (Ann 2026-11-27).
            if let bundleID = obj.object as? String, let name = appName(forBundleID: bundleID) {
                showToast(.success, "lc.sources.toast.prioritized %@".localizeWithFormat(name))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallCancelJobNotification)) { obj in
            if let bundleID = obj.object as? String, let name = appName(forBundleID: bundleID) {
                showToast(.success, "lc.sources.toast.cancelled %@".localizeWithFormat(name))
            }
        }
        .overlay(alignment: .top) {
            if let activeToast {
                LCSourceToastView(toast: activeToast) {
                    activeToast.undo?()
                    dismissToast()
                }
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: activeToast?.id)
    }

    // MARK: - Reminder bar

    private func showToast(_ kind: LCToastKind, _ message: String, undo: (() -> Void)? = nil) {
        let toast = LCSourceToastData(kind: kind, message: message, undo: undo)
        activeToast = toast
        toastDismissTask?.cancel()
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, activeToast?.id == toast.id else { return }
            activeToast = nil
        }
    }

    private func dismissToast() {
        toastDismissTask?.cancel()
        activeToast = nil
    }

    /// App display name for a bundle id, for the reminder
    /// texts that start life as a bare bundle id (the
    /// queue notifications carry nothing else).
    private func appName(forBundleID bundleID: String) -> String? {
        for item in viewModel.sources {
            guard let source = item.source else { continue }
            if let app = source.apps.first(where: { $0.bundleIdentifier == bundleID }) {
                return app.name
            }
        }
        return nil
    }

    /// The segment picker, riding as the first row of
    /// whichever segment is showing (see the note in body).
    @ViewBuilder
    private var segmentPicker: some View {
        if !viewModel.sources.isEmpty || downloadStore.count > 0 {
            Picker("lc.sources.segment".loc, selection: $selectedSegment) {
                Text("lc.sources.segment.software".loc).tag(0)
                Text("lc.sources.segment.updatesWithCount".localizeWithFormat(updatableApps.count)).tag(1)
                Text("lc.sources.segment.downloadsWithCount".localizeWithFormat(visibleDownloadCount)).tag(2)
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
    /// bar's geometry never changes. Browsing is filtered
    /// by the chips row (Ann 2026-11-26, second redesign
    /// round): the all chip flattens every source into one
    /// card list, a source's chip shows only that source —
    /// and every card carries its source badge either way
    /// (Ann 2026-11-27: always, no exceptions). The
    /// chips and rows are direct children of the
    /// LazyVStack, so rows and icons load as they scroll
    /// into view and there is no per-source app cap.
    private var sourcesScrollView: some View {
        LCSegmentShell(searchContext: sourcesSearchContext) {
            segmentPicker
        } content: {
            if viewModel.sources.isEmpty {
                emptySourcesView
                    .padding(.top, 48)
            } else if viewModel.enabledSources.isEmpty {
                Text("lc.sources.allDisabled".loc)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                    .padding(.horizontal)
            } else if isFiltering(sourcesSearchContext) {
                sourcesSearchResultsRows
            } else {
                sourcesChipsRow
                if let item = selectedChipItem {
                    sourceErrorCard(item: item)
                    if let source = item.source {
                        let apps = displayedApps(source.apps, for: item)
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
                } else if allSourcesSortMode == .recentlyUpdated {
                    // Date order mixes every source's apps
                    // into one stream, so the error cards
                    // have no home inside it and ride on
                    // top, as before.
                    ForEach(viewModel.enabledSources, id: \.id) { item in
                        sourceErrorCard(item: item)
                    }
                    ForEach(allSourcesApps, id: \.app.id) { pair in
                        sourceAppBanner(app: pair.app, source: pair.source, inUpdatesTab: false)
                            .padding(.horizontal)
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
                } else {
                    // Source order: each source's error card
                    // sits with its own apps instead of all
                    // the cards piling up at the top of the
                    // list (Ann 2026-11-27 audit).
                    ForEach(viewModel.enabledSources, id: \.id) { item in
                        sourceErrorCard(item: item)
                        if let source = item.source {
                            ForEach(source.apps) { app in
                                sourceAppBanner(app: app, source: source, inUpdatesTab: false)
                                    .padding(.horizontal)
                            }
                        }
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
    }

    /// The toolbar's sort menu: edits the selected
    /// chip's source, or the flat list's mode while the
    /// all chip is active — the same wiring the button
    /// used in the chips row before it moved up (Ann
    /// 2026-11-27). A selected source that has not
    /// loaded (or failed) offers no sort, as before.
    @ViewBuilder
    private var sortMenuButton: some View {
        if let item = selectedChipItem {
            if item.source != nil {
                LCSourceSortMenuButton(
                    sortMode: sortMode(for: item),
                    onSortModeChange: { setSortMode($0, for: item) }
                )
            }
        } else {
            LCSourceSortMenuButton(
                sortMode: allSourcesSortMode,
                onSortModeChange: { allSourcesSortRaw = $0.rawValue }
            )
        }
    }

    /// The filter chips (Ann 2026-11-26, second round):
    /// all sources + one chip per source, scrolling
    /// sideways, the whole row theirs since the sort
    /// button moved into the toolbar as its own item
    /// beside the add button (Ann 2026-11-27). (A
    /// per-source refresh / remove menu
    /// briefly lived here too; Ann removed it the same
    /// evening — removal lives in Manage Sources, and
    /// the toolbar refresh turns single-source while a
    /// chip is selected.) Global refresh and add-source
    /// stay in the toolbar, as before.
    @ViewBuilder
    private var sourcesChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sourceChip(title: "lc.sources.chip.allSources".loc, count: totalSourceAppsCount, iconURL: nil, systemImage: "square.grid.2x2", isSelected: selectedSourceChip == nil) {
                    selectedSourceChip = nil
                }
                ForEach(viewModel.enabledSources, id: \.id) { item in
                    sourceChip(title: item.source?.name ?? item.displayName, count: item.source?.apps.count ?? 0, iconURL: item.primaryIconURL, systemImage: nil, isSelected: selectedSourceChip == item.id) {
                        selectedSourceChip = item.id
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .padding(.horizontal)
    }

    private func sourceChip(title: String, count: Int, iconURL: URL?, systemImage: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let iconURL {
                    SourceIconView(url: iconURL)
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                // The count moved here from the segment
                // button (Ann 2026-11-26): each chip
                // carries its own number — the all-sources
                // chip the grand total, a source's chip
                // that source's app count.
                Text("(\(count))")
                    .font(.system(size: 13))
                    .opacity(0.7)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(isSelected ? Color.accentColor : Color(uiColor: UIColor.secondarySystemBackground)))
            .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    /// The source behind the active chip, if any.
    private var selectedChipItem: AltStoreSourcesViewModel.SourceItem? {
        guard let selectedSourceChip else { return nil }
        return viewModel.enabledSources.first { $0.id == selectedSourceChip }
    }

    /// The toolbar refresh button's single-source target
    /// (Ann 2026-11-26, her pick over a chip long-press
    /// menu): while the sources segment is showing one
    /// source's chip, the button refreshes just that
    /// source; in all-sources mode and on the other
    /// segments it refreshes every enabled source.
    private var refreshTargetItem: AltStoreSourcesViewModel.SourceItem? {
        guard selectedSegment == 0 else { return nil }
        // While searching, the chips row is covered by the
        // results and the user cannot see which chip is
        // selected — a refresh then means "everything on
        // screen", so it refreshes all sources (Ann
        // 2026-11-27 audit).
        guard !isFiltering(sourcesSearchContext) else { return nil }
        return selectedChipItem
    }

    /// A failed source's error card, shown wherever its
    /// apps would have been listed. Two wordings (Ann
    /// 2026-11-27 audit): a source with nothing loaded is
    /// a plain failure; a source still showing its last
    /// good load says so, so the stale rows below it are
    /// not mistaken for fresh ones.
    @ViewBuilder
    private func sourceErrorCard(item: AltStoreSourcesViewModel.SourceItem) -> some View {
        if let error = item.error {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.source == nil ? "lc.sources.section.error".loc : "lc.sources.section.errorStale".loc)
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
        }
    }

    /// Every loaded source's apps as one flat list, in
    /// source order — or, when the flat list's sort says
    /// so, everything interleaved by latest release date
    /// (the sort is stable, so same-date apps keep source
    /// order).
    private var allSourcesApps: [(source: AltStoreSource, app: AltStoreSourceApp)] {
        var pairs: [(source: AltStoreSource, app: AltStoreSourceApp)] = []
        for item in viewModel.enabledSources {
            guard let source = item.source else { continue }
            for app in source.apps {
                pairs.append((source: source, app: app))
            }
        }
        if allSourcesSortMode == .recentlyUpdated {
            pairs.sort { a, b in
                (a.app.latestVersion?.releaseDate ?? .distantPast) > (b.app.latestVersion?.releaseDate ?? .distantPast)
            }
        }
        return pairs
    }

    private var allSourcesSortMode: LCSourceAppSort {
        LCSourceAppSort(rawValue: allSourcesSortRaw) ?? .sourceOrder
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
                sourceAppBanner(app: pair.app, source: pair.source, inUpdatesTab: false)
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
                    // The count is the unignored count, the
                    // badge's own yardstick (Ann 2026-11-27):
                    // the button used to promise every row
                    // in the list, ignored ones included,
                    // while the badge counted fewer.
                    Text("lc.sources.updateAll %lld".localizeWithFormat(updateBadgeCount))
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
                // Every row ignored: nothing to update, so
                // the button rests instead of spinning on
                // an empty list.
                .disabled(updateBadgeCount == 0)
                .opacity(updateBadgeCount == 0 ? 0.5 : 1)

                ForEach(updatableApps, id: \.app.id) { pair in
                    sourceAppBanner(app: pair.app, source: pair.source, inUpdatesTab: true)
                        .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - Row construction

    /// The button state for an app, computed fresh on
    /// every call: the detail page asks again each time
    /// it renders (and again when its button is tapped),
    /// so installing from the detail page flips its
    /// button to Open instead of leaving the snapshot
    /// taken when the page was opened (Ann 2026-11-26
    /// audit).
    private func currentButtonState(for app: AltStoreSourceApp, inUpdatesTab: Bool) -> LCSourceAppButtonState {
        let installed = installedModel(for: app.bundleIdentifier)
        let update = hasUpdate(for: app)
        let ignored = LCSourceUpdateIgnore.isIgnored(app: app)
        guard installed != nil else { return .get }
        guard update else { return .open }
        // An ignored update (Ann 2026-11-27): on the
        // sources segment the row rests at Open; on the
        // updates segment it shows an Ignored button whose
        // tap lifts the ignore and turns it back to Update.
        if ignored {
            return inUpdatesTab ? .ignored : .open
        }
        return .update
    }

    @ViewBuilder
    private func sourceAppBanner(app: AltStoreSourceApp, source: AltStoreSource, inUpdatesTab: Bool) -> some View {
        let update = hasUpdate(for: app)
        let ignored = LCSourceUpdateIgnore.isIgnored(app: app)
        LCSourceAppBanner(
            app: app,
            source: source,
            buttonState: currentButtonState(for: app, inUpdatesTab: inUpdatesTab),
            liveState: { currentButtonState(for: app, inUpdatesTab: inUpdatesTab) },
            action: {
                switch currentButtonState(for: app, inUpdatesTab: inUpdatesTab) {
                case .open:
                    launchInstalledApp(app)
                case .get, .update:
                    install(app: app)
                case .ignored:
                    unignoreUpdate(for: app)
                }
            },
            copyAction: { copyLatestDownloadURL(app) },
            ignoreAction: (update && !ignored) ? { ignoreUpdate(for: app) } : nil,
            unignoreAction: (update && ignored) ? { unignoreUpdate(for: app) } : nil,
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
    /// first-appearance order. Ignored versions stay in this list —
    /// the updates segment shows them with an Ignored button — but
    /// the badge count and Update All skip them (Ann 2026-11-27).
    var updatableApps: [(source: AltStoreSource, app: AltStoreSourceApp)] {
        _ = ignoreTick
        // One lookup table per evaluation instead of a
        // linear scan of the installed list for every app
        // in every source (Ann 2026-11-26 audit): this is
        // re-evaluated on every render pass — the segment
        // picker, the updates list and the badge count all
        // ask — and sources now hold hundreds of apps.
        let installedByBundle = Dictionary(
            (sharedModel.apps + sharedModel.hiddenApps).map { ($0.appInfo.bundleIdentifier(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var bestByBundle: [String: (source: AltStoreSource, app: AltStoreSourceApp)] = [:]
        var order: [String] = []
        for item in viewModel.enabledSources {
            guard let source = item.source else { continue }
            for app in source.apps {
                guard let latest = app.latestVersion,
                      let installed = installedByBundle[app.bundleIdentifier],
                      lcIsVersion(latest.version, newerThan: installed.version) else { continue }
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

    func ignoreUpdate(for app: AltStoreSourceApp, announce: Bool = true) {
        guard let version = app.latestVersion?.version else { return }
        LCSourceUpdateIgnore.setIgnoredVersion(version, for: app.bundleIdentifier)
        ignoreTick += 1
        // The reminder bar confirms it, with an undo
        // (Ann 2026-11-27): the undo itself stays quiet,
        // it just puts things back.
        if announce {
            showToast(.success, "lc.sources.toast.ignored %@".localizeWithFormat(app.name)) {
                unignoreUpdate(for: app, announce: false)
            }
        }
    }

    /// Lifts an ignore (Ann 2026-11-27): offered by the
    /// updates segment's Ignored button and by either
    /// segment's long-press menu.
    func unignoreUpdate(for app: AltStoreSourceApp, announce: Bool = true) {
        LCSourceUpdateIgnore.setIgnoredVersion(nil, for: app.bundleIdentifier)
        ignoreTick += 1
        if announce {
            showToast(.success, "lc.sources.toast.unignored %@".localizeWithFormat(app.name)) {
                ignoreUpdate(for: app, announce: false)
            }
        }
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
        // Ignored versions are skipped (Ann 2026-11-27):
        // ignoring means "not this one", and Update All
        // used to steamroll straight over it.
        let items: [[String: Any]] = updatableApps.filter { !LCSourceUpdateIgnore.isIgnored(app: $0.app) }.compactMap { entry in
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
        for item in viewModel.enabledSources {
            guard let source = item.source else { continue }
            for app in appsMatching(source.apps, context: sourcesSearchContext) {
                results.append((source: source, app: app))
            }
        }
        return results
    }

    /// Adds a source and hands back the failure text, if
    /// any (Ann 2026-11-27 audit): the Manage Sources
    /// sheet shows it inline under its input, while the
    /// deep-link path turns it into the page's alert.
    @MainActor
    private func handleAddSource(_ rawValue: String) async -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "lc.sources.error.invalidUrl".loc }
        return await viewModel.addSource(from: trimmed)
    }
    
    @MainActor
    private func install(app: AltStoreSourceApp, version: AltStoreSourceAppVersion? = nil) {
        guard let downloadURL = (version ?? app.latestVersion)?.downloadURL else {
            errorMessage = "lc.sources.error.missingDownload".loc
            return
        }
        // A complete copy of exactly this version already
        // in the downloads library installs from disk
        // instead of downloading again (Ann 2026-11-27
        // audit): the main button's cloud form only covers
        // the latest version, so the version list's
        // Install used to re-download a package the
        // library already held.
        if let versionString = (version ?? app.latestVersion)?.version,
           let stored = LCDownloadStore.shared.packages.first(where: { $0.isComplete && $0.bundleID == app.bundleIdentifier && $0.version == versionString }) {
            NotificationCenter.default.post(name: NSNotification.InstallLocalFileNotification, object: LCDownloadStore.shared.fileURL(for: stored))
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
                    Task {
                        if let error = await handleAddSource(sourceUrl) {
                            errorMessage = error
                        }
                    }
                }
            }
        }
    }
}
