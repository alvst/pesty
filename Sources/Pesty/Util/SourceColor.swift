import AppKit
import SwiftUI

@MainActor
enum SourceColor {
    private static var cache: [String: Color] = [:]
    private static let fallback = Color(red: 0.24, green: 0.61, blue: 0.95)

    static func color(for bundleID: String?) -> Color {
        guard let id = bundleID, !id.isEmpty else { return fallback }
        if let color = cache[id] { return color }
        let color = dominantColor(in: AppIconProvider.icon(forBundleID: id)) ?? fallback
        cache[id] = color
        return color
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
            return darkWeight > 0 ? Color(red: 0.06, green: 0.12, blue: 0.31) : fallback
        }

        let main = NSColor(deviceRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        main.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(hue: Double(hue),
                     saturation: min(0.78, max(0.42, Double(saturation) * 1.06)),
                     brightness: min(0.84, max(0.40, Double(brightness))))
    }
}
