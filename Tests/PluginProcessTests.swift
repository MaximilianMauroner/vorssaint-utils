// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

// macOS standalone: swiftc PluginModels.swift PluginProcess.swift PluginProcessTests.swift -o tests
// Run: tests /absolute/node /absolute/Packages/plugin-runtime/runner.mjs
import Foundation

@main struct PluginProcessTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Pass absolute Node and runner paths")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = #"{"id":"com.example.process-test","name":"Test","version":"1.0.0","apiVersion":1,"main":"index.mjs","commands":[{"id":"hello","title":"Hello"},{"id":"hang","title":"Hang"}],"searchProviders":[{"id":"search","title":"Search","keyword":"test"}],"capabilities":["clipboard.write"]}"#
        let source = #"""
        await new Promise(resolve => setTimeout(resolve, 100));
        export default {
          commands: {
            hello: async ({argument}, host) => { await host.clipboard.writeText(argument); return {message: 'done'}; },
            hang: async () => new Promise(() => {})
          },
          searchProviders: { search: async (_, host) => {
            try { await host.clipboard.writeText('forbidden'); throw new Error('Search bridge was allowed'); }
            catch(error) { if (!error.message.includes('unavailable during search')) throw error; }
            return {items: []};
          }}
        };
        """#
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("plugin.json"))
        try Data(source.utf8).write(to: directory.appendingPathComponent("index.mjs"))
        let process = try PluginProcess(
            id: "com.example.process-test",
            directory: directory,
            node: URL(fileURLWithPath: CommandLine.arguments[1]),
            runner: URL(fileURLWithPath: CommandLine.arguments[2])
        ) { method, params, interactive, authorized, completion in
            // Avoid calling authorization on the process queue. The production bridge dispatches to main.
            DispatchQueue.global().async {
                guard authorized(), interactive, method == "clipboard.write",
                      params["text"] == .string("test")
                else {
                    completion(.failure(PluginFailure("Denied")))
                    return
                }
                completion(.success(.null))
            }
        }
        defer { process.stop() }
        let handshake = try await withCheckedThrowingContinuation { continuation in
            process.start { continuation.resume(with: $0) }
            // Typing while the module loads must leave initialize alive.
            process.cancelQueries()
        }
        assert(handshake.object?["apiVersion"] == .number(1))
        func request(
            _ method: String,
            _ params: [String: PluginJSON],
            interactive: Bool,
            timeout: TimeInterval = 2
        ) async throws -> PluginJSON {
            try await withCheckedThrowingContinuation { continuation in process.request(
                method: method,
                params: .object(params),
                interactive: interactive,
                timeout: timeout
            ) { continuation.resume(with: $0) } }
        }
        let result = try await request(
            "command",
            ["commandID": .string("hello"), "argument": .string("test")],
            interactive: true
        )
        assert(result.object?["message"] == .string("done"))
        let search = try await request(
            "search",
            ["providerID": .string("search"), "query": .string("test")],
            interactive: false
        )
        assert(search.object?["items"] == .array([]))
        do {
            _ = try await request(
                "command",
                ["commandID": .string("hang"), "argument": .string("")],
                interactive: true,
                timeout: 0.1
            )
            fatalError("Hung request should time out")
        } catch { assert(error.localizedDescription.contains("timed out")) }
        try await Task.sleep(nanoseconds: 400_000_000)
        do {
            _ = try await request(
                "command",
                ["commandID": .string("hello"), "argument": .string("test")],
                interactive: true
            )
            fatalError("Timed-out process should stop")
        } catch { assert(error.localizedDescription.contains("unavailable")) }
        try await cancellationRace(directory: directory)
        try await closedInput(directory: directory)
        print("Native plugin handshake, bridge, search denial, cancellation and timeout tests passed")
    }

    static func cancellationRace(directory: URL) async throws {
        // A deterministic peer places a host callback after the cancellation acknowledgment.
        // This reproduces crossed pipe traffic without depending on thread timing.
        let runner = directory.appendingPathComponent("race-runner.mjs")
        let source = #"""
        import { createInterface } from 'node:readline';
        const send = value => process.stdout.write(JSON.stringify({jsonrpc:'2.0',...value}) + '\n');
        createInterface({input:process.stdin}).on('line', line => {
          const m = JSON.parse(line);
          if (m.method === 'initialize') send({id:m.id,result:{apiVersion:1,pluginID:'com.example.process-test'}});
          if (m.method === 'cancel') {
            send({id:m.params.requestID,error:{code:-32800,message:'Cancelled'}});
            send({id:'late-host',method:'status.show',params:{requestID:m.params.requestID,message:'late'}});
          }
          if (m.method === 'command') send({id:m.id,result:{message:'alive'}});
        });
        """#
        try Data(source.utf8).write(to: runner)
        let process = try PluginProcess(
            id: "com.example.process-test",
            directory: directory,
            node: URL(fileURLWithPath: CommandLine.arguments[1]),
            runner: runner
        ) { _, _, _, _, _ in
            fatalError("A canceled parent must never reach the host bridge")
        }
        defer { process.stop() }
        _ = try await withCheckedThrowingContinuation { continuation in
            process.start { continuation.resume(with: $0) }
        }
        do {
            let _: PluginJSON = try await withCheckedThrowingContinuation { continuation in
                process
                    .request(method: "search", params: .object([:]), interactive: false, timeout: 2) {
                        continuation.resume(with: $0)
                    }
                process.cancelQueries()
            }
            fatalError("Search should be canceled")
        } catch { assert(error is CancellationError) }
        let result = try await withCheckedThrowingContinuation { continuation in
            process
                .request(method: "command", params: .object([:]), interactive: true, timeout: 2) {
                    continuation.resume(with: $0)
                }
        }
        assert(result.object?["message"] == .string("alive"))
        // Also wait past the grace deadline: the received acknowledgment must clear it.
        try await Task.sleep(nanoseconds: 350_000_000)
        let afterGrace = try await withCheckedThrowingContinuation { continuation in
            process
                .request(method: "command", params: .object([:]), interactive: true, timeout: 2) {
                    continuation.resume(with: $0)
                }
        }
        assert(afterGrace.object?["message"] == .string("alive"))
    }

    static func closedInput(directory: URL) async throws {
        let runner = directory.appendingPathComponent("closed-input-runner.mjs")
        let source = #"""
        import { createInterface } from 'node:readline';
        import { closeSync } from 'node:fs';
        const lines = createInterface({input: process.stdin});
        lines.once('line', line => {
          const request = JSON.parse(line);
          lines.close();
          process.stdin.pause();
          closeSync(0);
          process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,
            result:{apiVersion:1,pluginID:'com.example.process-test'}}) + '\n');
          setTimeout(() => process.exit(0), 5000);
        });
        """#
        try Data(source.utf8).write(to: runner)
        let process = try PluginProcess(
            id: "com.example.process-test", directory: directory,
            node: URL(fileURLWithPath: CommandLine.arguments[1]), runner: runner
        ) { _, _, _, _, _ in fatalError("No host calls expected") }
        defer { process.stop() }
        _ = try await withCheckedThrowingContinuation { continuation in
            process.start { continuation.resume(with: $0) }
        }
        do {
            let _: PluginJSON = try await withCheckedThrowingContinuation { continuation in
                process.request(method: "command", params: .object([:]), interactive: true, timeout: 2) {
                    continuation.resume(with: $0)
                }
            }
            fatalError("Writing to closed plugin stdin must fail")
        } catch {
            // Reaching this point proves the broken pipe did not terminate the host.
        }
    }

}
