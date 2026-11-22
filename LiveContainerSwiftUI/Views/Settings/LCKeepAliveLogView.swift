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
                .refreshable {
                    reload()
                }
            }
        }
        .navigationTitle("lc.keepAlive.logView".loc)
        .toolbar {
            // Ann 定版布局：左上删除（清空日志），右上复制。
            ToolbarItem(placement: .navigationBarLeading) {
                Button(role: .destructive) {
                    try? FileManager.default.removeItem(at: CZFKeepAliveLog.fileURL)
                    CZFKeepAliveLog.event("LC", "keep-alive-log-cleared")
                    reload()
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("lc.keepAlive.logClear".loc)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        text = (try? String(contentsOf: CZFKeepAliveLog.fileURL, encoding: .utf8)) ?? ""
    }
}
