//
//  LCKeepAliveSettingView.swift
//  LiveContainerSwiftUI
//
//  Settings page for background keep-alive. The keep-alive
//  implementation was removed on 2026-11-21; only this settings
//  entry point remains, ready for a new implementation.
//

import SwiftUI

struct LCKeepAliveSettingView: View {
    var body: some View {
        List {
        }
        .navigationTitle("lc.keepAlive.title".loc)
    }
}
