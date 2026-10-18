import AppKit
import ImageIO

/// A decoded, downscaled desktop picture. `CGImage` is immutable, so sharing it across actors is safe.
struct DesktopImage: @unchecked Sendable {
    let image: CGImage
    /// The wallpaper file it came from.
    let sourceURL: URL
}

/// The current desktop picture for a display, for the switcher's Desktop card and the Overview home tile.
///
/// No screen capture is involved: the file behind `NSWorkspace.desktopImageURL(for:)` is decoded off the main actor with
/// ImageIO's thumbnail path (which never decodes the full-size image) and cached by file, modification date and size.
///
/// Returns nil when there is no usable file: a dynamic or aerial wallpaper without a still, a folder of rotating
/// pictures (the current one is unknown), or an unreadable file. The UI should then draw a neutral placeholder.
@MainActor
final class DesktopImageProvider {
    private struct Key: Hashable {
        let url: URL
        let modified: Date?
        let width: Int
        let height: Int
    }

    private var cache: [(key: Key, value: DesktopImage)] = []
    private var inFlight: [Key: Task<DesktopImage?, Never>] = [:]
    private let capacity: Int

    init(capacity: Int = 4) { self.capacity = max(1, capacity) }

    /// The desktop picture for `screen`, fitted within `maxPixelSize` (aspect ratio preserved, never upscaled).
    /// The returned image is cached; calling again for the same file and size is immediate.
    func image(for screen: NSScreen, maxPixelSize: CGSize) async -> DesktopImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              !url.hasDirectoryPath else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = Key(url: url, modified: modified, width: Int(maxPixelSize.width.rounded(.up)),
                      height: Int(maxPixelSize.height.rounded(.up)))
        if let index = cache.firstIndex(where: { $0.key == key }) {
            let hit = cache.remove(at: index)
            cache.append(hit)
            return hit.value
        }
        if let task = inFlight[key] { return await task.value }
        let task = Task.detached(priority: .utility) {
            Self.load(url: url, width: key.width, height: key.height)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            cache.removeAll { $0.key.url == key.url && $0.key.modified != key.modified }
            cache.append((key, result))
            if cache.count > capacity { cache.removeFirst(cache.count - capacity) }
        }
        return result
    }

    func removeAll() {
        cache.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    nonisolated static func load(url: URL, width: Int, height: Int) -> DesktopImage? {
        guard width > 0, height > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        let scale = min(Double(width) / pixelWidth, Double(height) / pixelHeight, 1)
        let longEdge = max(1, Int((max(pixelWidth, pixelHeight) * scale).rounded(.up)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return DesktopImage(image: image, sourceURL: url)
    }
}
