import Foundation

/// Text Inserter seam: puts text into the frontmost app. Pasteboard + Cmd-V adapter in
/// production, recording fake in tests.
protocol TextInserting {
    func insert(_ text: String, submitBehavior: TextSubmitBehavior) throws
    func submit(behavior: TextSubmitBehavior)
}

/// Production adapter — forwards to the `TextInserter` statics.
struct PasteboardTextInserter: TextInserting {
    func insert(_ text: String, submitBehavior: TextSubmitBehavior) throws {
        try TextInserter.insert(text, submitBehavior: submitBehavior)
    }

    func submit(behavior: TextSubmitBehavior) {
        TextInserter.submit(behavior: behavior)
    }
}
