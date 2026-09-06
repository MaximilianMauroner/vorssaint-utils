// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import Foundation

/// Call from the main thread, like the native Command Bar services.
final class PluginManager: ObservableObject {
    static let shared = PluginManager()
    @Published private(set) var installed: [InstalledPlugin] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastError: String?
    var onChange: (() -> Void)?
    var onStatus: ((String, String) -> Void)?
    private let store: PluginStore?
    private let io = DispatchQueue(label: "Vorssaint.plugins.store")
    private var processes: [String: PluginProcess] = [:]
    private var generation = 0
    private var installing = Set<String>()
    private var validActions: [String: [PluginResultAction]] = [:]
    private var failures: [String: Date] = [:]
    var commands: [(pluginID: String, command: PluginCommand)] {
        installed.filter(\.enabled).flatMap { plugin in
            (plugin.manifest.commands ?? []).map { (plugin.id, $0) }
        }
    }

    var searchProviders: [(pluginID: String, provider: PluginSearchProvider)] {
        installed.filter(\.enabled).flatMap { plugin in
            (plugin.manifest.searchProviders ?? []).map { (plugin.id, $0) }
        }
    }

    private init() {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            store = try PluginStore(
                root: base
                    .appendingPathComponent(
                        (Bundle.main.bundleIdentifier ?? "Vorssaint") + "/Plugins",
                        isDirectory: true
                    ),
                hostVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            )
        } catch {
            store = nil
            lastError = error.localizedDescription
        }
        reload()
    }

    func reload() {
        let errors = Dictionary(uniqueKeysWithValues: installed.compactMap { plugin in
            plugin.lastError.map { (plugin.id, $0) }
        })
        installed = (store?.list() ?? []).map { plugin in
            var entry = plugin
            entry.lastError = errors[entry.id]
            if installing.contains(entry.id) {
                entry.enabled = false
            }
            return entry
        }
        onChange?()
    }

    @MainActor func inspect(_ url: URL) async throws -> PluginManifest {
        guard let store else {
            throw PluginFailure("Plugin storage is unavailable.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            io.async { continuation.resume(with: Result { try store.inspect(url).manifest }) }
        }
    }

    @MainActor @discardableResult func importPackage(_ url: URL) async throws -> PluginManifest {
        guard let store else {
            throw PluginFailure("Plugin storage is unavailable.")
        }
        let archive: PluginStore.Archive =
            try await withCheckedThrowingContinuation { continuation in
                io.async { continuation.resume(with: Result { try store.inspect(url) }) }
            }
        let id = archive.manifest.id
        guard installing.insert(id).inserted else {
            throw PluginFailure("This plugin is already being installed.")
        }
        defer {
            installing.remove(id)
            reload()
        }
        stop(id)
        if let index = installed.firstIndex(where: { $0.id == id }) {
            installed[index].enabled = false
        }
        onChange?()
        let result: PluginManifest = try await withCheckedThrowingContinuation { continuation in
            io.async { continuation.resume(with: Result { try store.install(archive) }) }
        }
        return result
    }

    func enable(id: String, trust: Bool, expectedRevision: String) throws {
        guard !installing.contains(id) else {
            throw PluginFailure("Wait for plugin installation to finish.")
        }
        guard let store else {
            throw PluginFailure("Plugin storage is unavailable.")
        }
        try store.enable(id, trusted: trust, expectedRevision: expectedRevision)
        failures[id] = nil
        clearError(id)
        reload()
    }

    func disable(id: String) {
        stop(id)
        do {
            try store?.disable(id)
        } catch {
            lastError = error.localizedDescription
        }
        reload()
    }

    func rollback(id: String) throws {
        guard !installing.contains(id) else {
            throw PluginFailure("Wait for plugin installation to finish.")
        }
        stop(id)
        try store?.rollback(id)
        reload()
    }

    func remove(id: String, deleteData: Bool) throws {
        guard !installing.contains(id) else {
            throw PluginFailure("Wait for plugin installation to finish.")
        }
        stop(id)
        try store?.remove(id, deleteData: deleteData)
        reload()
    }

    func settings(id: String) throws -> [String: PluginJSON] {
        guard let store else {
            throw PluginFailure("Plugin storage is unavailable.")
        }
        var values: [String: PluginJSON] = [:]
        for setting in try store.manifest(id)
            .settings ?? []
        {
            if let value = setting.default {
                values[setting.key] = value
            }
        }
        values.merge(try store.values(id, kind: "settings")) { _, new in new }
        return values
    }

    func setSetting(id: String, key: String, value: PluginJSON) throws {
        guard let store, let setting = try store.manifest(id).settings?.first(where: { $0.key == key }),
              PluginManifest.matches(
                  value,
                  type: setting.type
              )
        else {
            throw PluginFailure("Unknown setting or invalid value.")
        }
        try store.set(id, kind: "settings", key: key, value: value)
    }

    func cancelQueries() {
        generation += 1
        validActions.removeAll()
        processes.values.forEach { $0.cancelQueries() }
    }

    func shutdown() {
        generation += 1
        validActions.removeAll()
        processes.values.forEach { $0.stop() }
        processes.removeAll()
    }

    private func stop(_ id: String) {
        processes.removeValue(forKey: id)?.stop()
        validActions[id] = nil
        generation += 1
    }

    @MainActor func query(pluginID: String, providerID: String, query: String) async throws -> [PluginResultItem] {
        guard installed.first(where: { $0.id == pluginID && $0.enabled })?.manifest.searchProviders?
            .contains(where: { $0.id == providerID }) == true
        else {
            throw PluginFailure("Unknown search provider.")
        }
        let current = generation
        let value = try await request(
            pluginID,
            method: "search",
            params: ["providerID": .string(providerID), "query": .string(String(query.prefix(16384)))],
            interactive: false
        )
        guard current == generation else {
            throw CancellationError()
        }
        struct Results: Decodable {
            let items: [PluginResultItem]
        }
        let items = try JSONDecoder().decode(Results.self, from: JSONEncoder().encode(value)).items
        guard items.count <= 100,
              Set(items.map(\.id)).count == items.count
        else {
            throw PluginFailure("Invalid plugin result count or duplicate IDs.")
        }
        for item in items {
            guard PluginManifest.validID(item.id), !item.title.isEmpty, item.title.count <= 512,
                  (item.subtitle?.count ?? 0) <= 2048, (item.symbol?.count ?? 0) <= 120, !item.actions.isEmpty,
                  item.actions.count <= 10,
                  item.actions
                  .allSatisfy({ PluginManifest.validID($0.id) && !$0.title.isEmpty && $0.title.count <= 120 })
            else {
                throw PluginFailure("Invalid plugin result row.")
            }
        }
        validActions[pluginID] = items.flatMap(\.actions)
        return items
    }

    @MainActor func invoke(pluginID: String, commandID: String, argument: String) async throws -> String? {
        guard installed.first(where: { $0.id == pluginID && $0.enabled })?.manifest.commands?
            .contains(where: { $0.id == commandID }) == true
        else {
            throw PluginFailure("Unknown plugin command.")
        }
        return try await request(
            pluginID,
            method: "command",
            params: ["commandID": .string(commandID), "argument": .string(String(argument.prefix(16384)))],
            interactive: true
        ).object?["message"]?.string
    }

    @MainActor func invokeAction(pluginID: String, action: PluginResultAction) async throws -> String? {
        guard validActions[pluginID]?.contains(action) == true
        else {
            throw PluginFailure("This plugin result is no longer active.")
        }
        return try await request(
            pluginID,
            method: "action",
            params: ["actionID": .string(action.id), "arguments": action.arguments ?? .null],
            interactive: true
        ).object?["message"]?.string
    }

    @MainActor private func request(
        _ id: String,
        method: String,
        params: [String: PluginJSON],
        interactive: Bool
    ) async throws -> PluginJSON {
        try Task.checkCancellation()
        let requestGeneration = generation
        let process = try runtime(id)
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                process.start { continuation.resume(with: $0) }
            }
            try Task.checkCancellation()
            guard method != "search" || requestGeneration == generation else {
                throw CancellationError()
            }
            guard installed.contains(where: { $0.id == id && $0.enabled }),
                  processes[id] === process
            else {
                throw CancellationError()
            }
            let result: PluginJSON = try await withCheckedThrowingContinuation { continuation in
                process.request(
                    method: method,
                    params: .object(params),
                    interactive: interactive,
                    timeout: interactive ? 10 : 2
                ) { continuation.resume(with: $0) }
            }
            clearError(id)
            return result
        } catch {
            if !(error is CancellationError) {
                lastError = error.localizedDescription
                if let index = installed
                    .firstIndex(where: { $0.id == id })
                {
                    installed[index].lastError = error.localizedDescription
                }
            }
            throw error
        }
    }

    private func clearError(_ id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else {
            return
        }
        let priorError = installed[index].lastError
        installed[index].lastError = nil
        if let priorError, lastError == priorError {
            lastError = nil
        }
    }

    private func runtime(_ id: String) throws -> PluginProcess {
        guard !installing.contains(id), let store,
              let plugin = installed.first(where: { $0.id == id && $0.enabled })
        else {
            throw PluginFailure("Plugin is disabled.")
        }
        if let process = processes[id] {
            return process
        }
        if let failed = failures[id],
           Date()
           .timeIntervalSince(failed) < 5
        {
            throw PluginFailure("Plugin stopped. Wait a few seconds before retrying.")
        }
        guard processes.count < 2
        else {
            throw PluginFailure("Two plugins are active. Try again after they become idle.")
        }
        let node = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/plugin-node")
        guard let resources = Bundle.main.resourceURL
        else {
            throw PluginFailure("Plugin runtime resources are missing.")
        }
        let runner = resources.appendingPathComponent("PluginRuntime/runner.mjs")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.fileExists(atPath: runner.path)
        else {
            throw PluginFailure("Bundled plugin runtime is missing. Reinstall Vorssaint.")
        }
        let process = try PluginProcess(
            id: id,
            directory: store.code(id),
            node: node,
            runner: runner
        ) { [weak self] method, params, interactive, authorized, completion in
            Task { @MainActor in
                guard let self, authorized(),
                      self.installed.contains(where: { $0.id == id && $0.enabled })
                else {
                    completion(.failure(PluginFailure("Plugin is disabled.")))
                    return
                }
                completion(Result { try self.hostCall(
                    plugin: plugin.manifest,
                    method: method,
                    params: params,
                    interactive: interactive
                ) })
            }
        }
        process.onStop = { [weak self, weak process] in Task { @MainActor in
            guard let self, self.processes[id] === process else {
                return
            }
            self.processes[id] = nil
            self.failures[id] = Date()
        } }
        processes[id] = process
        return process
    }

    private func hostCall(
        plugin: PluginManifest,
        method: String,
        params: [String: PluginJSON],
        interactive: Bool
    ) throws -> PluginJSON {
        let capabilities = [
            "clipboard.write": "clipboard.write",
            "url.open": "url.open",
            "settings.get": "settings.read",
            "storage.get": "storage.read",
            "storage.set": "storage.write",
            "status.show": "status.show"
        ]
        guard let capability = capabilities[method],
              plugin.capabilities.contains(capability)
        else {
            throw PluginFailure("Plugin capability is not declared.")
        }
        switch method {
        case "clipboard.write":
            guard interactive, let text = params["text"]?.string,
                  text.utf8.count <= 262_144
            else {
                throw PluginFailure("Clipboard writes require a user action and bounded text.")
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return .null
        case "url.open":
            guard interactive, let text = params["url"]?.string, text.count <= 8192, let url = URL(string: text), [
                "https",
                "http",
                "mailto"
            ].contains(url.scheme?.lowercased() ?? "")
            else {
                throw PluginFailure("This URL is not allowed, or no user action is active.")
            }
            guard NSWorkspace.shared.open(url) else {
                throw PluginFailure("Could not open URL.")
            }
            return .null
        case "settings.get":
            guard let key = params["key"]?.string,
                  plugin.settings?.contains(where: { $0.key == key }) == true
            else {
                throw PluginFailure("Setting is not declared.")
            }
            return try settings(id: plugin.id)[key] ?? .null
        case "storage.get":
            guard let key = params["key"]?.string, PluginManifest.validID(key),
                  let store
            else {
                throw PluginFailure("Invalid storage key.")
            }
            return try store.values(plugin.id, kind: "storage")[key] ?? .null
        case "storage.set":
            guard let key = params["key"]?.string, let value = params["value"],
                  let store
            else {
                throw PluginFailure("Invalid storage write.")
            }
            try store.set(plugin.id, kind: "storage", key: key, value: value)
            return .null
        case "status.show":
            guard let message = params["message"]?.string,
                  message.count <= 4096
            else {
                throw PluginFailure("Invalid status message.")
            }
            statusMessage = "\(plugin.name): \(message)"
            onStatus?(plugin.id, message)
            return .null
        default:
            throw PluginFailure("Unknown host method.")
        }
    }
}
