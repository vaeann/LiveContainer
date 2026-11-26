//
//  LCSourceSortMenu.swift
//  LiveContainerSwiftUI
//
//  The source section header's sort control (Ann
//  2026-11-26): a system Menu + Picker exactly like
//  the App page's top-right sort menu — rows carry an
//  icon and the selection takes the system check.
//  (A custom ring popover briefly replaced the system
//  menu; Ann then asked for the App page's own menu
//  style, and for the name/size sorts to go, leaving
//  default order and recently updated.)
//

import Foundation
import SwiftUI

/// Sort menu for one source, written the same way as
/// the App page's: a Menu holding a Picker of
/// icon-labelled rows. The sort persists per source
/// (storage lives in LCSourcesView / LCSourceAppSort).
struct LCSourceSortMenuButton: View {
    let sortMode: LCSourceAppSort
    let onSortModeChange: (LCSourceAppSort) -> Void

    var body: some View {
        Menu {
            Picker("Sort by", selection: sortBinding) {
                ForEach(LCSourceAppSort.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
        } label: {
            // Same glyph as the App page's sort menu
            // (top-right), so sorting reads the same
            // across the app. The fixed frame is load-
            // bearing (Ann 2026-11-27, on device): with
            // the label sized by the symbol alone, the
            // button shifted once when the page scrolled
            // after the menu had been opened and closed —
            // the menu's presentation leaves the button
            // measuring slightly differently until the
            // next layout pass settles it. A pinned 32×32
            // frame gives layout nothing to renegotiate.
            Image(systemName: "line.3.horizontal.decrease.circle")
                .imageScale(.large)
                .foregroundColor(.secondary)
                .frame(width: 32, height: 32)
        }
    }

    private var sortBinding: Binding<LCSourceAppSort> {
        Binding(get: { sortMode }, set: { onSortModeChange($0) })
    }
}
