//
//  LCSegmentShell.swift
//  LiveContainerSwiftUI
//
//  Created during the sources-page refactor (2026-11-26,
//  stage 2): the scroll/search geometry the sources and
//  updates segments used to each write out by hand now
//  lives exactly once, here.
//

import Foundation
import SwiftUI

/// One segment of the sources page (Ann 2026-11-26,
/// search settled after four attempts; the header
/// placement re-settled 2026-11-27 — re-read both
/// before moving pieces):
///
/// - The scroll view is the navigation view's direct
///   content (the App page's geometry), so it scrolls
///   under the navigation bar and the drawer search
///   bar's hide mechanism engages. Nothing WRAPS it:
///   a VStack or a fixed view between the navigation
///   view and the scroll view breaks the link the
///   drawer's hide mechanism needs and pins the bar
///   (four attempts, 2026-11-26).
/// - The segment picker and the sources segment's
///   chips row ride in the scroll view's TOP SAFE-AREA
///   INSET instead — the inset is the scroll view's
///   own geometry, not a wrapper, so the drawer link
///   survives, while the header itself never scrolls:
///   one picker position for all three segments by
///   construction, and controls up there stand outside
///   the scroll flow entirely. That last part is what
///   ended the sort button's drift (Ann 2026-11-27):
///   iOS 26 restores a menu's anchor from a snapshot
///   after dismissal, and an anchor inside the scroll
///   flow lags the finger until the restore lands —
///   the App page's toolbar sort menu never showed
///   it, because a toolbar never scrolls. (Device
///   check still owed: drawer reveal/hide unchanged,
///   sort drift gone.)
/// - The drawer search bar hangs on the scroll view
///   itself — never on an outer container, where it
///   would belong to the whole navigation stack and
///   surface on the detail page.
/// - The content is always a hair taller than the
///   viewport (minHeight below): with sources collapsed
///   the content can be far shorter than the screen, and
///   a scroll view that cannot scroll gives the drawer
///   no travel to hide with — the bar stays pinned.
///
/// Only the sources segment searches (Ann 2026-11-26,
/// later the same day: the updates and downloads lists
/// hold little worth searching, so their bars were
/// removed for good); a segment passes nil to opt out.
struct LCSegmentShell<Header: View, Content: View>: View {
    private let searchContext: SearchContext?
    private let header: Header
    private let content: Content

    @State private var viewportHeight: CGFloat = 0

    init(searchContext: SearchContext? = nil,
         @ViewBuilder header: () -> Header,
         @ViewBuilder content: () -> Content) {
        self.searchContext = searchContext
        self.header = header()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                content
            }
            .padding(.vertical)
            .frame(minHeight: viewportHeight + 1, alignment: .top)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            header
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: UIColor.systemBackground))
        }
        .modifier(LCSegmentSearchBar(context: searchContext))
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { viewportHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { viewportHeight = $0 }
        })
    }
}

/// The drawer search bar for segments that search;
/// segments without a context get no bar at all.
private struct LCSegmentSearchBar: ViewModifier {
    let context: SearchContext?

    func body(content: Content) -> some View {
        if let context {
            content.searchable(text: Binding(
                get: { context.query },
                set: { context.query = $0 }
            ))
        } else {
            content
        }
    }
}
