import AppKit
import AVFoundation
import Photos

/// All PhotoKit access: fetching, thumbnails, exporting originals and importing files.
final class PhotoLibraryService: @unchecked Sendable {
    static let shared = PhotoLibraryService()

    private let imageManager = PHCachingImageManager()
    private let assets = Locked([String: PHAsset]())          // localIdentifier -> PHAsset
    private let uuidIndex = Locked([String: String]())         // uuid -> localIdentifier
    /// localIdentifier -> original filename + original file size (resolved once, then cached on disk).
    private let metaCache: Locked<[String: PhotoMeta]>
    private let metaCacheURL = AppPaths.file("photo-meta.plist")

    struct PhotoMeta: Codable, Sendable {
        let name: String
        let size: Int64
    }

    private init() {
        metaCache = Locked(PlistStore.load([String: PhotoMeta].self, from: metaCacheURL) ?? [:])
        try? FileManager.default.removeItem(at: AppPaths.file("photo-filenames.plist"))   // old cache format
        imageManager.allowsCachingHighQualityImages = false
    }

    // MARK: Authorization

    var authorizationStatus: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: Lookup

    func phAsset(for id: String) -> PHAsset? { assets.value[id] }
    func localIdentifier(forUUID uuid: String) -> String? { uuidIndex.value[uuid] }

    // MARK: Fetch

    /// Fetches every image in the library. Original filenames are resolved in parallel and cached on disk,
    /// so the second launch is near-instant even for very large libraries.
    func fetchAllImages(progress: @escaping @Sendable (Double) -> Void) async -> [PhotoAsset] {
        // Photos AND videos (the Photos app's library count includes both).
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        let count = result.count
        guard count > 0 else { return [] }

        let phAssets = result.objects(at: IndexSet(integersIn: 0 ..< count))
        let known = metaCache.value
        let newMeta = Locked([String: PhotoMeta]())
        let done = Locked(0)

        var output = [PhotoAsset?](repeating: nil, count: count)
        let chunkSize = 200
        let chunks = (count + chunkSize - 1) / chunkSize

        output.withUnsafeMutableBufferPointer { buffer in
            guard let raw = buffer.baseAddress else { return }
            let out = UnsafeSendablePointer(base: raw)
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                let lower = chunk * chunkSize
                let upper = min(count, lower + chunkSize)
                var localNew: [String: PhotoMeta] = [:]
                for i in lower ..< upper {
                    let asset = phAssets[i]
                    let meta: PhotoMeta
                    if let cached = known[asset.localIdentifier] {
                        meta = cached
                    } else {
                        meta = Self.resolveMeta(of: asset)
                        localNew[asset.localIdentifier] = meta
                    }
                    out.base[i] = Self.snapshot(asset, filename: meta.name, size: meta.size)
                }
                if !localNew.isEmpty { newMeta.mutate { $0.merge(localNew) { a, _ in a } } }
                let finished = done.mutate { $0 += upper - lower; return $0 }
                progress(Double(finished) / Double(count))
            }
        }

        var byID = [String: PHAsset](minimumCapacity: count)
        var byUUID = [String: String](minimumCapacity: count)
        for a in phAssets {
            byID[a.localIdentifier] = a
            if let uuid = a.localIdentifier.split(separator: "/").first { byUUID[String(uuid)] = a.localIdentifier }
        }
        assets.mutate { $0 = byID }
        uuidIndex.mutate { $0 = byUUID }

        let added = newMeta.value
        if !added.isEmpty {
            metaCache.mutate { $0.merge(added) { a, _ in a } }
            PlistStore.save(metaCache.value, to: metaCacheURL)
        }
        return output.compactMap { $0 }
    }

    /// PhotoKit has no public size API; PHAssetResource answers the `fileSize` key on every current macOS.
    /// Guarded so an OS without it simply reports "unknown" (0) instead of crashing.
    private static let resourceHasSize = PHAssetResource.instancesRespond(to: NSSelectorFromString("fileSize"))

    /// The resource holding the untouched original: the photo for images, the movie for videos.
    static func primaryResource(of asset: PHAsset, in resources: [PHAssetResource]) -> PHAssetResource? {
        if asset.mediaType == .video {
            return resources.first { $0.type == .video } ?? resources.first { $0.type == .fullSizeVideo } ?? resources.first
        }
        return resources.first { $0.type == .photo } ?? resources.first { $0.type == .fullSizePhoto } ?? resources.first
    }

    private static func resolveMeta(of asset: PHAsset) -> PhotoMeta {
        let resources = PHAssetResource.assetResources(for: asset)
        let primary = primaryResource(of: asset, in: resources)
        var size: Int64 = 0
        if resourceHasSize, let primary, let n = primary.value(forKey: "fileSize") as? NSNumber {
            size = n.int64Value
        }
        return PhotoMeta(name: primary?.originalFilename ?? "\(asset.localIdentifier.prefix(8)).jpg", size: size)
    }

    private static func snapshot(_ a: PHAsset, filename: String, size: Int64) -> PhotoAsset {
        PhotoAsset(id: a.localIdentifier, filename: filename, creationDate: a.creationDate,
                   pixelWidth: a.pixelWidth, pixelHeight: a.pixelHeight, isFavorite: a.isFavorite,
                   isScreenshot: a.mediaSubtypes.contains(.photoScreenshot), fileSize: size,
                   isVideo: a.mediaType == .video, duration: a.duration)
    }

    // MARK: Video playback

    /// A playable item for a Photos video (downloads from iCloud if needed).
    @MainActor
    func playerItem(for id: String) async -> AVPlayerItem? {
        guard let asset = phAsset(for: id), asset.mediaType == .video else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        options.version = .current
        return await withCheckedContinuation { continuation in
            imageManager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    // MARK: Library check

    /// Counts straight from PhotoKit, to compare with what the Photos app shows.
    func libraryStats() -> LibraryStats {
        var s = LibraryStats()
        s.limitedAccess = authorizationStatus == .limited
        s.photos = PHAsset.fetchAssets(with: .image, options: nil).count
        s.videos = PHAsset.fetchAssets(with: .video, options: nil).count
        let withHidden = PHFetchOptions()
        withHidden.includeHiddenAssets = true
        s.hidden = max(0, PHAsset.fetchAssets(with: withHidden).count - PHAsset.fetchAssets(with: nil).count)
        let withBursts = PHFetchOptions()
        withBursts.includeAllBurstAssets = true
        s.burstExtras = max(0, PHAsset.fetchAssets(with: withBursts).count - PHAsset.fetchAssets(with: nil).count)
        return s
    }

    // MARK: Images

    func image(for id: String, targetSize: CGSize, fill: Bool, highQuality: Bool) async -> NSImage? {
        guard let asset = phAsset(for: id), !Task.isCancelled else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat     // exactly one callback
        options.resizeMode = highQuality ? .exact : .fast
        options.isNetworkAccessAllowed = true          // iCloud "Optimize Storage" libraries
        options.version = .current

        let box = ImageRequestBox(manager: imageManager)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
                box.setContinuation(continuation)
                let requestID = imageManager.requestImage(
                    for: asset, targetSize: targetSize,
                    contentMode: fill ? .aspectFill : .aspectFit,
                    options: options
                ) { image, _ in box.finish(image) }
                box.setRequest(requestID)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Small CGImage for on-device analysis.
    func analysisImage(for id: String, maxPixel: CGFloat = 360) async -> CGImage? {
        guard let image = await image(for: id, targetSize: CGSize(width: maxPixel, height: maxPixel),
                                      fill: false, highQuality: false) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: Delete

    /// Moves assets to Photos' "Recently Deleted" album. macOS shows its own confirmation.
    func deleteAssets(ids: [String]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            PHAssetChangeRequest.deleteAssets(assets)
        }
        assets.mutate { dict in for id in ids { dict.removeValue(forKey: id) } }
    }

    // MARK: Export (Photos -> SSD)

    /// Writes the untouched original file of an asset into `folder`. Returns the written file URL.
    func exportOriginal(id: String, to folder: URL) async throws -> URL {
        guard let asset = phAsset(for: id) else { throw AppError.assetMissing }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = Self.primaryResource(of: asset, in: resources) else { throw AppError.noResource }

        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // SAFETY: download into a brand-new hidden temp file that only this app owns, then move it
        // into place. `moveItem` refuses to replace an existing file, so nothing on the SSD can ever be
        // overwritten, and on failure only our own temp file is cleaned up.
        let temp = folder.appendingPathComponent(".photobridge-\(UUID().uuidString).partial")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: temp, options: options)
        } catch {
            if fm.fileExists(atPath: temp.path) { try? fm.removeItem(at: temp) }
            throw error
        }

        var lastError: Error?
        for _ in 0 ..< 5 {
            let destination = FileUtils.reserveUniqueURL(in: folder, filename: resource.originalFilename)
            defer { FileUtils.release(destination) }
            do {
                try fm.moveItem(at: temp, to: destination)   // fails (never overwrites) if the name is taken
                if let date = asset.creationDate {
                    try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: destination.path)
                }
                return destination
            } catch {
                lastError = error   // name was taken in the meantime; pick the next free name
            }
        }
        try? fm.removeItem(at: temp)
        throw lastError ?? AppError.noResource
    }

    // MARK: Import (SSD -> Photos)

    /// Adds files to the Photos library (files are copied, never moved). Failed batches are retried one by one.
    func importFiles(_ urls: [URL]) async -> [URL: PhotoAsset] {
        do {
            return try await create(urls)
        } catch {
            guard urls.count > 1 else { return [:] }
            var out: [URL: PhotoAsset] = [:]
            for url in urls {
                if let single = try? await create([url]) { out.merge(single) { a, _ in a } }
            }
            return out
        }
    }

    private func create(_ urls: [URL]) async throws -> [URL: PhotoAsset] {
        let placeholders = Locked([URL: String]())
        try await PHPhotoLibrary.shared().performChanges {
            for url in urls {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                options.originalFilename = url.lastPathComponent
                request.addResource(with: Media.isVideo(url) ? .video : .photo, fileURL: url, options: options)
                if let id = request.placeholderForCreatedAsset?.localIdentifier {
                    placeholders.mutate { $0[url] = id }
                }
            }
        }

        let map = placeholders.value
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(map.values), options: nil)
        var byID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }

        var out: [URL: PhotoAsset] = [:]
        var metas: [String: PhotoMeta] = [:]
        for (url, id) in map {
            guard let asset = byID[id] else { continue }
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            out[url] = Self.snapshot(asset, filename: url.lastPathComponent, size: size)
            metas[id] = PhotoMeta(name: url.lastPathComponent, size: size)
        }
        assets.mutate { $0.merge(byID) { _, b in b } }
        uuidIndex.mutate { dict in
            for id in byID.keys { if let u = id.split(separator: "/").first { dict[String(u)] = id } }
        }
        metaCache.mutate { $0.merge(metas) { _, b in b } }
        PlistStore.save(metaCache.value, to: metaCacheURL)
        return out
    }
}

/// Bridges a PhotoKit image request to async/await with safe, exactly-once resumption and cancellation.
private final class ImageRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private let manager: PHImageManager
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var requestID: PHImageRequestID?
    private var cancelled = false

    init(manager: PHImageManager) { self.manager = manager }

    func setContinuation(_ c: CheckedContinuation<NSImage?, Never>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            c.resume(returning: nil)
            return
        }
        continuation = c
        lock.unlock()
    }

    func setRequest(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { manager.cancelImageRequest(id) }
    }

    func finish(_ image: NSImage?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: image)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = requestID
        lock.unlock()
        if let id { manager.cancelImageRequest(id) }
        finish(nil)
    }
}
