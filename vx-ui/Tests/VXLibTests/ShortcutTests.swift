import Carbon
import XCTest
@testable import VXLib

final class ShortcutTests: XCTestCase {
    func testSerializeDeserializeRoundTripsEveryShortcutKind() {
        let shortcuts: [Shortcut] = [
            .combo(keyCode: CGKeyCode(kVK_ANSI_Z), modifiers: [.maskCommand, .maskShift]),
            Shortcut(keyCode: CGKeyCode(kVK_Function), modifiers: []),
            .doubleTap(.rightOption),
            .modifier(.leftControl),
            .mouseButton(3),
        ]

        for shortcut in shortcuts {
            XCTAssertEqual(Shortcut.deserialize(shortcut.serialize()), shortcut)
        }
    }

    func testDeserializeAcceptsLegacyHoldPrefix() {
        XCTAssertEqual(Shortcut.deserialize("hold:rightOption"), .modifier(.rightOption))
    }

    func testMouseButtonsUseHumanButtonNumbersForDisplay() {
        XCTAssertEqual(Shortcut.mouseButton(3).displayName, "Mouse 4")
        XCTAssertEqual(Shortcut.mouseButton(4).displayName, "Mouse 5")
    }

    func testFnKeycodesNormaliseToTheFunctionKey() {
        let expected = Shortcut(keyCode: CGKeyCode(kVK_Function), modifiers: [])

        XCTAssertEqual(Shortcut(keyCode: 179, modifiers: []), expected)
        XCTAssertEqual(Shortcut(keyCode: 193, modifiers: []), expected)
        XCTAssertEqual(Shortcut(keyCode: CGKeyCode(kVK_Function), modifiers: []), expected)
        XCTAssertEqual(expected.displayName, "fn")
    }

    func testDeserializeRejectsMouseButtonsBelowTheBindableFloor() {
        XCTAssertNil(Shortcut.deserialize("mouse:0"))
        XCTAssertNil(Shortcut.deserialize("mouse:2"))
        XCTAssertEqual(Shortcut.deserialize("mouse:3"), .mouseButton(3))
    }

    func testEveryKeycodeHasANonEmptyDisplayName() {
        for keyCode in 0...255 {
            XCTAssertFalse(
                Shortcut(keyCode: CGKeyCode(keyCode), modifiers: []).displayName.isEmpty,
                "Keycode \(keyCode) must have a display name"
            )
        }
    }
}
