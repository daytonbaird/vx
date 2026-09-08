import Foundation

/// Flow Event: machine-readable lifecycle record emitted by a Dictation Flow. Consumed by
/// XCTest assertions and by the JSONL event log.
enum DictationFlowEvent: Equatable, Codable {
    case captureWillStart(goMode: Bool)
    case recordingStarted
    case recordingWillStop
    case transcribing
    case transcriptReceived(String)
    case processed(mode: String, profile: String, detectedContext: String?, ruleCount: Int, transformed: Bool)
    case textInserted(String, behavior: String)
    case submittedWithoutText(behavior: String)
    case noSpeech
    case cancelled
    case failed(String)
    case goModeStarted
    case goModeStopped(cancelled: Bool)
    case audioSourceDrained

    /// The bare case name, for log lines.
    var name: String {
        switch self {
        case .captureWillStart: return "captureWillStart"
        case .recordingStarted: return "recordingStarted"
        case .recordingWillStop: return "recordingWillStop"
        case .transcribing: return "transcribing"
        case .transcriptReceived: return "transcriptReceived"
        case .processed: return "processed"
        case .textInserted: return "textInserted"
        case .submittedWithoutText: return "submittedWithoutText"
        case .noSpeech: return "noSpeech"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        case .goModeStarted: return "goModeStarted"
        case .goModeStopped: return "goModeStopped"
        case .audioSourceDrained: return "audioSourceDrained"
        }
    }
}
