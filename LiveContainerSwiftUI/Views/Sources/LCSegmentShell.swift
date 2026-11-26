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
/// search settled after four attempts — do not move the
/// pieces around without re-reading why):
///
/// - The scroll view is the navigation view's direct
///   content (the App page's geometry), so it scrolls
///   under the navigation bar and the drawer search
///   bar's hide mechanism engages.
/// - The segment picker rides as the scroll view's first
///   row, so every segment's picker sits at the same
///   coordinates by construction.
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
struct LCSegmentShell<Picker: View, Content: View>: View {
    private let searchContext: SearchContext?
    private let picker: Picker
    private let content: Content

    @State private var viewportHeight: CGFloat = 0

    init(searchContext: SearchContext? = nil,
         @ViewBuilder picker: () -> Picker,
         @ViewBuilder content: () -> Content) {
        self.searchContext = searchContext
        self.picker = picker()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                picker
                content
            }
            .padding(.vertical)
            .frame(minHeight: viewportHeight + 1, alignment: .top)
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
