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
                // The color opens a sheet of handle-scene
                // cards instead of a plain list (Ann
                // 2026-11-27: the list was ugly, and she
                // wanted every color previewed as the
                // handle itself). Picking writes through
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
                .sheet(isPresented: $showBreathingColorPicker) {
                    LCBreathingLightColorSheet(selection: $breathingLightColorRaw)
                }
            }
        }
        .navigationTitle("lc.appBanner.multitask".loc)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The breathing-light color sheet (Ann 2026-11-27): a
/// grid of handle-scene cards — a dark tile, a glass
/// handle flush on its right edge, the grip in the
/// preset's color — instead of a list of names. Tapping
/// a card writes the choice through immediately (the
/// resting handle recolors on the spot via the dock
/// manager's defaults observer); the sheet stays open
/// so colors can be tried one after another, and the
/// selected card's grip breathes like the real one.
private struct LCBreathingLightColorSheet: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var pulseOn = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(LCBreathingLightColor.allCases, id: \.rawValue) { preset in
                        Button {
                            selection = preset.rawValue
                        } label: {
                            card(preset)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("lc.settings.breathingLightColor".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("lc.common.done".loc) {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                pulseOn = true
            }
        }
    }

    private func card(_ preset: LCBreathingLightColor) -> some View {
        let selected = selection == preset.rawValue
        let gripColor = preset.uiColor.map { Color($0) } ?? Color.black.opacity(0.4)
        return ZStack(alignment: .bottomLeading) {
            Color(red: 0.09, green: 0.095, blue: 0.11)
            // The mini handle, flush with the tile's
            // right edge.
            HStack {
                Spacer()
                ZStack {
                    LCHandlePreviewShape()
                        .fill(Color.white.opacity(0.14))
                    LCHandlePreviewShape()
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    Capsule()
                        .fill(gripColor)
                        .frame(width: 4, height: 20)
                        .opacity(selected ? (pulseOn ? 1 : 0.38) : 1)
                }
                .frame(width: 15, height: 44)
            }
            Text(preset.labelKey.loc)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .white : Color.white.opacity(0.75))
                .padding(.leading, 8)
                .padding(.bottom, 5)
        }
        .frame(height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? (preset == .standard ? Color.white.opacity(0.85) : gripColor) : Color.clear, lineWidth: 2)
        )
    }
}

/// A handle silhouette for the picker cards: square on
/// the right (it sits flush with the tile's edge),
/// rounded on the left.
private struct LCHandlePreviewShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 6
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + r),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
