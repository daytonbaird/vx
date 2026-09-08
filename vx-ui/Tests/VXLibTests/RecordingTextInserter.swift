import Foundation
@testable import VXLib

/// Test double for the Text Inserter seam: records what the flow tried to type instead of
/// touching the pasteboard or posting CGEvents.
final class RecordingTextInserter: TextInserting {
    private(set) var insertions: [(text: String, behavior: TextSubmitBehavior)] = []
    private(set) var submits: [TextSubmitBehavior] = []

    /// When set, `insert` throws this instead of recording — exercises the failure path.
    var insertError: Error?

    func insert(_ text: String, submitBehavior: TextSubmitBehavior) throws {
        if let insertError { throw insertError }
        insertions.append((text: text, behavior: submitBehavior))
    }

    func submit(behavior: TextSubmitBehavior) {
        submits.append(behavior)
    }
}
