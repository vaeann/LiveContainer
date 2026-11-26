//
//  AltStoreSource.swift
//  LiveContainerSwiftUI
//
//  Split out of LCAltStoreSourcesView.swift (2026-11-26 refactor,
//  stage 1: pure move, no code changes).
//

import Foundation
import SwiftUI

struct AltStoreSourceAppVersion: Identifiable, Hashable {
    let id = UUID()
    let version: String
    let buildVersion: String?
    let releaseDate: Date?
    let localizedDescription: String?
    let downloadURL: URL
    let size: Int64?
}

struct AltStoreSourceApp: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let subtitle: String?
    let description: String?
    let iconURL: URL?
    let tintColor: Color?
    let screenshots: [URL]
    let versions: [AltStoreSourceAppVersion]
    let latestVersion: AltStoreSourceAppVersion?
    let isBeta: Bool
}

struct AltStoreSource: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let identifier: String?
    let subtitle: String?
    let description: String?
    let iconURL: URL?
    let headerURL: URL?
    let tintColor: Color?
    let website: URL?
    let apps: [AltStoreSourceApp]
}

/// Segment-wise numeric version comparison (1.10 > 1.9); non-numeric
/// segments count as 0.
func lcIsVersion(_ a: String, newerThan b: String) -> Bool {
    let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
    let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
    let count = max(aParts.count, bParts.count)
    for i in 0..<count {
        let av = i < aParts.count ? aParts[i] : 0
        let bv = i < bParts.count ? bParts[i] : 0
        if av != bv { return av > bv }
    }
    return false
}

/// "Ignore this version" storage: per bundle id, the source version the
/// user chose to stop being reminded about. Ignoring only silences the
/// reminder (the sources-page row and the badge count); the app stays in
/// the Updates tab and in "Update All". A newer source version no longer
/// matches the stored one and reminds again.
enum LCSourceUpdateIgnore {
    private static func key(for bundleIdentifier: String) -> String {
        "LCIgnoredSourceUpdate-\(bundleIdentifier)"
    }

    static func ignoredVersion(for bundleIdentifier: String) -> String? {
        UserDefaults.standard.string(forKey: key(for: bundleIdentifier))
    }

    static func setIgnoredVersion(_ version: String?, for bundleIdentifier: String) {
        if let version {
            UserDefaults.standard.set(version, forKey: key(for: bundleIdentifier))
        } else {
            UserDefaults.standard.removeObject(forKey: key(for: bundleIdentifier))
        }
    }

    static func isIgnored(app: AltStoreSourceApp) -> Bool {
        guard let latest = app.latestVersion else { return false }
        return ignoredVersion(for: app.bundleIdentifier) == latest.version
    }
}

/// Per-source app ordering, chosen from the sort menu in
/// the source's section header (Ann 2026-11-26). Stored
/// per source URL, mirroring LCSourceUpdateIgnore above;
/// unstored means the source's own order. "Recently
/// updated" keys on each app's latest version date —
/// every app in a well-formed source carries one.
enum LCSourceAppSort: String, CaseIterable {
    case sourceOrder
    case recentlyUpdated

    var title: String {
        switch self {
        case .sourceOrder: return "lc.sources.sort.sourceOrder".loc
        case .recentlyUpdated: return "lc.sources.sort.recent".loc
        }
    }

    /// Menu icon, mirroring the App page's sort menu
    /// (its default is "ellipsis", its recency sort
    /// is "clock").
    var systemImage: String {
        switch self {
        case .sourceOrder: return "ellipsis"
        case .recentlyUpdated: return "clock"
        }
    }

    private static func key(for sourceURL: URL) -> String {
        "LCSourceAppSort-\(sourceURL.absoluteString)"
    }

    static func storedMode(for sourceURL: URL) -> LCSourceAppSort {
        guard let raw = UserDefaults.standard.string(forKey: key(for: sourceURL)) else {
            return .sourceOrder
        }
        return LCSourceAppSort(rawValue: raw) ?? .sourceOrder
    }

    static func storeMode(_ mode: LCSourceAppSort, for sourceURL: URL) {
        UserDefaults.standard.set(mode.rawValue, forKey: key(for: sourceURL))
    }
}

/// What the single action button on a source app row offers.
enum LCSourceAppButtonState {
    case get
    case open
    case update

    var title: String {
        switch self {
        case .get: return "lc.sources.action.get".loc
        case .open: return "lc.sources.action.open".loc
        case .update: return "lc.sources.action.update".loc
        }
    }
}
