import XCTest
@testable import VXLib

final class RuntimeProfileTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    // MARK: - No overrides: production behaviour

    func testDefaultsToUserHomeAndStandardDefaults() {
        let profile = RuntimeProfile(environment: [:], home: home)

        XCTAssertTrue(profile.defaults === UserDefaults.standard)
        XCTAssertNil(profile.defaultsSuiteName)
        XCTAssertEqual(profile.configHome, home)
        XCTAssertNil(profile.audioSourceURL)
        XCTAssertFalse(profile.disableUpdateCheck)
        XCTAssertNil(profile.eventLogURL)
        XCTAssertNil(profile.testControlSocketPath)
        XCTAssertFalse(profile.isHermetic)
    }

    func testDerivedPathsMatchTheLegacyLayout() {
        let profile = RuntimeProfile(environment: [:], home: home)

        XCTAssertEqual(profile.vxDirectory.path, "/Users/tester/.vx")
        XCTAssertEqual(profile.rulesDirectory.path, "/Users/tester/.vx/rules")
        XCTAssertEqual(profile.promptsDirectory.path, "/Users/tester/.vx/prompts")
        XCTAssertEqual(profile.appContextsFileURL.path, "/Users/tester/.vx/app-contexts.yaml")
        XCTAssertEqual(profile.logFileURL.path, "/Users/tester/Library/Logs/vx-debug.log")
        XCTAssertEqual(profile.userModelsDirectory.path, "/Users/tester/Library/Application Support/vx/Models")
    }

    /// The real profile must resolve to the same paths the app used before RuntimeProfile
    /// existed, so a normal launch touches exactly the files it always did.
    func testCurrentProfileMatchesFileManagerHomeWhenNotHermetic() throws {
        let profile = RuntimeProfile.current
        try XCTSkipIf(profile.isHermetic, "Test process has VX_* overrides set")
        XCTAssertEqual(profile.configHome, FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: - Individual overrides

    func testDefaultsSuiteOverride() {
        let suite = "vx.tests.\(UUID().uuidString)"
        defer { TestDefaults.destroy(suite) }

        let profile = RuntimeProfile(environment: ["VX_DEFAULTS_SUITE": suite], home: home)

        XCTAssertEqual(profile.defaultsSuiteName, suite)
        XCTAssertFalse(profile.defaults === UserDefaults.standard)
        XCTAssertTrue(profile.isHermetic)
    }

    func testConfigHomeOverrideRedirectsEveryPath() {
        let profile = RuntimeProfile(environment: ["VX_CONFIG_HOME": "/tmp/vx-scratch"], home: home)

        XCTAssertEqual(profile.configHome.path, "/tmp/vx-scratch")
        XCTAssertEqual(profile.rulesDirectory.path, "/tmp/vx-scratch/.vx/rules")
        XCTAssertEqual(profile.promptsDirectory.path, "/tmp/vx-scratch/.vx/prompts")
        XCTAssertEqual(profile.appContextsFileURL.path, "/tmp/vx-scratch/.vx/app-contexts.yaml")
        XCTAssertEqual(profile.logFileURL.path, "/tmp/vx-scratch/Library/Logs/vx-debug.log")
        XCTAssertEqual(profile.userModelsDirectory.path, "/tmp/vx-scratch/Library/Application Support/vx/Models")
        XCTAssertTrue(profile.isHermetic)
    }

    func testRelativeConfigHomeIsMadeAbsolute() {
        let profile = RuntimeProfile(environment: ["VX_CONFIG_HOME": "scratch/vx"], home: home)

        XCTAssertTrue(profile.configHome.path.hasPrefix("/"), "Got \(profile.configHome.path)")
        XCTAssertTrue(profile.configHome.path.hasSuffix("scratch/vx"), "Got \(profile.configHome.path)")
    }

    func testTildeInConfigHomeIsExpanded() {
        let profile = RuntimeProfile(environment: ["VX_CONFIG_HOME": "~/vx-scratch"], home: home)

        XCTAssertFalse(profile.configHome.path.contains("~"))
        XCTAssertTrue(profile.configHome.path.hasSuffix("/vx-scratch"))
    }

    func testAudioSourceOverride() {
        let profile = RuntimeProfile(environment: ["VX_AUDIO_SOURCE": "/tmp/sample.wav"], home: home)

        XCTAssertEqual(profile.audioSourceURL?.path, "/tmp/sample.wav")
        XCTAssertTrue(profile.isHermetic)
    }

    func testDisableUpdateCheckOnlyAcceptsOne() {
        XCTAssertTrue(RuntimeProfile(environment: ["VX_DISABLE_UPDATE_CHECK": "1"], home: home).disableUpdateCheck)
        XCTAssertFalse(RuntimeProfile(environment: ["VX_DISABLE_UPDATE_CHECK": "0"], home: home).disableUpdateCheck)
        XCTAssertFalse(RuntimeProfile(environment: ["VX_DISABLE_UPDATE_CHECK": "true"], home: home).disableUpdateCheck)
    }

    func testEventLogOverride() {
        let profile = RuntimeProfile(environment: ["VX_EVENT_LOG": "/tmp/vx/events.jsonl"], home: home)

        XCTAssertEqual(profile.eventLogURL?.path, "/tmp/vx/events.jsonl")
        XCTAssertTrue(profile.isHermetic)
    }

    func testTestControlOverride() {
        let profile = RuntimeProfile(environment: ["VX_TEST_CONTROL": "/tmp/vx.sock"], home: home)

        XCTAssertEqual(profile.testControlSocketPath, "/tmp/vx.sock")
        XCTAssertTrue(profile.isHermetic)
    }

    func testBlankOverridesAreIgnored() {
        let profile = RuntimeProfile(
            environment: ["VX_CONFIG_HOME": "   ", "VX_EVENT_LOG": "", "VX_TEST_CONTROL": " "],
            home: home
        )

        XCTAssertEqual(profile.configHome, home)
        XCTAssertNil(profile.eventLogURL)
        XCTAssertNil(profile.testControlSocketPath)
        XCTAssertFalse(profile.isHermetic)
    }

    func testSummaryListsActiveOverrides() {
        let profile = RuntimeProfile(
            environment: [
                "VX_CONFIG_HOME": "/tmp/vx-scratch",
                "VX_DEFAULTS_SUITE": "vx.p4",
                "VX_DISABLE_UPDATE_CHECK": "1",
            ],
            home: home
        )

        let summary = profile.summary
        XCTAssertTrue(summary.contains("defaults=vx.p4"), summary)
        XCTAssertTrue(summary.contains("configHome=/tmp/vx-scratch"), summary)
        XCTAssertTrue(summary.contains("updateCheck=disabled"), summary)
        XCTAssertFalse(summary.contains("eventLog="), summary)
    }
}
