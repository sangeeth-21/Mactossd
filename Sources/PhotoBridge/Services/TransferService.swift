import Foundation

/// Off-main-actor transfer work used by AppModel.
enum TransferService {
    /// Exports the Photos original for `item` into `root` (optionally into YYYY/YYYY-MM subfolders).
    static func exportToDisk(_ item: CompareItem, root: URL, organizeByDate: Bool) async -> (String, Result<DiskFile, Error>) {
        guard let photo = item.photo else { return (item.id, .failure(AppError.assetMissing)) }
        var folder = root
        if organizeByDate, let date = photo.creationDate {
            folder = root.appendingPathComponent(FileUtils.dateFolder(for: date), isDirectory: true)
        }
        do {
            let url = try await PhotoLibraryService.shared.exportOriginal(id: photo.id, to: folder)
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            let meta = DiskScanner.readMetadata(url)
            let file = DiskFile(
                url: url, fileSize: size, modified: photo.creationDate,
                captureDate: meta.date ?? photo.creationDate,
                pixelWidth: meta.width > 0 ? meta.width : photo.pixelWidth,
                pixelHeight: meta.height > 0 ? meta.height : photo.pixelHeight,
                duration: photo.duration)
            return (item.id, .success(file))
        } catch {
            return (item.id, .failure(error))
        }
    }
}
