// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Serializes the app's background observers of the general pasteboard.
/// NSPasteboard keeps a mutable type cache on its shared instance, so reading
/// it from two queues at once can race inside AppKit. Slow reads stay off the
/// main thread while the services that continuously inspect the clipboard use
/// one access lane.
final class GeneralPasteboardAccess {
    static let shared = GeneralPasteboardAccess()

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueValue: UInt8 = 1

    init(label: String = "Vorssaint.Pasteboard.general") {
        queue = DispatchQueue(label: label, qos: .utility)
        queue.setSpecific(key: queueKey, value: queueValue)
    }

    func async(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    func sync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            return try work()
        }
        return try queue.sync(execute: work)
    }

    /// A deadline limits result delivery and prevents expired queued work
    /// from starting. It cannot interrupt an AppKit call already in progress.
    /// `didFinish` runs on main only when the actual queue operation ends,
    /// even if `completion` already received nil at the deadline. Callers use
    /// it to keep admission bounded while a provider is unresponsive.
    func async<T>(timeout: TimeInterval,
                  _ work: @escaping (_ isExpired: () -> Bool) -> T?,
                  then completion: @escaping (T?) -> Void,
                  didFinish: @escaping (T?) -> Void = { _ in }) {
        let deadline = DispatchTime.now() + timeout
        let delivery = PasteboardResultDelivery(completion)
        let timeoutWork = DispatchWorkItem { delivery.complete(nil) }
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: timeoutWork)
        queue.async {
            let isExpired = { DispatchTime.now() >= deadline }
            let value = isExpired() ? nil : work(isExpired)
            DispatchQueue.main.async {
                timeoutWork.cancel()
                didFinish(value)
                delivery.complete(isExpired() ? nil : value)
            }
        }
    }
}

/// Both deadline and queue completion deliver on main. Clearing the callback
/// before invoking it also makes reentrant callers safe.
private final class PasteboardResultDelivery<Value> {
    private var completion: ((Value?) -> Void)?

    init(_ completion: @escaping (Value?) -> Void) {
        self.completion = completion
    }

    func complete(_ value: Value?) {
        precondition(Thread.isMainThread)
        let callback = completion
        completion = nil
        callback?(value)
    }
}
