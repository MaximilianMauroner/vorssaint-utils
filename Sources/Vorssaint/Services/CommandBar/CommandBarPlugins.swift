// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Translates the external protocol into native rows. Called on the main thread.
final class CommandBarPlugins {
    var onChange: (() -> Void)?
    var onRegistryChange: (() -> Void)?
    var onChooseProvider: ((String) -> Void)?
    var argumentQuery: ((String, String) -> String)?
    private var pending: Task<Void, Never>?
    private var generation = 0
    private var currentQuery: String?
    private var scopedRows: [CommandBarEntry]?
    private var feedback: [String: String] = [:]
    private var running = Set<String>()

    init() {
        PluginManager.shared.onStatus = { [weak self] pluginID, message in
            guard let self else {
                return
            }
            for key in self.running where key.hasPrefix("plugin:\(pluginID):") {
                self.feedback[key] = message
            }
            self.onChange?()
        }
        PluginManager.shared.onChange = { [weak self] in
            self?.reset()
            self?.onRegistryChange?()
        }
    }

    var commandKeys: Set<String> {
        Set(PluginManager.shared.commands.map { commandKey($0.pluginID, $0.command.id) })
    }

    func catalog() -> [CommandBarEntry] {
        let manager = PluginManager.shared
        var rows = manager.commands.map { pluginID, command in
            let id = commandKey(pluginID, command.id)
            return row(id: id, title: command.title, subtitle: name(pluginID),
                       answer: feedback[id], takesArgument: command.input == "text", durable: true) { [weak self] in
                guard let self else {
                    return
                }
                let text = self.argumentQuery?(id, command.title) ?? ""
                self.perform(id: id) {
                    try await manager.invoke(pluginID: pluginID, commandID: command.id,
                                             argument: command.input == "text" ? text : "")
                }
            }
        }
        rows += manager.searchProviders.map { pluginID, provider in
            row(id: "plugin:\(pluginID):\(provider.id):provider", title: provider.title,
                subtitle: "\(name(pluginID)) · \(provider.keyword)", takesArgument: false) { [weak self] in
                    self?.onChooseProvider?(provider.keyword + " ")
                }
        }
        return rows
    }

    /// A provider receives text only after its explicit keyword and a space.
    func update(query: String, enabled: Bool) {
        let wanted = enabled ? query : ""
        guard currentQuery != wanted else {
            return
        }
        reset()
        currentQuery = wanted
        guard enabled else {
            return
        }
        let matches = PluginManager.shared.searchProviders.filter {
            wanted.lowercased().hasPrefix($0.provider.keyword.lowercased() + " ")
        }
        guard let match = matches.first else {
            return
        }
        let queryText = String(wanted.dropFirst(match.provider.keyword.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if matches.count > 1 {
            scopedRows = [messageRow("Several plugins use this keyword. Disable one to choose a provider.")]
            return
        }
        guard !queryText.isEmpty else {
            scopedRows = [messageRow("Type a search after \(match.provider.keyword).")]
            return
        }
        scopedRows = [messageRow("Searching \(name(match.pluginID))…")]
        let token = generation
        pending = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.generation == token else {
                    return
                }
                let items = try await PluginManager.shared.query(pluginID: match.pluginID,
                                                                 providerID: match.provider.id, query: queryText)
                guard self.generation == token else {
                    return
                }
                self.scopedRows = items.flatMap { item in
                    item.actions.enumerated().map { index, action in
                        let id = "plugin:\(match.pluginID):\(match.provider.id):\(item.id):\(index)"
                        return self.row(id: id, title: index == 0 ? item.title : "\(item.title) · \(action.title)",
                                        subtitle: item.subtitle ?? self.name(match.pluginID),
                                        symbol: item.symbol ?? "puzzlepiece.extension",
                                        answer: self.feedback[id]) { [weak self] in
                            self?.perform(id: id) {
                                try await PluginManager.shared.invokeAction(pluginID: match.pluginID, action: action)
                            }
                        }
                    }
                }
                if self.scopedRows?.isEmpty == true {
                    self.scopedRows = [self.messageRow("No results.")]
                }
                self.onChange?()
            } catch is CancellationError {
                // A later query or a closed bar owns the screen now.
            } catch {
                guard let self, self.generation == token else {
                    return
                }
                self.scopedRows = [self.messageRow(error.localizedDescription)]
                self.onChange?()
            }
        }
    }

    func results() -> [CommandBarEntry]? {
        scopedRows?.map { entry in
            let symbol: String
            if case .symbol(let value) = entry.icon { symbol = value }
            else { symbol = "puzzlepiece.extension" }
            return row(id: entry.id, title: entry.title, subtitle: entry.subtitle,
                       symbol: symbol, answer: feedback[entry.id] ?? entry.answerValue) { entry.run(nil) }
        }
    }

    func reset() {
        generation += 1
        pending?.cancel()
        pending = nil
        currentQuery = nil
        scopedRows = nil
        feedback.removeAll()
        PluginManager.shared.cancelQueries()
    }

    private func perform(id: String, operation: @escaping @MainActor () async throws -> String?) {
        guard running.insert(id).inserted else {
            return
        }
        feedback[id] = "Running…"
        onChange?()
        Task { @MainActor [weak self] in
            do { self?.feedback[id] = try await operation() ?? "Done" }
            catch { self?.feedback[id] = error.localizedDescription }
            self?.running.remove(id)
            self?.onChange?()
        }
    }

    private func commandKey(_ pluginID: String, _ commandID: String) -> String {
        "plugin:\(pluginID):\(commandID):command"
    }

    private func name(_ id: String) -> String {
        PluginManager.shared.installed.first { $0.id == id }?.manifest.name ?? id
    }

    private func messageRow(_ text: String) -> CommandBarEntry {
        row(id: "plugin:message", title: text, subtitle: PluginStrings.title, symbol: "info.circle") {}
    }

    private func row(id: String, title: String, subtitle: String,
                     symbol: String = "puzzlepiece.extension", answer: String? = nil,
                     takesArgument: Bool = false, durable: Bool = false,
                     run: @escaping () -> Void) -> CommandBarEntry {
        CommandBarEntry(id: id, stableKey: id, title: title, subtitle: subtitle,
                        keywords: "\(title) \(subtitle)", icon: .symbol(symbol), shortcut: nil,
                        menuShortcut: nil, isActive: false, trouble: nil, numericRange: nil,
                        numericIsOptional: false, confirmationPrompt: nil, answerValue: answer,
                        isAnswer: !durable && id == "plugin:message", countsUsage: durable,
                        matchTitle: nil, keepsBarOpen: true, takesArgument: takesArgument,
                        run: { _ in run() })
    }
}
