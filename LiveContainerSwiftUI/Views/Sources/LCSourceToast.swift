//
//  LCSourceToast.swift
//  LiveContainerSwiftUI
//
//  The sources page's little reminder bar (Ann 2026-11-27,
//  her pick of three drawn designs): a floating pill that
//  slides down under the navigation bar, stays about three
//  seconds, and can carry an Undo. Liquid glass — white in
//  light mode, black in dark — with a semantic icon in
//  front: green check for a done thing, red cross for an
//  error, yellow mark for a warning (her spec; the error
//  and warning kinds are built in and wired up as fitting
//  cases appear).
//

import Foundation
import SwiftUI
import UIKit

enum LCToastKind {
    case success
    case error
    case warning

    var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: return Color(red: 0.18, green: 0.75, blue: 0.31)
        case .error: return Color(red: 0.96, green: 0.23, blue: 0.19)
        case .warning: return Color(red: 0.96, green: 0.73, blue: 0.05)
        }
    }
}

/// One showing of the reminder bar. The undo, when
/// present, runs and dismisses the bar.
struct LCSourceToastData: Identifiable {
    let id = UUID()
    let kind: LCToastKind
    let message: String
    let undo: (() -> Void)?
}

struct LCSourceToastView: View {
    let toast: LCSourceToastData
    let onUndo: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: toast.kind.symbol)
                .font(.system(size: 21))
                .foregroundStyle(toast.kind.color)
            Text(toast.message)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if toast.undo != nil {
                Button("lc.common.undo".loc) {
                    onUndo()
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.accentColor)
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 9)
        .modifier(LCToastGlassBackground())
    }
}

/// The pill's material (Ann 2026-11-27): liquid glass
/// where it runs — it reads white in light mode and
/// black in dark on its own — and a near-solid capsule
/// in the same two tones where it does not.
private struct LCToastGlassBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
            content
                .glassEffect(.regular, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        } else {
            content
                .background(
                    Capsule().fill(colorScheme == .dark ? Color.black.opacity(0.85) : Color.white.opacity(0.94))
                )
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        }
    }
}
