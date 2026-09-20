import AppKit

@MainActor
enum AppIconProvider {
    private static let pestyBundleID = AppIdentity.bundleIdentifier
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundleID bundleID: String?, appearance requestedAppearance: SourceIconOverrides.IconAppearance? = nil) -> NSImage {
        let appearance = requestedAppearance ?? SourceIconOverrides.shared.currentAppearance
        guard let bundleID else { return generic }
        if let override = SourceIconOverrides.shared.icon(for: bundleID, appearance: appearance) { return override }
        let cacheKey = "\(bundleID)|\(appearance.rawValue)"
        if let cached = cache[cacheKey] { return cached }
        var image = generic
        if bundleID == pestyBundleID || bundleID == Bundle.main.bundleIdentifier {
            image = pestyIcon()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        cache[cacheKey] = image
        return image
    }

    private static func pestyIcon() -> NSImage {
        // `NSApp.applicationIconImage` is the generic app-dashed symbol when Pesty
        // is launched with `swift run`. Prefer the bundled icon so copied clips
        // identify Pesty correctly in both the packaged app and development builds.
        if let url = Bundle.main.url(forResource: AppIdentity.displayName, withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        // `swift run` launches the bare executable, so it has no application
        // resource bundle. Resolve the packaged asset from this checkout as a
        // development fallback; released copies use the bundle path above.
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let developmentIcon = projectRoot.appending(path: "packaging/Pesty.icns")
        if let icon = NSImage(contentsOf: developmentIcon) {
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pestyBundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSApp.applicationIconImage ?? generic
    }

    /// The icon with its transparent margin cropped away. macOS app icons are
    /// drawn on a canvas roughly 10% larger than the artwork on every side, so
    /// aligning the raw image's edge to anything leaves a gap the size of that
    /// padding. Cropping to the opaque bounds makes the artwork itself the
    /// thing being positioned.
    static func trimmedIcon(forBundleID bundleID: String?, appearance requestedAppearance: SourceIconOverrides.IconAppearance? = nil) -> NSImage {
        let appearance = requestedAppearance ?? SourceIconOverrides.shared.currentAppearance
        let key = "\(bundleID ?? "__generic__")|\(appearance.rawValue)"
        if let cached = trimmedCache[key] { return cached }
        let source = icon(forBundleID: bundleID, appearance: appearance)
        let trimmed = trim(source) ?? source
        trimmedCache[key] = trimmed
        return trimmed
    }

    private static var trimmedCache: [String: NSImage] = [:]

    static func invalidate(bundleID: String) {
        cache.keys.filter { $0.hasPrefix("\(bundleID)|") }.forEach { cache.removeValue(forKey: $0) }
        trimmedCache.keys.filter { $0.hasPrefix("\(bundleID)|") }.forEach { trimmedCache.removeValue(forKey: $0) }
    }

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
