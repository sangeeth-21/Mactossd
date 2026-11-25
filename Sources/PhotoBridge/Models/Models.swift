import Foundation
import SwiftUI

/// An image in the macOS Photos library (lightweight, Sendable snapshot of a PHAsset).
struct PhotoAsset: Identifiable, Hashable, Sendable {
    let id: String          // PHAsset.localIdentifier
    let uuid: String        // first component of localIdentifier, matches ZUUID in Photos.sqlite
    let filename: String    // original filename (e.g. IMG_1234.HEIC)
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool
    let isScreenshot: Bool
    /// Size of the original file in bytes (0 = unknown).
    let fileSize: Int64
    let isVideo: Bool
    let duration: Double

    init(id: String, filename: String, creationDate: Date?, pixelWidth: Int, pixelHeight: Int,
         isFavorite: Bool, isScreenshot: Bool = false, fileSize: Int64 = 0,
         isVideo: Bool = false, duration: Double = 0) {
        self.id = id
        self.uuid = String(id.split(separator: "/").first ?? Substring(id))
        self.filename = filename
        self.creationDate = creationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isFavorite = isFavorite
        self.isScreenshot = isScreenshot
        self.fileSize = fileSize
        self.isVideo = isVideo
        self.duration = duration
    }
}

enum Media {
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp", "3g2", "avi", "mts", "m2ts", "hevc"]
    static func isVideo(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }

    static func duration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// An image file found on the external drive.
struct DiskFile: Identifiable, Hashable, Sendable {
    let url: URL
    let fileSize: Int64
    let modified: Date?
    let captureDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    var duration: Double = 0

    var id: String { url.path }
    var filename: String { url.lastPathComponent }
    var isVideo: Bool { Media.isVideo(url) }
}

enum MatchStatus: Sendable {
    case both, photosOnly, diskOnly

    var filter: CompareFilter {
        switch self {
        case .both: .both
        case .photosOnly: .photosOnly
        case .diskOnly: .diskOnly
        }
    }
}

/// One row of the comparison: a Photos asset, an SSD file, or both when they match.
struct CompareItem: Identifiable, Hashable, Sendable {
    let id: String
    var photo: PhotoAsset?
    var file: DiskFile?

    init(photo: PhotoAsset?, file: DiskFile?) {
        precondition(photo != nil || file != nil)
        self.photo = photo
        self.file = file
        self.id = photo.map { "p:" + $0.id } ?? "d:" + file!.id
    }

    var status: MatchStatus {
        switch (photo != nil, file != nil) {
        case (true, true): .both
        case (true, false): .photosOnly
        default: .diskOnly
        }
    }

    var name: String { photo?.filename ?? file?.filename ?? "" }
    var date: Date? { photo?.creationDate ?? file?.captureDate ?? file?.modified }
    var pixelWidth: Int { photo?.pixelWidth ?? file?.pixelWidth ?? 0 }
    var pixelHeight: Int { photo?.pixelHeight ?? file?.pixelHeight ?? 0 }

    /// Best known size of this image in bytes (the SSD file if present, else the Photos original).
    var byteSize: Int64 { file?.fileSize ?? photo?.fileSize ?? 0 }
    var isVideo: Bool { photo?.isVideo ?? file?.isVideo ?? false }
    var duration: Double { max(photo?.duration ?? 0, file?.duration ?? 0) }
    var fileExtension: String { (name as NSString).pathExtension.uppercased() }

    var canCopyToDisk: Bool { photo != nil && file == nil }
    var canImportToPhotos: Bool { file != nil && photo == nil }
}

enum CompareFilter: String, CaseIterable, Identifiable, Sendable {
    case all, both, photosOnly, diskOnly
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Images"
        case .both: "In Both"
        case .photosOnly: "Only in Photos"
        case .diskOnly: "Only on SSD"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .both: "checkmark.circle.fill"
        case .photosOnly: "photo.on.rectangle.angled"
        case .diskOnly: "externaldrive.fill"
        }
    }

    var tint: Color {
        switch self {
        case .all: .secondary
        case .both: .green
        case .photosOnly: .blue
        case .diskOnly: .purple
        }
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case newest, oldest, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        case .name: "File Name"
        }
    }
}

enum ImageSource: String, Sendable {
    case photos, disk
}

struct Volume: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let capacity: Int64?
    let available: Int64?
    var id: String { url.path }
}

struct Person: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let isNamed: Bool
    let photoCount: Int
    let keyAssetUUID: String?
    /// Normalized face center from Photos (used to pick the right face for the avatar).
    let keyFaceCenter: CGPoint?
}

struct ScanProgress: Equatable {
    var message: String
    var fraction: Double?
}

struct Activity: Equatable {
    var title: String
    var total: Int
    var completed = 0
    var failed = 0
    var fraction: Double { total == 0 ? 0 : Double(completed + failed) / Double(total) }
}

struct DeleteRequest: Identifiable {
    let id = UUID()
    let items: [CompareItem]
    var photoCount: Int { items.filter { $0.photo != nil }.count }
    var fileCount: Int { items.filter { $0.file != nil }.count }
}

enum PeopleState: Equatable {
    case idle, loading, loaded, needsAccess, failed(String)
}

struct Banner: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
}

enum AppError: LocalizedError {
    case assetMissing
    case noResource
    case folderUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .assetMissing: "The photo is no longer in the library."
        case .noResource: "The photo has no original file to export."
        case .folderUnavailable(let p): "The folder \(p) is not available. Is the SSD connected?"
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0 ..< Swift.min($0 + size, count)] }
    }
}

// MARK: - iPhone / camera

struct DeviceInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isPhone: Bool
}

enum DeviceState: Equatable {
    case idle, opening, locked, loading, ready, failed(String)
}

/// A photo on a connected iPhone/camera. Read-only: PhotoBridge never deletes or changes anything on the device.
struct DeviceFile: Identifiable, Hashable, Sendable, Matchable {
    let id: String
    let name: String
    let fileSize: Int64
    let date: Date?
    let width: Int
    let height: Int
    var photoMatchID: String?
    var diskMatchPath: String?

    var inPhotos: Bool { photoMatchID != nil }
    var onDisk: Bool { diskMatchPath != nil }

    var matchName: String { name }
    var matchDate: Date? { date }
    var matchWidth: Int { width }
    var matchHeight: Int { height }
}

enum DeviceFilter: String, CaseIterable, Identifiable {
    case all, notOnDisk, notInPhotos, newEverywhere, backedUp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .notOnDisk: "Not on SSD"
        case .notInPhotos: "Not in Photos"
        case .newEverywhere: "New"
        case .backedUp: "Backed Up"
        }
    }
    var help: String {
        switch self {
        case .all: "Every photo on the iPhone"
        case .notOnDisk: "Photos not yet copied to the SSD"
        case .notInPhotos: "Photos missing from the Mac's Photos library"
        case .newEverywhere: "Photos that are neither in Photos nor on the SSD"
        case .backedUp: "Photos already in Photos and on the SSD"
        }
    }
    func includes(_ f: DeviceFile) -> Bool {
        switch self {
        case .all: true
        case .notOnDisk: !f.onDisk
        case .notInPhotos: !f.inPhotos
        case .newEverywhere: !f.onDisk && !f.inPhotos
        case .backedUp: f.onDisk && f.inPhotos
        }
    }
}

// MARK: - Size summaries (shown in the right-side panel and status bar)

struct SizeBucket: Equatable {
    var count = 0
    var bytes: Int64 = 0
    mutating func add(_ b: Int64) { count += 1; bytes += b }
}

struct SizeSummary: Equatable {
    var total = SizeBucket()
    var both = SizeBucket()
    var photosOnly = SizeBucket()
    var diskOnly = SizeBucket()
    /// Images whose size is not known (counted, but contributing 0 bytes).
    var unknownSize = 0
    var earliest: Date?
    var latest: Date?

    /// Space needed on the SSD to copy the Photos-only images.
    var bytesToCopyToDisk: Int64 { photosOnly.bytes }
    /// Space needed in Photos to import the SSD-only images.
    var bytesToImport: Int64 { diskOnly.bytes }

    static func of<S: Sequence>(_ items: S) -> SizeSummary where S.Element == CompareItem {
        var s = SizeSummary()
        for item in items {
            let size = item.byteSize
            if size == 0 { s.unknownSize += 1 }
            s.total.add(size)
            switch item.status {
            case .both: s.both.add(size)
            case .photosOnly: s.photosOnly.add(size)
            case .diskOnly: s.diskOnly.add(size)
            }
            if let d = item.date {
                if s.earliest.map({ d < $0 }) ?? true { s.earliest = d }
                if s.latest.map({ d > $0 }) ?? true { s.latest = d }
            }
        }
        return s
    }
}

struct DeviceSizeSummary: Equatable {
    var total = SizeBucket()
    var notOnDisk = SizeBucket()
    var notInPhotos = SizeBucket()

    static func of<S: Sequence>(_ files: S) -> DeviceSizeSummary where S.Element == DeviceFile {
        var s = DeviceSizeSummary()
        for f in files {
            s.total.add(f.fileSize)
            if !f.onDisk { s.notOnDisk.add(f.fileSize) }
            if !f.inPhotos { s.notInPhotos.add(f.fileSize) }
        }
        return s
    }
}

extension Format {
    static func dateRange(_ a: Date?, _ b: Date?) -> String {
        guard let a, let b else { return "—" }
        let fa = a.formatted(date: .abbreviated, time: .omitted)
        let fb = b.formatted(date: .abbreviated, time: .omitted)
        return fa == fb ? fa : "\(fa) – \(fb)"
    }
}

// MARK: - Media type filter & library diagnostics

enum MediaFilter: String, CaseIterable, Identifiable {
    case all, photos, videos
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Photos & Videos"
        case .photos: "Photos Only"
        case .videos: "Videos Only"
        }
    }
    var systemImage: String {
        switch self {
        case .all: "photo.stack"
        case .photos: "photo"
        case .videos: "video"
        }
    }
    func includes(_ item: CompareItem) -> Bool {
        switch self {
        case .all: true
        case .photos: !item.isVideo
        case .videos: item.isVideo
        }
    }
}

/// What PhotoKit reports about the library, so counts can be compared with the Photos app.
struct LibraryStats: Equatable, Sendable {
    var photos = 0
    var videos = 0
    var hidden = 0
    var burstExtras = 0
    var limitedAccess = false
    var total: Int { photos + videos }
}
