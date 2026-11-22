//
//  LCKeepAliveLogView.swift
//  LiveContainerSwiftUI
//
//  Viewer for the shared keep-alive debug log written by the host
//  keeper (CZFHostKeepAlive), the guest dylib (CZFKeepAlive) and LC's
//  own deploy code into <appGroup>/CZFKeepAlive/keepalive.log.
//
//  The file grows to hundreds of KB (thousands of lines); a single
//  SwiftUI Text holding all of it renders BLANK (Ann hit this
//  2026-11-22: page empty while Copy still worked). The view
//  therefore displays only the last `displayLineLimit` lines; Copy
//  still exports the full text.
//

import SwiftUI

struct LCKeepAliveLogView: View {
    @State private var fullText = ""
    @State private var displayText = ""
    @State private var totalLines = 0

    private static let displayLineLimit = 300

    var body: some View {
        Group {
            if fullText.isEmpty {
                Text("lc.keepAlive.logEmpty".loc)
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if totalLines > Self.displayLineLimit {
                            Text(String(format: "lc.keepAlive.logTailNote".loc, Self.displayLineLimit))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        Text(displayText)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                }
                .refreshable {
                    reload()
                }
            }
        }
        .navigationTitle("lc.keepAlive.logView".loc)
        .toolbar {
            // Ann 定版布局：删除（清空日志）与复制都放右上。
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    try? FileManager.default.removeItem(at: CZFKeepAliveLog.fileURL)
                    CZFKeepAliveLog.event("LC", "keep-alive-log-cleared")
                    reload()
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("lc.keepAlive.logClear".loc)
                Button {
                    UIPasteboard.general.string = fullText
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let content = (try? String(contentsOf: CZFKeepAliveLog.fileURL, encoding: .utf8)) ?? ""
        fullText = content
        // Keep the newest lines; the tail is what matters when
        // debugging, and a bounded Text actually renders.
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        totalLines = lines.count
        displayText = lines.suffix(Self.displayLineLimit).joined(separator: "\n")
    }
}
