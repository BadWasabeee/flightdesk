// Bounded decoding for images that come from the network, and the shared decoded-logo cache.

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Checks an image's size from its header before anything is decoded, and decodes through ImageIO
/// thumbnails so a hostile file can't make FlightDesk allocate a huge bitmap.
enum ImageGuard {
    struct Limits: Sendable {
        var maxBytes: Int
        /// Longest allowed side, in pixels, as declared by the file.
        var maxPixels: Int
        /// Accepted container types.
        var types: Set<String>
    }

    static let logo = Limits(maxBytes: ResponseLimit.logo, maxPixels: 1024, types: [UTType.png.identifier])
    static let photo = Limits(maxBytes: ResponseLimit.photo, maxPixels: 2000,
                              types: [UTType.jpeg.identifier, UTType.png.identifier, UTType.webP.identifier])

    private static let noCache = [kCGImageSourceShouldCache: false] as CFDictionary

    /// Declared pixel size of the first image in `data`, read from the header only.
    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, noCache) else { return nil }
        return pixelSize(src)
    }

    private static func pixelSize(_ src: CGImageSource) -> (width: Int, height: Int)? {
        guard CGImageSourceGetCount(src) > 0,
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, noCache) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// An image source for `data` if it is within `limits` (bytes, declared dimensions, type).
    static func source(_ data: Data, _ limits: Limits) -> CGImageSource? {
        guard !data.isEmpty, data.count <= limits.maxBytes,
              let src = CGImageSourceCreateWithData(data as CFData, noCache),
              let type = CGImageSourceGetType(src) as String?, limits.types.contains(type),
              let size = pixelSize(src), size.width <= limits.maxPixels, size.height <= limits.maxPixels else { return nil }
        return src
    }

    /// The image in `data` decoded at most `maxPixel` on its longest side (never upscaled),
    /// or nil when it fails `limits`.
    static func thumbnail(_ data: Data, _ limits: Limits, maxPixel: Int) -> CGImage? {
        guard let src = source(data, limits) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
    }

    /// Whether `data` plausibly is a self-contained SVG document: an `<svg` root near the start and
    /// no DTD entities (entity expansion), within the logo byte limit.
    static func isPlainSVG(_ data: Data) -> Bool {
        guard data.count > 20, data.count <= logo.maxBytes,
              let text = String(data: data, encoding: .utf8) else { return false }
        let head = text.prefix(4096).lowercased()
        return head.contains("<svg") && !text.localizedCaseInsensitiveContains("<!entity")
    }
}

// MARK: - Decoded logo cache

/// Airline logos decoded once and shared by every view (widget, panel, main window), keyed by the
/// logo's code and file modification date so a re-downloaded logo replaces the old image.
enum LogoStore {
    /// A decoded logo with what views need to decide how to draw it.
    final class Logo: @unchecked Sendable {
        let image: PlatformImage
        let url: URL
        /// Alpha-weighted brightness (0…1), see `LogoTone`.
        let brightness: Double
        var size: CGSize { image.size }

        init(image: PlatformImage, url: URL, brightness: Double) {
            self.image = image
            self.url = url
            self.brightness = brightness
        }
    }

    // NSCache is thread-safe.
    private static let cache: NSCache<NSString, Logo> = {
        let c = NSCache<NSString, Logo>()
        c.countLimit = 300
        return c
    }()

    /// The cached logo for `code` (an `AirlineLogos.Key.id`), decoding it on first use. Costs one
    /// file stat per call once decoded.
    static func logo(for code: String?) -> Logo? {
        guard let url = AirlineLogos.path(for: code),
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        let key = "\(url.lastPathComponent)#\(date.timeIntervalSince1970)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        // Cached logos were checked and downscaled when they were downloaded; still decode them
        // through the guard in case the shared container holds something unexpected.
        guard let data = try? Data(contentsOf: url),
              let cg = ImageGuard.thumbnail(data, ImageGuard.logo, maxPixel: 256) else { return nil }
        let logo = Logo(image: PlatformImage.make(cg),
                        url: url, brightness: LogoTone.brightness(cg))
        cache.setObject(logo, forKey: key)
        return logo
    }
}
