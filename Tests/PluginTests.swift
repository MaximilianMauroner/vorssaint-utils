// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

// Run on macOS: swiftc Sources/Vorssaint/Core/Plugins/PluginModels.swift Sources/Vorssaint/Services/Plugins/PluginStore.swift Tests/PluginTests.swift -o /tmp/vorssaint-plugin-tests && /tmp/vorssaint-plugin-tests
import Foundation
import CryptoKit
import Darwin

@main struct PluginTests {
    static func main() throws {
        func check(_ condition: @autoclosure () throws -> Bool) rethrows {
            let result = try condition()
            assert(result)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PluginStore(root: root, hostVersion: "1.0.0")
        let archiveURL = root.appendingPathComponent("test.vorssaint-plugin")
        let source = Data("export default { commands: {} };".utf8)
        let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        func package(
            version: String = "1.0.0",
            path: String = "dist/index.js",
            hash: String? = nil,
            api: Int = 1,
            packageJSON: PluginJSON? = .object(["type": .string("module")])
        ) throws {
            let manifest: [String: PluginJSON] = [
                "id": .string("com.example.test"),
                "name": .string("Test"),
                "version": .string(version),
                "apiVersion": .number(Double(api)),
                "main": .string("dist/index.js"),
                "commands": .array([.object(["id": .string("test"), "title": .string("Test")])]),
                "capabilities": .array([])
            ]
            var files: [PluginJSON] = [.object([
                "path": .string(path),
                "data": .string(source.base64EncodedString()),
                "sha256": .string(hash ?? digest)
            ])]
            if let packageJSON {
                let data = try JSONEncoder().encode(packageJSON)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                files.append(.object([
                    "path": .string("package.json"),
                    "data": .string(data.base64EncodedString()),
                    "sha256": .string(hash)
                ]))
            }
            let archive: PluginJSON = .object([
                "formatVersion": .number(1),
                "manifest": .object(manifest),
                "files": .array(files)
            ])
            try JSONEncoder().encode(archive).write(to: archiveURL)
        }
        func rejected(_ name: String, operation: () throws -> Void) {
            do {
                try operation()
                fatalError("Expected rejection: \(name)")
            } catch { }
        }
        try package()
        let manifest = try store.install(archiveURL)
        assert(manifest.id == "com.example.test")
        try check(!store.state(manifest.id).enabled)
        let reviewedRevision = try store.state(manifest.id).current
        rejected("trust") {
            try store.enable(manifest.id, trusted: false, expectedRevision: reviewedRevision)
        }
        try store.enable(manifest.id, trusted: true, expectedRevision: reviewedRevision)
        try check(store.state(manifest.id).enabled)
        try store.set(manifest.id, kind: "storage", key: "saved", value: .string("kept"))
        try package(version: "1.1.0")
        _ = try store.install(archiveURL)
        try check(!store.state(manifest.id).enabled)
        try check(store.manifest(manifest.id).version == "1.1.0")
        try store.rollback(manifest.id)
        try check(store.manifest(manifest.id).version == "1.0.0")
        try check(store.values(manifest.id, kind: "storage")["saved"] == .string("kept"))
        // The same public version can contain different code. Trust binds to the immutable install revision.
        try package()
        _ = try store.install(archiveURL)
        let currentRevision = try store.state(manifest.id).current
        rejected("stale trust review") {
            try store.enable(manifest.id, trusted: true, expectedRevision: reviewedRevision)
        }
        try check(!store.state(manifest.id).enabled)
        try store.enable(manifest.id, trusted: true, expectedRevision: currentRevision)
        try store.rollback(manifest.id)
        try package(path: "../index.js")
        rejected("traversal") { _ = try store.install(archiveURL) }
        try package(hash: String(repeating: "0", count: 64))
        rejected("hash") { _ = try store.install(archiveURL) }
        try package(api: 2)
        rejected("API") { _ = try store.install(archiveURL) }
        try check(store.manifest(manifest.id).version == "1.0.0")
        try package(path: "assets/node_modules/dependency.js")
        rejected("reserved node_modules") { _ = try store.inspect(archiveURL) }
        try package(packageJSON: .object(["type": .string("module"), "scripts": .object([:])]))
        rejected("custom root package.json") { _ = try store.inspect(archiveURL) }
        try package(packageJSON: nil)
        rejected("missing root package.json") { _ = try store.inspect(archiveURL) }
        rejected("directory") { _ = try store.inspect(root) }
        let fifo = root.appendingPathComponent("fifo")
        guard mkfifo(fifo.path, 0o600) == 0 else {
            fatalError("Could not create FIFO fixture")
        }
        rejected("FIFO without blocking") { _ = try store.inspect(fifo) }
        let link = root.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: archiveURL)
        rejected("symlink") { _ = try store.inspect(link) }
        let oversized = root.appendingPathComponent("oversized")
        try Data().write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 30 * 1024 * 1024 + 1)
        try handle.close()
        rejected("oversized file") { _ = try store.inspect(oversized) }
        try store.remove(manifest.id, deleteData: false)
        assert(store.list().isEmpty)
        try check(store.values(manifest.id, kind: "storage")["saved"] == .string("kept"))
        try store.remove(manifest.id, deleteData: true)
        assert(!FileManager.default.fileExists(atPath: store.directory(manifest.id).path))
        for path in ["/absolute", "a//b", "a/../b", "a\\b", "./a", "a/"] {
            assert(!PluginManifest.validPath(path))
        }
        print("Plugin package, trust, update, rollback and storage tests passed")
    }
}
