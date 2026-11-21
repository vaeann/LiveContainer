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
//  itself.
//

import Compression
import SwiftUI

struct LCKeepAliveSettingView: View {
    @State private var enabled = true
    @State private var minutes = 20
    @State private var watchdog = true

    var body: some View {
        List {
            Section {
                Toggle(isOn: $enabled) {
                    Text("lc.keepAlive.enabled".loc)
                }
                .onChange(of: enabled) { newValue in
                    Self.writePreference("keepAliveEnabled", value: newValue)
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
                }
                Toggle(isOn: $watchdog) {
                    Text("lc.keepAlive.watchdog".loc)
                }
                .onChange(of: watchdog) { newValue in
                    Self.writePreference("keepAliveWatchdog", value: newValue ? 1 : 0)
                }
            } footer: {
                Text("lc.keepAlive.desc".loc)
            }
        }
        .navigationTitle("lc.keepAlive.title".loc)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            enabled = Self.boolPreference("keepAliveEnabled", default: true)
            minutes = Self.intPreference("keepAliveMinutes", default: 20)
            watchdog = Self.intPreference("keepAliveWatchdog", default: 1) != 0
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
        guard boolPreference("keepAliveEnabled", default: true) else { return }
        // The module's host half only loads when LC injects tweaks
        // into itself (the same switch 微珠 relies on).
        UserDefaults.standard.set(true, forKey: "LCLoadTweaksToSelf")
        // The dylib ships compressed (FMKeepAlive.dylib.z): as a
        // loose dylib in the .app its load commands got rewritten by
        // install-time re-signing, which broke the deployed copy.
        guard let src = Bundle.main.url(forResource: "FMKeepAlive.dylib", withExtension: "z"),
              let packed = try? Data(contentsOf: src),
              let srcData = try? (packed as NSData).decompressed(using: .zlib)
        else { return }
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
            }
        }
        Task {
            try? await LCUtils.signTweaks(tweakFolderUrl: LCPath.tweakPath)
            try? await LCUtils.signTweaks(tweakFolderUrl: LCPath.lcGroupTweakPath)
        }
    }
}
