import Combine
import XCTest
@testable import VXLib

/// `requestedPreferencesTab` is the one-shot channel the test-control `open preferences:<tab>`
/// command uses to reach the Preferences view. It must publish, and it must never persist —
/// a tab request is a message, not a setting.
final class AppStatePreferencesTabTests: XCTestCase {
    private var suiteName: String?
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        if let suiteName { TestDefaults.destroy(suiteName) }
        suiteName = nil
        cancellables.removeAll()
        super.tearDown()
    }

    private func makeState() throws -> AppState {
        let suite = TestDefaults.makeSuite()
        suiteName = suite.name
        return AppState(defaults: suite.defaults)
    }

    func testRequestedPreferencesTabPublishesAndClears() throws {
        let state = try makeState()
        XCTAssertNil(state.requestedPreferencesTab)

        var seen: [String?] = []
        state.$requestedPreferencesTab.sink { seen.append($0) }.store(in: &cancellables)

        state.requestedPreferencesTab = "sound"
        XCTAssertEqual(state.requestedPreferencesTab, "sound")
        state.requestedPreferencesTab = nil
        XCTAssertNil(state.requestedPreferencesTab)

        XCTAssertEqual(seen, [nil, "sound", nil], "Every request must reach subscribers")
    }

    func testRequestedPreferencesTabIsNotPersisted() throws {
        let suite = TestDefaults.makeSuite()
        suiteName = suite.name
        let defaults = suite.defaults

        let state = AppState(defaults: defaults)
        state.requestedPreferencesTab = "developer"

        XCTAssertNil(AppState(defaults: defaults).requestedPreferencesTab)
    }

    func testEveryPreferencesTabIDIsKnown() {
        XCTAssertEqual(
            PreferencesView.allTabIDs,
            ["config", "rules", "ai", "sound", "permissions", "developer"]
        )
    }
}
