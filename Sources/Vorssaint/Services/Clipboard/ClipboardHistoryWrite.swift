// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

protocol ClipboardHistoryPasteboard {
    func clearContents() -> Int
    var changeCount: Int { get }
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool
    func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: ClipboardHistoryPasteboard {}

struct ClipboardHistoryWriteResult {
    let succeeded: Bool
    let changeCount: Int
}

enum ClipboardHistoryWrite {
    case text(String)
    case image(png: Data, tiff: Data?)
    case files([NSURL])
    case rich(NSAttributedString, plain: String)

    /// Expiry stops subsequent calls. A pasteboard call already in progress
    /// cannot be cancelled, and clearing or a partial write cannot be undone.
    func write(to pasteboard: any ClipboardHistoryPasteboard,
               isExpired: () -> Bool) -> ClipboardHistoryWriteResult? {
        guard !isExpired() else { return nil }
        _ = pasteboard.clearContents()
        guard !isExpired() else { return nil }

        let succeeded: Bool
        switch self {
        case let .text(text):
            succeeded = pasteboard.setString(text, forType: .string)
        case let .image(png, tiff):
            succeeded = pasteboard.setData(png, forType: .png)
            if succeeded, let tiff {
                guard !isExpired() else { return nil }
                _ = pasteboard.setData(tiff, forType: .tiff)
            }
        case let .files(urls):
            succeeded = pasteboard.writeObjects(urls)
        case let .rich(rich, plain):
            succeeded = pasteboard.writeObjects([rich])
            if succeeded, !plain.isEmpty {
                guard !isExpired() else { return nil }
                _ = pasteboard.setString(plain, forType: .string)
            }
        }

        guard !isExpired() else { return nil }
        let changeCount = pasteboard.changeCount
        guard !isExpired() else { return nil }
        return ClipboardHistoryWriteResult(succeeded: succeeded, changeCount: changeCount)
    }
}
