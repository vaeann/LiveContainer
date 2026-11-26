//
//  LCSourceSortMenu.swift
//  LiveContainerSwiftUI
//
//  The source section header's sort control (Ann
//  2026-11-26, design confirmed by preview in the main
//  chat): a custom popover card instead of a system
//  Menu, so the selection reads as rings, not checks.
//

import Foundation
import SwiftUI

/// Sort + today-filter popover for one source.
///
/// - The four sorts are a radio group: each row leads
///   with a 20pt ring — stroked and empty when
///   unselected, solid accent with NO check when
///   selected. Unselected rows keep the ring slot, so
///   the text never shifts sideways.
/// - "Today's updates" below the divider is a toggle,
///   not a radio: its ring fills WITH a white check
///   when on, so on/off and single-select read
///   differently at a glance.
///
/// Behavior is unchanged from the Menu it replaces:
/// the sort persists per source, the today filter is
/// session-only (both live in LCSourcesView), and the
/// popover supplies what the Menu used to — outside-tap
/// dismissal and the presentation animation.
struct LCSourceSortMenuButton: View {
    let sortMode: LCSourceAppSort
    let onSortModeChange: (LCSourceAppSort) -> Void
    let todayFilterOn: Bool
    let onToggleTodayFilter: () -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
                .imageScale(.large)
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented) {
            card
                .modifier(LCPopoverCardAdaptation())
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(LCSourceAppSort.allCases, id: \.self) { mode in
                row(title: mode.title, ring: sortMode == mode ? .filled : .empty) {
                    onSortModeChange(mode)
                    isPresented = false
                }
            }
            Divider()
                .padding(.vertical, 5)
            row(title: "lc.sources.filter.today".loc, ring: todayFilterOn ? .checked : .empty) {
                onToggleTodayFilter()
                isPresented = false
            }
        }
        .padding(8)
        .frame(width: 224)
    }

    private enum Ring {
        case empty
        case filled
        case checked
    }

    private func row(title: String, ring: Ring, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    switch ring {
                    case .empty:
                        Circle()
                            .strokeBorder(Color.secondary, lineWidth: 1.5)
                    case .filled:
                        Circle()
                            .fill(Color.accentColor)
                    case .checked:
                        Circle()
                            .fill(Color.accentColor)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 20, height: 20)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Keeps the popover a floating card on compact-width
/// devices too (iOS 16.4+); older systems fall back to
/// the default sheet-style presentation.
private struct LCPopoverCardAdaptation: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationCompactAdaptation(.popover)
        } else {
            content
        }
    }
}
