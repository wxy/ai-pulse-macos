import XCTest
@testable import AIPulse

final class DashboardNoteInteractionTests: XCTestCase {
    func testHoverOpensWithoutClickAndLeavingCloses() {
        var note = DashboardNoteInteraction()
        note.iconHover(true)
        XCTAssertTrue(note.isPresented)
        note.dismissIfUnattended()
        XCTAssertTrue(note.isPresented)
        note.iconHover(false)
        note.dismissIfUnattended()
        XCTAssertFalse(note.isPresented)
    }

    func testMovingFromIconIntoContentDoesNotDismiss() {
        var note = DashboardNoteInteraction()
        note.iconHover(true)
        note.iconHover(false)
        note.contentHover(true)
        note.dismissIfUnattended()
        XCTAssertTrue(note.isPresented)
        note.contentHover(false)
        note.dismissIfUnattended()
        XCTAssertFalse(note.isPresented)
    }

    func testClickPinsAndResetClearsAllPresentationState() {
        var note = DashboardNoteInteraction()
        note.iconHover(true)
        note.click()
        note.iconHover(false)
        note.dismissIfUnattended()
        XCTAssertTrue(note.isPresented)
        XCTAssertTrue(note.pinned)
        note.reset()
        XCTAssertFalse(note.isPresented)
        XCTAssertFalse(note.pinned)
        XCTAssertFalse(note.iconHovered)
        XCTAssertFalse(note.contentHovered)
    }

    func testReenteringIconCancelsAnUnattendedDismissal() {
        var note = DashboardNoteInteraction()
        note.iconHover(true)
        note.iconHover(false)
        note.iconHover(true)
        note.dismissIfUnattended()
        XCTAssertTrue(note.isPresented)
    }
}
