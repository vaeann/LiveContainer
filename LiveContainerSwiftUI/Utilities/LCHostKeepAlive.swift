//
//  LCHostKeepAlive.swift
//  LiveContainerSwiftUI
//
//  Host-side background keep-alive. While LiveContainer is in the
//  background with guests running, the host loops a 1-second silent
//  WAV so the system does not reclaim the host process — and with it
//  the LiveProcess guests. Guest processes run the twin engine
//  (LCKeepAliveEngine in LCBootstrap); both share the settings below.
//
//  The state machine is a port of 微珠's FMKeepAlive (itself derived
//  from LiveContainer-zh's CZF keep-alive): every lifecycle signal
//  funnels into one refresh() decision — enabled → in background →
//  not timed out → guests running → play. Playback starts early on
//  willResignActive, the category is set only when the player is
//  (re)created and never saved/restored, and stops simply pause the
//  player and deactivate the session. The host adds one channel the
//  guests do not have: a background task taken while playing, whose
//  expiry rebuilds the player and renews the task.
//
//  Settings (app-group defaults, shared with the guest engines):
//    LCKeepAliveEnabled          Bool, default true — one global
//                                switch, no per-app switches
//    LCKeepAliveDurationMinutes  Int,  default 20, 0 = unlimited
//    LCKeepAliveWatchdogEnabled  Bool, default true
//
//  Each side writes a state file under
//  <appGroup>/LiveContainer/KeepAliveState/ for the status panel in
//  the keep-alive settings page.
//

import AVFoundation
import Foundation
import UIKit

final class LCHostKeepAlive {
    static let shared = LCHostKeepAlive()

    private var player: AVAudioPlayer?
    private var watchdogTimer: Timer?
    private var timeoutTimer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private var inBackground = false
    private var timedOut = false
    private var lastSkipNoGuests = false

    private var backgroundStart: Date?
    private var sessionStart: Date?
    private var lastWatchdogConfirm: Date?

    private var started = false

    // MARK: Diagnostic log (temporary — see LCKeepAliveLogEvent in
    // LCBootstrap.m; remove together with its switch once keep-alive
    // is confirmed healthy)

    /// One shared append-only log for the host keeper and every guest
    /// engine, so a single timeline shows which process did what.
    /// Lines look like `MM-dd HH:mm:ss 宿主 · 事件`; the keep-alive
    /// settings page renders them in a viewer with copy/clear.
    private static var lastLogLine: String?
    private static var lastLogTime: TimeInterval = 0

    static func logEvent(_ event: String) {
        let defaults = LCUtils.appGroupUserDefault
        if let enabled = defaults.object(forKey: "LCKeepAliveLogEnabled") as? Bool, !enabled {
            return
        }
        // The same event can be evaluated twice in quick succession;
        // drop an identical line repeated within 2 seconds.
        let body = "宿主 · \(event)"
        let now = Date().timeIntervalSinceReferenceDate
        if body == lastLogLine && now - lastLogTime < 2 {
            return
        }
        lastLogLine = body
        lastLogTime = now

        let dir = LCPath.lcGroupDocPath.appendingPathComponent("KeepAliveState")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("keepalive.log")
        // Bound the file: past ~512 KB keep only the newest 200 lines.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512 * 1024,
           let content = try? String(contentsOf: url, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n")
            if lines.count > 200 {
                try? lines.suffix(200).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(body)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Settings

    private var keepAliveEnabled: Bool {
        LCUtils.appGroupUserDefault.object(forKey: "LCKeepAliveEnabled") as? Bool ?? true
    }

    private var watchdogEnabled: Bool {
        LCUtils.appGroupUserDefault.object(forKey: "LCKeepAliveWatchdogEnabled") as? Bool ?? true
    }

    private var durationMinutes: Int {
        LCUtils.appGroupUserDefault.object(forKey: "LCKeepAliveDurationMinutes") as? Int ?? 20
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        writeState()
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Self.logEvent("收到通知：将要失去活跃")
            self?.enterBackground()
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Self.logEvent("收到通知：已进入后台")
            self?.enterBackground()
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Self.logEvent("收到通知：将回前台")
            self?.enterForeground()
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Self.logEvent("收到通知：已活跃")
            self?.enterForeground()
        }
        center.addObserver(forName: NSNotification.MultitaskRunningAppsChanged, object: nil, queue: .main) { [weak self] _ in
            Self.logEvent("收到通知：运行中的游客有变化")
            guard let self, self.inBackground else { return }
            self.refresh()
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleMediaServicesReset()
        }
        Self.logEvent("引擎装载完成")
    }

    private func enterBackground() {
        if inBackground {
            refresh()
            return
        }
        inBackground = true
        backgroundStart = Date()
        timedOut = false
        startTimeoutTimer()
        writeState()
        refresh()
    }

    private func enterForeground() {
        guard inBackground else { return }
        inBackground = false
        timedOut = false
        writeState()
        stopPlayback(reason: "回到前台")
    }

    // MARK: Decision (single entry point, FMKeepAlive's refresh)

    private func refresh() {
        guard keepAliveEnabled else {
            stopPlayback(reason: "保活总开关被关闭")
            return
        }
        guard inBackground else {
            stopPlayback(reason: "回到前台")
            return
        }
        guard !timedOut else {
            stopPlayback(reason: "达到时长上限")
            return
        }
        // The host only plays while guests are running.
        guard MultitaskManager.isMultitasking() else {
            if !lastSkipNoGuests {
                lastSkipNoGuests = true
                Self.logEvent("跳过保活：无游客在跑")
                writeState()
            }
            stopPlayback(reason: "已无游客在跑")
            return
        }
        lastSkipNoGuests = false
        startPlayback()
        if watchdogTimer == nil {
            scheduleWatchdog()
        }
    }

    // MARK: Playback

    /// 1 second of silence as a WAV (8 kHz, 16-bit mono) — the exact
    /// bytes the guest engine synthesises in LCBootstrap.
    private static let silentWAVData: Data = {
        let sampleRate: UInt32 = 8000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let chunkSize = 36 + dataSize
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        var data = Data()
        func append(_ string: String) { data.append(string.data(using: .ascii)!) }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append("RIFF"); appendLE(chunkSize); append("WAVE"); append("fmt ")
        appendLE(UInt32(16)); appendLE(UInt16(1)); appendLE(channels)
        appendLE(sampleRate); appendLE(byteRate); appendLE(blockAlign); appendLE(bitsPerSample)
        append("data"); appendLE(dataSize)
        data.append(Data(count: Int(dataSize))) // zero-filled = silence
        return data
    }()

    // FMKeepAlive structure: the category is set only when the player
    // is (re)created and is never saved/restored; a stopped player is
    // thrown away by the watchdog and interruption paths, so a
    // restart always rebuilds the whole chain.
    private func startPlayback() {
        if player?.isPlaying == true {
            beginKeepAliveBackgroundTask()
            return
        }
        let session = AVAudioSession.sharedInstance()
        if player == nil {
            if session.category != .playback || !session.categoryOptions.contains(.mixWithOthers) {
                Self.logEvent("会话类目不对（当前 \(session.category.rawValue)），重设为 Playback+混音")
                do {
                    try session.setCategory(.playback, options: [.mixWithOthers])
                } catch {
                    Self.logEvent("设置类目失败：\(error.localizedDescription)")
                }
            } else {
                Self.logEvent("会话类目正常（Playback+混音）")
            }
            do {
                player = try AVAudioPlayer(data: Self.silentWAVData)
                player?.numberOfLoops = -1 // loop forever
                player?.volume = 0
                player?.prepareToPlay()
                Self.logEvent("播放器已创建")
            } catch {
                Self.logEvent("播放器创建失败：\(error.localizedDescription)")
                player = nil
                return
            }
        }
        do {
            try session.setActive(true)
            Self.logEvent("会话已激活")
        } catch {
            Self.logEvent("会话激活失败：\(error.localizedDescription)")
        }
        let playing = player?.play() ?? false
        Self.logEvent(playing ? "播放器开始播放" : "播放器启动失败（play 返回否）")
        if playing {
            if sessionStart == nil {
                sessionStart = Date()
                Self.logEvent("保活开始")
                Self.logEvent("会话参数：时长上限 \(durationMinutes > 0 ? "\(durationMinutes) 分钟" : "不限")，看门狗 \(watchdogEnabled ? "开" : "关")")
            }
            beginKeepAliveBackgroundTask()
        }
    }

    private func stopPlayback(reason: String) {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        let hadSession = sessionStart != nil
        let seconds = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        sessionStart = nil
        player?.pause()
        // No category save/restore (FMKeepAlive parity): the session
        // is deactivated as-is.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        endBackgroundTask()
        if hadSession {
            Self.logEvent("保活停止：\(reason)（本次 \(Int(seconds)) 秒）")
        } else {
            Self.logEvent("停止请求：当前未在保活（\(reason)）")
        }
        writeState()
    }

    // MARK: Background task (second survival channel, host-only)

    private func beginKeepAliveBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LCKeepAlive") { [weak self] in
            // Expiring with no renewal kills the process on the spot;
            // rebuild the player from scratch and renew instead
            // (FMKeepAlive's expiry path).
            guard let self else { return }
            Self.logEvent("后台任务已到期，正在续期")
            self.backgroundTask = .invalid
            self.player = nil
            if !self.timedOut {
                self.startPlayback()
            }
            if self.backgroundTask == .invalid {
                Self.logEvent("后台任务未能续期")
            }
        }
        Self.logEvent("后台任务已申请")
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Duration cap (independent timer, not the watchdog)

    private func startTimeoutTimer() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        let minutes = durationMinutes
        guard minutes > 0, let backgroundStart else { return }
        let remaining = TimeInterval(minutes * 60) - Date().timeIntervalSince(backgroundStart)
        if remaining <= 0 {
            timedOut = true
            Self.logEvent("保活达到时长上限")
            stopPlayback(reason: "达到时长上限")
            return
        }
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            guard let self, self.inBackground else { return }
            self.timedOut = true
            Self.logEvent("保活达到时长上限")
            self.stopPlayback(reason: "达到时长上限")
        }
        RunLoop.main.add(timer, forMode: .common)
        timeoutTimer = timer
    }

    // MARK: Watchdog (adaptive interval, heartbeat for the status panel)

    private func scheduleWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        guard watchdogEnabled else { return }
        // Shorter interval early in the session, longer later.
        let elapsed = backgroundStart.map { Date().timeIntervalSince($0) } ?? 0
        let interval: TimeInterval = elapsed < 300 ? 30 : (elapsed < 600 ? 45 : 60)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.watchdogTick()
        }
        timer.tolerance = interval / 3
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func watchdogTick() {
        guard inBackground else {
            watchdogTimer = nil
            return
        }
        guard keepAliveEnabled else {
            // The global switch is the fuse: turning it off stops everything.
            stopPlayback(reason: "保活总开关被关闭")
            return
        }
        lastWatchdogConfirm = Date()
        if !timedOut && player?.isPlaying != true {
            Self.logEvent("看门狗发现播放已停止，已重新启动")
            player = nil
            startPlayback()
        }
        // Heartbeat probe, double-sampled: the silent file loops
        // every second, so a single currentTime reading wraps and
        // proves nothing — two readings half a second apart that
        // differ mean the player is really rendering; identical
        // readings mean playback is an illusion.
        let first = player?.currentTime ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let second = self.player?.currentTime ?? 0
            Self.logEvent("心跳：播放器 \(self.player?.isPlaying == true ? "播放中" : "未播放")，进度 \(String(format: "%.1f", first)) → \(String(format: "%.1f", second)) 秒，后台任务 \(self.backgroundTask != .invalid ? "有" : "无")")
        }
        writeState()
        scheduleWatchdog()
    }

    // MARK: Interruptions & media services

    private func handleInterruption(_ note: Notification) {
        // FMKeepAlive ignores the Began half entirely — the system
        // pauses playback on its own.
        guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: typeValue) == .ended else {
            return
        }
        guard inBackground, !timedOut else { return }
        Self.logEvent("音频打断结束，尝试恢复保活")
        player = nil
        refresh()
    }

    private func handleMediaServicesReset() {
        guard inBackground, !timedOut else { return }
        Self.logEvent("媒体服务丢失或重置，已重建播放器")
        player = nil
        refresh()
    }

    // MARK: State file (read by the settings status panel)

    private var stateFileURL: URL {
        LCPath.lcGroupDocPath
            .appendingPathComponent("KeepAliveState")
            .appendingPathComponent("host.json")
    }

    private func writeState() {
        let state: [String: Any] = [
            "role": "host",
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "dataUUID": "",
            "pid": ProcessInfo.processInfo.processIdentifier,
            "playing": player?.isPlaying ?? false,
            "background": inBackground,
            "enabled": keepAliveEnabled,
            "watchdogEnabled": watchdogEnabled,
            "beat": Date().timeIntervalSince1970,
            "watchdog": lastWatchdogConfirm?.timeIntervalSince1970 ?? 0,
            "playStart": sessionStart?.timeIntervalSince1970 ?? 0,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state) else { return }
        let url = stateFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
