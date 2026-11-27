//
//  LCMultitaskSettingView.swift
//  LiveContainer
//
//  Created by s s on 2026/3/21.
//

import SwiftUI

struct LCMultitaskSettingView: View {
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("LCLaunchInMultitaskMode") var launchInMultitaskMode = false
    @AppStorage("LCLaunchMultitaskMaximized") var launchMultitaskMaximized = false
    @AppStorage("LCHideWindowBar") var hideWindowBar = false
    @AppStorage("LCMultitaskBottomWindowBar", store: LCUtils.appGroupUserDefault) var bottomWindowBar = false
    @AppStorage("LCAutoEndPiP", store: LCUtils.appGroupUserDefault) var autoEndPiP = false
    @AppStorage("LCSkipTerminatedScreen", store: LCUtils.appGroupUserDefault) var skipTerminatedScreen = false
    @AppStorage("LCRestartTerminatedApp", store: LCUtils.appGroupUserDefault) var restartTerminatedApp = false
    @AppStorage("LCMaxOneAppOnStage", store: LCUtils.appGroupUserDefault) var onlyOneAppOnStage = false
    @AppStorage("LCDockWidth", store: LCUtils.appGroupUserDefault) var dockWidth: Double = 80
    @AppStorage("LCBreathingLightColor", store: LCUtils.appGroupUserDefault) var breathingLightColorRaw: String = LCBreathingLightColor.standard.rawValue
    @State private var showBreathingColorPicker = false
    @AppStorage("LCRedirectURLToHost", store: LCUtils.appGroupUserDefault) var redirectURLToHost = false
    
    var body: some View {
        List {
            Section {
                if(UIApplication.shared.supportsMultipleScenes) {
                    Picker(selection: $multitaskMode) {
                        Text("lc.settings.multitaskMode.virtualWindow".loc).tag(MultitaskMode.virtualWindow)
                        Text("lc.settings.multitaskMode.nativeWindow".loc).tag(MultitaskMode.nativeWindow)
                    } label: {
                        Text("lc.settings.multitaskMode".loc)
                    }
                }
                Toggle(isOn: $launchInMultitaskMode) {
                    Text("lc.settings.autoLaunchInMultitaskMode".loc)
                }
                
                if multitaskMode == .virtualWindow {
                    Toggle(isOn: $launchMultitaskMaximized) {
                        Text("lc.settings.launchMultitaskMaximized".loc)
                    }
                    if launchMultitaskMaximized {
                        Toggle(isOn: $onlyOneAppOnStage) {
                            Text("lc.settings.onlyOneAppOnStage".loc)
                        }
                    }
                    Toggle(isOn: $hideWindowBar) {
                        Text("lc.settings.hideWindowBar".loc)
                    }
                    if hideWindowBar {
                        Text("lc.settings.hideWindowBar.gestureGuide".loc)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Toggle(isOn: $autoEndPiP) {
                        Text("lc.settings.autoEndPiP".loc)
                    }
                    Toggle(isOn: $skipTerminatedScreen) {
                        Text("lc.settings.skipTerminatedScreen".loc)
                    }
                    if skipTerminatedScreen {
                        Toggle(isOn: $restartTerminatedApp) {
                            Text("lc.settings.restartTerminatedApp".loc)
                        }
                    }
                    Toggle(isOn: $bottomWindowBar) {
                        Text("lc.settings.bottomWindowBar".loc)
                    }
                    Toggle(isOn: $redirectURLToHost) {
                        Text("lc.settings.redirectURLToHost".loc)
                    }

                }
            }
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("lc.settings.dockWidth".loc)
                            .foregroundColor(.primary)
                        Spacer()
                        Text("\(Int(dockWidth))px")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    Slider(value: $dockWidth, in: 50...100) {
                        Text("lc.settings.dockWidth".loc)
                    }
                    .tint(.accentColor)
                }
                .padding(.vertical, 4)
                Text("lc.settings.dock.gestureGuide".loc)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                // The color opens a sheet of round
                // swatches instead of a plain list (Ann
                // 2026-11-27: the list was ugly; a
                // handle-scene card grid was drawn and
                // tried first, then she settled on the
                // round swatches). Picking writes through
                // at once — the resting handle recolors
                // immediately (see the manager's defaults
                // observer), so there is no preview strip
                // in the sheet: the handle IS the preview.
                Button {
                    showBreathingColorPicker = true
                } label: {
                    HStack {
                        Text("lc.settings.breathingLightColor".loc)
                            .foregroundColor(.primary)
                        Spacer()
                        Circle()
                            .fill((LCBreathingLightColor(rawValue: breathingLightColorRaw) ?? .standard).color)
                            .frame(width: 12, height: 12)
                        Text((LCBreathingLightColor(rawValue: breathingLightColorRaw) ?? .standard).labelKey.loc)
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } footer: {
                // The multitask explanation moved here from
                // the settings root (Ann 2026-11-27: the
                // group footer there is gone; each page
                // carries its own description).
                Text("lc.settings.multitaskDesc".loc)
            }
        }
        .navigationTitle("lc.appBanner.multitask".loc)
        .navigationBarTitleDisplayMode(.inline)
        // The color picker is a CENTERED popup, not a
        // bottom sheet (Ann 2026-11-27: she asked for the
        // centered kind explicitly, after the bottom
        // sheet — first full-height, then fitted — both
        // felt wrong for fifteen swatches).
        .overlay {
            if showBreathingColorPicker {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture {
                            showBreathingColorPicker = false
                        }
                        .transition(.opacity)
                    LCBreathingLightColorCard(selection: $breathingLightColorRaw)
                    .padding(.horizontal, 28)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: showBreathingColorPicker)
    }
}

/// The breathing-light color popup (Ann 2026-11-27): a
/// centered card over a dimmed page — a grid of round
/// swatches, the iOS color-picker idiom, with the name
/// under each; the selected swatch wears a ring in its
/// own color. Tapping writes the choice through
/// immediately (the resting handle recolors on the spot
/// via the dock manager's defaults observer); the card
/// stays open so colors can be tried one after another,
/// and a tap on the dim around it closes it — there is
/// no Done button, by her word. (Tried
/// before it the same night: a handle-scene card grid,
/// then a bottom sheet; she settled on swatches,
/// centered.)
private struct LCBreathingLightColorCard: View {
    @Binding var selection: String

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        VStack(spacing: 16) {
            // No Done button (Ann 2026-11-27): picking
            // applies and saves on the tap itself, and
            // the card closes by tapping the dim around
            // it — a button would only repeat that.
            Text("lc.settings.breathingLightColor".loc)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(LCBreathingLightColor.allCases, id: \.rawValue) { preset in
                    Button {
                        selection = preset.rawValue
                    } label: {
                        swatch(preset)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(uiColor: .systemBackground))
        )
        .shadow(color: Color.black.opacity(0.25), radius: 24, y: 8)
    }

    private func swatch(_ preset: LCBreathingLightColor) -> some View {
        let selected = selection == preset.rawValue
        return VStack(spacing: 5) {
            ZStack {
                if preset == .standard {
                    // No color of its own: a pale disc
                    // standing for the platform default.
                    Circle()
                        .fill(LinearGradient(colors: [Color.white, Color.gray.opacity(0.55)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    Circle()
                        .fill(preset.color)
                }
            }
            .frame(width: 36, height: 36)
            .overlay(
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .overlay(
                // The selection ring sits a breath
                // outside the disc, in the swatch's own
                // color (a neutral ring for standard).
                Circle()
                    .stroke(preset == .standard ? Color.primary : preset.color, lineWidth: 2)
                    .padding(-4)
                    .opacity(selected ? 1 : 0)
            )
            Text(preset.labelKey.loc)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .primary : .secondary)
        }
    }
}
