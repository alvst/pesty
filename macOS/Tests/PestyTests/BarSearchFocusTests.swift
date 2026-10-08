import AppKit
import SwiftUI
import XCTest
@testable import Pesty

@MainActor
final class BarSearchFocusTests: XCTestCase {
    func testCollapsedSearchDoesNotTakeInitialKeyboardFocus() {
        let (panel, bridge) = makeBar()
        defer { panel.orderOut(nil) }

        panel.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertNotNil(bridge.field)
        XCTAssertFalse(bridge.field?.acceptsFirstResponder ?? true,
                       "Collapsed search must be excluded from AppKit's automatic focus selection.")
        XCTAssertFalse(bridge.ownsFirstResponder(in: panel),
                       "The invisible search field must not consume the first arrow key.")
    }

    func testExplicitSearchFocusWorksBeforeSwiftUIExpandsField() throws {
        let (panel, bridge) = makeBar()
        defer { panel.orderOut(nil) }
        panel.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(bridge.focusAtEnd())
        XCTAssertTrue(bridge.ownsFirstResponder(in: panel))
        let editor = try XCTUnwrap(bridge.field?.currentEditor() as? NSTextView)
        editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(editor.string, "x", "Type-to-search must retain its first character.")
    }

    func testReopeningClearsPreviousSearchFocusBeforeSwiftUIUpdates() {
        let (panel, bridge) = makeBar(isExpanded: true)
        defer { panel.orderOut(nil) }
        panel.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        for _ in 0..<5 {
            XCTAssertTrue(bridge.focusAtEnd())
            XCTAssertTrue(bridge.ownsFirstResponder(in: panel))
            panel.orderOut(nil)

            bridge.resetForPresentation()
            panel.makeKeyAndOrderFront(nil)
            XCTAssertFalse(bridge.field?.acceptsFirstResponder ?? true)
            XCTAssertFalse(bridge.ownsFirstResponder(in: panel))
        }
    }

    func testResetDoesNotStealFocusFromAnotherControl() {
        let (panel, bridge) = makeBar()
        defer { panel.orderOut(nil) }
        panel.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let otherField = NSTextField(string: "Pinboard name")
        panel.contentView?.addSubview(otherField)
        XCTAssertTrue(panel.makeFirstResponder(otherField))
        let editor = otherField.currentEditor()
        XCTAssertNotNil(editor)
        bridge.resetForPresentation()
        XCTAssertTrue(panel.firstResponder === editor,
                      "Resetting search must not resign a different control's editor.")
    }

    private func makeBar(isExpanded: Bool = false) -> (BarPanel, BarSearchFieldBridge) {
        _ = NSApplication.shared
        let bridge = BarSearchFieldBridge()
        let root = NativeBarSearchField(
            text: .constant(""), bridge: bridge,
            onBegin: {}, onEnd: {}, onSubmit: {}, onCancel: {}
        )
        .frame(width: isExpanded ? 180 : 0, height: 30)
        .opacity(isExpanded ? 1 : 0)
        let panel = BarPanel(contentRect: NSRect(x: 100, y: 100, width: 400, height: 100),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        let content = NSHostingView(rootView: root)
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        panel.contentView = container
        return (panel, bridge)
    }
}
