//
//  LCMultitaskGuideViews.swift
//  LiveContainer
//
//  The two tutorial pages behind the entries at the
//  bottom of the multitask settings (Ann 2026-11-27).
//  "Multitask Guide": the two skeleton figures (edge
//  handle / expanded dock) side by side on top, the
//  text and the numbered legend 1-6 below. "Multitask
//  Gestures": the window four-corner figure on the
//  left, the legend 7-10 on the right. The figures are
//  drawn, not images, on a 430x932 canvas at the real
//  proportions (dock width 80, icons 54, handle 14x80,
//  corner gesture areas 44), so they stay truthful at
//  whatever size the page gives them.
//

import SwiftUI

/// A numbered badge in a legend row (display size).
private struct LCGuideNumberBadge: View {
    let number: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 19, height: 19)
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

/// One legend row: badge, bold title, description.
private struct LCGuideLegendRow: View {
    let number: Int
    let titleKey: String
    let descKey: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LCGuideNumberBadge(number: number)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleKey.loc)
                    .font(.subheadline.weight(.semibold))
                Text(descKey.loc)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// The skeleton figures. Everything is laid out on a
/// 430x932 canvas (points on the real screen) and
/// scaled by the width the page hands in, so the
/// proportions are the device's own: the window bar's
/// dots sit where the real bar puts them (first dot's
/// left edge at 26, 20 across, 16 apart), the dock is
/// 80 wide with 54 icons and the home button last, the
/// handle is 14 wide and as tall as the dock is wide,
/// and the corner gesture areas are 44 squares.
private struct LCGuideFigure: View {
    enum Kind {
        case handle
        case dock
        case corners
    }

    let kind: Kind

    // The window bar's dot colors, taken from
    // DecoratedAppSceneViewController so the drawing
    // matches the real bar exactly.
    private let dotRed = Color(red: 1.0, green: 0.373, blue: 0.341)
    private let dotYellow = Color(red: 0.996, green: 0.737, blue: 0.180)
    private let dotGreen = Color(red: 0.157, green: 0.784, blue: 0.251)

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 430
            ZStack(alignment: .topLeading) {
                // Screen frame.
                RoundedRectangle(cornerRadius: 50 * s)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .frame(width: 430 * s, height: 932 * s)
                    .overlay(
                        RoundedRectangle(cornerRadius: 50 * s)
                            .stroke(Color(uiColor: .separator), lineWidth: 1.2)
                    )
                // Dynamic island.
                Capsule()
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: 126 * s, height: 30 * s)
                    .offset(x: 152 * s, y: 24 * s)
                switch kind {
                case .handle:
                    windowWithBar(s)
                    handle(s)
                    badge(6, centerX: 48, centerY: 104, s: s)
                    badge(1, centerX: 390, centerY: 402, s: s)
                case .dock:
                    windowWithBar(s)
                    // The tap-outside region: the whole
                    // screen except the dock, tinted.
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.10))
                        .frame(width: 430 * s, height: 932 * s)
                    expandedDock(s)
                    badge(5, centerX: 90, centerY: 330, s: s)
                case .corners:
                    cornerWindow(s)
                    badge(7, centerX: 43, centerY: 121, s: s)
                    badge(8, centerX: 387, centerY: 121, s: s)
                    badge(9, centerX: 43, centerY: 792, s: s)
                    badge(10, centerX: 387, centerY: 792, s: s)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 50 * s))
        }
        .aspectRatio(430.0 / 932.0, contentMode: .fit)
    }

    /// A badge inside a figure, at canvas scale.
    private func badge(_ number: Int, centerX: CGFloat, centerY: CGFloat, s: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 44 * s, height: 44 * s)
            Text("\(number)")
                .font(.system(size: 22 * s, weight: .bold))
                .foregroundColor(.white)
        }
        .offset(x: (centerX - 22) * s, y: (centerY - 22) * s)
    }

    /// A skeleton text line inside a window.
    private func skeletonLine(_ width: CGFloat, s: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8 * s)
            .fill(Color.secondary.opacity(0.18))
            .frame(width: width * s, height: 16 * s)
    }

    /// The guest window with its bar: three colored
    /// dots, the chevron, and a few content lines.
    private func windowWithBar(_ s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 36 * s)
                .fill(Color(uiColor: .systemBackground))
                .frame(width: 310 * s, height: 541 * s)
                .overlay(
                    RoundedRectangle(cornerRadius: 36 * s)
                        .stroke(Color(uiColor: .separator), lineWidth: 1)
                )
            HStack(spacing: 16 * s) {
                Circle().fill(dotRed).frame(width: 20 * s, height: 20 * s)
                Circle().fill(dotYellow).frame(width: 20 * s, height: 20 * s)
                Circle().fill(dotGreen).frame(width: 20 * s, height: 20 * s)
            }
            .offset(x: 26 * s, y: 8 * s)
            Image(systemName: "chevron.down")
                .font(.system(size: 16 * s, weight: .semibold))
                .foregroundColor(.secondary)
                .offset(x: 278 * s, y: 10 * s)
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(width: 310 * s, height: 1)
                .offset(y: 36 * s)
            VStack(alignment: .leading, spacing: 14 * s) {
                skeletonLine(230, s: s)
                skeletonLine(170, s: s)
                skeletonLine(205, s: s)
            }
            .offset(x: 24 * s, y: 64 * s)
        }
        .offset(x: 39 * s, y: 112 * s)
    }

    /// The resting handle on the right edge, as tall
    /// as the dock is wide, with its grip and the
    /// breathing dot.
    private func handle(_ s: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7 * s)
                .fill(Color.accentColor.opacity(0.85))
                .frame(width: 14 * s, height: 80 * s)
            VStack(spacing: 4 * s) {
                RoundedRectangle(cornerRadius: 1.5 * s)
                    .fill(Color.white.opacity(0.75))
                    .frame(width: 3 * s, height: 22 * s)
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 6 * s, height: 6 * s)
                RoundedRectangle(cornerRadius: 1.5 * s)
                    .fill(Color.white.opacity(0.75))
                    .frame(width: 3 * s, height: 22 * s)
            }
        }
        .offset(x: 416 * s, y: 426 * s)
    }

    /// The expanded dock: a capsule against the right
    /// edge, app icons in a column, home button last.
    private func expandedDock(_ s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(Color(uiColor: .systemBackground))
                .frame(width: 80 * s, height: 300 * s)
                .overlay(
                    Capsule()
                        .stroke(Color(uiColor: .separator), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 10 * s, y: 4 * s)
            VStack(spacing: 8 * s) {
                dockIcon(current: false, s: s)
                dockIcon(current: true, s: s)
                dockIcon(current: false, s: s)
                ZStack {
                    RoundedRectangle(cornerRadius: 14 * s)
                        .fill(Color(uiColor: .secondarySystemBackground))
                        .frame(width: 54 * s, height: 54 * s)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14 * s)
                                .stroke(Color(uiColor: .separator), lineWidth: 1)
                        )
                    Image(systemName: "house.fill")
                        .font(.system(size: 26 * s))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 80 * s)
            .offset(y: 30 * s)
            badge(2, centerX: 11, centerY: 28, s: s)
            badge(3, centerX: 11, centerY: 90, s: s)
            badge(4, centerX: 11, centerY: 276, s: s)
        }
        .offset(x: 342 * s, y: 316 * s)
    }

    private func dockIcon(current: Bool, s: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 14 * s)
            .fill(Color(uiColor: .secondarySystemBackground))
            .frame(width: 54 * s, height: 54 * s)
            .overlay(
                RoundedRectangle(cornerRadius: 14 * s)
                    .stroke(current ? Color.accentColor : Color(uiColor: .separator),
                            lineWidth: current ? 4 * s : 1)
            )
    }

    /// The corner-gesture window: large but not full
    /// screen, no window bar (the bar is hidden in
    /// this mode), the four 44-point corner areas
    /// shaded.
    private func cornerWindow(_ s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 40 * s)
                .fill(Color(uiColor: .systemBackground))
                .frame(width: 344 * s, height: 671 * s)
                .overlay(
                    RoundedRectangle(cornerRadius: 40 * s)
                        .stroke(Color(uiColor: .separator), lineWidth: 1)
                )
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 14 * s) {
                    skeletonLine(250, s: s)
                    skeletonLine(180, s: s)
                    skeletonLine(215, s: s)
                    skeletonLine(150, s: s)
                }
                .offset(x: 24 * s, y: 40 * s)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.30))
                    .frame(width: 44 * s, height: 44 * s)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.30))
                    .frame(width: 44 * s, height: 44 * s)
                    .offset(x: 300 * s)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.30))
                    .frame(width: 44 * s, height: 44 * s)
                    .offset(y: 627 * s)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.30))
                    .frame(width: 44 * s, height: 44 * s)
                    .offset(x: 300 * s, y: 627 * s)
            }
            .frame(width: 344 * s, height: 671 * s)
            .clipShape(RoundedRectangle(cornerRadius: 40 * s))
        }
        .offset(x: 43 * s, y: 121 * s)
    }
}

/// "Multitask Guide": figures 1 and 2 side by side,
/// filling the width, then the text and legend 1-6.
struct LCMultitaskGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    figureColumn(kind: .handle, captionKey: "lc.multitask.guide.figureHandle")
                    figureColumn(kind: .dock, captionKey: "lc.multitask.guide.figureDock")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("lc.multitask.guide.lead".loc)
                        .font(.title3.weight(.bold))
                    Text("lc.multitask.guide.sharedNote".loc)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    LCGuideLegendRow(number: 1, titleKey: "lc.multitask.legend1.title", descKey: "lc.multitask.legend1.desc")
                    LCGuideLegendRow(number: 2, titleKey: "lc.multitask.legend2.title", descKey: "lc.multitask.legend2.desc")
                    LCGuideLegendRow(number: 3, titleKey: "lc.multitask.legend3.title", descKey: "lc.multitask.legend3.desc")
                    LCGuideLegendRow(number: 4, titleKey: "lc.multitask.legend4.title", descKey: "lc.multitask.legend4.desc")
                    LCGuideLegendRow(number: 5, titleKey: "lc.multitask.legend5.title", descKey: "lc.multitask.legend5.desc")
                    // Legend 6 ends in a link: the corner
                    // gestures themselves live on the
                    // gestures page (Ann 2026-11-27).
                    HStack(alignment: .top, spacing: 10) {
                        LCGuideNumberBadge(number: 6)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("lc.multitask.legend6.title".loc)
                                .font(.subheadline.weight(.semibold))
                            Text("lc.multitask.legend6.desc".loc)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            NavigationLink {
                                LCMultitaskGestureGuideView()
                            } label: {
                                HStack(spacing: 3) {
                                    Text("lc.multitask.gestures.title".loc)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .font(.footnote.weight(.semibold))
                            }
                            .padding(.top, 2)
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("lc.multitask.guide.title".loc)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func figureColumn(kind: LCGuideFigure.Kind, captionKey: String) -> some View {
        VStack(spacing: 8) {
            LCGuideFigure(kind: kind)
            Text(captionKey.loc)
                .font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
    }
}

/// "Multitask Gestures": the four-corner figure on
/// the left, the legend 7-10 on the right (Ann
/// 2026-11-27: one figure only, so it takes the left
/// half and the text goes beside it).
struct LCMultitaskGestureGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("lc.multitask.gesture.cornersTitle".loc)
                        .font(.title3.weight(.bold))
                    Text("lc.multitask.gesture.cornersIntro".loc)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                HStack(alignment: .top, spacing: 14) {
                    LCGuideFigure(kind: .corners)
                        .frame(width: 150)
                    VStack(alignment: .leading, spacing: 14) {
                        LCGuideLegendRow(number: 7, titleKey: "lc.multitask.legend7.title", descKey: "lc.multitask.legend7.desc")
                        LCGuideLegendRow(number: 8, titleKey: "lc.multitask.legend8.title", descKey: "lc.multitask.legend8.desc")
                        LCGuideLegendRow(number: 9, titleKey: "lc.multitask.legend9.title", descKey: "lc.multitask.legend9.desc")
                        LCGuideLegendRow(number: 10, titleKey: "lc.multitask.legend10.title", descKey: "lc.multitask.legend10.desc")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .navigationTitle("lc.multitask.gestures.title".loc)
        .navigationBarTitleDisplayMode(.inline)
    }
}
