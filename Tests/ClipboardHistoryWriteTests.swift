// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

struct ClipboardHistoryWriteTests {
    static func run(expect: (Bool, String) -> Void) {
        let png = Data([1, 2, 3])
        let tiff = Data([4, 5, 6])
        let rich = NSAttributedString(string: "saved rich text")
        let writes: [(String, ClipboardHistoryWrite, String)] = [
            ("text", .text("saved text"), "string"),
            ("files", .files([NSURL(fileURLWithPath: "/tmp/saved-file")]), "objects"),
            ("rich", .rich(rich, plain: "fallback"), "objects"),
            ("PNG", .image(png: png, tiff: tiff), "png"),
        ]
        for (name, write, requiredOperation) in writes {
            let pasteboard = FakeHistoryPasteboard()
            pasteboard.rejectedOperations = [requiredOperation]
            let result = write.write(to: pasteboard, isExpired: { false })
            expect(result?.succeeded == false, "failed \(name) write reports failure")
            expect(result?.changeCount == 12, "failed \(name) preserves final change count")
            expect(pasteboard.operations == ["clear", requiredOperation, "count"],
                   "failed \(name) skips optional representations")
        }

        for (name, write, optionalOperation) in [
            ("PNG", ClipboardHistoryWrite.image(png: png, tiff: tiff), "tiff"),
            ("rich", ClipboardHistoryWrite.rich(rich, plain: "fallback"), "string"),
        ] {
            let pasteboard = FakeHistoryPasteboard()
            pasteboard.rejectedOperations = [optionalOperation]
            let result = write.write(to: pasteboard, isExpired: { false })
            expect(result?.succeeded == true,
                   "successful \(name) remains successful if optional representation fails")
            expect(pasteboard.operations.contains(optionalOperation),
                   "successful \(name) attempts optional representation")
            expect(result?.changeCount == 13, "\(name) returns count after optional write")
        }

        for (name, write, _) in writes {
            let pasteboard = FakeHistoryPasteboard()
            let result = write.write(to: pasteboard, isExpired: { false })
            expect(result?.succeeded == true, "successful \(name) reports success")
        }

        // Expire at each boundary, including after a call that mutates the
        // clipboard. No later optional write or count read may then run.
        for write in [ClipboardHistoryWrite.image(png: png, tiff: tiff),
                      ClipboardHistoryWrite.rich(rich, plain: "fallback")] {
            for allowedCalls in 0...4 {
                let pasteboard = FakeHistoryPasteboard()
                let result = write.write(to: pasteboard) {
                    pasteboard.operations.count >= allowedCalls
                }
                expect(result == nil, "expired write does not report success after \(allowedCalls) calls")
                expect(pasteboard.operations.count == allowedCalls,
                       "expired write stops pasteboard calls at boundary \(allowedCalls)")
            }
        }

        let textPasteboard = FakeHistoryPasteboard()
        _ = ClipboardHistoryWrite.text("exact saved text").write(to: textPasteboard, isExpired: { false })
        expect(textPasteboard.strings == ["exact saved text"], "text write preserves saved text")
        let imagePasteboard = FakeHistoryPasteboard()
        _ = ClipboardHistoryWrite.image(png: png, tiff: tiff).write(to: imagePasteboard, isExpired: { false })
        expect(imagePasteboard.data == [png, tiff], "image write preserves PNG and TIFF payloads")
    }
}

private final class FakeHistoryPasteboard: ClipboardHistoryPasteboard {
    var operations: [String] = []
    var rejectedOperations: Set<String> = []
    var strings: [String] = []
    var data: [Data] = []
    private var count = 10

    var changeCount: Int {
        operations.append("count")
        return count
    }

    func clearContents() -> Int {
        _ = mutate("clear")
        return count
    }

    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        strings.append(string)
        return mutate("string")
    }

    func setData(_ value: Data?, forType type: NSPasteboard.PasteboardType) -> Bool {
        if let value { data.append(value) }
        return mutate(type == .png ? "png" : "tiff")
    }

    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool {
        mutate("objects")
    }

    private func mutate(_ operation: String) -> Bool {
        operations.append(operation)
        count += 1
        return !rejectedOperations.contains(operation)
    }
}
