//
//  LCHostKeepAlive.swift
//  LiveContainerSwiftUI
//
//  Host-side background keep-alive. While LiveContainer itself is in the
//  background with guest apps still running, the host loops a 1-second
//  silent WAV so the system does not reclaim the host (and with it the
//  LiveProcess guests). Guest processes run their own engine
//  (LCKeepAliveEngine in LCBootstrap); both share one global switch in the
//  app-group defaults — no per-app switches.
//
//  Settings (app-group defaults):
//    LCKeepAliveEnabled          Bool, default true
//    LCKeepAliveDurationMinutes  Int,  default 20, 0 = unlimited
//    LCKeepAliveWatchdogEnabled  Bool, default true
//

import AVFoundation
import Foundation
import UIKit

final class LCHostKeepAlive {
    static let shared = LCHostKeepAlive()

    private var player: AVAudioPlayer?
    private var watchdogTimer: Timer?
    private var capTimer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private var keepingAlive = false
    private var capReached = false
    private var interrupted = false

    private var sessionChanged = false
    private var savedCategory: AVAudioSession.Category?
    private var savedMode: AVAudioSession.Mode?
    private var savedOptions: AVAudioSession.CategoryOptions?

    private var sessionStart: Date?
    private var lastWatchdogConfirm: Date?
    private var lastEnd: Date?
    private var lastSeconds: TimeInterval = 0
    private var lastStopTimedOut = false

    private var started = false

    // MARK: Diagnostic log (temporary — see LCKeepAliveLogEvent in
    // LCBootstrap.m; remove together with its switch once keep-alive
    // is confirmed healthy)

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
        let defaults = LCUtils.appGroupUserDefault
        return defaults.object(forKey: "LCKeepAliveEnabled") == nil
            ? true
            : defaults.bool(forKey: "LCKeepAliveEnabled")
    }

    private var watchdogEnabled: Bool {
        let defaults = LCUtils.appGroupUserDefault
        return defaults.object(forKey: "LCKeepAliveWatchdogEnabled") == nil
            ? true
            : defaults.bool(forKey: "LCKeepAliveWatchdogEnabled")
    }

    private var durationMinutes: Int {
        let defaults = LCUtils.appGroupUserDefault
        return defaults.object(forKey: "LCKeepAliveDurationMinutes") == nil
            ? 20
            : defaults.integer(forKey: "LCKeepAliveDurationMinutes")
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        restoreLastRecord()
        writeState()

        let center = NotificationCenter.default
        // Early start, FMKeepAlive parity: begin playback while the
        // app is still resigning active, so audio is already rolling
        // when the backgrounding completes — waiting for
        // didEnterBackground leaves a gap where the system can
        // throttle the process before playback ever starts. A
        // transient resign (Control Center, call banner) is undone
        // by the willEnterForeground stop.
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, MultitaskManager.isMultitasking() else { return }
            self.tryStartSession(fromResign: true)
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.evaluate()
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.enterForeground()
        }
        // A transient resign (Control Center, call banner) that
        // started a session on willResignActive ends with
        // didBecomeActive and no willEnterForeground — stop there
        // too, or the session would run on in the foreground.
        // stopSession is idempotent, so the normal return path
        // firing both is harmless.
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.enterForeground()
        }
        // Guest set changes while backgrounded: start when the first guest
        // appears, stop as soon as the last one exits. Event-driven — the
        // running-apps registry is LC's own, no guessing, no polling.
        center.addObserver(forName: NSNotification.MultitaskRunningAppsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.evaluate()
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleMediaServicesFailure()
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleMediaServicesFailure()
        }
    }

    private func enterForeground() {
        stopSession(timedOut: false, reason: "回到前台")
        capReached = false
        interrupted = false
    }

    /// Start or stop playback to match the current conditions. Called on
    /// backgrounding and whenever the running-guest set changes.
    private func evaluate() {
        guard UIApplication.shared.applicationState == .background else { return }
        if MultitaskManager.isMultitasking() {
            tryStartSession()
        } else if keepingAlive {
            stopSession(timedOut: false, reason: "已无游客在跑")
        }
    }

    // MARK: Session control

    private func tryStartSession(fromResign: Bool = false) {
        guard keepAliveEnabled else {
            Self.logEvent("跳过保活：保活总开关已关闭")
            return
        }
        guard !capReached else {
            Self.logEvent("跳过保活：已达到时长上限")
            return
        }
        guard !interrupted else {
            Self.logEvent("跳过保活：正被音频打断")
            return
        }
        guard fromResign || UIApplication.shared.applicationState == .background else { return }
        guard MultitaskManager.isMultitasking() else { return }
        if startPlayback() {
            if !keepingAlive {
                keepingAlive = true
                lastStopTimedOut = false
                sessionStart = Date()
                scheduleCapTimer()
                Self.logEvent("保活开始")
            }
            beginKeepAliveBackgroundTask()
            scheduleWatchdog()
            writeState()
        } else {
            Self.logEvent("保活开始失败：音频未能启动")
        }
    }

    private func stopSession(timedOut: Bool, reason: String) {
        let wasKeepingAlive = keepingAlive
        keepingAlive = false
        capTimer?.invalidate()
        capTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        player?.pause()
        restoreAudioSession(wasKeepingAlive: wasKeepingAlive)
        endBackgroundTask()
        if wasKeepingAlive, let sessionStart {
            lastSeconds = Date().timeIntervalSince(sessionStart)
            lastEnd = Date()
        }
        sessionStart = nil
        if timedOut {
            capReached = true
        }
        lastStopTimedOut = timedOut
        writeState()
        if wasKeepingAlive {
            Self.logEvent("保活停止：\(reason)（本次 \(Int(lastSeconds)) 秒）")
        }
    }

    // Second channel, FMKeepAlive parity: a background task taken at
    // session start keeps the host process scheduled even if the
    // audio path hiccups in the first seconds — the window where this
    // keeper previously died before its first watchdog tick. On
    // expiry the player is rebuilt on the re-verified session and a
    // fresh task is taken, so one expiry does not end the session.
    private func beginKeepAliveBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LCHostKeepAlive") { [weak self] in
            guard let self else { return }
            Self.logEvent("后台任务已到期")
            self.endBackgroundTask()
            if self.keepingAlive, UIApplication.shared.applicationState == .background {
                self.player = nil
                _ = self.startPlayback()
                self.beginKeepAliveBackgroundTask()
                self.writeState()
            }
        }
    }

    // MARK: Audio

    private static let silentWAVData: Data = {
        var data = Data()
        let sampleRate: UInt32 = 8000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let chunkSize: UInt32 = 36 + dataSize
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        func appendString(_ string: String) {
            data.append(string.data(using: .ascii)!)
        }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        appendString("RIFF")
        appendLE(chunkSize)
        appendString("WAVE")
        appendString("fmt ")
        appendLE(UInt32(16))
        appendLE(UInt16(1)) // PCM
        appendLE(channels)
        appendLE(sampleRate)
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        appendString("data")
        appendLE(dataSize)
        data.append(Data(count: Int(dataSize))) // zero-filled = silence
        return data
    }()

    private func startPlayback() -> Bool {
        if player?.isPlaying == true {
            return true
        }
        let session = AVAudioSession.sharedInstance()
        // The session is shared with every guest process: another
        // process may have changed (or restored) the category since
        // this keeper last set it, so verify the live values on
        // every start instead of trusting sessionChanged — a
        // non-playback category in the background means no keep-alive.
        let category = session.category
        let options = session.categoryOptions
        if category != .playback || !options.contains(.mixWithOthers) {
            if !sessionChanged {
                // Remember LC's own configuration so stop can restore
                // exactly what we changed — and nothing else.
                savedCategory = category
                savedOptions = options
                savedMode = session.mode
                sessionChanged = true
            }
            try? session.setCategory(.playback, mode: savedMode ?? .default, options: options.union(.mixWithOthers))
        }
        try? session.setActive(true)
        if player == nil {
            player = try? AVAudioPlayer(data: Self.silentWAVData)
            player?.numberOfLoops = -1 // loop forever
            player?.volume = 0
            player?.prepareToPlay()
        }
        return player?.play() ?? false
    }

    private func restoreAudioSession(wasKeepingAlive: Bool) {
        // While still backgrounded, leave the shared session alone:
        // it is one session for the host and all guests, so restoring
        // the category or deactivating here would cut the ground from
        // under every guest still keeping alive. The full restore
        // runs on the foreground stop.
        guard UIApplication.shared.applicationState != .background else { return }
        let session = AVAudioSession.sharedInstance()
        if sessionChanged, let savedCategory, let savedOptions {
            try? session.setCategory(savedCategory, mode: savedMode ?? .default, options: savedOptions)
            sessionChanged = false
        }
        // Deactivate only when nothing else is playing: if an app has audio
        // running, its session stays untouched.
        if wasKeepingAlive && !session.isOtherAudioPlaying {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Duration cap (independent timer, not the watchdog)

    private func scheduleCapTimer() {
        capTimer?.invalidate()
        capTimer = nil
        let minutes = durationMinutes
        guard minutes > 0 else { return } // unlimited
        let timer = Timer(timeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            self?.stopSession(timedOut: true, reason: "达到时长上限")
        }
        RunLoop.main.add(timer, forMode: .common)
        capTimer = timer
    }

    // MARK: Watchdog (adaptive interval, heartbeat for the status panel)

    private func scheduleWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        guard keepingAlive, watchdogEnabled else { return }
        let elapsed = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        let interval: TimeInterval = elapsed < 300 ? 30 : (elapsed < 600 ? 45 : 60)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.watchdogTick()
        }
        timer.tolerance = interval / 3
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func watchdogTick() {
        guard keepingAlive else { return }
        if !keepAliveEnabled {
            // The global switch is the fuse: turning it off stops everything.
            stopSession(timedOut: false, reason: "保活总开关被关闭")
            return
        }
        if !MultitaskManager.isMultitasking() {
            stopSession(timedOut: false, reason: "已无游客在跑")
            return
        }
        lastWatchdogConfirm = Date()
        if !interrupted && player?.isPlaying != true {
            // Rebuild the player from scratch on the re-verified
            // session: re-playing a player whose session was
            // deactivated under it does not reliably recover.
            player = nil
            if startPlayback() {
                Self.logEvent("看门狗发现播放已停止，已重新启动")
            } else {
                Self.logEvent("看门狗恢复播放失败")
            }
        }
        writeState()
        scheduleWatchdog()
    }

    // MARK: Interruptions & media services

    private func handleInterruption(_ note: Notification) {
        guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        switch type {
        case .began:
            interrupted = true
            // No extra background task here: the session's own task
            // (taken at start) already holds the process through the
            // interruption.
            if keepingAlive {
                Self.logEvent("音频被打断")
            }
        case .ended:
            interrupted = false
            // The background task belongs to the session, not to the
            // interruption — it ends in stopSession.
            if let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
                if keepingAlive {
                    Self.logEvent("音频打断结束，恢复播放")
                }
                evaluate()
            }
        @unknown default:
            break
        }
    }

    private func handleMediaServicesFailure() {
        // The media server died or reset: the player and session
        // configuration are gone — rebuild both instead of trusting the
        // watchdog to notice a dead player.
        player = nil
        sessionChanged = false
        if keepingAlive {
            Self.logEvent("媒体服务丢失或重置，已重建播放器")
            _ = startPlayback()
            writeState()
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: State file (read by the settings status panel)

    private var stateFileURL: URL {
        LCPath.lcGroupDocPath
            .appendingPathComponent("KeepAliveState")
            .appendingPathComponent("host.json")
    }

    private func restoreLastRecord() {
        guard let data = try? Data(contentsOf: stateFileURL),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let lastEndEpoch = state["lastEnd"] as? Double, lastEndEpoch > 0 {
            lastEnd = Date(timeIntervalSince1970: lastEndEpoch)
            lastSeconds = state["lastSeconds"] as? Double ?? 0
        }
    }

    private func writeState() {
        let state: [String: Any] = [
            "role": "host",
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "dataUUID": "",
            "pid": ProcessInfo.processInfo.processIdentifier,
            "playing": keepingAlive,
            "background": UIApplication.shared.applicationState == .background,
            "timedOut": lastStopTimedOut,
            "enabled": keepAliveEnabled,
            "watchdogEnabled": watchdogEnabled,
            "beat": Date().timeIntervalSince1970,
            "watchdog": lastWatchdogConfirm?.timeIntervalSince1970 ?? 0,
            "playStart": sessionStart?.timeIntervalSince1970 ?? 0,
            "lastEnd": lastEnd?.timeIntervalSince1970 ?? 0,
            "lastSeconds": lastSeconds,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: stateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: stateFileURL, options: .atomic)
    }
}
