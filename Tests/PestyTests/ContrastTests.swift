import SwiftUI
import XCTest
@testable import Pesty

final class ContrastTests: XCTestCase {

    // MARK: - The math itself

    func testRatioMatchesKnownWCAGValues() {
        XCTAssertEqual(Contrast.ratio(.black, .white), 21, accuracy: 0.01)
        XCTAssertEqual(Contrast.ratio(.white, .white), 1, accuracy: 0.001)
        // The canonical worked example from the WCAG 2.1 techniques: #808080
        // on white is 3.95:1.
        let midGray = Color(.sRGB, red: 0.5019, green: 0.5019, blue: 0.5019, opacity: 1)
        XCTAssertEqual(Contrast.ratio(midGray, .white), 3.95, accuracy: 0.02)
    }

    func testCompositeFlattensAlphaOntoTheBackdrop() {
        let half = Contrast.composite(Color.white.opacity(0.5), over: .black)
        let c = Contrast.components(half)
        XCTAssertEqual(c.red, 0.5, accuracy: 0.001)
        XCTAssertEqual(c.alpha, 1, accuracy: 0.001)
    }

    func testForegroundPicksTheInkThatActuallyReadsBetter() {
        XCTAssertEqual(Contrast.foreground(on: .black), Contrast.lightInk)
        XCTAssertEqual(Contrast.foreground(on: .white), Contrast.darkInk)
    }

    func testMutedRaisesOpacityRatherThanReturningAnIllegibleInk() {
        // 20% white on near-white cannot possibly reach AA, so `muted` must
        // hand back something stronger than what was asked for.
        let surface = Color(white: 0.95)
        let result = Contrast.muted(Contrast.darkInk, opacity: 0.2, on: surface, over: .white)
        XCTAssertGreaterThanOrEqual(
            Contrast.ratio(Contrast.composite(result, over: surface), surface),
            Contrast.aaText
        )
    }

    // MARK: - The palettes this app actually ships

    /// Every fill in both chrome palettes has to be able to carry text.
    func testEveryChromeFillClearsAAWithItsPalettesInk() {
        for (name, palette) in [("dark", Theme.darkChrome), ("light", Theme.lightChrome)] {
            let fills: [(String, Color)] = [
                ("panel", .clear),
                ("fieldBG", palette.fieldBG),
                ("pillBG", palette.pillBG),
                ("pillSelected", palette.pillSelected)
            ]
            for (label, fill) in fills {
                let ratio = Contrast.ratio(palette.ink, on: fill, over: palette.surface)
                XCTAssertGreaterThanOrEqual(
                    ratio, Contrast.aaText,
                    "\(name) palette: ink on \(label) is \(String(format: "%.2f", ratio)):1"
                )
            }
        }
    }

    /// The bug in the report: white pill labels over a light desktop. The
    /// chosen ink has to clear AA on the fill it is actually painted on, in
    /// both appearances and in both selection states.
    func testPillLabelsClearAAInBothAppearances() {
        for (name, palette) in [("dark", Theme.darkChrome), ("light", Theme.lightChrome)] {
            let selectedInk = Contrast.foreground(on: palette.pillSelected, over: palette.surface)
            let selected = Contrast.ratio(selectedInk, on: palette.pillSelected, over: palette.surface)
            XCTAssertGreaterThanOrEqual(selected, Contrast.aaText,
                                        "\(name) palette: selected pill is \(selected):1")

            let mutedInk = Contrast.muted(
                Contrast.foreground(on: palette.pillBG, over: palette.surface),
                opacity: 0.74, on: palette.pillBG, over: palette.surface)
            let unselected = Contrast.ratio(mutedInk, on: palette.pillBG, over: palette.surface)
            XCTAssertGreaterThanOrEqual(unselected, Contrast.aaText,
                                        "\(name) palette: unselected pill is \(unselected):1")
        }
    }

    func testSearchFocusRingClearsNonTextAAInBothAppearances() {
        for (name, palette) in [("dark", Theme.darkChrome), ("light", Theme.lightChrome)] {
            let ring = Theme.searchFocusRing(for: palette)
            let ratio = Contrast.ratio(
                ring,
                on: Theme.searchFocusFill,
                over: palette.surface
            )
            XCTAssertGreaterThanOrEqual(
                ratio,
                Contrast.aaLarge,
                "\(name) palette: search focus ring is \(ratio):1"
            )
        }
    }

    /// Regression guard for what shipped before: one hard-coded white-on-glass
    /// palette, which collapsed over a light backdrop. If someone reintroduces
    /// a fixed light ink, this is the measurement that catches it.
    func testTheOldFixedPaletteWouldHaveFailedOverALightBackdrop() {
        let oldInk = Color.white.opacity(0.96)
        let oldSelectedFill = Color.white.opacity(0.34)
        let lightGlass = Contrast.composite(Color.white.opacity(0.10), over: Color(white: 0.82))

        XCTAssertLessThan(Contrast.ratio(oldInk, on: oldSelectedFill, over: lightGlass), 2.0)
        XCTAssertGreaterThanOrEqual(
            Contrast.ratio(Theme.lightChrome.ink,
                           on: Theme.lightChrome.pillSelected,
                           over: Theme.lightChrome.surface),
            Contrast.aaText
        )
    }

    /// Selecting a tab must not make its label harder to read than leaving it
    /// alone — which is what the old `white 0.34` selected fill did in dark
    /// mode, landing at 3.88:1 against an unselected 6.39:1.
    func testSelectingATabDoesNotDropItsLabelBelowAA() {
        let palette = Theme.darkChrome
        let ink = Contrast.foreground(on: palette.pillSelected, over: palette.surface)
        XCTAssertGreaterThanOrEqual(
            Contrast.ratio(ink, on: palette.pillSelected, over: palette.surface),
            Contrast.aaText
        )
    }
}
