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
/// Each segment supplies its own SearchContext, so each
/// searches only itself and keeps its own query.
struct LCSegmentShell<Picker: View, Content: View>: View {
    @ObservedObject var searchContext: SearchContext
    private let picker: Picker
    private let content: Content

    @State private var viewportHeight: CGFloat = 0

    init(searchContext: SearchContext,
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
        .searchable(text: $searchContext.query)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { viewportHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { viewportHeight = $0 }
        })
    }
}
