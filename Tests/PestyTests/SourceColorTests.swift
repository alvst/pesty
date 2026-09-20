import AppKit
import SwiftUI
import XCTest
@testable import Pesty

@MainActor
final class SourceColorTests: XCTestCase {
    func testMonochromeIconsProduceAdaptiveNeutralHeaders() throws {
        let mostlyDark = try XCTUnwrap(SourceColor.dominantColor(
            in: monochromeIcon(whiteFraction: 0.15)
        ))
        let mostlyWhite = try XCTUnwrap(SourceColor.dominantColor(
            in: monochromeIcon(whiteFraction: 0.85)
        ))
        let dark = Contrast.components(mostlyDark)
        let light = Contrast.components(mostlyWhite)

        XCTAssertEqual(dark.red, dark.green, accuracy: 0.01)
        XCTAssertEqual(dark.green, dark.blue, accuracy: 0.01)
        XCTAssertEqual(light.red, light.green, accuracy: 0.01)
        XCTAssertEqual(light.green, light.blue, accuracy: 0.01)
        XCTAssertLessThan(dark.red, light.red)
        XCTAssertGreaterThanOrEqual(
            Contrast.ratio(.white, SourceColor.readableHeaderColor(mostlyWhite)),
            Contrast.aaText
        )
    }

    func testDefaultEnhancementDoesNotTintANeutralColor() {
        let color = Contrast.components(SourceColor.vibrantColor(from: Color(white: 0.35)))

        XCTAssertEqual(color.red, color.green, accuracy: 0.01)
        XCTAssertEqual(color.green, color.blue, accuracy: 0.01)
    }

    func testSubtlyNavyInkOnAWhiteIconStillCountsAsNeutral() throws {
        let icon = monochromeIcon(
            whiteFraction: 0.87,
            darkColor: NSColor(red: 0.21, green: 0.22, blue: 0.28, alpha: 1)
        )
        let color = Contrast.components(try XCTUnwrap(SourceColor.dominantColor(in: icon)))

        XCTAssertEqual(color.red, color.green, accuracy: 0.01)
        XCTAssertEqual(color.green, color.blue, accuracy: 0.01)
    }

    private func monochromeIcon(
        whiteFraction: CGFloat,
        darkColor: NSColor = .black
    ) -> NSImage {
        let size = NSSize(width: 40, height: 40)
        let image = NSImage(size: size)
        image.lockFocus()
        darkColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size.width * whiteFraction, height: size.height).fill()
        image.unlockFocus()
        return image
    }
}
