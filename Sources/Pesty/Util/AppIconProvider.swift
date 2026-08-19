import AppKit

@MainActor
enum AppIconProvider {
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundleID bundleID: String?) -> NSImage {
        guard let bundleID else { return generic }
        if let cached = cache[bundleID] { return cached }
        var image = generic
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        cache[bundleID] = image
        return image
    }

    /// The icon with its transparent margin cropped away. macOS app icons are
    /// drawn on a canvas roughly 10% larger than the artwork on every side, so
    /// aligning the raw image's edge to anything leaves a gap the size of that
    /// padding. Cropping to the opaque bounds makes the artwork itself the
    /// thing being positioned.
    static func trimmedIcon(forBundleID bundleID: String?) -> NSImage {
        let key = bundleID ?? "__generic__"
        if let cached = trimmedCache[key] { return cached }
        let source = icon(forBundleID: bundleID)
        let trimmed = trim(source) ?? source
        trimmedCache[key] = trimmed
        return trimmed
    }

    private static var trimmedCache: [String: NSImage] = [:]

    private static func trim(_ image: NSImage) -> NSImage? {
        // Render at 512px, not at the icon's nominal point size: NSImage picks
        // the representation matching the target, so this pulls the sharpest
        // artwork available and leaves headroom for Retina drawing. Cropping
        // pixels out of this keeps the result crisp; re-rasterizing at point
        // size would bake in a blurry upscale.
        let pixels = 512
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: pixels * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.bitmapData else { return nil }
        let bytesPerRow = bitmap.bytesPerRow
        var minX = pixels, minY = pixels, maxX = -1, maxY = -1
        for y in 0..<pixels {
            let row = data + y * bytesPerRow
            for x in 0..<pixels where row[x * 4 + 3] > 12 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY,
              let full = bitmap.cgImage else { return nil }

        let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard crop.width < CGFloat(pixels) || crop.height < CGFloat(pixels),
              let cropped = full.cropping(to: crop) else { return nil }
        // Half the pixel count as the point size, so the image carries 2x
        // density wherever the card draws it.
        return NSImage(cgImage: cropped,
                       size: NSSize(width: crop.width / 2, height: crop.height / 2))
    }

    static let generic: NSImage =
        NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        ?? NSImage()
}
