// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

indirect enum PluginJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PluginJSON])
    case object([String: PluginJSON])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([PluginJSON].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: PluginJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:
            try c.encodeNil()
        case .bool(let v):
            try c.encode(v)
        case .number(let v):
            try c.encode(v)
        case .string(let v):
            try c.encode(v)
        case .array(let v):
            try c.encode(v)
        case .object(let v):
            try c.encode(v)
        }
    }

    var string: String? {
        if case .string(let s) = self {
            return s
        }
        return nil
    }

    var object: [String: PluginJSON]? {
        if case .object(let o) = self {
            return o
        }
        return nil
    }
}

struct PluginCommand: Codable, Identifiable {
    let id: String
    let title: String
    let input: String?
}

struct PluginSearchProvider: Codable, Identifiable {
    let id: String
    let title: String
    let keyword: String
}

struct PluginSetting: Codable {
    let key: String
    let title: String
    let type: String
    let `default`: PluginJSON?
}

struct PluginManifest: Codable, Identifiable {
    let id: String
    let name: String
    let version: String
    let apiVersion: Int
    let main: String
    let commands: [PluginCommand]?
    let searchProviders: [PluginSearchProvider]?
    let capabilities: [String]
    let settings: [PluginSetting]?
    let minimumHostVersion: String?
    func validate(hostVersion: String) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw PluginFailure(message)
            }
        }
        try require(Self.validID(id) && id.contains("."), "Plugin ID must be a reverse-domain identifier.")
        try require(
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120,
            "Invalid plugin name."
        )
        try require(apiVersion == 1, "Unsupported plugin API version.")
        let versionPattern = #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?$"#
        try require(version.range(of: versionPattern, options: .regularExpression) != nil, "Invalid plugin version.")
        if let minimumHostVersion {
            try require(
                minimumHostVersion.range(of: versionPattern, options: .regularExpression) != nil,
                "Invalid minimum host version."
            )
            try require(
                hostVersion.compare(minimumHostVersion, options: .numeric) != .orderedAscending,
                "This plugin requires Vorssaint \(minimumHostVersion)."
            )
        }
        try require(
            Self.validPath(main) && (main.hasSuffix(".js") || main.hasSuffix(".mjs")),
            "Invalid JavaScript entry path."
        )
        let known: Set<String> = [
            "clipboard.write",
            "url.open",
            "settings.read",
            "storage.read",
            "storage.write",
            "status.show"
        ]
        try require(
            Set(capabilities).count == capabilities.count && Set(capabilities).isSubset(of: known),
            "Unknown or duplicate capability."
        )
        let commands = commands ?? []
        let providers = searchProviders ?? []
        try require(
            commands.count + providers.count > 0 && commands.count + providers.count <= 100,
            "Declare between 1 and 100 commands and providers."
        )
        try require(
            Set(commands.map(\.id) + providers.map(\.id)).count == commands.count + providers
                .count && Set(providers.map(\.keyword)).count == providers.count,
            "Duplicate command or provider ID."
        )
        for command in commands {
            try require(
                Self.validID(command.id) && !command.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty && command.title.count <= 120 && [
                        nil,
                        "text",
                        "none"
                    ].contains(command.input),
                "Invalid command."
            )
        }
        for provider in providers {
            try require(
                Self.validID(provider.id) && !provider.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty && provider.title.count <= 120 && provider.keyword.range(
                        of: #"^[a-z0-9][a-z0-9-]{0,31}$"#,
                        options: .regularExpression
                    ) != nil,
                "Invalid search provider."
            )
        }
        let settings = settings ?? []
        try require(
            settings.count <= 100 && Set(settings.map(\.key)).count == settings.count,
            "Invalid or duplicate settings."
        )
        for setting in settings {
            try require(
                Self.validID(setting.key) && !setting.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty && setting.title.count <= 120 && [
                        "string",
                        "boolean",
                        "number"
                    ].contains(setting.type),
                "Invalid setting."
            )
            if let value = setting.default {
                try require(
                    Self.matches(value, type: setting.type),
                    "Invalid setting default."
                )
            }
        }
    }

    static func matches(_ value: PluginJSON, type: String) -> Bool {
        switch (value, type) {
        case (.string, "string"), (.bool, "boolean"), (.number, "number"):
            return true
        default:
            return false
        }
    }

    static func validID(_ value: String) -> Bool {
        value.range(
            of: #"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil
    }

    static func validPath(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 512 && !value.hasPrefix("/") && !value.contains("\\") && !value
            .contains(":") && !value.unicodeScalars.contains(where: { $0.value < 32 }) && value.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

struct PluginResultAction: Codable, Equatable {
    let id: String
    let title: String
    let arguments: PluginJSON?
}

struct PluginResultItem: Codable, Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String?
    let actions: [PluginResultAction]
}

struct InstalledPlugin: Identifiable {
    var id: String {
        manifest.id
    }

    let manifest: PluginManifest
    let revision: String
    var enabled: Bool
    let hasPrevious: Bool
    var lastError: String?
}

struct PluginFailure: LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
