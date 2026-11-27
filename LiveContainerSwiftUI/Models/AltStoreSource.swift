//
//  AltStoreSource.swift
//  LiveContainerSwiftUI
//
//  Split out of LCAltStoreSourcesView.swift (2026-11-26 refactor,
//  stage 1: pure move, no code changes).
//

import CryptoKit
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
    /// This source's badge color (hex), assigned by the
    /// view model when the source is decoded — a random
    /// palette color no other current source uses,
    /// persisted per source URL so it stays fixed across
    /// launches (Ann 2026-11-26). Stamped after decoding,
    /// never part of the source file.
    var badgeColorHex: String?

    var badgeColor: Color? {
        badgeColorHex.flatMap { lcColor(fromHex: $0) }
    }
}

/// HSL → RGB (hue in degrees, saturation / lightness
/// 0…1), channels truncated like Ann's source
/// generator does.
func lcHSLToRGB(hue: Double, saturation: Double, lightness: Double) -> (r: Double, g: Double, b: Double) {
    let c = (1 - abs(2 * lightness - 1)) * saturation
    let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
    let m = lightness - c / 2
    let sector = (Int(hue) / 60) % 6
    let base: (Double, Double, Double)
    switch sector {
    case 0: base = (c, x, 0)
    case 1: base = (x, c, 0)
    case 2: base = (0, c, x)
    case 3: base = (0, x, c)
    case 4: base = (x, 0, c)
    default: base = (c, 0, x)
    }
    return (base.0 + m, base.1 + m, base.2 + m)
}

func lcColor(fromHex hex: String) -> Color? {
    var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    cleaned = cleaned.replacingOccurrences(of: "#", with: "")
    guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
    return Color(
        red: Double((value & 0xFF0000) >> 16) / 255,
        green: Double((value & 0x00FF00) >> 8) / 255,
        blue: Double(value & 0x0000FF) / 255
    )
}

extension AltStoreSourceApp {
    /// The card color is decided here, not by the source
    /// file (Ann 2026-11-26): MD5 of the bundle id, with
    /// the exact recipe her own AltSource collection
    /// uses — hue from the digest's first 8 hex digits,
    /// saturation 58–69%, lightness 44–52% (HSL). The
    /// same app gets the same color in every source and
    /// on every launch, with no storage; the narrow S/L
    /// bands keep all cards in one visual family.
    var lcCardColor: Color {
        // Module-qualified: inside this property the name
        // lcCardColor resolves to the property itself.
        LiveContainerSwiftUI.lcCardColor(forKey: bundleIdentifier)
    }
}

/// The shared card-color recipe (see above), keyed by
/// any stable string — the downloads library colors its
/// cards with it too, keyed by bundle id.
func lcCardColor(forKey key: String) -> Color {
    let digest = Insecure.MD5.hash(data: Data(key.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    let hue = Double(Int(hex.prefix(8), radix: 16)! % 360)
    let saturation = Double(58 + (Int(hex.dropFirst(8).prefix(2), radix: 16)! % 12)) / 100
    let lightness = Double(44 + (Int(hex.dropFirst(10).prefix(2), radix: 16)! % 9)) / 100
    let rgb = lcHSLToRGB(hue: hue, saturation: saturation, lightness: lightness)
    return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
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
    /// The updates segment's form for an ignored update
    /// (Ann 2026-11-27): the button says Ignored, and
    /// tapping it lifts the ignore instead of updating —
    /// it turns back into Update.
    case ignored

    var title: String {
        switch self {
        case .get: return "lc.sources.action.get".loc
        case .open: return "lc.sources.action.open".loc
        case .update: return "lc.sources.action.update".loc
        case .ignored: return "lc.sources.action.ignored".loc
        }
    }
}
