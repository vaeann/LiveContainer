//
//  LCKeepAliveSettingView.swift
//  LiveContainerSwiftUI
//
//  Settings page for background keep-alive. The engine is the
//  standalone FMKeepAlive.dylib module (extracted from 微珠's
//  LCOrbit FMKeepAlive): this page only writes the module's three
//  settings into <appGroup>/LCOrbit/config.json — the same file,
//  format and keys the module reads — and deploys the dylib into
//  the global Tweaks folders. No keep-alive logic lives in LC
//  itself. LC and the module share one diagnostic log
//  (<appGroup>/LCOrbit/keepalive.log); this page shows it.
//

import SwiftUI

struct LCKeepAliveSettingView: View {
    @State private var enabled = true
    @State private var minutes = 20
    @State private var watchdog = true
    @State private var logEnabled = true

    var body: some View {
        List {
            Section {
                Toggle(isOn: $enabled) {
                    Text("lc.keepAlive.enabled".loc)
                }
                .onChange(of: enabled) { newValue in
                    Self.writePreference("keepAliveEnabled", value: newValue)
                    Self.logEvent("setting", "keepAliveEnabled=\(newValue)")
                    if newValue { Self.syncModule() }
                }
                Picker(selection: $minutes) {
                    Text("lc.keepAlive.minutes".localizeWithFormat("10")).tag(10)
                    Text("lc.keepAlive.minutes".localizeWithFormat("20")).tag(20)
                    Text("lc.keepAlive.minutes".localizeWithFormat("30")).tag(30)
                } label: {
                    Text("lc.keepAlive.duration".loc)
                }
                .pickerStyle(.segmented)
                .onChange(of: minutes) { newValue in
                    Self.writePreference("keepAliveMinutes", value: newValue)
                    Self.logEvent("setting", "keepAliveMinutes=\(newValue)")
                }
                Toggle(isOn: $watchdog) {
                    Text("lc.keepAlive.watchdog".loc)
                }
                .onChange(of: watchdog) { newValue in
                    Self.writePreference("keepAliveWatchdog", value: newValue ? 1 : 0)
                    Self.logEvent("setting", "keepAliveWatchdog=\(newValue ? 1 : 0)")
                }
            } footer: {
                Text("lc.keepAlive.desc".loc)
            }
            Section {
                Toggle(isOn: $logEnabled) {
                    Text("lc.keepAlive.logEnabled".loc)
                }
                .onChange(of: logEnabled) { newValue in
                    Self.writePreference("keepAliveLog", value: newValue)
                }
                NavigationLink {
                    LCKeepAliveLogView()
                } label: {
                    Text("lc.keepAlive.logView".loc)
                }
                Button(role: .destructive) {
                    Self.clearLog()
                } label: {
                    Text("lc.keepAlive.logClear".loc)
                }
            } header: {
                Text("lc.keepAlive.log".loc)
            } footer: {
                Text("lc.keepAlive.logDesc".loc)
            }
        }
        .navigationTitle("lc.keepAlive.title".loc)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            enabled = Self.boolPreference("keepAliveEnabled", default: true)
            minutes = Self.intPreference("keepAliveMinutes", default: 20)
            watchdog = Self.intPreference("keepAliveWatchdog", default: 1) != 0
            logEnabled = Self.boolPreference("keepAliveLog", default: true)
        }
    }

    // MARK: - Module settings store (<appGroup>/LCOrbit/config.json)

    static var configFileURL: URL {
        LCPath.lcGroupDocPath.deletingLastPathComponent()
            .appendingPathComponent("LCOrbit", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    static func readPreferences() -> [String: Any] {
        guard let data = try? Data(contentsOf: configFileURL),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prefs = doc["preferences"] as? [String: Any] else { return [:] }
        return prefs
    }

    static func writePreference(_ key: String, value: Any) {
        var prefs = readPreferences()
        prefs["LCFloatingMenu.\(key)"] = value
        let doc: [String: Any] = ["schemaVersion": 1, "preferences": prefs]
        guard let data = try? JSONSerialization.data(withJSONObject: doc,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? FileManager.default.createDirectory(
            at: configFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: configFileURL, options: .atomic)
    }

    static func boolPreference(_ key: String, default def: Bool) -> Bool {
        (readPreferences()["LCFloatingMenu.\(key)"] as? NSNumber)?.boolValue ?? def
    }

    static func intPreference(_ key: String, default def: Int) -> Int {
        (readPreferences()["LCFloatingMenu.\(key)"] as? NSNumber)?.intValue ?? def
    }

    // MARK: - Module deployment

    /// Copies the bundled FMKeepAlive.dylib into both global Tweaks
    /// folders and signs whatever is unsigned there. Runs at launch
    /// and when the switch is turned on. Turning the switch off only
    /// writes the preference — the module reads it and stops itself.
    static func syncModule() {
        guard boolPreference("keepAliveEnabled", default: true) else {
            logEvent("deploy-skip", "reason=disabled")
            return
        }
        // The module's host half only loads when LC injects tweaks
        // into itself (the same switch 微珠 relies on).
        UserDefaults.standard.set(true, forKey: "LCLoadTweaksToSelf")
        // The dylib ships base64-encoded (FMKeepAlive.dylib.b64):
        // as a loose dylib in the .app its load commands got
        // rewritten by install-time re-signing, which broke the
        // deployed copy. A text file passes through untouched.
        guard let src = Bundle.main.url(forResource: "FMKeepAlive.dylib", withExtension: "b64"),
              let packed = try? Data(contentsOf: src),
              let srcData = Data(base64Encoded: packed, options: [.ignoreUnknownCharacters])
        else {
            logEvent("deploy-skip", "reason=bundle-copy-missing-or-undecodable")
            return
        }
        logEvent("deploy", "bytes=\(srcData.count)")
        let fm = FileManager.default
        for folder in [LCPath.tweakPath, LCPath.lcGroupTweakPath] {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent("FMKeepAlive.dylib")
            let destData = try? Data(contentsOf: dest)
            if destData != srcData {
                // Write via a temp file so a failed write never
                // leaves the folder without a working dylib.
                let tmpDest = dest.appendingPathExtension("tmp")
                try? fm.removeItem(at: tmpDest)
                if (try? srcData.write(to: tmpDest)) != nil {
                    try? fm.removeItem(at: dest)
                    if (try? fm.moveItem(at: tmpDest, to: dest)) == nil {
                        try? fm.removeItem(at: tmpDest)
                    }
                }
                logEvent("deployed", "folder=\(folder.lastPathComponent) updated=true")
            } else {
                logEvent("deployed", "folder=\(folder.lastPathComponent) updated=false")
            }
        }
        Task {
            try? await LCUtils.signTweaks(tweakFolderUrl: LCPath.tweakPath)
            try? await LCUtils.signTweaks(tweakFolderUrl: LCPath.lcGroupTweakPath)
            logEvent("sign-tweaks", "done=true")
        }
    }

    // MARK: - Shared diagnostic log (<appGroup>/LCOrbit/keepalive.log)

    static var logFileURL: URL {
        LCPath.lcGroupDocPath.deletingLastPathComponent()
            .appendingPathComponent("LCOrbit", isDirectory: true)
            .appendingPathComponent("keepalive.log")
    }

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    /// Appends one line in the module's log format
    /// (`MM-dd HH:mm:ss LC · <event> <details>`). The module writes
    /// the same file with its own tags （宿主 / guest bundle tail).
    static func logEvent(_ event: String, _ details: String = "") {
        guard boolPreference("keepAliveLog", default: true) else { return }
        var line = "\(logTimeFormatter.string(from: Date())) LC · \(event)"
        if !details.isEmpty { line += " " + details }
        line += "\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: logFileURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logFileURL)
        }
    }

    static func clearLog() {
        try? FileManager.default.removeItem(at: logFileURL)
    }
}

struct LCKeepAliveLogView: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "lc.keepAlive.logEmpty".loc : text)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("lc.keepAlive.log".loc)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    LCKeepAliveSettingView.clearLog()
                    text = ""
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .onAppear {
            text = (try? String(contentsOf: LCKeepAliveSettingView.logFileURL,
                                encoding: .utf8)) ?? ""
        }
    }
}
