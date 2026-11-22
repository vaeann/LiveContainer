// CZFHostKeepAlive.swift
// 宿主侧无声音频保活，移植自 LiveContainer-zh 的同名实现：宿主切后台时
// 若有游客在跑，让宿主自己播一段静音，宿主进程保持运行，游客所在的
// LiveProcess Extension 才不被系统回收。与游客侧 CZFKeepAlive.dylib
// 同一套配方（8kHz 单声道静音循环 + 看门狗），但跑在宿主进程里：
// 覆盖所有游客（含 dontInject、没挂保活夹的），不依赖游客侧插件。
// 开关与游客侧保活共用 LCKeepAliveEnabled（默认开）。
// 只在“开关开 + 有游客在跑 + 宿主已切后台”三者同时满足时播放；
// 宿主回前台、最后一个游客退出、开关关闭时立即停。
// 游客判定：虚拟模式看 MultitaskManager 的容器注册表，原生模式看
// 系统场景数（详见下方本 fork 适配说明）；只要有游客在跑宿主就保，
// 宿主半不做按 App 的白名单过滤——CZFKeepAliveApps.txt 白名单由
// 游客侧 dylib 对它自己生效。
// v1.1 优化（防 1 分钟内被掐）：①提前启动 —— WillResignActive 就先
// 播，切后台时音频会话已经是激活态；②游客计数补原生模式 —— 虚拟
// 模式数 dock，原生模式数系统已连接的场景；③后台任务第二通道 ——
// 音频被打断时，后台任务先顶住，过期时重开音频并续一个新任务。
//
// 本 fork 的适配（与 zh 的关键差异，2026-11-22 启动闪退定位后定）：
// zh 在 refresh 里读它自己的坞管理器 apps；本 fork 的
// MultitaskDockManager 是 UI 耦合的——它的 init 里有
// keyWindow!.rootViewController!.view.subviews.first! 三处强解包，
// 只能在界面就绪后由多任务 UI 首次创建，生命周期回调里抢先碰它
// 会直接闪退（完整版与阶段 1 版均死于此，日志为证）。所以本 fork
// 的宿主半改读 MultitaskManager 的容器注册表（纯数据、无 UI 耦合，
// 任意时刻可读）判断有无游客；代价是宿主半不再按 bundle id 过滤
// 白名单（注册表只有 UUID）——白名单仍由游客侧 dylib 对自己生效。
// 另有：全程诊断日志（CZFKeepAliveLog，与游客侧 dylib 写同一个
// 文件），以及游客模块的 base64 部署（syncGuestModule）。

import AVFoundation
import CryptoKit
import UIKit

/// Shared keep-alive debug log: host, guests and LC itself append to
/// <appGroup>/CZFKeepAlive/keepalive.log in the format
/// `MM-dd HH:mm:ss Tag · event k=v ...`. The guest-side dylib writes
/// the same file with the same format.
enum CZFKeepAliveLog {
    private static let queue = DispatchQueue(label: "czf.keepalive.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static var fileURL: URL {
        let root = LCPath.lcGroupDocPath.deletingLastPathComponent()
        return root.appendingPathComponent("CZFKeepAlive", isDirectory: true)
            .appendingPathComponent("keepalive.log")
    }

    /// 日志开关（微珠式设置）：关了就一行都不写。键缺省 = 开。
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "LCKeepAliveLogEnabled") as? Bool ?? true
    }

    static func event(_ tag: String, _ event: String, _ details: [String: String] = [:]) {
        guard isEnabled else { return }
        queue.async {
            let url = fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let suffix = details.keys.sorted().compactMap { key in details[key].map { "\(key)=\($0)" } }.joined(separator: " ")
            let line = "\(formatter.string(from: Date())) \(tag) · \(event)\(suffix.isEmpty ? "" : " " + suffix)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Keep the log bounded: above 512 KB keep only the last 200 lines.
    static func trimIfNeeded() {
        queue.async {
            let url = fileURL
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.intValue, size > 512 * 1024,
                  let content = try? String(contentsOf: url, encoding: .utf8) else { return }
            let lines = content.components(separatedBy: "\n").suffix(200)
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

final class CZFHostKeepAlive {
    static let shared = CZFHostKeepAlive()

    private var player: AVAudioPlayer?
    private var watchdog: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var isBackgrounded = false
    private var installed = false
    private var playStartedAt: Date?
    /// 保活上限闩锁：本轮后台播满上限后置位，refresh 不再重起；
    /// 回前台时清零，下一轮后台重新计时。
    private var limitReached = false
    // block 观察者返的 token 必须留住——NotificationCenter 不强持有
    // 它，丢掉就当场注销。
    private var observerTokens: [NSObjectProtocol] = []

    private init() {}

    /// App 启动时调一次：装后台/前台/音频中断观察者（主队列）。
    func install() {
        guard !installed else { return }
        installed = true
        isBackgrounded = UIApplication.shared.applicationState == .background
        CZFKeepAliveLog.trimIfNeeded()
        CZFKeepAliveLog.event("宿主", "keep-alive-install", [
            "state": "\(UIApplication.shared.applicationState.rawValue)",
            "enabled": "\(UserDefaults.standard.object(forKey: "LCKeepAliveEnabled") as? Bool ?? true)",
            "pid": "\(ProcessInfo.processInfo.processIdentifier)"])
        // 把当前上限/日志开关同步给游客侧（config.plist），保证用户
        // 从没动过新设置时游客读到的也是现值。
        Self.writeGuestConfig()
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            CZFKeepAliveLog.event("宿主", "keep-alive-notify", ["name": "didEnterBackground"])
            self?.isBackgrounded = true
            self?.refresh()
        })
        observerTokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            CZFKeepAliveLog.event("宿主", "keep-alive-notify", ["name": "willEnterForeground"])
            self?.isBackgrounded = false
            self?.limitReached = false
            self?.refresh()
        })
        // 提前启动：上滑切 App 时 WillResignActive 先于 DidEnterBackground，
        // 这里就先播，切后台时音频会话已经是激活态。
        observerTokens.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            CZFKeepAliveLog.event("宿主", "keep-alive-notify", ["name": "willResignActive"])
            self?.isBackgrounded = true
            self?.refresh()
        })
        observerTokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            CZFKeepAliveLog.event("宿主", "keep-alive-notify", ["name": "didBecomeActive"])
            self?.isBackgrounded = false
            self?.limitReached = false
            self?.refresh()
        })
        observerTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else {
                CZFKeepAliveLog.event("宿主", "keep-alive-notify", ["name": "interruption", "type": "unknown"])
                return
            }
            CZFKeepAliveLog.event("宿主", "keep-alive-notify", ["name": "interruption", "type": type == .began ? "began" : "ended"])
            guard type == .ended else { return }
            self.refresh()
        })
        // 音频服务丢了/重置了（mediaserverd 崩了重起等），播放器会静默
        // 停掉且不发 interruption——直接听这两个通知，丢了就重起。
        observerTokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: .main) { [weak self] _ in
            CZFKeepAliveLog.event("宿主", "keep-alive-notify", ["name": "mediaServicesLost"])
            self?.refresh()
        })
        observerTokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            CZFKeepAliveLog.event("宿主", "keep-alive-notify", ["name": "mediaServicesReset"])
            self?.refresh()
        })
    }

    /// 开关/游客数/前后台任一变化时调：重算该不该播（主队列）。
    /// 游客判定只读 MultitaskManager 的容器注册表与系统场景数——
    /// 绝不能在这里碰 MultitaskDockManager（见文件头适配说明）。
    func refresh() {
        let enabled = UserDefaults.standard.object(forKey: "LCKeepAliveEnabled") as? Bool ?? true
        // 虚拟模式：注册表里有容器即有游客。原生模式：游客是独立
        // 场景，主场景之外多一个即有游客。
        let multitasking = MultitaskManager.isMultitasking()
        let sceneCount = UIApplication.shared.connectedScenes.count
        let guestsRunning = multitasking || sceneCount > 1
        // 保活上限：本轮已播满就闩锁，refresh 不再重起（看门狗也会查，
        // 这里是事件驱动路径的同一道闸）。
        if !limitReached, Self.limitSeconds > 0, let started = playStartedAt,
           Date().timeIntervalSince(started) >= Self.limitSeconds {
            limitReached = true
        }
        let shouldPlay = enabled && guestsRunning && isBackgrounded && !limitReached
        CZFKeepAliveLog.event("宿主", "keep-alive-refresh", [
            "enabled": "\(enabled)",
            "guests": "\(guestsRunning)",
            "multitask": "\(multitasking)",
            "scenes": "\(sceneCount)",
            "bg": "\(isBackgrounded)",
            "playing": "\(player?.isPlaying ?? false)",
            "limitReached": "\(limitReached)",
            "decision": shouldPlay ? "start" : "stop"])
        if shouldPlay {
            start()
        } else {
            stop()
        }
    }

    /// 后台任务第二通道：音频被打断时先顶住，过期时重开音频并续一个新任务。
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            guard let self else { return }
            CZFKeepAliveLog.event("宿主", "keep-alive-bgtask-expire", ["id": "\(self.backgroundTask.rawValue)", "bg": "\(self.isBackgrounded)"])
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
            if self.isBackgrounded { self.start() }
        }
        CZFKeepAliveLog.event("宿主", "keep-alive-bgtask-begin", ["id": "\(backgroundTask.rawValue)"])
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        CZFKeepAliveLog.event("宿主", "keep-alive-bgtask-end", ["id": "\(backgroundTask.rawValue)"])
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func start() {
        beginBackgroundTask()
        if watchdog == nil { armWatchdog() }
        if let player = player, player.isPlaying { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            let created = player == nil
            if created {
                player = try AVAudioPlayer(data: CZFHostKeepAlive.silentWAVData())
                player?.numberOfLoops = -1
                player?.volume = 0.0
                player?.prepareToPlay()
            }
            player?.play()
            if playStartedAt == nil { playStartedAt = Date() }
            CZFKeepAliveLog.event("宿主", "keep-alive-start", [
                "created": "\(created)",
                "playing": "\(player?.isPlaying ?? false)",
                "currentTime": "\(player?.currentTime ?? -1)",
                "pid": "\(ProcessInfo.processInfo.processIdentifier)"])
        } catch {
            // 宿主保活绝不能拖垮宿主：起不来就安静失败（但要留日志）。
            CZFKeepAliveLog.event("宿主", "keep-alive-start-failed", ["error": error.localizedDescription])
            return
        }
        // 刚起播时 playStartedAt 才定下来，有上限就按剩余时间重排
        // 一次看门狗，上限附近的间隔才算得准。
        if Self.limitSeconds > 0 { armWatchdog() }
    }

    // MARK: - 看门狗（自适应）

    /// 看门狗只作兜底：主因（中断结束、音频服务丢/重置、前后台切换）
    /// 都已有通知直接触发 refresh() 重起；这表防通知没覆盖到的漏网
    /// 情况，顺带执行保活上限。单次定时、每轮按状态重算间隔——
    /// 自适应：没上限时 300 秒一轮；有上限时取剩余时间的一半
    /// （最短 30 秒），越接近上限查得越密，到点能及时停。
    private func armWatchdog() {
        watchdog?.invalidate()
        let interval = watchdogInterval()
        watchdog = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.watchdogTick()
        }
        watchdog?.tolerance = interval * 0.2
        CZFKeepAliveLog.event("宿主", "keep-alive-watchdog-armed", ["interval": "\(Int(interval))"])
    }

    private func watchdogInterval() -> TimeInterval {
        let limit = Self.limitSeconds
        guard limit > 0, let started = playStartedAt else { return 300 }
        let remaining = limit - Date().timeIntervalSince(started)
        return min(300, max(30, remaining / 2))
    }

    private func watchdogTick() {
        watchdog = nil
        // 只在真后台才动作：applicationState 才是真后台。
        let inBg = UIApplication.shared.applicationState == .background
        let playing = player?.isPlaying ?? false
        // 上限先于健康检查：到点就停并闩锁，本轮后台不再重起。
        if inBg, playing, Self.limitSeconds > 0, let started = playStartedAt,
           Date().timeIntervalSince(started) >= Self.limitSeconds {
            CZFKeepAliveLog.event("宿主", "keep-alive-watchdog", [
                "state": "\(UIApplication.shared.applicationState.rawValue)",
                "playing": "\(playing)",
                "action": "limit-stop"])
            limitReached = true
            stop()
            return
        }
        CZFKeepAliveLog.event("宿主", "keep-alive-watchdog", [
            "state": "\(UIApplication.shared.applicationState.rawValue)",
            "playing": "\(playing)",
            "currentTime": "\(player?.currentTime ?? -1)",
            "action": (inBg && !playing) ? "restart" : "none"])
        if inBg && !playing {
            start()
        } else if inBg {
            armWatchdog()
        }
    }

    private func stop() {
        let wasPlaying = player?.isPlaying ?? false
        let seconds = playStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if wasPlaying || playStartedAt != nil {
            CZFKeepAliveLog.event("宿主", "keep-alive-stop", [
                "wasPlaying": "\(wasPlaying)",
                "seconds": "\(seconds)",
                "bg": "\(isBackgrounded)"])
        }
        playStartedAt = nil
        watchdog?.invalidate()
        watchdog = nil
        player?.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        endBackgroundTask()
    }

    /// 1 秒静音 WAV（8000Hz 单声道 16bit PCM），与游客侧 CZFKeepAlive.m 同配方。
    private static func silentWAVData() -> Data {
        let sampleRate: UInt32 = 8000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let chunkSize = 36 + dataSize
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        var data = Data()
        func append<T>(_ value: T) {
            var v = value
            data.append(Data(bytes: &v, count: MemoryLayout<T>.size))
        }
        data.append("RIFF".data(using: .ascii)!)
        append(chunkSize)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        append(UInt32(16))
        append(UInt16(1))
        append(channels)
        append(sampleRate)
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        data.append("data".data(using: .ascii)!)
        append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }

    // MARK: - 开关与游客模块部署

    /// 保活总开关：写键 + 同步游客 dylib + 刷新宿主保活。
    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "LCKeepAliveEnabled")
        CZFKeepAliveLog.event("LC", "keep-alive-setting", ["enabled": "\(enabled)"])
        syncGuestModule(enabled: enabled)
        shared.refresh()
    }

    // MARK: - 微珠式设置：上限 / 日志开关 / 状态

    /// 保活上限（秒）：0 = 不限。设置键 LCKeepAliveLimitMinutes 存分钟。
    static var limitSeconds: TimeInterval {
        let minutes = UserDefaults.standard.integer(forKey: "LCKeepAliveLimitMinutes")
        return minutes > 0 ? TimeInterval(minutes * 60) : 0
    }

    static func setLimitMinutes(_ minutes: Int) {
        UserDefaults.standard.set(minutes, forKey: "LCKeepAliveLimitMinutes")
        CZFKeepAliveLog.event("LC", "keep-alive-setting", ["limitMinutes": "\(minutes)"])
        writeGuestConfig()
        // 正在播且已超过新上限时，refresh 里的闸会立刻停掉。
        shared.refresh()
    }

    static func setLogEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "LCKeepAliveLogEnabled")
        writeGuestConfig()
        if enabled {
            CZFKeepAliveLog.event("LC", "keep-alive-setting", ["logEnabled": "true"])
        }
    }

    /// 游客侧配置：写进与日志同目录的 config.plist，游客 dylib 在
    /// 加载、起播和看门狗轮次里读（上限秒数 + 日志开关）——游客进程
    /// 读不到宿主的标准 defaults，只能走 App Group 文件。
    static func writeGuestConfig() {
        let dir = CZFKeepAliveLog.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "limitSeconds": limitSeconds,
            "logEnabled": CZFKeepAliveLog.isEnabled,
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0) {
            try? data.write(to: dir.appendingPathComponent("config.plist"), options: .atomic)
        }
    }

    /// 设置页「保活状态」行的数据。在主线程读（设置页调用）。
    /// 游客判定与 refresh 同源：注册表 + 场景数，不碰坞管理器。
    struct Status {
        var enabled: Bool
        var playing: Bool
        var elapsed: TimeInterval
        var limitMinutes: Int
        var guestsRunning: Bool
        var limitReached: Bool
    }

    func statusSnapshot() -> Status {
        let guests = MultitaskManager.isMultitasking() || UIApplication.shared.connectedScenes.count > 1
        return Status(
            enabled: UserDefaults.standard.object(forKey: "LCKeepAliveEnabled") as? Bool ?? true,
            playing: player?.isPlaying ?? false,
            elapsed: playStartedAt.map { Date().timeIntervalSince($0) } ?? 0,
            limitMinutes: UserDefaults.standard.integer(forKey: "LCKeepAliveLimitMinutes"),
            guestsRunning: guests,
            limitReached: limitReached)
    }

    /// 游客侧 CZFKeepAlive.dylib 的部署。构建产物以 base64 文本形式
    /// 放在 App 包里（散装 dylib 会被装机重签改坏加载命令——FMK 时代
    /// 的教训），这里解码后写进两个 Tweaks 文件夹并签名；关开关时
    /// 移除，游客就不再加载它。
    static func syncGuestModule(enabled: Bool) {
        let folders = [LCPath.tweakPath, LCPath.lcGroupTweakPath]
        let fm = FileManager.default
        if !enabled {
            for folder in folders {
                let dest = folder.appendingPathComponent("CZFKeepAlive.dylib")
                let existed = fm.fileExists(atPath: dest.path)
                try? fm.removeItem(at: dest)
                CZFKeepAliveLog.event("LC", "deploy-remove", ["folder": folder.lastPathComponent, "existed": "\(existed)"])
            }
            return
        }
        guard let b64URL = Bundle.main.url(forResource: "CZFKeepAlive.dylib", withExtension: "b64"),
              let b64Data = try? Data(contentsOf: b64URL),
              let data = Data(base64Encoded: b64Data, options: .ignoreUnknownCharacters) else {
            CZFKeepAliveLog.event("LC", "deploy-failed", ["reason": "resource-missing-or-undecodable"])
            return
        }
        // 签名纪律：dylib 内容变了才重签；另存一份已签摘要在标准
        // defaults 里（重装 LC 会清掉），摘要对不上时也重签一次——
        // 覆盖“重装后字节没变但签名身份变了”的情况，常态启动不重签。
        // 两个文件夹的签名在一个 Task 里串行做：LCUtils 的签名机
        // 器不是并发安全的（上一版每文件夹一个 Task 并发签，是启动
        // 闪退的嫌疑之一）。
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let alreadySigned = UserDefaults.standard.string(forKey: "CZFKeepAliveSignedDigest") == digest
        CZFKeepAliveLog.event("LC", "deploy", ["bytes": "\(data.count)", "alreadySigned": "\(alreadySigned)"])
        var foldersToSign: [URL] = []
        for folder in folders {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent("CZFKeepAlive.dylib")
            let existing = try? Data(contentsOf: dest)
            var updated = false
            if existing != data {
                // 先写临时文件再换位，写失败时旧文件原样保留。
                let tmp = dest.appendingPathExtension("tmp")
                try? fm.removeItem(at: tmp)
                if (try? data.write(to: tmp)) != nil {
                    try? fm.removeItem(at: dest)
                    try? fm.moveItem(at: tmp, to: dest)
                    updated = true
                }
            }
            CZFKeepAliveLog.event("LC", "deployed", ["folder": folder.lastPathComponent, "updated": "\(updated)"])
            if updated || !alreadySigned {
                foldersToSign.append(folder)
            } else {
                CZFKeepAliveLog.event("LC", "sign-tweaks", ["folder": folder.lastPathComponent, "skipped": "unchanged"])
            }
        }
        guard !foldersToSign.isEmpty else { return }
        Task {
            for folder in foldersToSign {
                do {
                    try await LCUtils.signTweaks(tweakFolderUrl: folder, force: true)
                    CZFKeepAliveLog.event("LC", "sign-tweaks", ["folder": folder.lastPathComponent, "done": "true"])
                } catch {
                    CZFKeepAliveLog.event("LC", "sign-tweaks", ["folder": folder.lastPathComponent, "done": "false", "error": error.localizedDescription])
                    return
                }
            }
            UserDefaults.standard.set(digest, forKey: "CZFKeepAliveSignedDigest")
        }
    }
}
