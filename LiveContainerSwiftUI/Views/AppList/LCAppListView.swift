//
//  ContentView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

class SearchContext: ObservableObject {
    @Published var query: String = ""
    @Published var debouncedQuery: String = ""
    @Published var isTyping: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        $query
            .debounce(for: .seconds(0.2), scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isTyping = true
                self?.debouncedQuery = value
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.isTyping = false
                }
            }
            .store(in: &cancellables)
    }
}

struct AppReplaceOption : Hashable {
    var isReplace: Bool
    var nameOfFolderToInstall: String
    var appToReplace: LCAppModel?
}

/// Red close badge shown on running apps (list and grid). Drawn as a real
/// circle shape rather than an SF Symbol so the visible circle is exactly
/// `size` wide and its center lands precisely where it is positioned —
/// callers place it like the iOS home screen's numeric badges, its center
/// a quarter of its diameter inside the icon's top-right corner, treating
/// the icon as a square.
struct LCRunningCloseBadge: View {
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.red)
                Image(systemName: "xmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// One unit of install work for the serial install pipeline.
/// Every install entry point (source install, update-all, manual
/// URL, itms-services plist, picked IPA file) enqueues a job here
/// instead of installing directly, and a single processor drains
/// the queue one job at a time — so a request that arrives while
/// another install is running waits its turn instead of being
/// silently dropped by the old busy gate (Ann 2026-11-24).
enum InstallJob {
    case url(urlStr: String, name: String?, iconURL: URL?, autoReplace: Bool, bundleID: String?, version: String?)
    case file(URL)

    /// Identity used to drop duplicate requests (e.g. update-all
    /// tapped twice): the same URL or file is never queued twice.
    var dedupeKey: String {
        switch self {
        case .url(let urlStr, _, _, _, _, _):
            return "url:\(urlStr)"
        case .file(let fileUrl):
            return "file:\(fileUrl.path)"
        }
    }

    /// Human-readable name for progress and the batch summary.
    var displayName: String {
        switch self {
        case .url(let urlStr, let name, _, _, _, _):
            return name ?? URL(string: urlStr)?.lastPathComponent ?? urlStr
        case .file(let fileUrl):
            return fileUrl.lastPathComponent
        }
    }
}

struct LCAppListView : View, LCAppBannerDelegate, LCAppModelDelegate {
    @State var didAppear = false
    // ipa choosing stuff
    @State var choosingIPA = false
    @State var errorShow = false
    @State var errorInfo = ""
    
    // ipa installing stuff
    @State var installprogressVisible = false
    // (install progress percentage lives on DownloadHelper now —
    // see LCDownloadView.swift)
    @State var installObserver : NSKeyValueObservation?

    // serial install queue (used by the sources page's "update all")
    @State var installQueue: [InstallJob] = []
    @State var currentInstallJobKey: String? = nil
    // Per-session tallies for the end-of-batch summary: errors a
    // job raises are collected instead of popping one alert per
    // failure while the queue is still running.
    @State var sessionTotalJobs = 0
    @State var sessionFailures: [(jobKey: String, name: String, error: String)] = []
    @State var sessionSuccesses: [(name: String, isUpdate: Bool, version: String?, bundleID: String?)] = []
    @State var sessionWasCancelled = false
    @State var batchSummaryShow = false
    @State var batchSummaryText = ""
    @State var isInstallQueueRunning = false
    // when true, the next install silently replaces the same-bundle app
    // instead of asking which bundle to replace
    @State var autoReplaceNextInstall = false

    @State var installOptions: [AppReplaceOption]
    @StateObject var installReplaceAlert = AlertHelper<AppReplaceOption>()
    
    @State var webViewOpened = false
    @State var webViewURL : URL = URL(string: "about:blank")!
    @StateObject private var webViewUrlInput = InputHelper()
    
    @EnvironmentObject var downloadHelper: DownloadHelper
    @StateObject private var installUrlInput = InputHelper()
    
    @State private var jitLog = ""
    @StateObject private var jitAlert = YesNoHelper()
    
    @StateObject private var runWhenMultitaskAlert = YesNoHelper()
    
    @StateObject private var generatedIconStyleSelector = AlertHelper<GeneratedIconStyle>()
    
    @State var safariViewOpened = false
    @State var safariViewURL = URL(string: "https://google.com")!
    
    @State private var navigateTo : AnyView?
    @State private var isNavigationActive = false
    
    @State private var helpPresent = false
    
    @State private var customSortViewPresent = false

    @State private var gridSettingsPresent = false
    @State private var runningAppsTick = 0

    @AppStorage("LCAppListGridMode", store: LCUtils.appGroupUserDefault) private var gridMode = false
    @AppStorage("LCAppGridColumns", store: LCUtils.appGroupUserDefault) private var gridColumns = 5
    @AppStorage("LCAppGridIconSize", store: LCUtils.appGroupUserDefault) private var gridIconSize = 0

    @EnvironmentObject private var sharedModel : SharedModel
    @EnvironmentObject private var sharedAppSortManager : LCAppSortManager
    
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    
    @State private var isViewAppeared = false
    
    // StateObject for the same reason as in LCSourcesView: an
    // ObservedObject with a default instance is replaced whenever
    // the parent re-creates this view, wiping the search query.
    @StateObject private var searchContext = SearchContext()
    var sortedApps: [LCAppModel] {
        return sharedAppSortManager.sortedApps
    }
    
    var sortedHiddenApps: [LCAppModel] {
        return sharedAppSortManager.sortedHiddenApps
    }
    
    var filteredApps: [LCAppModel] {
        let apps = sortedApps
        if searchContext.debouncedQuery.isEmpty {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    var filteredHiddenApps: [LCAppModel] {
        let apps = sortedHiddenApps
        if searchContext.debouncedQuery.isEmpty || !sharedModel.isHiddenAppUnlocked {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    init() {
        _installOptions = State(initialValue: [])
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                NavigationLink(
                    destination: navigateTo,
                    isActive: $isNavigationActive,
                    label: {
                        EmptyView()
                })
                .hidden()
                
                appCollection(apps: filteredApps)
                .padding()
                .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredApps)

                VStack {
                    if LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                        if sharedModel.isHiddenAppUnlocked {
                            VStack {
                                HStack {
                                    Text("lc.appList.hiddenApps".loc)
                                        .font(.system(.title2).bold())
                                    Spacer()
                                }

                                appCollection(apps: filteredHiddenApps)

                            }
                            .padding()
                            .transition(.opacity)
                            .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredHiddenApps)
                            
                            if sharedModel.hiddenApps.count == 0 {
                                Text("lc.appList.hideAppTip".loc)
                                    .foregroundStyle(.gray)
                            }
                        }
                    } else if sharedModel.hiddenApps.count > 0 {
                        VStack {
                            HStack {
                                Text("lc.appList.hiddenApps".loc)
                                    .font(.system(.title2).bold())
                                Spacer()
                            }
                            if sharedModel.isHiddenAppUnlocked {
                                appCollection(apps: filteredHiddenApps)
                            } else if gridMode {
                                LazyVGrid(columns: gridLayoutColumns, spacing: 12) {
                                    ForEach(filteredHiddenApps, id: \.self) { _ in
                                        LCAppGridSkeletonCell()
                                    }
                                }
                                .onTapGesture {
                                    Task { await authenticateUser() }
                                }
                            } else {
                                LazyVStack {
                                    ForEach(filteredHiddenApps, id: \.self) { _ in
                                        LCAppSkeletonBanner()
                                    }
                                }
                                .onTapGesture {
                                    Task { await authenticateUser() }
                                }
                            }
                        }
                        .animation(.easeInOut, value: sharedModel.isHiddenAppUnlocked)
                        .padding()
                        .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredHiddenApps)
                    }

                    let appCount = sharedModel.isHiddenAppUnlocked ? filteredApps.count + filteredHiddenApps.count : filteredApps.count
                    Text(appCount > 0 || searchContext.debouncedQuery != "" ? "lc.appList.appCounter %lld".localizeWithFormat(appCount) : (sharedModel.multiLCStatus == 2 ? "lc.appList.convertToSharedToShowInLC2".loc : "lc.appList.installTip".loc))
                        .padding(.horizontal)
                        .foregroundStyle(.gray)
                        .animation(searchContext.isTyping ? nil : .easeInOut, value: appCount)
                        .onTapGesture(count: 3) {
                            Task { await authenticateUser() }
                        }
                }.animation(searchContext.isTyping ? nil : .easeInOut, value: LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding"))

                if sharedModel.multiLCStatus == 2 {
                    Text("lc.appList.manageInPrimaryTip".loc).foregroundStyle(.gray).padding()
                }

            }
            .navigationBarProgressBar(show:$installprogressVisible, progress: $downloadHelper.installProgressPercentage)
            .coordinateSpace(name: "scroll")
            .onAppear {
                if !didAppear {
                    onAppear()
                }
            }
            
            .navigationTitle("lc.appList.myApps".loc)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if sharedModel.multiLCStatus != 2 {
                        if !installprogressVisible {
                            Menu {
                                
                                Button("lc.appList.installFromIpa".loc, systemImage: "doc.badge.plus", action: {
                                    choosingIPA = true
                                })
                                Button("lc.appList.installFromUrl".loc, systemImage: "link.badge.plus", action: {
                                    Task{ await startInstallFromUrl() }
                                })
                            } label: {
                                Label("add", systemImage: "plus")
                            }
                            
                        } else {
                            ProgressView().progressViewStyle(.circular).padding(.horizontal, 8)
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if(UserDefaults.sideStoreExist()) {
                        Button {
                            LCUtils.openSideStore(delegate: self)
                        } label: {
                            IconImageView(icon: BuiltInSideStoreAppInfo.shared.iconIsDarkIcon(darkModeIcon))
                                .frame(width: UIFont.preferredFont(forTextStyle: .body).lineHeight, height: UIFont.preferredFont(forTextStyle: .body).lineHeight)

                        }
                    } else {
                        Button("Help", systemImage: "questionmark") {
                            helpPresent = true
                        }
                    }
                    

                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.appList.openLink".loc, systemImage: "link", action: {
                        Task { await onOpenWebViewTapped() }
                    })
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort by", selection: $sharedAppSortManager.appSortType) {
                            ForEach(AppSortType.allCases, id: \.self) { sortType in
                                Label(sortType.displayName, systemImage: sortType.systemImage)
                                    .tag(sortType)
                            }
                        }
                        .onChange(of: sharedAppSortManager.appSortType) { newValue in
                            if sharedAppSortManager.appSortType == .custom {
                                customSortViewPresent = true
                            }
                        }
                        if sharedAppSortManager.appSortType == .custom {
                            Divider()

                            Button {
                                customSortViewPresent = true
                            } label: {
                                Label("lc.appList.sort.customManage".loc, systemImage: "slider.horizontal.3")
                            }
                        }
                        Divider()

                        Button {
                            gridMode.toggle()
                        } label: {
                            Label(gridMode ? "lc.appList.layout.list".loc : "lc.appList.layout.grid".loc, systemImage: gridMode ? "list.bullet" : "square.grid.2x2")
                        }
                        if gridMode {
                            Button {
                                gridSettingsPresent = true
                            } label: {
                                Label("lc.appList.gridSettings".loc, systemImage: "square.grid.3x3.square")
                            }
                        }
                    } label: {
                        Label("Sort by", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .alert("lc.common.error".loc, isPresented: Binding(
            // While the install queue is running, error alerts are
            // held back and collected by the processor — one alert
            // per failed download in a batch was a popup storm.
            // They surface once when the session ends (see
            // reportSessionResults).
            get: { errorShow && !isInstallQueueRunning },
            set: { errorShow = $0 }
        )){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .alert("lc.install.batchSummary.title".loc, isPresented: $batchSummaryShow) {
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                UIPasteboard.general.string = batchSummaryText
            })
        } message: {
            Text(batchSummaryText)
        }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
            enqueueInstall(.file(fileUrls[0]))
        }, onDismiss: {
            choosingIPA = false
        })
        .alert("lc.appList.installation".loc, isPresented: $installReplaceAlert.show) {
            ForEach(installOptions, id: \.self) { installOption in
                Button(role: installOption.isReplace ? .destructive : nil, action: {
                    installReplaceAlert.close(result: installOption)
                }, label: {
                    Text(installOption.isReplace ? installOption.nameOfFolderToInstall : "lc.appList.installAsNew".loc)
                })
            
            }
            Button(role: .cancel, action: {
                installReplaceAlert.close(result: nil)
            }, label: {
                Text("lc.appList.abortInstallation".loc)
            })
        } message: {
            Text("lc.appList.installReplaceTip".loc)
        }
        .alert("lc.webView.runApp".loc, isPresented: $runWhenMultitaskAlert.show) {
            Button(role: .destructive) {
                runWhenMultitaskAlert.close(result: true)
            } label: {
                Text("lc.common.continue".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                runWhenMultitaskAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.confirmRunWhenMultitasking".loc)
        }
        .alert("lc.appList.generatedIconStyleSelector.title".loc, isPresented:$generatedIconStyleSelector.show) {
            Button {
                generatedIconStyleSelector.close(result: .Light)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.light".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Dark)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.dark".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Original)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.original".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                generatedIconStyleSelector.close(result: nil)
            }
        }
        .textFieldAlert(
            isPresented: $webViewUrlInput.show,
            title:  "lc.appList.enterUrlTip".loc,
            text: $webViewUrlInput.initVal,
            placeholder: "scheme://",
            action: { newText in
                webViewUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                webViewUrlInput.close(result: nil)
            }
        )
        .textFieldAlert(
            isPresented: $installUrlInput.show,
            title:  "lc.appList.installUrlInputTip".loc,
            text: $installUrlInput.initVal,
            placeholder: "https://",
            action: { newText in
                installUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                installUrlInput.close(result: nil)
            }
        )
        .sheet(isPresented: $jitAlert.show, onDismiss: {
            jitAlert.close(result: false)
        }) {
            JITEnablingModal
        }
        .onChange(of: jitAlert.show) { newValue in
            sharedModel.isJITModalOpen = newValue
        }
        .fullScreenCover(isPresented: $webViewOpened) {
            LCWebView(url: $webViewURL, isPresent: $webViewOpened, itmsServicesHandler: { urlStr in
                await installFromPlist(urlStr: urlStr)
            })
        }
        .fullScreenCover(isPresented: $safariViewOpened) {
            SafariView(url: $safariViewURL)
        }
        .sheet(isPresented: $helpPresent) {
            LCHelpView(isPresent: $helpPresent)
        }
        .sheet(isPresented: $customSortViewPresent) {
            LCCustomSortView()
        }
        .sheet(isPresented: $gridSettingsPresent) {
            LCAppGridSettingsView()
        }
        .onAppear() {
            if !isViewAppeared {
                if let webpageUrlStr = UserDefaults.standard.string(forKey: "webPageToOpen") {
                    Task { await openWebView(urlString: webpageUrlStr) }
                    UserDefaults.standard.set(nil, forKey: "webPageToOpen")
                }
                
                guard sharedModel.selectedTab == .apps, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .apps, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
        .onDrop(of: [.url], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url else { return }
                Task {
                    guard let urlToOpen = await webViewUrlInput.open(initVal: url.absoluteString), urlToOpen != "" else {
                        return
                    }
                    await openWebView(urlString: urlToOpen)
                }
            }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.MultitaskRunningAppsChanged)) { _ in
            runningAppsTick += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallAppNotification)) { obj in
            if let obj2 = obj.object as? [String: Any], let installUrl = obj2["url"] as? URL {
                let autoReplace = obj2["autoReplace"] as? Bool ?? false
                enqueueInstall(.url(urlStr: installUrl.absoluteString, name: obj2["name"] as? String, iconURL: obj2["iconURL"] as? URL, autoReplace: autoReplace, bundleID: obj2["bundleID"] as? String, version: obj2["version"] as? String))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallAppQueueNotification)) { obj in
            if let obj2 = obj.object as? [String: Any], let items = obj2["items"] as? [[String: Any]] {
                for item in items {
                    guard let url = item["url"] as? URL else { continue }
                    enqueueInstall(.url(urlStr: url.absoluteString, name: item["name"] as? String, iconURL: item["iconURL"] as? URL, autoReplace: true, bundleID: item["bundleID"] as? String, version: item["version"] as? String))
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallCancelAllNotification)) { _ in
            // The user cancelled from the download capsule: drop
            // everything still waiting. The running job aborts
            // itself through DownloadHelper's cancelled flag.
            installQueue.removeAll()
            downloadHelper.queuedInstallCount = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.ShowInstallSummaryNotification)) { _ in
            // Tapped on the batch-with-failures success card.
            if !batchSummaryText.isEmpty {
                batchSummaryShow = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.OpenInstalledAppNotification)) { obj in
            // The success card's Open button.
            if let bundleID = obj.object as? String {
                Task { await launchAppWithBundleId(bundleId: bundleID, container: nil) }
            }
        }
        .searchable(text: $searchContext.query)

    }
    
    var JITEnablingModal : some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    Text("lc.appBanner.waitForJitMsg".loc)
                        .padding(.vertical)
                        .id(0)
                    
                    HStack {
                        Text(jitLog)
                            .font(.system(size: 12).monospaced())
                            .fixedSize(horizontal: false, vertical: false)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .onAppear {
                    proxy.scrollTo(0)
                }
            }
            .navigationTitle("lc.appBanner.waitForJitTitle".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.cancel".loc, role: .cancel) {
                        jitAlert.close(result: false)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        jitAlert.close(result: true)
                    } label: {
                        Text("lc.appBanner.jitLaunchNow".loc)
                    }
                }
            }
        }
    }
    
    func onOpenWebViewTapped() async {
        guard let urlToOpen = await webViewUrlInput.open(), urlToOpen != "" else {
            return
        }
        await openWebView(urlString: urlToOpen)
        
    }
    func onAppear() {
        for app in sharedModel.apps {
            app.delegate = self
        }
        for app in sharedModel.hiddenApps {
            app.delegate = self
        }
        didAppear = true
    }

    // MARK: - List / Grid shared content

    var gridLayoutColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: gridColumns)
    }

    @ViewBuilder
    func appCollection(apps: [LCAppModel]) -> some View {
        if gridMode {
            LCAppGridView(apps: apps, columns: gridColumns, iconSize: gridIconSize, darkModeIcon: darkModeIcon, actions: gridActions)
        } else {
            LazyVStack {
                ForEach(apps, id: \.self) { app in
                    appBannerWithClose(app)
                }
                .transition(.scale)
            }
        }
    }

    @ViewBuilder
    func appBannerWithClose(_ app: LCAppModel) -> some View {
        LCAppBanner(appModel: app, delegate: self)
            .overlay(alignment: .topLeading) {
                if isAppRunning(app) {
                    // The banner icon is a 60pt square at x 14, y 14 inside
                    // the 88pt banner, so its top-right corner is (74, 14).
                    // Like the iOS home screen's numeric badges, the badge
                    // center sits a quarter of its diameter inside that
                    // corner (24 * 0.25 = 6): center (68, 20), so the 24pt
                    // badge's top-left lands at (56, 8).
                    LCRunningCloseBadge(size: 24) {
                        closeRunningApp(app)
                    }
                    .offset(x: 56, y: 8)
                }
            }
    }

    func isAppRunning(_ app: LCAppModel) -> Bool {
        _ = runningAppsTick
        guard let container = app.uiSelectedContainer?.folderName else {
            return false
        }
        return MultitaskManager.isUsing(container: container)
    }

    func closeRunningApp(_ app: LCAppModel) {
        guard let container = app.uiSelectedContainer?.folderName else {
            return
        }
        _ = MultitaskManager.terminateApp(container: container)
    }

    var gridActions: LCAppGridActions {
        LCAppGridActions(
            onLaunch: { app, iconRect in gridLaunchApp(app, from: iconRect) },
            onLaunchMultitaskToggle: { app in gridLaunchApp(app, multitask: !(app.shouldLaunchInMultitaskMode)) },
            onOpenSettings: { app in
                openNavigationView(view: AnyView(LCAppSettingsView(model: app)))
            },
            onOpenDataFolder: { app in gridOpenDataFolder(app) },
            onCopyLaunchUrl: { app in gridCopyLaunchUrl(app) },
            onSaveIcon: { app in await gridSaveIcon(app) },
            onCreateAppClip: { app in await gridCreateAppClip(app) },
            onUninstall: { app, deleteData in await gridUninstallApp(app, deleteData: deleteData) },
            onError: { message in
                errorInfo = message
                errorShow = true
            },
            isRunning: { app in isAppRunning(app) },
            onCloseRunning: { app in closeRunningApp(app) }
        )
    }

    func gridLaunchApp(_ app: LCAppModel, multitask: Bool? = nil, from iconRect: CGRect? = nil) {
        // Already running: bring it to the front, exactly like the banner's run button.
        if multitask == nil, #available(iOS 16.0, *),
           let folderName = app.uiSelectedContainer?.folderName,
           MultitaskManager.isUsing(container: folderName) {
            var found = false
            if #available(iOS 16.1, *) {
                found = MultitaskWindowManager.openExistingAppWindow(dataUUID: folderName)
            }
            if !found {
                found = MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: folderName, from: iconRect)
            }
            if found {
                return
            }
        }

        Task {
            if app.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    return
                }
            }

            do {
                try await app.runApp(multitask: multitask)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
        }
    }

    func gridOpenDataFolder(_ app: LCAppModel) {
        guard let folderName = app.uiSelectedContainer?.folderName,
              let url = URL(string: "shareddocuments://\(LCPath.dataPath.path)/\(folderName)") else {
            return
        }
        UIApplication.shared.open(url)
    }

    func gridCopyLaunchUrl(_ app: LCAppModel) {
        guard let relativeBundlePath = app.appInfo.relativeBundlePath else {
            return
        }
        if let folderName = app.uiSelectedContainer?.folderName {
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(relativeBundlePath)&container-folder-name=\(folderName)"
        } else {
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(relativeBundlePath)"
        }
    }

    func gridSaveIcon(_ app: LCAppModel) async {
        guard let style = await promptForGeneratedIconStyle() else {
            return
        }
        do {
            guard let image = app.appInfo.generateLiveContainerWrappedIcon(with: style),
                  let imageData = image.pngData() else {
                throw CocoaError(.fileWriteUnknown)
            }
            let rawDisplayName = app.appInfo.displayName() ?? app.displayName
            let displayName = rawDisplayName.replacingOccurrences(of: "/", with: "_")
            try LCIconExportHelper.exportPNG(imageData: imageData, fileName: "\(displayName) Icon.png")
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    func gridCreateAppClip(_ app: LCAppModel) async {
        guard let style = await promptForGeneratedIconStyle() else {
            return
        }
        do {
            guard let profile = app.appInfo.generateWebClipConfig(
                withContainerId: app.uiSelectedContainer?.folderName,
                iconStyle: style
            ) else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
            installMdm(data: data)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    func gridUninstallApp(_ app: LCAppModel, deleteData: Bool) async {
        do {
            guard let bundlePath = app.appInfo.bundlePath() else {
                throw CocoaError(.fileNoSuchFile)
            }
            let fileManager = FileManager.default
            try fileManager.removeItem(atPath: bundlePath)
            removeApp(app: app)

            if deleteData {
                for container in app.appInfo.containers {
                    let dataUUID = container.folderName
                    try fileManager.removeItem(at: LCPath.dataPath.appendingPathComponent(dataUUID))
                    LCUtils.removeAppKeychain(dataUUID: dataUUID)
                    DataManager.shared.model.appDataFolderNames.removeAll { $0 == dataUUID }
                }
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    
    func openWebView(urlString: String) async {
        guard var urlToOpen = URLComponents(string: urlString), urlToOpen.url != nil else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        if urlToOpen.scheme == nil || urlToOpen.scheme! == "" {
            urlToOpen.scheme = "https"
        }
        
        if urlToOpen.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: urlString)
            return
        }
        
        if urlToOpen.scheme != "https" && urlToOpen.scheme != "http" {
            var appToLaunch : LCAppModel? = nil
            var appListsToConsider = [sharedModel.apps]
            if sharedModel.isHiddenAppUnlocked || !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                appListsToConsider.append(sharedModel.hiddenApps)
            }
            appLoop:
            for appList in appListsToConsider {
                for app in appList {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == urlToOpen.scheme {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
            }


            guard let appToLaunch = appToLaunch else {
                errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(urlToOpen.scheme!)
                errorShow = true
                return
            }
            
            if appToLaunch.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    return
                }
            }
            
            do {
                try await appToLaunch.runApp(urlStr: urlToOpen.url!.absoluteString)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            return
        }
        webViewURL = urlToOpen.url!
        if webViewOpened {
            webViewOpened = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                webViewOpened = true
            })
        } else {
            webViewOpened = true
        }
    }


    
    /// Runs one local-file install job. Only ever called by the
    /// serial queue processor — entry points enqueue instead.
    func performInstallApp(_ fileUrl:URL) async {
        // A local file job is all install phase: stamp the capsule.
        downloadHelper.downloadName = fileUrl.lastPathComponent
        downloadHelper.downloadIconURL = nil
        downloadHelper.isInstallingPhase = true
        do {
            self.installprogressVisible = true
            try await installIpaFile(fileUrl)
            try FileManager.default.removeItem(at: fileUrl)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            self.installprogressVisible = false
        }
    }
    
    nonisolated func decompress(_ path: String, _ destination: String ,_ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }
    
    func installIpaFile(_ url:URL) async throws {
        let fm = FileManager()
        
        let installProgress = Progress.discreteProgress(totalUnitCount: 100)
        self.downloadHelper.installProgressPercentage = 0.0
        self.installObserver = installProgress.observe(\.fractionCompleted) { p, v in
            DispatchQueue.main.async {
                self.downloadHelper.installProgressPercentage = Float(p.fractionCompleted)
            }
        }
        let decompressProgress = Progress.discreteProgress(totalUnitCount: 100)
        installProgress.addChild(decompressProgress, withPendingUnitCount: 80)
        let payloadPath = fm.temporaryDirectory.appendingPathComponent("Payload")
        if fm.fileExists(atPath: payloadPath.path) {
            try fm.removeItem(at: payloadPath)
        }
        
        // decompress
        guard await decompress(url.path, fm.temporaryDirectory.path, decompressProgress) == 0 else {
            throw "lc.appList.urlFileIsNotIpaError".loc
        }

        let payloadContents = try fm.contentsOfDirectory(atPath: payloadPath.path)
        var appBundleName : String? = nil
        for fileName in payloadContents {
            if fileName.hasSuffix(".app") {
                appBundleName = fileName
                break
            }
        }
        guard let appBundleName = appBundleName else {
            throw "lc.appList.bundleNotFondError".loc
        }

        let appFolderPath = payloadPath.appendingPathComponent(appBundleName)
        
        guard let newAppInfo = LCAppInfo(bundlePath: appFolderPath.path) else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }

        var appRelativePath = "\(newAppInfo.bundleIdentifier()!.sanitizeNonACSII()).app"
        var outputFolder = LCPath.bundlePath.appendingPathComponent(appRelativePath)
        var appToReplace : LCAppModel? = nil
        // Folder exist! show alert for user to choose which bundle to replace
        var sameBundleIdApp = sharedModel.apps.filter { app in
            return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
        }
        if sameBundleIdApp.count == 0 {
            sameBundleIdApp = sharedModel.hiddenApps.filter { app in
                return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
            }
            
            // we found a hidden app, we need to authenticate before proceeding
            if sameBundleIdApp.count > 0 && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        self.installprogressVisible = false
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    self.installprogressVisible = false
                    return
                }
            }
            
        }
        
        if autoReplaceNextInstall, let existingApp = sameBundleIdApp.first {
            // Batch update from the sources page: replace the existing app in
            // place without asking. Settings/data carry over via appToReplace.
            appRelativePath = existingApp.appInfo.relativeBundlePath
            if existingApp.uiIsShared {
                outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(appRelativePath)
            } else {
                outputFolder = LCPath.bundlePath.appendingPathComponent(appRelativePath)
            }
            appToReplace = existingApp
            try fm.removeItem(at: outputFolder)
        } else if fm.fileExists(atPath: outputFolder.path) || sameBundleIdApp.count > 0 {
            appRelativePath = "\(newAppInfo.bundleIdentifier()!)_\(Int(CFAbsoluteTimeGetCurrent())).app"
            
            self.installOptions = [AppReplaceOption(isReplace: false, nameOfFolderToInstall: appRelativePath)]
            
            for app in sameBundleIdApp {
                self.installOptions.append(AppReplaceOption(isReplace: true, nameOfFolderToInstall: app.appInfo.relativeBundlePath, appToReplace: app))
            }

            guard let installOptionChosen = await installReplaceAlert.open() else {
                // user cancelled
                self.installprogressVisible = false
                try fm.removeItem(at: payloadPath)
                return
            }
            
            if let appToReplace = installOptionChosen.appToReplace, appToReplace.uiIsShared {
                outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            } else {
                outputFolder = LCPath.bundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            }
            appRelativePath = installOptionChosen.nameOfFolderToInstall
            appToReplace = installOptionChosen.appToReplace
            if installOptionChosen.isReplace {
                try fm.removeItem(at: outputFolder)
            }
        }
        // Move it!
        try fm.moveItem(at: appFolderPath, to: outputFolder)
        let finalNewApp = LCAppInfo(bundlePath: outputFolder.path)
        finalNewApp?.relativeBundlePath = appRelativePath
        
        guard let finalNewApp else {
            errorInfo = "lc.appList.appInfoInitError".loc
            errorShow = true
            return
        }
        
        // patch and sign it
        var signError : String? = nil
        var signSuccess = false
        await withUnsafeContinuation({ c in
            if appToReplace?.uiDontSign ?? false || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
                finalNewApp.dontSign = true
            }
            finalNewApp.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error
                signSuccess = success
                c.resume()
            }, progressHandler: { signProgress in
                installProgress.addChild(signProgress!, withPendingUnitCount: 20)
            }, forceSign: false)
        })
        
        // we leave it unsigned even if signing failed
        if let signError {
            if signSuccess {
                errorInfo = "\("lc.appList.signSuccessWithError".loc)\n\n\(signError)"
            } else {
                errorInfo = signError.loc
            }
            errorShow = true
        }
        
        if let appToReplace {
            LCAppModel.copy(fromApp: appToReplace, toAppInfo: finalNewApp)
        } else {
            // enable SDK version spoof by defalut
            finalNewApp.spoofSDKVersion = true
        }
        finalNewApp.installationDate = Date.now
        
        DispatchQueue.main.async {
            if let appToReplace {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                
                if appToReplace.uiIsHidden {
                    sharedModel.hiddenApps.removeAll { $0 == appToReplace }
                    sharedModel.hiddenApps.append(newAppModel)
                } else {
                    sharedModel.apps.removeAll { $0 == appToReplace }
                    sharedModel.apps.append(newAppModel)
                }

            } else {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                sharedModel.apps.append(newAppModel)
                
                // add url schemes
                if let urlSchemes = finalNewApp.urlSchemes(), urlSchemes.count > 0 {
                    UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                        .addObjects(from: urlSchemes as! [Any])
                }
            }

            self.installprogressVisible = false
        }
    }
    
    func startInstallFromUrl() async {
        guard let installUrlStr = await installUrlInput.open(), installUrlStr.count > 0 else {
            return
        }
        if let url = URL(string:installUrlStr), url.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: installUrlStr)
            return
        }
        enqueueInstall(.url(urlStr: installUrlStr, name: nil, iconURL: nil, autoReplace: false, bundleID: nil, version: nil))
    }
    
    /// Drain the serial install queue one app at a time. installFromUrl
    /// drops requests while another install runs, so queued installs must
    /// await each other; every queued install auto-replaces its old version.
    /// Adds one job to the serial install pipeline and kicks the
    /// processor. Duplicates of the running or an already-waiting
    /// job are ignored, so no request is ever lost or doubled.
    func enqueueInstall(_ job: InstallJob) {
        let key = job.dedupeKey
        guard currentInstallJobKey != key,
              !installQueue.contains(where: { $0.dedupeKey == key }) else {
            return
        }
        installQueue.append(job)
        downloadHelper.queuedInstallCount = installQueue.count
        Task { await processInstallQueue() }
    }

    /// The single install processor: drains the queue strictly
    /// one job at a time. This is the only place the perform*
    /// install functions are called from, which is what makes the
    /// pipeline serial. It also drives the capsule's session state
    /// on the download helper and collects per-job errors for the
    /// end-of-session report instead of letting each one pop an
    /// alert mid-batch.
    func processInstallQueue() async {
        guard !isInstallQueueRunning else { return }
        isInstallQueueRunning = true
        sessionTotalJobs = 0
        sessionFailures = []
        sessionSuccesses = []
        sessionWasCancelled = false
        downloadHelper.isInstallSessionActive = true
        defer {
            isInstallQueueRunning = false
            downloadHelper.isInstallSessionActive = false
            downloadHelper.isInstallingPhase = false
            downloadHelper.queuedInstallCount = 0
            reportSessionResults()
        }
        while !installQueue.isEmpty {
            let job = installQueue.removeFirst()
            currentInstallJobKey = job.dedupeKey
            sessionTotalJobs += 1
            downloadHelper.queuedInstallCount = installQueue.count
            downloadHelper.isInstallingPhase = false
            // An error already pending when the job starts is not
            // this job's — leave it for the normal alert path.
            let errorWasPending = errorShow
            switch job {
            case .url(let urlStr, let name, let iconURL, let autoReplace, _, _):
                autoReplaceNextInstall = autoReplace
                await performInstallFromUrl(urlStr: urlStr, downloadName: name, downloadIconURL: iconURL)
                autoReplaceNextInstall = false
            case .file(let fileUrl):
                await performInstallApp(fileUrl)
            }
            var jobFailed = false
            if errorShow && !errorWasPending {
                sessionFailures.append((jobKey: job.dedupeKey, name: job.displayName, error: errorInfo))
                errorShow = false
                jobFailed = true
            }
            if downloadHelper.cancelled {
                // The user stopped this job (and drained the rest
                // of the queue): it counts as neither success nor
                // failure, and no success card is shown for the
                // session — failures already recorded still are.
                sessionWasCancelled = true
            } else if !jobFailed {
                switch job {
                case .url(_, _, _, let autoReplace, let bundleID, let version):
                    sessionSuccesses.append((name: job.displayName, isUpdate: autoReplace, version: version, bundleID: bundleID))
                case .file:
                    sessionSuccesses.append((name: job.displayName, isUpdate: false, version: nil, bundleID: nil))
                }
            }
            currentInstallJobKey = nil
        }
    }

    /// Presents what a finished session collected. A single job:
    /// success shows the capsule's success card, failure keeps
    /// the classic error alert. A batch: one success card with
    /// update/install counts, or — when anything failed — a
    /// persistent mixed card whose tap opens the failure summary
    /// (names and messages, kept in batchSummaryText). A session
    /// the user cancelled shows no success card, but failures
    /// recorded before the cancel are still reported.
    func reportSessionResults() {
        let failures = sessionFailures
        let successes = sessionSuccesses
        let total = sessionTotalJobs
        let cancelled = sessionWasCancelled
        sessionFailures = []
        sessionSuccesses = []
        sessionWasCancelled = false
        guard total > 0 else { return }

        if total <= 1 {
            if let failure = failures.first {
                errorInfo = failure.error
                errorShow = true
            } else if !cancelled, let success = successes.first {
                downloadHelper.installCompletion = .single(name: success.name, isUpdate: success.isUpdate, version: success.version, bundleID: success.bundleID)
            }
            return
        }

        let failedJobs = Set(failures.map { $0.jobKey }).count
        let updates = successes.filter { $0.isUpdate }.count
        let installs = successes.count - updates
        if !failures.isEmpty {
            var text = "lc.install.batchSummary.result %lld %lld".localizeWithFormat(total - failedJobs, failedJobs)
            for failure in failures {
                text += "\n\(failure.name)：\(failure.error)"
            }
            batchSummaryText = text
            downloadHelper.installCompletion = .batch(done: total - failedJobs, failed: failedJobs, updates: updates, installs: installs)
        } else if !cancelled {
            downloadHelper.installCompletion = .batch(done: total, failed: 0, updates: updates, installs: installs)
        }
    }

    func installFromPlist(urlStr: String) async {
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        var plistUrlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let urlComponents = URLComponents(string: plistUrlStr),
               let queryItems = urlComponents.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                errorInfo = "lc.appList.plistInvalidError".loc
                errorShow = true
                return
            }
        }
        
        guard let plistUrl = URL(string: plistUrlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: plistUrl)
            
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                errorInfo = "lc.appList.plistParseError".loc
                errorShow = true
                return
            }
            
            var ipaUrlStr: String?
            for asset in assets {
                if let kind = asset["kind"] as? String, kind == "software-package",
                   let url = asset["url"] as? String {
                    ipaUrlStr = url
                    break
                }
            }
            
            guard let ipaUrlStr else {
                errorInfo = "lc.appList.plistNoIpaError".loc
                errorShow = true
                return
            }
            
            enqueueInstall(.url(urlStr: ipaUrlStr, name: nil, iconURL: nil, autoReplace: false, bundleID: nil, version: nil))

        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    /// Downloads (when remote) and installs one URL job. Only
    /// ever called by the serial queue processor, so installs can
    /// never overlap — the old "drop the request while busy" gate
    /// is gone because the queue now provides the serialization.
    func performInstallFromUrl(urlStr: String, downloadName: String? = nil, downloadIconURL: URL? = nil) async {

        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        guard var installUrl = URL(string: urlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        self.installprogressVisible = true
        defer {
            self.installprogressVisible = false
        }
        
        if installUrl.isFileURL {
            // install from local, we directly call local install method
            let fileExtension = installUrl.pathExtension.lowercased()
            if fileExtension != "ipa" && fileExtension != "tipa" {
                errorInfo = "lc.appList.urlFileIsNotIpaError".loc
                errorShow = true
                return
            }
            
            let fm = FileManager.default
            var didStartAccessing = false
            if !fm.isReadableFile(atPath: installUrl.path),
               let bookmarkData = LCUtils.appGroupUserDefault.data(forKey: "LCLaunchExtensionFileBookmark") {
                do {
                    var isStale = false
                    let resolvedURL = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: URL.BookmarkResolutionOptions(rawValue: 1 << 10),
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    installUrl = resolvedURL
                    didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                } catch {
                    errorInfo =  "Failed to resolve shared IPA bookmark: \(error.localizedDescription)"
                    errorShow = true
                    return
                }
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                didStartAccessing = installUrl.startAccessingSecurityScopedResource()
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                errorInfo = "lc.appList.ipaAccessError".loc
                errorShow = true
                return
            }
            
            defer {
                if didStartAccessing {
                    installUrl.stopAccessingSecurityScopedResource()
                }
            }
            
            do {
                downloadHelper.isInstallingPhase = true
                try await installIpaFile(installUrl)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            do {
                // delete ipa if it's in inbox
                var shouldDelete = false
                if let documentsDirectory = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let inboxURL = documentsDirectory.appendingPathComponent("Inbox")
                    shouldDelete = installUrl.deletingLastPathComponent().standardizedFileURL == inboxURL.standardizedFileURL
                }
                if shouldDelete {
                    try fm.removeItem(at: installUrl)
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            return
        }
        
        do {
            let fileManager = FileManager.default
            let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(installUrl.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            
            downloadHelper.downloadName = downloadName ?? installUrl.lastPathComponent
            downloadHelper.downloadIconURL = downloadIconURL
            try await downloadHelper.download(url: installUrl, to: destinationURL)
            if downloadHelper.cancelled {
                return
            }
            downloadHelper.isInstallingPhase = true
            try await installIpaFile(destinationURL)
            try fileManager.removeItem(at: destinationURL)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func removeApp(app: LCAppModel) {
        DispatchQueue.main.async {
            sharedModel.apps.removeAll { now in
                return app == now
            }
            sharedModel.hiddenApps.removeAll { now in
                return app == now
            }
            
        }
    }
    
    func changeAppVisibility(app: LCAppModel) {
        DispatchQueue.main.async {
            if app.appInfo.isHidden {
                sharedModel.apps.removeAll { now in
                    return app == now
                }
                if !sharedModel.hiddenApps.contains(app) {
                    sharedModel.hiddenApps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .removeObjects(in: app.appInfo.urlSchemes() as! [Any])
            } else {
                sharedModel.hiddenApps.removeAll { now in
                    return app == now
                }
                if !sharedModel.apps.contains(app) {
                    sharedModel.apps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .addObjects(from: app.appInfo.urlSchemes() as! [Any])
            }
            
        }
    }
    
    func launchAppWithBundleId(bundleId : String, container : String?, urlStr: String? = nil, forceJIT: Bool? = nil) async {
        if bundleId == "" {
            return
        }
        var appFound : LCAppModel? = nil
        var isFoundAppLocked = false
        for app in sharedModel.apps {
            if app.appInfo.relativeBundlePath == bundleId {
                appFound = app
                if app.appInfo.isLocked {
                    isFoundAppLocked = true
                }
                break
            }
        }
        if appFound == nil && !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
            for app in sharedModel.hiddenApps {
                if app.appInfo.relativeBundlePath == bundleId {
                    appFound = app
                    isFoundAppLocked = true
                    break
                }
            }
        }
        
        if appFound == nil && bundleId == "builtinSideStore" {
            appFound = LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared)
        }
        
        if isFoundAppLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        
        guard let appFound else {
            errorInfo = "lc.appList.appNotFoundError".loc
            errorShow = true
            return
        }

        do {
            try await appFound.runApp(multitask: nil, containerFolderName: container, urlStr: urlStr, forceJIT: forceJIT)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func authenticateUser() async {
        do {
            if !(try await LCUtils.authenticateUser()) {
                return
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
    }
    
    func jitLaunch(appName: String, classicMode: UInt) async {
        await jitLaunch(withScript: "", appName: appName, classicMode: classicMode)
    }

    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async {
        await MainActor.run {
            jitLog = ""
        }
        let enableJITTask = Task {
            
            let _ = await LCUtils.askForJIT(withScript: script, appName: appName, classicMode: classicMode) { newMsg in
                Task { await MainActor.run {
                    self.jitLog += "\(newMsg)\n"
                }}
            }
            guard let _ = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) else {
                return
            }
        }
        guard let result = await jitAlert.open(), result else {
            UserDefaults.standard.removeObject(forKey: "selected")
            enableJITTask.cancel()
            return
        }
        LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)

    }
    
    func jitLaunch(withPID pid: Int, withScript script: String? = nil, appName: String) async {
        await MainActor.run {
            let encodedData = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                
            
            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {
                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
                    let encoded = encodedData.map { "&script=\($0)" } ?? ""
                    if jitEnabler == .StosDebugLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stosdebug") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&relaunchApp=false& forcePID=true\(encoded)") {
                                Task { await openWebView(urlString: url.absoluteString) }
                            }
                        } else {
                            errorInfo = "StosDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&forcePID=true\(encoded)") {
                            UIApplication.shared.open(url)
                        }
                    }
                    return
                }
                
                let encoded = encodedData.map { "&script-data=\($0)" } ?? ""
                if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                    if jitEnabler == .StikJITLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stikjit") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            Task { await openWebView(urlString: url.absoluteString) }
                        } else {
                            errorInfo = "StikDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }

    func showRunWhenMultitaskAlert() async -> Bool? {
        return await runWhenMultitaskAlert.open()
    }
    
    func installMdm(data: Data) {
        safariViewURL = URL(string:"data:application/x-apple-aspen-config;base64,\(data.base64EncodedString())")!
        safariViewOpened = true
    }
    
    func openNavigationView(view: AnyView) {
        navigateTo = view
        isNavigationActive = true
    }
    
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle? {
        if #available(iOS 18.0, *) {
            return await generatedIconStyleSelector.open()
        } else {
            return .Light
        }
        
    }
    
    func closeNavigationView() {
        isNavigationActive = false
        navigateTo = nil
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    func handleURL(url : URL) {
        if url.isFileURL {
            enqueueInstall(.url(urlStr: url.absoluteString, name: nil, iconURL: nil, autoReplace: false, bundleID: nil, version: nil))
            return
        }
        
        if url.scheme == "sidestore" && UserDefaults.sideStoreExist() {
            UserDefaults.standard.setValue(url.absoluteString, forKey: "launchAppUrlScheme")
            LCUtils.openSideStore(delegate: self)
            return
        }
        
        if url.host == "open-web-page" || url.host == "open-url" {
            if let urlComponent = URLComponents(url: url, resolvingAgainstBaseURL: false), let queryItem = urlComponent.queryItems?.first {
                if queryItem.value?.isEmpty ?? true {
                    return
                }
                
                if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                   let decodedUrl = String(data: decodedData, encoding: .utf8) {
                    Task { await openWebView(urlString: decodedUrl) }
                }
            }
        } else if url.host == "livecontainer-launch" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var bundleId : String? = nil
                var containerName : String? = nil
                var forceJIT: Bool? = nil
                var urlStr: String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "bundle-name", let bundleId1 = queryItem.value {
                        bundleId = bundleId1
                    } else if queryItem.name == "container-folder-name", let containerName1 = queryItem.value {
                        containerName = containerName1
                    } else if queryItem.name == "jit", let forceJIT1 = queryItem.value {
                        if forceJIT1 == "true" {
                            forceJIT = true
                        } else if forceJIT1 == "false" {
                            forceJIT = false
                        }
                    } else if queryItem.name == "open-url" {
                        if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                           let decodedUrl = String(data: decodedData, encoding: .utf8) {
                            urlStr = decodedUrl
                        }
                    }
                }
                if let bundleId, bundleId != "ui"{
                    Task { await launchAppWithBundleId(bundleId: bundleId, container: containerName, urlStr: urlStr, forceJIT: forceJIT) }
                }
            }
        } else if url.host == "install" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var installUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        installUrl = installUrl1
                    }
                }
                if let installUrl {
                    enqueueInstall(.url(urlStr: installUrl, name: nil, iconURL: nil, autoReplace: false, bundleID: nil, version: nil))
                }
            }
        }
    }
    
}

extension View {
    func apply<V: View>(@ViewBuilder _ block: (Self) -> V) -> V { block(self) }
}
