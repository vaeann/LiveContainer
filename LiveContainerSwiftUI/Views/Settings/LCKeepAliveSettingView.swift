//
//  LCKeepAliveSettingView.swift
//  LiveContainerSwiftUI
//
//  Settings page for background keep-alive: one global switch (default
//  on, no per-app switches), a session duration cap, a watchdog switch,
//  and a live status panel fed by the state file the host keeper
//  writes into the app group. The switch also deploys the guest-side
//  plugin (CZFKeepAlive.dylib) — see LCHostKeepAlive.
//

import Combine
import SwiftUI
import UIKit

private struct KeepAliveRecord: Identifiable {
    var id: String
    var role: String
    var dataUUID: String
    var playing: Bool
    var watchdogEnabled: Bool
    var beat: Date?
    var watchdog: Date?
    var playStart: Date?

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
                .onChange(of: keepAliveEnabled) { enabled in
                    // The guest-side plugin is deployed (or removed)
                    // with the switch — see LCHostKeepAlive.
                    LCHostKeepAlive.syncKeepAliveTweak(enabled: enabled)
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
            }
        }
        .padding(.vertical, 2)
    }

    private func statusText(for record: KeepAliveRecord) -> String {
        // Only live sessions reach the panel (see reload()).
        guard let playStart = record.playStart else {
            return "lc.keepAlive.status.active".loc
        }
        let elapsed = Self.durationFormatter.string(from: playStart, to: Date()) ?? ""
        return "\("lc.keepAlive.status.active".loc) · \("lc.keepAlive.status.elapsed".loc) \(elapsed)"
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
                watchdogEnabled: dict["watchdogEnabled"] as? Bool ?? true,
                beat: date("beat"),
                watchdog: date("watchdog"),
                playStart: date("playStart")
            )
            // Prune state files of processes that died long ago, so
            // the directory does not grow one stale file per app
            // forever; a live process recreates its file on the next
            // transition.
            if !record.isAlive, let beat = record.beat, Date().timeIntervalSince(beat) > 48 * 3600 {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            // Only sessions keeping alive right now are listed —
            // the panel mirrors 微珠: no history, no idle entries.
            if record.isAlive {
                loaded.append(record)
            }
        }
        // Host ahead of guests, then by most recent heartbeat.
        loaded.sort {
            if $0.isHost != $1.isHost { return $0.isHost }
            return ($0.beat ?? .distantPast) > ($1.beat ?? .distantPast)
        }
        records = loaded
    }
}

/// Viewer for the temporary keep-alive diagnostic log: one shared
/// file written by the host keeper (see LCHostKeepAlive.logEvent).
/// Newest first, last 200
/// lines. New-format lines ("11-21 16:46:02 Swiftgram · 保活开始")
/// render as time / source / event columns; older lines still in
/// the file are shown as-is. The copy button puts the whole log on
/// the clipboard; the clear button truncates the file.
struct LCKeepAliveLogView: View {
    @State private var lines: [String] = []
    @State private var copied = false

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
                    logRow(lines[index])
                }
            }
        }
        .navigationTitle("lc.keepAlive.log".loc)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(copied ? "lc.keepAlive.logCopied".loc : "lc.keepAlive.logCopy".loc) {
                    copyLog()
                }
                .disabled(lines.isEmpty)
                Button("lc.keepAlive.logClear".loc) {
                    clearLog()
                }
            }
        }
        .onAppear { reload() }
    }

    private func logRow(_ line: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let parts = parse(line) {
                Text(parts.time)
                    .foregroundStyle(.secondary)
                Text(parts.tag)
                    .fontWeight(.semibold)
                Text(parts.event)
            } else {
                Text(line)
            }
        }
        .font(.footnote.monospaced())
    }

    /// "11-21 16:46:02 Swiftgram · 保活开始" → time / tag / event.
    private func parse(_ line: String) -> (time: String, tag: String, event: String)? {
        guard line.count > 14 else { return nil }
        let timeEnd = line.index(line.startIndex, offsetBy: 14)
        let time = String(line[..<timeEnd])
        let rest = line[timeEnd...].trimmingCharacters(in: .whitespaces)
        guard let range = rest.range(of: " · ") else { return nil }
        let tag = String(rest[..<range.lowerBound])
        let event = String(rest[range.upperBound...])
        guard !tag.isEmpty, !event.isEmpty else { return nil }
        return (time, tag, event)
    }

    private func copyLog() {
        UIPasteboard.general.string = lines.joined(separator: "\n")
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
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
