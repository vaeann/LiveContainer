//
//  LCKeepAliveSettingView.swift
//  LiveContainerSwiftUI
//
//  Settings page for background keep-alive: one global switch (default
//  on, no per-app switches), a session duration cap, a watchdog switch,
//  and a live status panel fed by the state files the host keeper and
//  the guest engines write into the app group.
//

import Combine
import SwiftUI

private struct KeepAliveRecord: Identifiable {
    var id: String
    var role: String
    var dataUUID: String
    var playing: Bool
    var timedOut: Bool
    var watchdogEnabled: Bool
    var beat: Date?
    var watchdog: Date?
    var playStart: Date?
    var lastEnd: Date?
    var lastSeconds: TimeInterval

    /// A session only counts as live while its heartbeat is fresh: if the
    /// process died (jetsam, crash) the file stays behind with playing=true
    /// but the beat stops advancing.
    var isAlive: Bool {
        guard playing, let beat else { return false }
        return Date().timeIntervalSince(beat) <= 120
    }

    var isHost: Bool { role == "host" }
}

struct LCKeepAliveSettingView: View {
    @AppStorage("LCKeepAliveEnabled", store: LCUtils.appGroupUserDefault) var keepAliveEnabled = true
    @AppStorage("LCKeepAliveDurationMinutes", store: LCUtils.appGroupUserDefault) var durationMinutes = 20
    @AppStorage("LCKeepAliveWatchdogEnabled", store: LCUtils.appGroupUserDefault) var watchdogEnabled = true
    @AppStorage("LCKeepAliveLogEnabled", store: LCUtils.appGroupUserDefault) var logEnabled = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false

    @State private var records: [KeepAliveRecord] = []
    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let relativeFormatter = RelativeDateTimeFormatter()

    var body: some View {
        List {
            Section {
                Toggle(isOn: $keepAliveEnabled) {
                    Text("lc.keepAlive.enabled".loc)
                }
                Picker(selection: $durationMinutes) {
                    Text("lc.keepAlive.minutes".localizeWithFormat("10")).tag(10)
                    Text("lc.keepAlive.minutes".localizeWithFormat("20")).tag(20)
                    Text("lc.keepAlive.minutes".localizeWithFormat("30")).tag(30)
                    Text("lc.keepAlive.duration.unlimited".loc).tag(0)
                } label: {
                    Text("lc.keepAlive.duration".loc)
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $watchdogEnabled) {
                    Text("lc.keepAlive.watchdog".loc)
                }
            } footer: {
                Text("lc.keepAlive.desc".loc)
            }

            // Temporary diagnostic log (remove together with its
            // writers once keep-alive is confirmed healthy).
            Section {
                Toggle(isOn: $logEnabled) {
                    Text("lc.keepAlive.logEnabled".loc)
                }
                NavigationLink {
                    LCKeepAliveLogView()
                } label: {
                    Text("lc.keepAlive.logView".loc)
                }
            } header: {
                Text("lc.keepAlive.log".loc)
            } footer: {
                Text("lc.keepAlive.logDesc".loc)
            }

            Section {
                if records.isEmpty {
                    Text("lc.keepAlive.status.none".loc)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(records) { record in
                        recordRow(record)
                    }
                }
            } header: {
                Text("lc.keepAlive.status".loc)
            } footer: {
                Text("lc.keepAlive.statusDesc".loc)
            }
        }
        .navigationTitle("lc.keepAlive.title".loc)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .onReceive(refreshTimer) { _ in reload() }
    }

    // MARK: Rows

    private func recordRow(_ record: KeepAliveRecord) -> some View {
        HStack(spacing: 12) {
            if record.isHost {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.secondary.opacity(0.25))
                    Image(systemName: "house.fill")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 40, height: 40)
            } else if let app = appModel(for: record) {
                IconImageView(icon: app.appInfo.iconIsDarkIcon(darkModeIcon))
                    .frame(width: 40, height: 40)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.secondary.opacity(0.25))
                    Image(systemName: "app.fill")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: record))
                    .lineLimit(1)
                Text(statusText(for: record))
                    .font(.caption)
                    .foregroundStyle(record.isAlive ? Color.green : .secondary)
                Text(watchdogText(for: record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if record.lastSeconds > 0 {
                    Text(lastSessionText(for: record))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func statusText(for record: KeepAliveRecord) -> String {
        if record.isAlive, let playStart = record.playStart {
            let elapsed = Self.durationFormatter.string(from: playStart, to: Date()) ?? ""
            return "\("lc.keepAlive.status.active".loc) · \("lc.keepAlive.status.elapsed".loc) \(elapsed)"
        }
        if record.timedOut {
            return "lc.keepAlive.status.timedOut".loc
        }
        return "lc.keepAlive.status.idle".loc
    }

    private func watchdogText(for record: KeepAliveRecord) -> String {
        guard record.watchdogEnabled else {
            return "lc.keepAlive.watchdog.disabled".loc
        }
        guard let watchdog = record.watchdog else {
            return "lc.keepAlive.status.lastWatchdog".loc + " -"
        }
        let relative = Self.relativeFormatter.localizedString(for: watchdog, relativeTo: Date())
        return "\("lc.keepAlive.status.lastWatchdog".loc): \(relative)"
    }

    private func lastSessionText(for record: KeepAliveRecord) -> String {
        let duration = Self.durationFormatter.string(from: record.lastSeconds) ?? ""
        if let lastEnd = record.lastEnd {
            let relative = Self.relativeFormatter.localizedString(for: lastEnd, relativeTo: Date())
            return "\("lc.keepAlive.status.lastSession".loc): \(duration) · \(relative)"
        }
        return "\("lc.keepAlive.status.lastSession".loc): \(duration)"
    }

    // MARK: Data

    private func appModel(for record: KeepAliveRecord) -> LCAppModel? {
        let model = DataManager.shared.model
        return (model.apps + model.hiddenApps).first { $0.appInfo.dataUUID == record.dataUUID }
    }

    private func displayName(for record: KeepAliveRecord) -> String {
        if record.isHost {
            return "lc.keepAlive.host".loc
        }
        return appModel(for: record)?.displayName ?? record.dataUUID
    }

    private func reload() {
        let dir = LCPath.lcGroupDocPath.appendingPathComponent("KeepAliveState")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            records = []
            return
        }
        var loaded: [KeepAliveRecord] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            func date(_ key: String) -> Date? {
                guard let epoch = dict[key] as? Double, epoch > 0 else { return nil }
                return Date(timeIntervalSince1970: epoch)
            }
            let role = dict["role"] as? String ?? "guest"
            let dataUUID = dict["dataUUID"] as? String ?? ""
            let record = KeepAliveRecord(
                id: role == "host" ? "host" : dataUUID,
                role: role,
                dataUUID: dataUUID,
                playing: dict["playing"] as? Bool ?? false,
                timedOut: dict["timedOut"] as? Bool ?? false,
                watchdogEnabled: dict["watchdogEnabled"] as? Bool ?? true,
                beat: date("beat"),
                watchdog: date("watchdog"),
                playStart: date("playStart"),
                lastEnd: date("lastEnd"),
                lastSeconds: dict["lastSeconds"] as? Double ?? 0
            )
            let freshest = max(record.beat ?? .distantPast, record.lastEnd ?? .distantPast)
            // Prune state files of sessions that ended long ago, so the
            // directory does not grow one stale file per app forever; a
            // live process recreates its file on the next transition.
            if !record.isAlive, Date().timeIntervalSince(freshest) > 48 * 3600 {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            // The panel is a status view, not a history log: live
            // sessions, plus sessions that ended within the last
            // 30 minutes so a just-finished (or timed-out) session can
            // still be checked.
            if record.isAlive || Date().timeIntervalSince(freshest) <= 30 * 60 {
                loaded.append(record)
            }
        }
        // Live sessions first (host ahead of guests), then the rest by
        // most recent activity.
        loaded.sort {
            if $0.isAlive != $1.isAlive { return $0.isAlive }
            if $0.isHost != $1.isHost { return $0.isHost }
            let a = max($0.beat ?? .distantPast, $0.lastEnd ?? .distantPast)
            let b = max($1.beat ?? .distantPast, $1.lastEnd ?? .distantPast)
            return a > b
        }
        records = loaded
    }
}

/// Viewer for the temporary keep-alive diagnostic log: one shared
/// file written by the host keeper and every guest engine (see
/// LCKeepAliveLogEvent in LCBootstrap.m). Newest first, last 200
/// lines; the trash button truncates the file.
struct LCKeepAliveLogView: View {
    @State private var lines: [String] = []

    private var logURL: URL {
        LCPath.lcGroupDocPath
            .appendingPathComponent("KeepAliveState")
            .appendingPathComponent("keepalive.log")
    }

    var body: some View {
        List {
            if lines.isEmpty {
                Text("lc.keepAlive.logEmpty".loc)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index])
                        .font(.footnote.monospaced())
                }
            }
        }
        .navigationTitle("lc.keepAlive.log".loc)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("lc.keepAlive.logClear".loc) {
                    clearLog()
                }
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            lines = []
            return
        }
        lines = Array(content
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .suffix(200)
            .reversed())
    }

    private func clearLog() {
        try? Data().write(to: logURL, options: .atomic)
        lines = []
    }
}
