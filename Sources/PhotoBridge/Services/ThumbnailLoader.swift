import AppKit
import AVFoundation
import ImageIO

/// Memory-cached thumbnails for both sources. Sizes are bucketed so slider changes reuse cache entries.
enum ThumbnailLoader {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 5000
        c.totalCostLimit = 600 * 1024 * 1024
        return c
    }()

    static func bucket(_ pixels: CGFloat) -> Int {
        max(128, Int((pixels / 128).rounded(.up)) * 128)
    }

    private static func resolve(_ item: CompareItem, _ prefer: ImageSource?) -> (ImageSource, String)? {
        let source = prefer ?? (item.photo != nil ? .photos : .disk)
        switch source {
        case .photos: return item.photo.map { (.photos, $0.id) }
        case .disk: return item.file.map { (.disk, $0.url.path) }
        }
    }

    private static func key(_ source: ImageSource, _ id: String, _ px: Int, _ hq: Bool) -> NSString {
        "\(source.rawValue)|\(px)|\(hq ? 1 : 0)|\(id)" as NSString
    }

    static func cached(for item: CompareItem, prefer: ImageSource? = nil, pixelSize: CGFloat, highQuality: Bool = false) -> NSImage? {
        guard let (source, id) = resolve(item, prefer) else { return nil }
        return cache.object(forKey: key(source, id, bucket(pixelSize), highQuality))
    }

    static func image(for item: CompareItem, prefer: ImageSource? = nil, pixelSize: CGFloat, highQuality: Bool = false) async -> NSImage? {
        guard let (source, id) = resolve(item, prefer) else { return nil }
        let px = bucket(pixelSize)
        let k = key(source, id, px, highQuality)
        if let hit = cache.object(forKey: k) { return hit }
        if Task.isCancelled { return nil }

        let image: NSImage?
        switch source {
        case .photos:
            image = await PhotoLibraryService.shared.image(
                for: id, targetSize: CGSize(width: px, height: px), fill: !highQuality, highQuality: highQuality)
        case .disk:
            let url = URL(fileURLWithPath: id)
            if Media.isVideo(url) {
                image = await videoFrame(url, maxPixel: px).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            } else {
                image = diskImage(url: url, maxPixel: px, highQuality: highQuality)
            }
        }
        if let image { cache.setObject(image, forKey: k, cost: px * px * 4) }
        return image
    }

    /// Decodes a downsampled image with ImageIO. Uses the embedded EXIF thumbnail when it is big enough,
    /// otherwise decodes at reduced size (much faster than decoding full resolution).
    static func diskImage(url: URL, maxPixel: Int, highQuality: Bool) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }

        func make(always: Bool) -> CGImage? {
            let options: [CFString: Any] = [
                always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }

        var cg: CGImage?
        if !highQuality {
            cg = make(always: false)
            if let c = cg, Double(max(c.width, c.height)) < Double(maxPixel) * 0.6 { cg = nil }
        }
        if cg == nil { cg = make(always: true) }
        guard let cg else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Poster frame of a video file (rotation applied).
    static func videoFrame(_ url: URL, maxPixel: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
    }

    /// Small CGImage of any SSD file (photo or video), used for analysis and duplicate checks.
    static func diskCGImage(_ url: URL, maxPixel: Int) async -> CGImage? {
        if Media.isVideo(url) { return await videoFrame(url, maxPixel: maxPixel) }
        return JunkDetector.diskThumbnail(url, maxPixel: maxPixel)
    }

    // MARK: iPhone

    static func cachedDevice(_ id: String, pixelSize: CGFloat) -> NSImage? {
        cache.object(forKey: "dev|\(bucket(pixelSize))|\(id)" as NSString)
    }

    @MainActor
    static func deviceImage(_ id: String, service: DeviceService, pixelSize: CGFloat) async -> NSImage? {
        let px = bucket(pixelSize)
        let k = "dev|\(px)|\(id)" as NSString
        if let hit = cache.object(forKey: k) { return hit }
        guard let image = await service.thumbnail(for: id, maxPixel: px) else { return nil }
        cache.setObject(image, forKey: k, cost: px * px * 4)
        return image
    }

    // MARK: People avatars

    static func avatar(personID: Int64, assetID: String, hint: CGPoint?) async -> NSImage? {
        let k = "face|\(personID)" as NSString
        if let hit = cache.object(forKey: k) { return hit }
        guard let image = await PhotoLibraryService.shared.image(
            for: assetID, targetSize: CGSize(width: 640, height: 640), fill: false, highQuality: false)
        else { return nil }
        let face = PeopleService.faceCrop(image, hint: hint) ?? image
        cache.setObject(face, forKey: k)
        return face
    }
}
