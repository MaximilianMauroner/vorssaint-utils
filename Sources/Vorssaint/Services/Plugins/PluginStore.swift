// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import CryptoKit
import Darwin

/// All code is immutable after validation. A single atomic state file selects active and rollback versions.
final class PluginStore {
    struct State: Codable {
        var current: String
        var previous: String?
        var enabled: Bool
    }

    struct Archive: Decodable {
        let formatVersion: Int
        let manifest: PluginManifest
        let files: [File]
    }

    struct File: Decodable {
        let path: String
        let data: String
        let sha256: String
    }

    let root: URL
    let hostVersion: String
    private let fm = FileManager.default
    init(root: URL, hostVersion: String) throws {
        self.root = root
        self.hostVersion = hostVersion
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func directory(_ id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    func state(_ id: String) throws -> State {
        try JSONDecoder().decode(
            State.self,
            from: Data(contentsOf: directory(id).appendingPathComponent("state.json"))
        )
    }

    func save(_ state: State, id: String) throws {
        try JSONEncoder().encode(state).write(
            to: directory(id).appendingPathComponent("state.json"),
            options: .atomic
        )
    }

    func code(_ id: String) throws -> URL {
        let state = try state(id)
        return directory(id).appendingPathComponent("versions").appendingPathComponent(state.current)
    }

    func manifest(_ id: String) throws -> PluginManifest {
        try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(contentsOf: code(id).appendingPathComponent("plugin.json"))
        )
    }

    func list() -> [InstalledPlugin] {
        ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).compactMap { url in
            let id = url.lastPathComponent
            guard PluginManifest.validID(id), let state = try? state(id), let manifest = try? manifest(id),
                  (try? manifest.validate(hostVersion: hostVersion)) != nil
            else {
                return nil
            }
            return InstalledPlugin(
                manifest: manifest,
                revision: state.current,
                enabled: state.enabled,
                hasPrevious: state.previous != nil
            )
        }.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
    }

    func inspect(_ url: URL) throws -> Archive {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw PluginFailure("Could not open the plugin package as a regular file.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        let maximumBytes = 30 * 1024 * 1024
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size >= 0,
              metadata.st_size <= off_t(maximumBytes)
        else {
            throw PluginFailure("Plugin packages must be regular files of at most 30 MiB.")
        }
        var contents = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - contents.count)), !chunk.isEmpty {
            contents.append(chunk)
            guard contents.count <= maximumBytes else {
                throw PluginFailure("Package exceeds 30 MiB.")
            }
        }
        let archive = try JSONDecoder().decode(Archive.self, from: contents)
        guard archive.formatVersion == 1, !archive.files.isEmpty,
              archive.files.count <= 512
        else {
            throw PluginFailure("Unsupported package format or file count.")
        }
        try archive.manifest.validate(hostVersion: hostVersion)
        var paths = Set<String>()
        var total = 0
        for file in archive.files {
            let path = file.path
            guard PluginManifest.validPath(path), paths.insert(path.lowercased()).inserted,
                  path.lowercased() != "plugin.json",
                  !path.lowercased().split(separator: "/").contains("node_modules"),
                  !path.lowercased().hasSuffix(".node"),
                  let data = Data(base64Encoded: file.data)
            else {
                throw PluginFailure("Invalid or duplicate package file: \(path)")
            }
            if path.lowercased() == "package.json" {
                guard path == "package.json",
                      let package = try? JSONDecoder().decode(PluginJSON.self, from: data),
                      package == .object(["type": .string("module")])
                else {
                    throw PluginFailure("Root package.json must contain only the generated module type.")
                }
            }
            total += data.count
            guard total <= 20 * 1024 * 1024 else {
                throw PluginFailure("Unpacked package exceeds 20 MiB.")
            }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == file.sha256 else {
                throw PluginFailure("File checksum mismatch: \(path)")
            }
        }
        guard archive.files.contains(where: { $0.path == "package.json" }) else {
            throw PluginFailure("Package is missing its generated package.json.")
        }
        guard archive.files.contains(where: { $0.path == archive.manifest.main })
        else {
            throw PluginFailure("Package entry file is missing.")
        }
        return archive
    }

    func install(_ url: URL) throws -> PluginManifest {
        try install(inspect(url))
    }

    func install(_ archive: Archive) throws -> PluginManifest {
        let id = archive.manifest.id
        let versions = directory(id).appendingPathComponent("versions", isDirectory: true)
        try fm.createDirectory(at: versions, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let staged = versions.appendingPathComponent(token, isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: false)
        var committed = false
        defer {
            if !committed {
                try? fm.removeItem(at: staged)
            }
        }
        for file in archive.files {
            let output = staged.appendingPathComponent(file.path)
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = Data(base64Encoded: file.data) else {
                throw PluginFailure("Invalid base64 file.")
            }
            try data.write(to: output, options: .atomic)
        }
        try JSONEncoder().encode(archive.manifest).write(
            to: staged.appendingPathComponent("plugin.json"),
            options: .atomic
        )
        let old = try? state(id)
        try save(State(current: token, previous: old?.current, enabled: false), id: id)
        committed = true
        if let previous = old?.previous {
            try? fm.removeItem(at: versions.appendingPathComponent(previous))
        }
        return archive.manifest
    }

    func enable(_ id: String, trusted: Bool, expectedRevision: String) throws {
        guard trusted else {
            throw PluginFailure("Explicit trust is required to enable local plugin code.")
        }
        var s = try state(id)
        guard s.current == expectedRevision else {
            throw PluginFailure("This plugin changed after review. Review the installed version before enabling it.")
        }
        s.enabled = true
        try save(s, id: id)
    }

    func disable(_ id: String) throws {
        var s = try state(id)
        s.enabled = false
        try save(s, id: id)
    }

    func rollback(_ id: String) throws {
        var s = try state(id)
        guard let previous = s.previous else {
            throw PluginFailure("No previous version is available.")
        }
        s.previous = s.current
        s.current = previous
        s.enabled = false
        try save(s, id: id)
    }

    func remove(_ id: String, deleteData: Bool) throws {
        let dir = directory(id)
        for name in ["state.json", "versions"] {
            let url = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
        if deleteData {
            try fm.removeItem(at: dir)
        }
    }

    func values(_ id: String, kind: String) throws -> [String: PluginJSON] {
        let url = directory(id).appendingPathComponent("data").appendingPathComponent(kind + ".json")
        guard fm.fileExists(atPath: url.path) else {
            return [:]
        }
        return try JSONDecoder().decode([String: PluginJSON].self, from: Data(contentsOf: url))
    }

    func set(_ id: String, kind: String, key: String, value: PluginJSON) throws {
        guard PluginManifest.validID(key) else {
            throw PluginFailure("Invalid storage key.")
        }
        var values = try values(id, kind: kind)
        values[key] = value
        let data = try JSONEncoder().encode(values)
        guard data.count <= 1024 * 1024 else {
            throw PluginFailure("Plugin data exceeds 1 MiB.")
        }
        let dir = directory(id).appendingPathComponent("data", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(kind + ".json"), options: .atomic)
    }
}
