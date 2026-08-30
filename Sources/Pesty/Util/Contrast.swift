import AppKit
import SwiftUI

/// Measured contrast, so a foreground color is chosen against the surface it
/// actually lands on instead of being hand-tuned per surface.
///
/// This is WCAG 2.1: `luminance` is the standard sRGB relative luminance and
/// `ratio` is `(L1 + 0.05) / (L2 + 0.05)`. The wrinkle for Pesty is that a
/// contrast ratio is only meaningful between *opaque* colors, and almost
/// every surface here is a translucent fill over glass or over a card. So
/// `composite(_:over:)` flattens a fill onto its backdrop first, and the
/// entry points callers actually want — `foreground(on:)` and
/// `adjust(_:on:)` — do that flattening for you.
enum Contrast {
    /// WCAG AA for body-sized text.
    static let aaText = 4.5
    /// WCAG AA for large text (18 pt, or 14 pt bold) and for non-text glyphs
    /// such as icons and control borders.
    static let aaLarge = 3.0

    /// The two inks every surface in Pesty picks between. Not pure black:
    /// full black on a light glass reads as a hole punched in the panel,
    /// and the last few points of contrast aren't worth that.
    static let darkInk = Color(white: 0.08)
    static let lightInk = Color.white

    // MARK: - Measuring

    /// WCAG 2.1 relative luminance. Alpha is ignored — flatten with
    /// `composite(_:over:)` first if the color is translucent.
    static func luminance(_ color: Color) -> Double {
        let c = components(color)
        return luminance(red: c.red, green: c.green, blue: c.blue)
    }

    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.040_45
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Contrast ratio between two opaque colors, from 1 (identical) to 21
    /// (pure black against pure white). Order doesn't matter.
    static func ratio(_ a: Color, _ b: Color) -> Double {
        ratio(luminance(a), luminance(b))
    }

    static func ratio(_ a: Double, _ b: Double) -> Double {
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Contrast of a possibly-translucent `foreground` painted onto a
    /// possibly-translucent `surface`, which is itself sitting on `backdrop`.
    /// This is the shape nearly every real question in Pesty takes: white
    /// label on a `white.opacity(0.34)` pill on glass.
    static func ratio(_ foreground: Color, on surface: Color, over backdrop: Color) -> Double {
        let flatSurface = composite(surface, over: backdrop)
        return ratio(composite(foreground, over: flatSurface), flatSurface)
    }

    /// True when `foreground` clears `target` against the flattened surface.
    static func meets(_ target: Double, _ foreground: Color,
                      on surface: Color, over backdrop: Color) -> Bool {
        ratio(foreground, on: surface, over: backdrop) >= target
    }

    // MARK: - Choosing

    /// Whichever ink reads better on `surface` — the core of "adjust to the
    /// background instead of assuming one".
    static func foreground(on surface: Color, over backdrop: Color = .white,
                           light: Color = lightInk, dark: Color = darkInk) -> Color {
        let flat = composite(surface, over: backdrop)
        return ratio(light, flat) >= ratio(dark, flat) ? light : dark
    }

    /// `foreground` if it already clears `target`, otherwise the same hue
    /// pushed toward whichever extreme gains contrast until it does. Returns
    /// the closest it could get if even the extreme falls short, so a caller
    /// never ends up with a color that's worse than what it asked for.
    static func adjust(_ foreground: Color, on surface: Color, over backdrop: Color = .white,
                       target: Double = aaText) -> Color {
        let flat = composite(surface, over: backdrop)
        guard ratio(composite(foreground, over: flat), flat) < target else { return foreground }

        // Push toward black or white, whichever the surface leaves room for.
        let extreme: Color = luminance(flat) > 0.5 ? .black : .white
        var best = foreground
        var bestRatio = ratio(composite(foreground, over: flat), flat)
        for step in 1...20 {
            let candidate = blend(foreground, toward: extreme, amount: Double(step) / 20)
            let candidateRatio = ratio(composite(candidate, over: flat), flat)
            if candidateRatio > bestRatio {
                best = candidate
                bestRatio = candidateRatio
            }
            if candidateRatio >= target { return candidate }
        }
        return best
    }

    /// `surface` if a fixed foreground already reads on it, otherwise the
    /// same surface pushed toward whichever extreme gives that foreground
    /// more contrast. Card headers use this when their ink is intentionally
    /// always white, including colors supplied by extensions.
    static func adjustSurface(
        _ surface: Color,
        for foreground: Color,
        over backdrop: Color = .white,
        target: Double = aaText
    ) -> Color {
        let flat = composite(surface, over: backdrop)
        let originalRatio = ratio(composite(foreground, over: flat), flat)
        guard originalRatio < target else { return surface }

        let darkSurface = Color.black
        let lightSurface = Color.white
        let darkRatio = ratio(composite(foreground, over: darkSurface), darkSurface)
        let lightRatio = ratio(composite(foreground, over: lightSurface), lightSurface)
        let extreme = darkRatio >= lightRatio ? darkSurface : lightSurface

        var best = surface
        var bestRatio = originalRatio
        for step in 1...20 {
            let candidate = blend(surface, toward: extreme, amount: Double(step) / 20)
            let flatCandidate = composite(candidate, over: backdrop)
            let candidateRatio = ratio(
                composite(foreground, over: flatCandidate),
                flatCandidate
            )
            if candidateRatio > bestRatio {
                best = candidate
                bestRatio = candidateRatio
            }
            if candidateRatio >= target { return candidate }
        }
        return best
    }

    /// A de-emphasized version of `ink` that is still legible: the requested
    /// opacity if it clears `target`, otherwise the least amount of extra
    /// opacity that does. This is what keeps a "muted" label from quietly
    /// becoming an unreadable one on a surface it wasn't tuned for.
    static func muted(_ ink: Color, opacity: Double, on surface: Color,
                      over backdrop: Color = .white, target: Double = aaText) -> Color {
        let flat = composite(surface, over: backdrop)
        var candidate = opacity
        while candidate < 1 {
            let color = ink.opacity(candidate)
            if ratio(composite(color, over: flat), flat) >= target { return color }
            candidate += 0.02
        }
        return ink
    }

    // MARK: - Compositing

    /// Flattens a translucent `color` onto an opaque `backdrop`. Straight
    /// source-over in sRGB, which is what the window server does for these
    /// fills, so the result is what the eye actually receives.
    static func composite(_ color: Color, over backdrop: Color) -> Color {
        let top = components(color)
        guard top.alpha < 1 else { return color }
        let under = components(backdrop)
        let a = top.alpha
        return Color(.sRGB,
                     red: top.red * a + under.red * (1 - a),
                     green: top.green * a + under.green * (1 - a),
                     blue: top.blue * a + under.blue * (1 - a),
                     opacity: 1)
    }

    private static func blend(_ color: Color, toward other: Color, amount: Double) -> Color {
        let a = components(color)
        let b = components(other)
        return Color(.sRGB,
                     red: a.red + (b.red - a.red) * amount,
                     green: a.green + (b.green - a.green) * amount,
                     blue: a.blue + (b.blue - a.blue) * amount,
                     opacity: a.alpha)
    }

    /// sRGB components. A `Color` that can't be resolved into sRGB — a
    /// pattern or catalog color with no concrete value — is reported as
    /// opaque mid-gray, which makes contrast against it read as poor rather
    /// than as a false pass.
    static func components(_ color: Color) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else {
            return (0.5, 0.5, 0.5, 1)
        }
        return (Double(srgb.redComponent),
                Double(srgb.greenComponent),
                Double(srgb.blueComponent),
                Double(srgb.alphaComponent))
    }
}
