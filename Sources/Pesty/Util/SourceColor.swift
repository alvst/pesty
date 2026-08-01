import AppKit
import SwiftUI

@MainActor
enum SourceColor {
    // Keep the default appearance aligned with Pesty's established card design:
    // a card takes its color from the app that produced it.  The original color
    // theme experiment used a stored palette for this option, which meant merely
    // upgrading could unexpectedly recolor every existing card.
    private static let sourceAppFallback = Color(red: 0.02, green: 0.48, blue: 1.0)
    private static let accentVariants: [AccentVariant] = [
        AccentVariant(hueOffset: -0.055, saturationOffset:  0.08, brightnessOffset: -0.34),
        AccentVariant(hueOffset:  0.040, saturationOffset: -0.08, brightnessOffset: -0.27),
        AccentVariant(hueOffset: -0.025, saturationOffset:  0.10, brightnessOffset: -0.19),
        AccentVariant(hueOffset:  0.020, saturationOffset: -0.10, brightnessOffset: -0.11),
        AccentVariant(hueOffset: -0.010, saturationOffset:  0.06, brightnessOffset: -0.03),
        AccentVariant(hueOffset:  0.010, saturationOffset: -0.05, brightnessOffset:  0.05),
        AccentVariant(hueOffset: -0.020, saturationOffset:  0.10, brightnessOffset:  0.13),
        AccentVariant(hueOffset:  0.025, saturationOffset: -0.10, brightnessOffset:  0.21),
        AccentVariant(hueOffset: -0.040, saturationOffset:  0.04, brightnessOffset:  0.29),
        AccentVariant(hueOffset:  0.055, saturationOffset: -0.14, brightnessOffset:  0.35)
    ]

    private static var sourceAppCache: [String: Color] = [:]
    private static var vibrantCache: [String: Color] = [:]

    static func color(for bundleID: String?) -> Color {
        return switch Settings.shared.clipColorTheme {
        case .default:
            sourceAppColor(for: bundleID)
        case .vibrant:
            vibrantColor(for: bundleID)
        case .accentShades:
            accentShade(
                for: bundleID?.isEmpty == false ? bundleID! : "unknown",
                accentHex: Settings.shared.clipColorAccentHex
            )
        }
    }

    static func accentShades(for accentHex: String) -> [Color] {
        accentVariants.map { accentShade(variant: $0, accentHex: accentHex) }
    }

    private static func sourceAppColor(for bundleID: String?) -> Color {
        guard let bundleID, !bundleID.isEmpty else { return sourceAppFallback }
        if let color = sourceAppCache[bundleID] { return color }

        let color = dominantColor(in: AppIconProvider.icon(forBundleID: bundleID)) ?? sourceAppFallback
        sourceAppCache[bundleID] = color
        return color
    }

    private static func vibrantColor(for bundleID: String?) -> Color {
        guard let bundleID, !bundleID.isEmpty else { return vibrantColor(from: sourceAppFallback) }
        if let color = vibrantCache[bundleID] { return color }

        let color = vibrantColor(from: sourceAppColor(for: bundleID))
        vibrantCache[bundleID] = color
        return color
    }

    private static func vibrantColor(from color: Color) -> Color {
        guard let nsColor = NSColor(color).usingColorSpace(.sRGB) else { return color }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)

        // Make the vibrant option visibly distinct while keeping headers dark
        // enough for their white labels to remain readable.
        return Color(
            hue: Double(hue),
            saturation: min(0.99, max(0.92, Double(saturation) * 1.08)),
            brightness: min(0.90, max(0.68, Double(brightness) * 0.90))
        )
    }

    private static func accentShade(for bundleID: String, accentHex: String) -> Color {
        let index = stableIndex(for: bundleID, count: accentVariants.count)
        return accentShade(variant: accentVariants[index], accentHex: accentHex)
    }

    private static func accentShade(variant: AccentVariant, accentHex: String) -> Color {
        let nsColor = NSColor(hex: accentHex)?.usingColorSpace(.sRGB)
            ?? NSColor.systemPink.usingColorSpace(.sRGB)!
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)

        // Normalizing the middle brightness prevents very light or very dark
        // user selections from collapsing several variants into the same color.
        let middleBrightness = min(0.76, max(0.66, Double(brightness)))
        let adjustedHue = (Double(hue) + variant.hueOffset + 1).truncatingRemainder(dividingBy: 1)

        return Color(
            hue: adjustedHue,
            saturation: min(0.98, max(0.60, Double(saturation) + variant.saturationOffset)),
            brightness: min(0.98, max(0.32, middleBrightness + variant.brightnessOffset))
        )
    }

    private static func stableIndex(for bundleID: String, count: Int) -> Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in bundleID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }

    private struct AccentVariant {
        let hueOffset: Double
        let saturationOffset: Double
        let brightnessOffset: Double
    }

    private static func dominantColor(in icon: NSImage) -> Color? {
        let size = 40
        let thumbnail = NSImage(size: NSSize(width: size, height: size))
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                  from: .zero,
                  operation: .sourceOver,
                  fraction: 1,
                  respectFlipped: true,
                  hints: [.interpolation: NSImageInterpolation.high])
        thumbnail.unlockFocus()
        guard let data = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else { return nil }

        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var weight = 0.0
        var darkWeight = 0.0

        for x in 0..<size {
            for y in 0..<size {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let alpha = color.alphaComponent
                guard alpha > 0.35 else { continue }
                let maximum = max(color.redComponent, color.greenComponent, color.blueComponent)
                let minimum = min(color.redComponent, color.greenComponent, color.blueComponent)
                let saturation = maximum == 0 ? 0 : (maximum - minimum) / maximum
                let brightness = maximum

                if brightness < 0.45 { darkWeight += alpha }
                guard saturation > 0.16, brightness > 0.14 else { continue }
                let pixelWeight = alpha * saturation * (0.45 + 0.55 * brightness)
                red += Double(color.redComponent) * pixelWeight
                green += Double(color.greenComponent) * pixelWeight
                blue += Double(color.blueComponent) * pixelWeight
                weight += pixelWeight
            }
        }

        if weight == 0 {
            return darkWeight > 0 ? Color(red: 0.025, green: 0.075, blue: 0.24) : sourceAppFallback
        }

        let main = NSColor(deviceRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        main.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(hue: Double(hue),
                     saturation: min(0.99, max(0.90, Double(saturation) * 1.85)),
                     brightness: min(0.98, max(0.84, Double(brightness) * 1.20)))
    }
}
