//
//  LCManageSourcesSheet.swift
//  LiveContainerSwiftUI
//
//  Split out of LCAltStoreSourcesView.swift (2026-11-26 refactor,
//  stage 1: pure move, no code changes).
//

import Foundation
import SwiftUI
import UIKit

struct ManageSourcesSheet: View {
    @ObservedObject var viewModel: AltStoreSourcesViewModel
    @Binding var isPresented: Bool
    let onAdd: (String) async -> Bool
    
    @State private var manualSourceValue = ""
    @State private var isAddingManual = false
    @State private var sourcePendingRemoval: AltStoreSourcesViewModel.SourceItem?
    @FocusState private var isManualFieldFocused: Bool
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    if viewModel.sources.isEmpty {
                        Text("lc.sources.empty".loc)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.sources, id: \.id) { item in
                            // Card-style row (Ann 2026-11-26,
                            // from her reference screenshot):
                            // big icon, name with the built-in
                            // badge, truncated URL, app count,
                            // and the on/off switch on the
                            // right. Swipe-to-delete stays.
                            HStack(spacing: 12) {
                                SourceIconView(url: resolvedIconURL(for: item))
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(item.displayName)
                                            .font(.system(size: 16)).bold()
                                            .lineLimit(1)
                                        if viewModel.isBuiltInSource(item) {
                                            Text("lc.sources.badge.builtIn".loc)
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(.purple)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Color.purple.opacity(0.15)))
                                        }
                                    }
                                    Text(item.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .textSelection(.enabled)
                                    if let source = item.source {
                                        Text("lc.sources.manage.appCount %lld".localizeWithFormat(source.apps.count))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { viewModel.isSourceEnabled(item) },
                                    set: { viewModel.setSourceEnabled(item, $0) }
                                ))
                                .labelsHidden()
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    sourcePendingRemoval = item
                                } label: {
                                    Label("lc.sources.removeSource".loc, systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("\("lc.sources.manage.current".loc) (\(viewModel.sources.count))")
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("https://example.com/source.json", text: $manualSourceValue)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .focused($isManualFieldFocused)
                        
                        Button {
                            attemptManualAdd()
                        } label: {
                            if isAddingManual {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("lc.sources.addSource".loc)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualSourceValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingManual)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("lc.sources.manage.manual".loc)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("lc.sources.addSource".loc)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.close".loc) {
                        isPresented = false
                    }
                }
            }
        }
        .confirmationDialog(
            "lc.sources.removeConfirmation.title".loc,
            isPresented: Binding<Bool>(
                get: { sourcePendingRemoval != nil },
                set: { if !$0 { sourcePendingRemoval = nil } }
            ),
            presenting: sourcePendingRemoval
        ) { item in
            Button("lc.common.remove".loc, role: .destructive) {
                viewModel.removeSource(item)
                sourcePendingRemoval = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                sourcePendingRemoval = nil
            }
        } message: { item in
            Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(item.displayName))
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private func resolvedIconURL(for item: AltStoreSourcesViewModel.SourceItem) -> URL? {
        if let icon = item.primaryIconURL {
            return icon
        }
        if let existing = viewModel.sources.first(where: { $0.url == item.url }) {
            if let icon = existing.primaryIconURL {
                return icon
            }
        }
        return nil
    }
    
    private func attemptManualAdd() {
        let trimmed = manualSourceValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAddingManual else { return }
        isAddingManual = true
        Task {
            let success = await onAdd(trimmed)
            if success {
                manualSourceValue = ""
                isManualFieldFocused = false
            }
            isAddingManual = false
        }
    }
}
