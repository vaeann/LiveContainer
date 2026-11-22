//
//  LCKeepAliveLogView.swift
//  LiveContainerSwiftUI
//
//  Viewer for the shared keep-alive debug log written by the host
//  keeper (CZFHostKeepAlive), the guest dylib (CZFKeepAlive) and LC's
//  own deploy code into <appGroup>/CZFKeepAlive/keepalive.log.
//

import SwiftUI

struct LCKeepAliveLogView: View {
    @State private var text = ""

    var body: some View {
        Group {
            if text.isEmpty {
                Text("lc.keepAlive.logEmpty".loc)
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("lc.keepAlive.logView".loc)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        text = (try? String(contentsOf: CZFKeepAliveLog.fileURL, encoding: .utf8)) ?? ""
    }
}
