import XCTest
@testable import VXLib

final class AppStateDefaultsTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            TestDefaults.destroy(name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeSuite() throws -> UserDefaults {
        let suite = TestDefaults.makeSuite()
        suiteNames.append(suite.name)
        return suite.defaults
    }

    func testSettingsDoNotLeakBetweenSuites() throws {
        let suiteA = try makeSuite()
        let suiteB = try makeSuite()

        let stateA = AppState(defaults: suiteA)
        stateA.isDebugMode = true
        stateA.selectedInputDeviceUID = "device-a"

        let stateB = AppState(defaults: suiteB)
        XCTAssertFalse(stateB.isDebugMode, "Suite B must not see suite A's debug flag")
        XCTAssertNil(stateB.selectedInputDeviceUID)

        // Reloading suite A sees its own writes.
        let reloadedA = AppState(defaults: suiteA)
        XCTAssertTrue(reloadedA.isDebugMode)
        XCTAssertEqual(reloadedA.selectedInputDeviceUID, "device-a")

        // And nothing landed in the real user defaults.
        XCTAssertNil(UserDefaults.standard.string(forKey: "vx.input-device-uid"))
    }

    func testTranscriptionHistoryRoundTripsThroughItsSuite() throws {
        let suite = try makeSuite()
        let history = TranscriptionHistory(defaults: suite)
        history.append("first")
        history.append("second")

        XCTAssertEqual(history.entries.map(\.text), ["second", "first"], "Newest entry first")

        let reloaded = TranscriptionHistory(defaults: suite)
        XCTAssertEqual(reloaded.entries.map(\.text), ["second", "first"])
    }

    func testClearOnlyRemovesItsOwnSuiteKey() throws {
        let suiteA = try makeSuite()
        let suiteB = try makeSuite()

        let historyA = TranscriptionHistory(defaults: suiteA)
        let historyB = TranscriptionHistory(defaults: suiteB)
        historyA.append("alpha")
        historyB.append("beta")

        historyA.clear()

        XCTAssertTrue(historyA.entries.isEmpty)
        XCTAssertNil(suiteA.data(forKey: "vx.transcription-history"))
        XCTAssertEqual(historyB.entries.map(\.text), ["beta"])
        XCTAssertNotNil(suiteB.data(forKey: "vx.transcription-history"))
    }
}
