//
//  LCSourceAppDetailView.swift
//  LiveContainerSwiftUI
//
//  Detail page for an app listed in a source: description, screenshots,
//  version history, per-version detail and installing a specific version.
//

import Foundation
import SwiftUI
import UIKit

struct LCSourceAppDetailView: View {
    let app: AltStoreSourceApp
    let source: AltStoreSource
    let buttonState: LCSourceAppButtonState
    let action: () -> Void
    let copyAction: () -> Void
    let installVersionAction: (AltStoreSourceAppVersion) -> Void

    @State private var copied = false

    private var descriptionText: String? {
        if let description = app.description, !description.isEmpty {
            return description
        }
        return app.latestVersion?.localizedDescription
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .center, spacing: 14) {
                    SourceIconView(url: app.iconURL)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.headline)
                        if let developer = app.developerName, !developer.isEmpty {
                            Text(developer)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let latest = app.latestVersion {
                            Text(versionLine(latest))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)

                HStack(spacing: 12) {
                    Button {
                        action()
                    } label: {
                        Text(buttonState.title)
                            .bold()
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                    }
                    .buttonStyle(BasicButtonStyle())
                    .background(Capsule().fill(Color("FontColor")))
                    .foregroundColor(.white)
                    .clipShape(Capsule())

                    Button {
                        copyAction()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let descriptionText {
                Section {
                    Text(descriptionText)
                        .font(.body)
                } header: {
                    Text("lc.sources.detail.description".loc)
                }
            }

            if !app.screenshots.isEmpty {
                Section {
                    // screenshots scroller
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(app.screenshots, id: \.self) { url in
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .scaledToFit()
                                    default:
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color(uiColor: UIColor.secondarySystemBackground))
                                    }
                                }
                                .frame(height: 280)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    Text("lc.sources.detail.screenshots".loc)
                }
            }

            if !app.versions.isEmpty {
                Section {
                    // version history rows
                    ForEach(app.versions) { version in
                        NavigationLink {
                            LCSourceAppVersionDetailView(
                                app: app,
                                version: version,
                                installAction: { installVersionAction(version) }
                            )
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(versionTitle(version))
                                        .font(.body)
                                    Text(versionSubtitle(version))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    installVersionAction(version)
                                } label: {
                                    Text("lc.common.install".loc)
                                        .font(.subheadline).bold()
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                } header: {
                    Text("lc.sources.detail.versions".loc)
                }
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func versionLine(_ version: AltStoreSourceAppVersion) -> String {
        var parts = ["\(version.version)"]
        if let build = version.buildVersion, !build.isEmpty {
            parts.append("(\(build))")
        }
        if let size = version.size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.joined(separator: " • ")
    }

    private func versionTitle(_ version: AltStoreSourceAppVersion) -> String {
        if let build = version.buildVersion, !build.isEmpty {
            return "\(version.version) (\(build))"
        }
        return version.version
    }

    private func versionSubtitle(_ version: AltStoreSourceAppVersion) -> String {
        var parts: [String] = []
        if let date = version.releaseDate {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        if let size = version.size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.joined(separator: " • ")
    }
}

struct LCSourceAppVersionDetailView: View {
    let app: AltStoreSourceApp
    let version: AltStoreSourceAppVersion
    let installAction: () -> Void

    @State private var copied = false

    var body: some View {
        List {
            Section {
                HStack(alignment: .center, spacing: 14) {
                    SourceIconView(url: app.iconURL)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.headline)
                        Text(versionTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if let date = version.releaseDate {
                    HStack {
                        Text("lc.sources.detail.releaseDate".loc)
                        Spacer()
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(.secondary)
                    }
                }
                if let size = version.size {
                    HStack {
                        Text("lc.sources.detail.size".loc)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let notes = version.localizedDescription, !notes.isEmpty {
                Section {
                    Text(notes)
                        .font(.body)
                } header: {
                    Text("lc.sources.detail.releaseNotes".loc)
                }
            }

            Section {
                Button {
                    installAction()
                } label: {
                    Text("lc.sources.detail.installVersion".loc)
                        .bold()
                        .frame(maxWidth: .infinity)
                }
                Button {
                    UIPasteboard.general.string = version.downloadURL.absoluteString
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "lc.common.copied".loc : "lc.sources.detail.copyDownloadURL".loc,
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(versionTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var versionTitle: String {
        if let build = version.buildVersion, !build.isEmpty {
            return "\(version.version) (\(build))"
        }
        return version.version
    }
}
