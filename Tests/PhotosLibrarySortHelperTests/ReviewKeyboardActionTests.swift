import SwiftUI
import XCTest
@testable import PhotosLibrarySortHelper

final class ReviewKeyboardActionTests: XCTestCase {
    func testArrowKeysMapToReviewActions() {
        XCTAssertEqual(
            ReviewKeyboardAction.resolve(keyCode: 123, charactersIgnoringModifiers: "", modifiers: [.numericPad]),
            .previousGroup
        )
        XCTAssertEqual(
            ReviewKeyboardAction.resolve(keyCode: 124, charactersIgnoringModifiers: "", modifiers: [.numericPad]),
            .nextGroup
        )
        XCTAssertEqual(
            ReviewKeyboardAction.resolve(keyCode: 126, charactersIgnoringModifiers: "", modifiers: [.numericPad]),
            .previousItem
        )
        XCTAssertEqual(
            ReviewKeyboardAction.resolve(keyCode: 125, charactersIgnoringModifiers: "", modifiers: [.numericPad]),
            .nextItem
        )
    }

    func testCharacterShortcutsMapToReviewActions() {
        XCTAssertEqual(
            ReviewKeyboardAction.resolve(keyCode: 14, charactersIgnoringModifiers: "e", modifiers: []),
            .queueForEdit
        )
        XCTAssertEqual(
            ReviewKeyboardAction.resolve(keyCode: 50, charactersIgnoringModifiers: "`", modifiers: []),
            .toggleKeepDiscard
        )
        XCTAssertEqual(
            ReviewKeyboardAction.resolve(keyCode: 14, charactersIgnoringModifiers: "E", modifiers: [.capsLock]),
            .queueForEdit
        )
    }

    func testCommandModifiedKeysAreIgnoredForReviewPaneBindings() {
        XCTAssertNil(
            ReviewKeyboardAction.resolve(keyCode: 123, charactersIgnoringModifiers: "", modifiers: [.command, .numericPad])
        )
        XCTAssertNil(
            ReviewKeyboardAction.resolve(keyCode: 14, charactersIgnoringModifiers: "e", modifiers: [.command])
        )
        XCTAssertNil(
            ReviewKeyboardAction.resolve(keyCode: 50, charactersIgnoringModifiers: "`", modifiers: [.shift])
        )
    }
}
