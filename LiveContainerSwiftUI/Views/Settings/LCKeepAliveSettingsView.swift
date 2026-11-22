//
//  LCKeepAliveSettingsView.swift
//  LiveContainerSwiftUI
//
//  「后台保活」独立设置页（Ann 定版式，状态面板照微珠设计）：
//  设置主列表里只留一个入口，点进来依次是——保活状态（每进程
//  一行：宿主 + 每个游客，读 CZFKeepAlive/state/ 下的状态文件）、
//  设置（总开关 / 时间上限 / 看门狗开关）、日志（记录开关 /
//  查看日志）。状态每秒刷新一次。
//

import SwiftUI

struct LCKeepAliveSettingsView: View {
    @AppStorage("LCKeepAliveEnabled") var keepAliveEnabled = true
    @AppStorage("LCKeepAliveLimitMinutes") var keepAliveLimitMinutes = 0
    @AppStorage("LCKeepAliveWatchdogEnabled") var keepAliveWatchdogEnabled = true
    @AppStorage("LCKeepAliveLogEnabled") var keepAliveLogEnabled = true
    @State private var states: [[String: Any]] = CZFHostKeepAlive.readAllStates()

    var body: some View {
        Form {
            // Ann 定的从上往下顺序：保活开关 / 保活时间 / 看门狗
            // 开关 / 保活状态 / 日志开关 / 查看日志。
            Section {
                Toggle(isOn: $keepAliveEnabled) {
                    Text("lc.keepAlive.title".loc)
                }
                .onChange(of: keepAliveEnabled) { newValue in
                    CZFHostKeepAlive.setEnabled(newValue)
                }
                Picker(selection: $keepAliveLimitMinutes) {
                    Text("lc.keepAlive.limitUnlimited".loc).tag(0)
                    ForEach([5, 10, 20, 45], id: \.self) { minutes in
                        Text("lc.keepAlive.limitMinutes".localizeWithFormat(minutes)).tag(minutes)
                    }
                } label: {
                    Text("lc.keepAlive.timeLimit".loc)
                }
                .onChange(of: keepAliveLimitMinutes) { newValue in
                    CZFHostKeepAlive.setLimitMinutes(newValue)
                }
                Toggle(isOn: $keepAliveWatchdogEnabled) {
                    Text("lc.keepAlive.watchdog".loc)
                }
                .onChange(of: keepAliveWatchdogEnabled) { newValue in
                    CZFHostKeepAlive.setWatchdogEnabled(newValue)
                }
            } footer: {
                Text("lc.keepAlive.watchdogDesc".loc)
            }

            Section {
                if states.isEmpty {
                    Text("lc.keepAlive.statusIdle".loc)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                        statusRow(state)
                    }
                }
            } header: {
                Text("lc.keepAlive.status".loc)
            } footer: {
                Text("lc.keepAlive.desc".loc)
            }

            Section {
                Toggle(isOn: $keepAliveLogEnabled) {
                    Text("lc.keepAlive.logEnabled".loc)
                }
                .onChange(of: keepAliveLogEnabled) { newValue in
                    CZFHostKeepAlive.setLogEnabled(newValue)
                }
                NavigationLink {
                    LCKeepAliveLogView()
                } label: {
                    Text("lc.keepAlive.logView".loc)
                }
            }
        }
        .navigationTitle("lc.keepAlive.entry".loc)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            states = CZFHostKeepAlive.readAllStates()
        }
    }

    // MARK: - 状态行（微珠式：进程名 + 一行状态详情）

    private func statusRow(_ state: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(processName(state))
            Text(statusDetail(state))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func processName(_ state: [String: Any]) -> String {
        if (state["role"] as? String) == "host" {
            return "lc.keepAlive.stateHost".loc
        }
        if let name = state["name"] as? String, !name.isEmpty {
            return name
        }
        return (state["bundle"] as? String) ?? ""
    }

    private func statusDetail(_ state: [String: Any]) -> String {
        let playing = flag(state, "playing")
        if flag(state, "timedOut") && !playing {
            return "lc.keepAlive.statusLimited".loc
        }
        if playing {
            let elapsed = Date().timeIntervalSince1970 - num(state, "playStart")
            var text = "lc.keepAlive.statePlaying".localizeWithFormat(durationText(elapsed))
            if flag(state, "watchdog") {
                let beatAge = Date().timeIntervalSince1970 - num(state, "beat")
                // 看门狗最长间隔 60 秒（容差另算）：心跳超过 150 秒
                // 没更新，这个进程多半已经没了。
                text += " · " + (beatAge > 150
                    ? "lc.keepAlive.stateBeatLost".loc
                    : "lc.keepAlive.stateBeat".localizeWithFormat(Int(beatAge)))
            } else {
                text += " · " + "lc.keepAlive.stateWatchdogOff".loc
            }
            return text
        }
        if num(state, "lastSeconds") > 0 {
            var text = "lc.keepAlive.stateLast".localizeWithFormat(durationText(num(state, "lastSeconds")))
            let reason = reasonText(state["lastReason"] as? String ?? "")
            if !reason.isEmpty {
                text += "（\(reason)）"
            }
            return text
        }
        return "lc.keepAlive.statusIdle".loc
    }

    private func reasonText(_ reason: String) -> String {
        switch reason {
        case "limit":
            return "lc.keepAlive.reasonLimit".loc
        case "willEnterForeground", "didBecomeActive", "extensionHostWillEnterForeground":
            return "lc.keepAlive.reasonForeground".loc
        case "refresh":
            // 宿主的停播多由 refresh 统一触发（回前台、游客退出、
            // 关开关都会走它），分不出具体原因时就不标注。
            return ""
        default:
            return reason
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func num(_ state: [String: Any], _ key: String) -> Double {
        (state[key] as? NSNumber)?.doubleValue ?? 0
    }

    private func flag(_ state: [String: Any], _ key: String) -> Bool {
        (state[key] as? NSNumber)?.boolValue ?? false
    }
}
