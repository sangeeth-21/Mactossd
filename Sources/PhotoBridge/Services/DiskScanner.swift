import AVFoundation
import Foundation
import ImageIO

/// Scans a folder (e.g. on an external SSD) for images and reads lightweight metadata
/// (pixel size + capture date) from the image header only. Results are cached by path/size/mtime,
/// so rescans only touch new or changed files.
enum DiskScanner {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "gif", "bmp", "webp", "avif", "jxl",
        "dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "raw",
    ]

    private struct Candidate: Sendable {
        let url: URL
        let size: Int64
        let mtime: Date?
    }

    private struct CacheEntry: Codable {
        let size: Int64
        let mtime: Double
        let width: Int
        let height: Int
        let capture: Double?
        var duration: Double? = nil
    }

    private static let cacheURL = AppPaths.file("disk-metadata.plist")

    enum ScanError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let p): "Can't read \(p). Check that the drive is connected and PhotoBridge has access."
            }
        }
    }

    static func scan(root: URL, progress: @escaping @Sendable (String, Double?) -> Void) async throws -> [DiskFile] {
        let candidates = try collect(root: root, progress: progress)
        try Task.checkCancellation()
        guard !candidates.isEmpty else { return [] }

        let cache = PlistStore.load([String: CacheEntry].self, from: cacheURL) ?? [:]
        let cancelled = Locked(false)
        let done = Locked(0)
        let total = candidates.count

        var results: [(DiskFile, CacheEntry?)?] = await withTaskCancellationHandler {
            var out = [(DiskFile, CacheEntry?)?](repeating: nil, count: total)
            let chunkSize = 64
            let chunks = (total + chunkSize - 1) / chunkSize
            out.withUnsafeMutableBufferPointer { buffer in
                guard let raw = buffer.baseAddress else { return }
            let out = UnsafeSendablePointer(base: raw)
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    if cancelled.value { return }
                    let lower = chunk * chunkSize
                    let upper = min(total, lower + chunkSize)
                    for i in lower ..< upper {
                        let c = candidates[i]
                        let mtime = c.mtime?.timeIntervalSince1970.rounded() ?? 0
                        if let hit = cache[c.url.path], hit.size == c.size, hit.mtime == mtime {
                            out.base[i] = (DiskFile(url: c.url, fileSize: c.size, modified: c.mtime,
                                                captureDate: hit.capture.map(Date.init(timeIntervalSince1970:)),
                                                pixelWidth: hit.width, pixelHeight: hit.height,
                                                duration: hit.duration ?? 0), nil)
                        } else if Media.isVideo(c.url) {
                            out.base[i] = nil   // read below with AVFoundation (async)
                        } else {
                            let meta = readMetadata(c.url)
                            let file = DiskFile(url: c.url, fileSize: c.size, modified: c.mtime,
                                                captureDate: meta.date, pixelWidth: meta.width, pixelHeight: meta.height)
                            let entry = CacheEntry(size: c.size, mtime: mtime, width: meta.width, height: meta.height,
                                                   capture: meta.date?.timeIntervalSince1970)
                            out.base[i] = (file, entry)
                        }
                    }
                    let finished = done.mutate { $0 += upper - lower; return $0 }
                    if chunk % 4 == 0 || finished == total {
                        progress("Reading \(finished.formatted()) of \(total.formatted())…", Double(finished) / Double(total))
                    }
                }
            }
            return out
        } onCancel: {
            cancelled.mutate { $0 = true }
        }
        try Task.checkCancellation()

        // Videos that weren't cached: read size / date / length with AVFoundation, 4 at a time.
        let videoIndices = results.indices.filter { results[$0] == nil && Media.isVideo(candidates[$0].url) }
        if !videoIndices.isEmpty {
            progress("Reading \(videoIndices.count.formatted()) videos…", nil)
            await withTaskGroup(of: (Int, (DiskFile, CacheEntry?)).self) { group in
                var next = 0
                func add(_ k: Int) {
                    let i = videoIndices[k]
                    let c = candidates[i]
                    group.addTask {
                        let meta = await readVideoMetadata(c.url)
                        let mtime = c.mtime?.timeIntervalSince1970.rounded() ?? 0
                        let file = DiskFile(url: c.url, fileSize: c.size, modified: c.mtime, captureDate: meta.date,
                                            pixelWidth: meta.width, pixelHeight: meta.height, duration: meta.duration)
                        let entry = CacheEntry(size: c.size, mtime: mtime, width: meta.width, height: meta.height,
                                               capture: meta.date?.timeIntervalSince1970, duration: meta.duration)
                        return (i, (file, entry))
                    }
                }
                while next < min(4, videoIndices.count) { add(next); next += 1 }
                while let done = await group.next() {
                    results[done.0] = done.1
                    if next < videoIndices.count && !Task.isCancelled { add(next); next += 1 }
                }
            }
            try Task.checkCancellation()
        }

        // Update cache: drop stale entries under this root, keep everything else.
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var newCache = cache.filter { !$0.key.hasPrefix(prefix) }
        var files: [DiskFile] = []
        files.reserveCapacity(total)
        for case let (file, entry)? in results {
            files.append(file)
            if let entry {
                newCache[file.url.path] = entry
            } else if let old = cache[file.url.path] {
                newCache[file.url.path] = old
            }
        }
        PlistStore.save(newCache, to: cacheURL)
        return files
    }

    /// Synchronous directory walk (NSEnumerator iteration is not allowed in async contexts).
    private static func collect(root: URL, progress: @Sendable (String, Double?) -> Void) throws -> [Candidate] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { throw ScanError.unreadable(root.path) }

        let keySet = Set(keys)
        var out: [Candidate] = []
        var seen = 0
        while let url = enumerator.nextObject() as? URL {
            seen += 1
            if seen % 512 == 0 {
                if Task.isCancelled { throw CancellationError() }
            }
            let ext = url.pathExtension.lowercased()
            guard imageExtensions.contains(ext) || Media.videoExtensions.contains(ext) else { continue }
            guard let values = try? url.resourceValues(forKeys: keySet), values.isRegularFile == true else { continue }
            out.append(Candidate(url: url, size: Int64(values.fileSize ?? 0), mtime: values.contentModificationDate))
            if out.count % 1000 == 0 { progress("Found \(out.count.formatted()) images…", nil) }
        }
        return out
    }

    // MARK: Metadata

    struct Metadata {
        var width = 0
        var height = 0
        var date: Date?
        var duration: Double = 0
    }

    /// Reads a video's display size (rotation applied), recording date and length.
    static func readVideoMetadata(_ url: URL) async -> Metadata {
        var meta = Metadata()
        let asset = AVURLAsset(url: url)
        guard let (tracks, duration, created) = try? await asset.load(.tracks, .duration, .creationDate) else {
            return meta
        }
        meta.duration = duration.seconds.isFinite ? duration.seconds : 0
        if let created { meta.date = try? await created.load(.dateValue) }
        if let video = tracks.first(where: { $0.mediaType == .video }),
           let (size, transform) = try? await video.load(.naturalSize, .preferredTransform) {
            let r = CGRect(origin: .zero, size: size).applying(transform)
            meta.width = Int(abs(r.width).rounded())
            meta.height = Int(abs(r.height).rounded())
        }
        return meta
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    private static let exifOffsetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
        return f
    }()

    static func readMetadata(_ url: URL) -> Metadata {
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, noCache),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache) as? [CFString: Any]
        else { return Metadata() }

        var meta = Metadata()
        meta.width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        meta.height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = (exif[kCGImagePropertyExifDateTimeOriginal] ?? exif[kCGImagePropertyExifDateTimeDigitized]) as? String {
            if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String,
               let d = exifOffsetFormatter.date(from: raw + offset) {
                meta.date = d
            } else {
                meta.date = exifFormatter.date(from: raw)
            }
        } else if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
                  let raw = tiff[kCGImagePropertyTIFFDateTime] as? String {
            meta.date = exifFormatter.date(from: raw)
        }
        return meta
    }

    // MARK: Volumes

    static func externalVolumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey,
                                      .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                               options: [.skipHiddenVolumes]) else { return [] }
        return urls.compactMap { url in
            guard url.path.hasPrefix("/Volumes/"),
                  let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsRootFileSystem != true, v.volumeIsBrowsable != false
            else { return nil }
            return Volume(url: url, name: v.volumeName ?? url.lastPathComponent,
                          capacity: v.volumeTotalCapacity.map(Int64.init),
                          available: v.volumeAvailableCapacity.map(Int64.init))
        }
    }
}
