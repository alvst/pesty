import AppKit
import XCTest
@testable import Pesty

final class BarOutsideClickShieldTests: XCTestCase {
    @MainActor
    func testDismissalPanelDoesNotTakeAppOrKeyboardFocus() {
        let panel = BarDismissalPanel(frame: NSRect(x: 0, y: 0, width: 100, height: 100)) {}
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.level, .normal)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isAccessibilityElement())
        XCTAssertGreaterThan(panel.backgroundColor.alphaComponent, 0)
        XCTAssertLessThanOrEqual(panel.backgroundColor.alphaComponent, 0.001)
    }

    @MainActor
    func testDismissalViewAcceptsTheFirstClickWithoutBecomingKey() {
        let view = BarDismissalView {}
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertFalse(view.needsPanelToBecomeKey)
        XCTAssertFalse(view.acceptsFirstResponder)
    }

    @MainActor
    func testEveryMouseButtonDismissesOnlyOnce() throws {
        for type: NSEvent.EventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            var dismissals = 0
            let view = BarDismissalView { dismissals += 1 }
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            for _ in 0..<2 {
                switch type {
                case .leftMouseDown: view.mouseDown(with: event)
                case .rightMouseDown: view.rightMouseDown(with: event)
                default: view.otherMouseDown(with: event)
                }
            }
            XCTAssertEqual(dismissals, 1)
        }
    }
}
