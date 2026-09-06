// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Darwin

final class PluginProcess {
    typealias Bridge = (
        String,
        [String: PluginJSON],
        Bool,
        @escaping () -> Bool,
        @escaping (Result<PluginJSON, Error>) -> Void
    ) -> Void
    private struct Pending {
        let method: String
        let interactive: Bool
        let completion: (Result<PluginJSON, Error>) -> Void
    }

    private let queue = DispatchQueue(label: "Vorssaint.plugin.process")
    private let writer = DispatchQueue(label: "Vorssaint.plugin.writer")
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var buffer = Data()
    private var pending: [String: Pending] = [:]
    private var stopped = false
    private var ready = false
    private var idle: DispatchWorkItem?
    private var startup: [(Result<PluginJSON, Error>) -> Void] = []
    private var stderrTail = Data()
    private var hostCalls = 0
    private var awaitingCancellation = Set<String>()
    private var recentRequestIDs: [String] = []
    let id: String
    var onStop: (() -> Void)?
    let bridge: Bridge
    init(id: String, directory: URL, node: URL, runner: URL, bridge: @escaping Bridge) throws {
        self.id = id
        self.bridge = bridge
        // A child can close stdin before the writer sees its exit. Report EPIPE
        // for this pipe instead of delivering SIGPIPE to the entire app.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw PluginFailure("Could not configure the plugin input pipe.")
        }
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("plugin.json"))
        )
        process.executableURL = node
        process.arguments = [
            "--max-old-space-size=128",
            runner.path,
            directory.appendingPathComponent(manifest.main).path
        ]
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    func start(_ completion: @escaping (Result<PluginJSON, Error>) -> Void) {
        queue.async {
            if self.ready {
                completion(.success(.null))
                return
            }
            if self.stopped {
                completion(.failure(PluginFailure("Plugin process stopped.")))
                return
            }
            self.startup.append(completion)
            if self.startup.count > 1 {
                return
            }
            self.output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                self?.queue.async { self?.receive(data) }
            }
            self.errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                self?.queue.async {
                    guard let self else {
                        return
                    }
                    self.stderrTail.append(data)
                    if self.stderrTail.count > 16_384 {
                        self.stderrTail.removeFirst(self.stderrTail.count - 16_384)
                    }
                }
            }
            self.process
                .terminationHandler = { [weak self] _ in
                    self?.queue.async { self?.finish(PluginFailure("Plugin process exited.")) }
                }
            do {
                try self.process.run()
                self.sendRequest(
                    method: "initialize",
                    params: .object(["apiVersion": .number(1)]),
                    interactive: false,
                    timeout: 5
                ) { result in
                    let checked = result.flatMap { value -> Result<PluginJSON, Error> in
                        guard value.object?["apiVersion"] == .number(1),
                              value.object?["pluginID"] == .string(self.id)
                        else {
                            return .failure(PluginFailure("Plugin handshake mismatch."))
                        }
                        return .success(value)
                    }
                    self.ready = (try? checked.get()) != nil
                    let callbacks = self.startup
                    self.startup.removeAll()
                    callbacks.forEach { $0(checked) }
                    if !self.ready {
                        self.finish(PluginFailure("Plugin startup failed."))
                    }
                }
            } catch {
                self.finish(error)
            }
        }
    }

    func request(
        method: String,
        params: PluginJSON,
        interactive: Bool,
        timeout: TimeInterval,
        completion: @escaping (Result<PluginJSON, Error>) -> Void
    ) {
        queue.async {
            guard self.ready, !self.stopped else {
                completion(.failure(PluginFailure("Plugin is unavailable.")))
                return
            }
            self.sendRequest(
                method: method,
                params: params,
                interactive: interactive,
                timeout: timeout,
                completion: completion
            )
        }
    }

    func cancelQueries() {
        queue.async { self.cancelSearches() }
    }

    func stop() {
        queue.async { self.finish(PluginFailure("Plugin stopped.")) }
    }

    private func sendRequest(
        method: String,
        params: PluginJSON,
        interactive: Bool,
        timeout: TimeInterval,
        completion: @escaping (Result<PluginJSON, Error>) -> Void
    ) {
        guard pending.count + awaitingCancellation.count < 16
        else {
            completion(.failure(PluginFailure("Plugin is busy.")))
            return
        }
        idle?.cancel()
        let requestID = UUID().uuidString
        pending[requestID] = Pending(method: method, interactive: interactive, completion: completion)
        send(.object([
            "jsonrpc": .string("2.0"),
            "id": .string(requestID),
            "method": .string(method),
            "params": params
        ]))
        queue.asyncAfter(deadline: .now() + timeout) {
            guard let request = self.pending.removeValue(forKey: requestID) else {
                return
            }
            self.remember(requestID)
            self.send(.object([
                "jsonrpc": .string("2.0"),
                "method": .string("cancel"),
                "params": .object(["requestID": .string(requestID)])
            ]))
            request.completion(.failure(PluginFailure("Plugin request timed out.")))
            self.queue
                .asyncAfter(deadline: .now() + 0.25) { self.finish(PluginFailure("Plugin exceeded its deadline.")) }
        }
    }

    private func cancelSearches() {
        for (id, request) in pending where request.method == "search" {
            pending.removeValue(forKey: id)
            remember(id)
            awaitingCancellation.insert(id)
            queue
                .asyncAfter(deadline: .now() + 0.25) {
                    if self.awaitingCancellation
                        .contains(id)
                    {
                        self.finish(PluginFailure("Plugin did not acknowledge cancellation."))
                    }
                }
            send(.object([
                "jsonrpc": .string("2.0"),
                "method": .string("cancel"),
                "params": .object(["requestID": .string(id)])
            ]))
            request.completion(.failure(CancellationError()))
        }
        scheduleIdle()
    }

    private func send(_ value: PluginJSON) {
        guard !stopped, var data = try? JSONEncoder().encode(value),
              data.count <= 1_048_576
        else {
            finish(PluginFailure("Invalid or oversized outgoing plugin message."))
            return
        }
        data.append(10)
        let handle = input.fileHandleForWriting
        writer.async { [weak self] in
            do {
                try handle.write(contentsOf: data)
            } catch {
                self?.queue.async { self?.finish(error) }
            }
        }
    }

    private func receive(_ data: Data) {
        guard !stopped else {
            return
        }
        guard !data.isEmpty else {
            finish(PluginFailure("Plugin closed its output."))
            return
        }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let frame = buffer.prefix(upTo: end)
            buffer.removeSubrange(...end)
            guard frame.count <= 1_048_576, let value = try? JSONDecoder().decode(PluginJSON.self, from: frame),
                  let message = value.object,
                  message["jsonrpc"] == .string("2.0")
            else {
                finish(PluginFailure("Malformed plugin message."))
                return
            }
            if let method = message["method"]?.string {
                guard let rpcID = message["id"]?.string, let params = message["params"]?.object,
                      let parent = params["requestID"]?.string
                else {
                    finish(PluginFailure("Malformed plugin host call."))
                    return
                }
                guard let context = pending[parent] else {
                    guard recentRequestIDs.contains(parent)
                    else {
                        finish(PluginFailure("Plugin host call has no active request."))
                        return
                    }
                    send(.object([
                        "jsonrpc": .string("2.0"),
                        "id": .string(rpcID),
                        "error": .object([
                            "code": .number(-32800),
                            "message": .string("Parent request is no longer active.")
                        ])
                    ]))
                    continue
                }
                guard hostCalls < 32 else {
                    finish(PluginFailure("Too many pending plugin host calls."))
                    return
                }
                hostCalls += 1
                bridge(
                    method,
                    params,
                    context.interactive,
                    { self.queue.sync { !self.stopped && self.pending[parent] != nil } }
                ) { result in
                    self.queue.async {
                        self.hostCalls -= 1
                        guard !self.stopped, self.pending[parent] != nil else {
                            return
                        }
                        var response: [String: PluginJSON] = ["jsonrpc": .string("2.0"), "id": .string(rpcID)]
                        switch result {
                        case .success(let value):
                            response["result"] = value
                        case .failure(let error):
                            response["error"] = .object([
                                "code": .number(-32000),
                                "message": .string(error.localizedDescription)
                            ])
                        }
                        self.send(.object(response))
                    }
                }
            } else if let rpcID = message["id"]?.string, let request = pending.removeValue(forKey: rpcID) {
                remember(rpcID)
                if let error = message["error"]?
                    .object
                {
                    request.completion(.failure(PluginFailure(error["message"]?.string ?? "Plugin request failed.")))
                } else if let result = message["result"] {
                    request.completion(.success(result))
                } else {
                    request.completion(.failure(PluginFailure("Malformed plugin response.")))
                }
                scheduleIdle()
            } else if let rpcID = message["id"]?.string {
                awaitingCancellation.remove(rpcID)
            }
        }
        if buffer.count > 1_048_576 {
            finish(PluginFailure("Plugin output exceeded 1 MiB."))
        }
    }

    private func remember(_ requestID: String) {
        recentRequestIDs.append(requestID)
        if recentRequestIDs.count > 128 {
            recentRequestIDs.removeFirst(recentRequestIDs.count - 128)
        }
    }

    private func scheduleIdle() {
        guard pending.isEmpty else {
            return
        }
        idle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish(PluginFailure("Plugin idle timeout.")) }
        idle = work
        queue.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func finish(_ error: Error) {
        guard !stopped else {
            return
        }
        stopped = true
        idle?.cancel()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
            queue.asyncAfter(deadline: .now() + 0.25) {
                if self.process.isRunning {
                    kill(
                        self.process.processIdentifier,
                        SIGKILL
                    )
                }
            }
        }
        let callbacks = pending.values.map(\.completion)
        pending.removeAll()
        callbacks.forEach { $0(.failure(error)) }
        let initial = startup
        startup.removeAll()
        initial.forEach { $0(.failure(error)) }
        onStop?()
    }
}
