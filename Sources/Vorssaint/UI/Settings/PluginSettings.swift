// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Native list and detail controls, matching the built-in feature settings.
struct PluginSettings: View {
    @ObservedObject private var manager = PluginManager.shared
    @State private var selectedID: String?
    @State private var review: PackageReview?
    @State private var trustReview: InstalledPlugin?
    @State private var removal: InstalledPlugin?
    @State private var rollback: InstalledPlugin?
    @State private var deleteData = false
    @State private var error: String?
    @State private var working = false

    private struct PackageReview: Identifiable {
        let id = UUID()
        let url: URL
        let manifest: PluginManifest
    }

    private var selected: InstalledPlugin? {
        manager.installed.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(manager.installed) { plugin in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(plugin.manifest.name).font(.body.weight(.medium))
                            Text(plugin.lastError != nil ? "Needs attention" : (plugin.enabled ? PluginStrings.enabled : PluginStrings.disabled))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .tag(plugin.id)
                    }
                }
                .overlay {
                    if manager.installed.isEmpty {
                        Text(PluginStrings.empty).font(.callout).foregroundStyle(.secondary).padding()
                    }
                }
                if let message = manager.lastError {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red).padding(12)
                        .textSelection(.enabled)
                }
                Divider()
                Button(PluginStrings.importPackage) { choosePackage() }
                    .padding(12)
                    .disabled(working)
            }
            .frame(width: 190)
            Divider()
            if let selected {
                detail(selected)
            } else {
                Text(PluginStrings.choose)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }
        }
        .padding(.top, 12)
        .sheet(item: $review) { package in packageReview(package) }
        .sheet(item: $trustReview) { plugin in trustSheet(plugin) }
        .sheet(item: $removal) { plugin in removalSheet(plugin) }
        .alert(PluginStrings.rollback, isPresented: Binding(get: { rollback != nil }, set: { if !$0 { rollback = nil } })) {
            Button("Restore") {
                if let plugin = rollback { perform { try manager.rollback(id: plugin.id) } }
                rollback = nil
            }
            Button("Cancel", role: .cancel) { rollback = nil }
        } message: { Text(PluginStrings.rollbackNote) }
        .alert("Plugin Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func detail(_ plugin: InstalledPlugin) -> some View {
        Form {
            Section {
                LabeledContent("Name", value: plugin.manifest.name)
                LabeledContent("Version", value: plugin.manifest.version)
                LabeledContent("Identifier", value: plugin.id)
                Toggle(PluginStrings.enabled, isOn: Binding(get: { plugin.enabled }, set: { enabled in
                    if enabled { trustReview = plugin } else { manager.disable(id: plugin.id) }
                }))
                if let message = plugin.lastError {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
            }
            declarations(plugin.manifest)
            if let status = manager.statusMessage {
                Section("Plugin Status") { Text(status).textSelection(.enabled) }
            }
            if !(plugin.manifest.settings ?? []).isEmpty {
                Section("Settings") {
                    PluginSettingsFields(plugin: plugin, manager: manager, reportError: { error = $0 })
                        .id(plugin.id + ":" + plugin.manifest.version)
                }
            }
            Section("Manage") {
                Button(PluginStrings.update) { choosePackage(updating: plugin.id) }
                    .disabled(working)
                Button(PluginStrings.rollback) { rollback = plugin }
                    .disabled(!plugin.hasPrevious)
                Button(PluginStrings.remove, role: .destructive) {
                    deleteData = false
                    removal = plugin
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func declarations(_ manifest: PluginManifest) -> some View {
        Section("Commands and Search") {
            ForEach(manifest.commands ?? []) { command in
                Label(command.title, systemImage: "terminal")
            }
            ForEach(manifest.searchProviders ?? []) { provider in
                LabeledContent(provider.title, value: provider.keyword + " …")
            }
        }
        Section("Vorssaint API Access") {
            if manifest.capabilities.isEmpty { Text("No Vorssaint API access requested.") }
            ForEach(manifest.capabilities, id: \.self) { capability in
                Text(capabilityName(capability))
            }
        }
    }

    private func packageReview(_ package: PackageReview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(PluginStrings.review).font(.title2.weight(.semibold))
            Form {
                Section {
                    LabeledContent("Name", value: package.manifest.name)
                    LabeledContent("Identifier", value: package.manifest.id)
                    LabeledContent("Version", value: package.manifest.version)
                    if let current = manager.installed.first(where: { $0.id == package.manifest.id }) {
                        LabeledContent("Replaces", value: current.manifest.version)
                    }
                }
                declarations(package.manifest)
            }.formStyle(.grouped)
            Text(PluginStrings.installNote).font(.callout)
            HStack {
                Spacer()
                Button("Cancel") { review = nil }.keyboardShortcut(.cancelAction)
                Button("Import Disabled") {
                    working = true
                    Task { @MainActor in
                        defer { working = false }
                        do {
                            let manifest = try await manager.importPackage(package.url)
                            selectedID = manifest.id
                            review = nil
                        } catch { self.error = error.localizedDescription; review = nil }
                    }
                }.buttonStyle(.borderedProminent).disabled(working)
            }
        }
        .padding(24).frame(width: 540, height: 520)
        .interactiveDismissDisabled(working)
    }

    private func trustSheet(_ plugin: InstalledPlugin) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enable \(plugin.manifest.name)?").font(.title2.weight(.semibold))
            Text("Version \(plugin.manifest.version) · \(plugin.id)")
                .font(.caption).foregroundStyle(.secondary)
            Label(PluginStrings.trust, systemImage: "exclamationmark.shield")
                .fixedSize(horizontal: false, vertical: true)
            Form { declarations(plugin.manifest) }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { trustReview = nil }.keyboardShortcut(.cancelAction)
                Button(PluginStrings.enable) {
                    perform { try manager.enable(id: plugin.id, trust: true, expectedRevision: plugin.revision) }
                    trustReview = nil
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 540, height: 500)
    }

    private func removalSheet(_ plugin: InstalledPlugin) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove \(plugin.manifest.name)?").font(.title2.weight(.semibold))
            Text(PluginStrings.retainData)
            Toggle(PluginStrings.deleteData, isOn: $deleteData)
            HStack {
                Spacer()
                Button("Cancel") { removal = nil }.keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) {
                    perform { try manager.remove(id: plugin.id, deleteData: deleteData) }
                    removal = nil
                }
            }
        }.padding(24).frame(width: 480)
    }

    private func choosePackage(updating id: String? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "vorssaint-plugin") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                let manifest = try await manager.inspect(url)
                if let id, manifest.id != id { throw PluginFailure("Choose an update with the same plugin identifier.") }
                review = PackageReview(url: url, manifest: manifest)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = error.localizedDescription }
    }

    private func capabilityName(_ value: String) -> String {
        switch value {
        case "clipboard.write": return "Write to clipboard"
        case "url.open": return "Open web addresses"
        case "settings.read": return "Read its plugin settings"
        case "storage.read": return "Read its stored data"
        case "storage.write": return "Write its stored data"
        case "status.show": return "Show status messages"
        default: return value
        }
    }
}

private struct PluginSettingsFields: View {
    let plugin: InstalledPlugin
    @ObservedObject var manager: PluginManager
    let reportError: (String) -> Void
    @State private var values: [String: PluginJSON] = [:]

    var body: some View {
        ForEach(plugin.manifest.settings ?? [], id: \.key) { setting in
            switch setting.type {
            case "boolean":
                Toggle(setting.title, isOn: Binding(get: {
                    if let stored = value(setting), case .bool(let flag) = stored { return flag }; return false
                }, set: { save(setting, value: .bool($0)) }))
            case "number":
                TextField(setting.title, value: Binding(get: {
                    if let stored = value(setting), case .number(let number) = stored { return number }; return 0
                }, set: { save(setting, value: .number($0)) }), format: .number)
            default:
                TextField(setting.title, text: Binding(get: { value(setting)?.string ?? "" },
                                                      set: { save(setting, value: .string($0)) }))
            }
        }
        .onAppear {
            do { values = try manager.settings(id: plugin.id) }
            catch { reportError(error.localizedDescription) }
        }
    }

    private func value(_ setting: PluginSetting) -> PluginJSON? { values[setting.key] ?? setting.default }
    private func save(_ setting: PluginSetting, value: PluginJSON) {
        do {
            try manager.setSetting(id: plugin.id, key: setting.key, value: value)
            values[setting.key] = value
        } catch { reportError(error.localizedDescription) }
    }
}
