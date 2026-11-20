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
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.evaluate()
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
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
        stopSession(timedOut: false)
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
            stopSession(timedOut: false)
        }
    }

    // MARK: Session control

    private func tryStartSession() {
        guard keepAliveEnabled, !capReached, !interrupted else { return }
        guard UIApplication.shared.applicationState == .background else { return }
        guard MultitaskManager.isMultitasking() else { return }
        if startPlayback() {
            if !keepingAlive {
                keepingAlive = true
                lastStopTimedOut = false
                sessionStart = Date()
                scheduleCapTimer()
            }
            scheduleWatchdog()
            writeState()
        }
    }

    private func stopSession(timedOut: Bool) {
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
        if !sessionChanged {
            let category = session.category
            let options = session.categoryOptions
            if category != .playback || !options.contains(.mixWithOthers) {
                // Remember LC's own configuration so stop can restore
                // exactly what we changed — and nothing else.
                savedCategory = category
                savedOptions = options
                savedMode = session.mode
                try? session.setCategory(.playback, mode: session.mode, options: options.union(.mixWithOthers))
                sessionChanged = true
            }
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
            self?.stopSession(timedOut: true)
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
            stopSession(timedOut: false)
            return
        }
        if !MultitaskManager.isMultitasking() {
            stopSession(timedOut: false)
            return
        }
        lastWatchdogConfirm = Date()
        if !interrupted && player?.isPlaying != true {
            _ = startPlayback()
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
            // Second channel: a background task keeps the host process
            // alive through the interruption so playback can resume after.
            if keepingAlive && backgroundTask == .invalid {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LCHostKeepAliveInterruption") { [weak self] in
                    self?.endBackgroundTask()
                }
            }
        case .ended:
            interrupted = false
            endBackgroundTask()
            if let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
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
