import XCTest
@testable import VXLib

final class DictationTriggerTests: XCTestCase {
    private let doubleTapWindow: TimeInterval = 0.05

    private func makeTrigger(
        mode: ActivationMode = .holdToTalk,
        onBegin: @escaping () -> Void = {},
        onFinish: @escaping () -> Void = {},
        onToggle: @escaping () -> Void = {},
        onLatch: @escaping () -> Void = {}
    ) -> DictationTrigger {
        DictationTrigger(
            doubleTapWindow: doubleTapWindow,
            mode: { mode },
            onBegin: onBegin,
            onFinish: onFinish,
            onToggle: onToggle,
            onLatch: onLatch
        )
    }

    func testLongPressFinishesImmediatelyOnRelease() {
        let began = expectation(description: "began")
        let finished = expectation(description: "finished")
        var events: [String] = []
        let trigger = makeTrigger(
            onBegin: {
                events.append("begin")
                began.fulfill()
            },
            onFinish: {
                events.append("finish")
                finished.fulfill()
            }
        )

        trigger.press()
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow * 2) {
            trigger.release()
        }

        wait(for: [began, finished], timeout: 1)
        XCTAssertEqual(events, ["begin", "finish"])
    }

    func testShortPressFinishesAfterDoubleTapWindow() {
        let began = expectation(description: "began")
        let finished = expectation(description: "finished")
        var events: [String] = []
        let trigger = makeTrigger(
            onBegin: {
                events.append("begin")
                began.fulfill()
            },
            onFinish: {
                events.append("finish")
                finished.fulfill()
            }
        )

        trigger.press()
        trigger.release()

        wait(for: [began, finished], timeout: 1)
        XCTAssertEqual(events, ["begin", "finish"])
    }

    func testSecondShortPressLatchesWithoutFinishing() {
        let began = expectation(description: "began")
        let latched = expectation(description: "latched")
        let finished = expectation(description: "finished")
        finished.isInverted = true
        var beginCount = 0
        let trigger = makeTrigger(
            onBegin: {
                beginCount += 1
                began.fulfill()
            },
            onFinish: {
                finished.fulfill()
            },
            onLatch: {
                latched.fulfill()
            }
        )

        trigger.press()
        trigger.release()
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow / 2) {
            trigger.press()
            trigger.release()
        }

        wait(for: [began, latched, finished], timeout: doubleTapWindow * 3)
        XCTAssertEqual(beginCount, 1)
    }

    func testPressWhileLatchedFinishesAndReleaseDoesNothing() {
        let began = expectation(description: "began")
        let latched = expectation(description: "latched")
        let finished = expectation(description: "finished")
        finished.expectedFulfillmentCount = 1
        var finishCount = 0
        let trigger = makeTrigger(
            onBegin: {
                began.fulfill()
            },
            onFinish: {
                finishCount += 1
                finished.fulfill()
            },
            onLatch: {
                latched.fulfill()
            }
        )

        trigger.press()
        trigger.release()
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow / 2) {
            trigger.press()
            trigger.release()
            trigger.press()
            trigger.release()
        }

        wait(for: [began, latched, finished], timeout: 1)
        XCTAssertEqual(finishCount, 1)
    }

    func testToggleModeOnlyTogglesOnPress() {
        let toggled = expectation(description: "toggled")
        var beginCount = 0
        var finishCount = 0
        let trigger = makeTrigger(
            mode: .toggle,
            onBegin: { beginCount += 1 },
            onFinish: { finishCount += 1 },
            onToggle: {
                toggled.fulfill()
            }
        )

        trigger.press()
        trigger.release()

        wait(for: [toggled], timeout: 1)
        XCTAssertEqual(beginCount, 0)
        XCTAssertEqual(finishCount, 0)
    }

    func testClearLatchLetsTheNextPressStartRecordingAgain() {
        // Escape and the HUD's cancel button end the recording without going through the
        // trigger. Unless the latch is cleared, the next press is spent turning it off and
        // the user has to press twice to start recording again.
        let beganTwice = expectation(description: "began twice")
        var beginCount = 0
        var finishCount = 0
        let trigger = makeTrigger(
            onBegin: {
                beginCount += 1
                if beginCount == 2 { beganTwice.fulfill() }
            },
            onFinish: { finishCount += 1 }
        )

        trigger.press()
        trigger.release()
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow / 2) {
            trigger.press()          // latches
            trigger.release()
            trigger.clearLatch()     // stands in for Escape cancelling the recording
            trigger.press()          // must begin, not be eaten as a stop
        }

        wait(for: [beganTwice], timeout: 1)
        XCTAssertEqual(finishCount, 0, "clearLatch must not end anything itself")
    }

    func testResetWhileAShortPressIsStillWaitingToStopFinishesIt() {
        // The press began a recording and the stop is deferred waiting on a possible second
        // press. Resetting drops that deferred stop, so it has to finish the recording itself
        // or nothing ever will.
        let finished = expectation(description: "finished")
        let trigger = makeTrigger(onFinish: { finished.fulfill() })

        trigger.press()
        trigger.release()
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow / 2) {
            trigger.reset()
        }

        wait(for: [finished], timeout: 1)
    }

    func testResetWhileTheButtonIsStillHeldFinishesTheRecording() {
        let finished = expectation(description: "finished")
        let trigger = makeTrigger(onFinish: { finished.fulfill() })

        trigger.press()
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow / 2) {
            trigger.reset()
        }

        wait(for: [finished], timeout: 1)
    }

    func testResetWhileLatchedFinishesAndClearsLatch() {
        let latched = expectation(description: "latched")
        let finished = expectation(description: "finished")
        let beganAgain = expectation(description: "began again")
        var beginCount = 0
        let trigger = makeTrigger(
            onBegin: {
                beginCount += 1
                if beginCount == 2 { beganAgain.fulfill() }
            },
            onFinish: {
                finished.fulfill()
            },
            onLatch: {
                latched.fulfill()
            }
        )

        trigger.press()
        trigger.release()
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow / 2) {
            trigger.press()
            trigger.release()
            trigger.reset()
            trigger.press()
        }

        wait(for: [latched, finished, beganAgain], timeout: 1)
    }
}
