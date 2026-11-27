//
//  LCSourceSortMenu.swift
//  LiveContainerSwiftUI
//
//  The sources page's sort control (Ann 2026-11-26;
//  moved into the toolbar beside the add button
//  2026-11-27, then aligned with the App page's own
//  top-right buttons later that day — a separate
//  toolbar item with the system gap, and the label
//  below is the App page's exact Label: default size,
//  default colour, no large scale, no grey tint):
//  a system Menu + Picker exactly like the App page's
//  top-right sort menu — rows carry an icon and the
//  selection takes the system check.
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
            // The App page's sort-menu label verbatim
            // (LCAppListView's top-right Menu): same
            // glyph, same default size and colour, so
            // the two pages' buttons match.
            Label("Sort by", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private var sortBinding: Binding<LCSourceAppSort> {
        Binding(get: { sortMode }, set: { onSortModeChange($0) })
    }
}
