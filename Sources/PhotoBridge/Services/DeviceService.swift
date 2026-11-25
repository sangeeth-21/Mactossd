import AppKit
import ImageCaptureCore
import UniformTypeIdentifiers

/// Talks to iPhones / cameras connected by cable using ImageCaptureCore (the framework behind Image Capture).
///
/// SAFETY: this service is strictly read-only towards the device. It only reads the catalog, thumbnails
/// and downloads byte-exact copies of originals. It never passes `deleteAfterSuccessfulDownload`, never
/// calls `requestDeleteFiles`, and never modifies anything on the iPhone.
@MainActor
final class DeviceService: NSObject {
    var onDevicesChanged: (([DeviceInfo]) -> Void)?
    var onStateChanged: ((String, DeviceState) -> Void)?
    var onCatalog: ((String, [DeviceFile]) -> Void)?

    private let browser = ICDeviceBrowser()
    private var cameras: [String: ICCameraDevice] = [:]
    private var files: [String: ICCameraFile] = [:]
    private var rebuildTask: Task<Void, Never>?

    func start() {
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask)!
        browser.start()
    }

    func open(_ id: String) {
        guard let camera = cameras[id] else { return }
        camera.delegate = self
        if camera.hasOpenSession {
            if camera.isAccessRestrictedAppleDevice {
                onStateChanged?(id, .locked)
            } else {
                rebuildCatalog(for: camera, delay: 0)
            }
        } else {
            onStateChanged?(id, .opening)
            camera.requestOpenSession()
        }
    }

    private func id(of device: ICDevice) -> String {
        device.uuidString ?? "\(ObjectIdentifier(device).hashValue)"
    }

    private func publishDevices() {
        let list = cameras.values.map { cam in
            DeviceInfo(id: id(of: cam), name: cam.name ?? "iPhone",
                       isPhone: (cam.productKind ?? "").localizedCaseInsensitiveContains("iphone")
                           || (cam.name ?? "").localizedCaseInsensitiveContains("iphone"))
        }.sorted { $0.name < $1.name }
        onDevicesChanged?(list)
    }

    /// Debounced: the catalog can arrive in many small batches.
    private func rebuildCatalog(for camera: ICCameraDevice, delay: Double = 0.4) {
        let deviceID = id(of: camera)
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled else { return }
            var out: [DeviceFile] = []
            for item in camera.mediaFiles ?? [] {
                guard let file = item as? ICCameraFile, Self.isImage(file) else { continue }
                let fid = "\(deviceID)|\(ObjectIdentifier(file).hashValue)"
                files[fid] = file
                out.append(DeviceFile(
                    id: fid, name: file.name ?? "Untitled",
                    fileSize: Int64(file.fileSize),
                    date: file.exifCreationDate ?? file.creationDate,
                    width: file.width, height: file.height))
            }
            out.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            onCatalog?(deviceID, out)
            onStateChanged?(deviceID, .ready)
        }
    }

    private static func isImage(_ file: ICCameraFile) -> Bool {
        if let uti = file.uti, let type = UTType(uti) { return type.conforms(to: .image) || type.conforms(to: .movie) }
        let ext = ((file.name ?? "") as NSString).pathExtension.lowercased()
        return DiskScanner.imageExtensions.contains(ext) || Media.videoExtensions.contains(ext)
    }

    // MARK: Thumbnails & downloads

    func thumbnail(for fileID: String, maxPixel: Int) async -> NSImage? {
        guard let file = files[fileID] else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: maxPixel]) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data else { return nil }
        return NSImage(data: data)
    }

    /// Downloads a byte-exact copy of the original (full quality, untouched) into `directory` as `filename`.
    /// `overwrite` is false, so an existing file is never replaced.
    func download(_ fileID: String, into directory: URL, as filename: String) async throws -> URL {
        guard let file = files[fileID] else { throw AppError.assetMissing }
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: directory,
            .saveAsFilename: filename,
            .overwrite: false,
        ]
        let saved: String = try await withCheckedThrowingContinuation { continuation in
            _ = file.requestDownload(options: options) { name, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: name ?? filename)
                }
            }
        }
        return directory.appendingPathComponent(saved)
    }
}

// MARK: - Delegates (ImageCaptureCore calls these on the main thread)

extension DeviceService: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        MainActor.assumeIsolated {
            guard let camera = device as? ICCameraDevice else { return }
            cameras[id(of: camera)] = camera
            if !moreComing { publishDevices() }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        MainActor.assumeIsolated {
            let key = id(of: device)
            cameras.removeValue(forKey: key)
            files = files.filter { !$0.key.hasPrefix(key + "|") }
            onStateChanged?(key, .idle)
            if !moreGoing { publishDevices() }
        }
    }
}

extension DeviceService: ICCameraDeviceDelegate {
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        MainActor.assumeIsolated {
            let key = id(of: device)
            if let error {
                onStateChanged?(key, .failed(error.localizedDescription))
            } else if (device as? ICCameraDevice)?.isAccessRestrictedAppleDevice == true {
                onStateChanged?(key, .locked)
            } else {
                onStateChanged?(key, .loading)
            }
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        MainActor.assumeIsolated { onStateChanged?(id(of: device), .idle) }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        MainActor.assumeIsolated {
            let key = id(of: device)
            cameras.removeValue(forKey: key)
            onStateChanged?(key, .idle)
            publishDevices()
        }
    }

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        MainActor.assumeIsolated {
            if device.isAccessRestrictedAppleDevice {
                onStateChanged?(id(of: device), .locked)
            } else {
                rebuildCatalog(for: device, delay: 0)
            }
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        MainActor.assumeIsolated { rebuildCatalog(for: camera) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        MainActor.assumeIsolated { rebuildCatalog(for: camera) }
    }

    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        MainActor.assumeIsolated {
            onStateChanged?(id(of: device), .loading)
            if let camera = device as? ICCameraDevice { rebuildCatalog(for: camera, delay: 1.0) }
        }
    }

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        MainActor.assumeIsolated { onStateChanged?(id(of: device), .locked) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?,
                                  for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
                                  for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
}
