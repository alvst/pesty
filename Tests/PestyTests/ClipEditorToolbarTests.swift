import AppKit
import XCTest
@testable import Pesty

@MainActor
final class ClipEditorToolbarTests: XCTestCase {
    private let symbols = ["bold", "italic", "underline", "strikethrough", "pencil.and.scribble"]

    func testAllToolbarIconsUseNativeContrastInEveryAppearance() throws {
        for appearanceName: NSAppearance.Name in [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
        ] {
            for symbol in symbols {
                let button = ClipEditorToolbar.button(symbol: symbol, label: symbol, tooltip: symbol,
                                                      target: nil, action: nil)
                button.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                XCTAssertTrue(try XCTUnwrap(button.image, symbol).isTemplate)
                XCTAssertNil(button.bezelColor)
                XCTAssertNil(button.contentTintColor)
                XCTAssertEqual(button.attributedTitle.length, 0)
                XCTAssertEqual(button.imagePosition, .imageOnly)
            }
        }
    }

    func testShortcutsAndAccessibleNamesArePreserved() {
        for (symbol, label, key) in [("bold", "Bold", "b"), ("italic", "Italic", "i"),
                                      ("underline", "Underline", "u")] {
            let button = ClipEditorToolbar.button(symbol: symbol, label: label, tooltip: label,
                                                  target: nil, action: nil, key: key, toggles: true)
            XCTAssertEqual(button.keyEquivalent, key)
            XCTAssertEqual(button.keyEquivalentModifierMask, .command)
            XCTAssertEqual(button.accessibilityLabel(), label)
            button.performClick(nil)
            XCTAssertEqual(button.state, .on)
            button.performClick(nil)
            XCTAssertEqual(button.state, .off)
        }
    }

    func testToggleStatesDoNotIntroduceCustomInkOrBezelColors() throws {
        let button = ClipEditorToolbar.button(symbol: "bold", label: "Bold", tooltip: "Bold",
                                              target: nil, action: nil, toggles: true)
        button.allowsMixedState = true
        for state: NSControl.StateValue in [.off, .on, .mixed] {
            button.state = state
            XCTAssertTrue(try XCTUnwrap(button.image).isTemplate)
            XCTAssertNil(button.contentTintColor)
            XCTAssertNil(button.bezelColor)
        }
    }

    /// Set PESTY_TOOLBAR_SNAPSHOTS to export the off/on/mixed rows for visual QA.
    /// Rendering is offscreen and never opens or alters a user's editor.
    func testNativeToolbarRendersInLightAndDarkAppearances() throws {
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let canvas = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
            canvas.appearance = appearance
            canvas.material = .sheet
            canvas.blendingMode = .withinWindow
            canvas.state = .active
            let snapshot = NSImage(size: canvas.frame.size)
            appearance.performAsCurrentDrawingAppearance {
                snapshot.lockFocus()
                defer { snapshot.unlockFocus() }
                NSColor.windowBackgroundColor.setFill()
                canvas.bounds.fill()
                for (row, state) in [NSControl.StateValue.off, .on, .mixed].enumerated() {
                    for (column, symbol) in symbols.enumerated() {
                        let button = ClipEditorToolbar.button(
                            symbol: symbol, label: symbol, tooltip: symbol,
                            target: nil, action: nil, toggles: true)
                        button.appearance = appearance
                        button.allowsMixedState = true
                        button.state = state
                        button.frame = NSRect(x: 20 + column * 52, y: 108 - row * 44,
                                              width: 38, height: 32)
                        canvas.addSubview(button)
                        NSGraphicsContext.saveGraphicsState()
                        let transform = NSAffineTransform()
                        transform.translateX(by: button.frame.minX,
                                             yBy: button.isFlipped ? button.frame.maxY : button.frame.minY)
                        if button.isFlipped { transform.scaleX(by: 1, yBy: -1) }
                        transform.concat()
                        button.cell?.draw(withFrame: button.bounds, in: button)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                }
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(snapshot.tiffRepresentation)))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertFalse(png.isEmpty)
            if let output = ProcessInfo.processInfo.environment["PESTY_TOOLBAR_SNAPSHOTS"] {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("toolbar-\(name).png"))
            }
        }
    }
}
