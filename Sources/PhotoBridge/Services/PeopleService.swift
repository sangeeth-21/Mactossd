import AppKit
import Foundation
import SQLite3
import Vision

/// Reads the People (faces) that the Photos app has recognized.
///
/// PhotoKit has no public API for People, so this reads a *temporary copy* of the library's
/// Photos.sqlite database (the real library is never opened or modified). That requires
/// Full Disk Access for PhotoBridge. The schema is detected at runtime to support several macOS versions.
enum PeopleService {
    struct Index: Sendable {
        var people: [Person]
        var assetsByPerson: [Int64: Set<String>]   // person id -> asset UUIDs
    }

    enum PeopleError: LocalizedError {
        case libraryNotFound(String)
        case noAccess
        case database(String)

        var errorDescription: String? {
            switch self {
            case .libraryNotFound(let p): "No Photos library found at \(p)."
            case .noAccess: "PhotoBridge needs Full Disk Access to read People from Photos."
            case .database(let m): "Couldn't read People: \(m)"
            }
        }
    }

    static var defaultLibraryPath: String {
        if let p = UserDefaults(suiteName: "com.apple.photolibraryd")?.string(forKey: "SystemLibraryPath"),
           FileManager.default.fileExists(atPath: p) {
            return p
        }
        return NSHomeDirectory() + "/Pictures/Photos Library.photoslibrary"
    }

    static func fullDiskAccessSettingsURL() -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    }

    static func load(libraryURL: URL, includeUnnamed: Bool) async throws -> Index {
        try loadSync(libraryURL: libraryURL, includeUnnamed: includeUnnamed)
    }

    private static func loadSync(libraryURL: URL, includeUnnamed: Bool) throws -> Index {
        let fm = FileManager.default
        guard fm.fileExists(atPath: libraryURL.path) else { throw PeopleError.libraryNotFound(libraryURL.path) }
        let dbURL = libraryURL.appendingPathComponent("database/Photos.sqlite")

        let tmp = fm.temporaryDirectory.appendingPathComponent("PhotoBridge-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let local = tmp.appendingPathComponent("Photos.sqlite")
        do {
            try fm.copyItem(at: dbURL, to: local)
        } catch {
            throw PeopleError.noAccess   // TCC blocks reading inside the library without Full Disk Access
        }
        for suffix in ["-wal", "-shm"] {
            try? fm.copyItem(atPath: dbURL.path + suffix, toPath: local.path + suffix)
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(local.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            throw PeopleError.database("could not open database copy")
        }
        defer { sqlite3_close(db) }

        let tables = Set(try strings(db, "SELECT name FROM sqlite_master WHERE type='table'"))
        guard let assetTable = ["ZASSET", "ZGENERICASSET"].first(where: tables.contains),
              tables.contains("ZPERSON"), tables.contains("ZDETECTEDFACE")
        else { throw PeopleError.database("unsupported Photos library format") }

        let faceCols = Set(try strings(db, "SELECT name FROM pragma_table_info('ZDETECTEDFACE')"))
        let personCols = Set(try strings(db, "SELECT name FROM pragma_table_info('ZPERSON')"))
        let assetCols = Set(try strings(db, "SELECT name FROM pragma_table_info('\(assetTable)')"))

        let facePerson = faceCols.contains("ZPERSONFORFACE") ? "ZPERSONFORFACE" : "ZPERSON"
        let faceAsset = faceCols.contains("ZASSETFORFACE") ? "ZASSETFORFACE" : "ZASSET"
        guard faceCols.contains(facePerson), faceCols.contains(faceAsset), assetCols.contains("ZUUID") else {
            throw PeopleError.database("unsupported face table format")
        }

        // 1. person -> assets
        var assetFilter = ""
        if assetCols.contains("ZTRASHEDSTATE") { assetFilter += " AND a.ZTRASHEDSTATE = 0" }
        if faceCols.contains("ZHIDDEN") { assetFilter += " AND f.ZHIDDEN = 0" }
        let mapSQL = """
            SELECT f.\(facePerson), a.ZUUID FROM ZDETECTEDFACE f
            JOIN \(assetTable) a ON a.Z_PK = f.\(faceAsset)
            WHERE f.\(facePerson) IS NOT NULL\(assetFilter)
            """
        var map: [Int64: Set<String>] = [:]
        try query(db, mapSQL) { stmt in
            if let uuid = text(stmt, 1) { map[sqlite3_column_int64(stmt, 0), default: []].insert(uuid) }
        }

        // 2. people
        let full = personCols.contains("ZFULLNAME") ? "p.ZFULLNAME" : "NULL"
        let display = personCols.contains("ZDISPLAYNAME") ? "p.ZDISPLAYNAME" : "NULL"
        var whereClause = "1=1"
        if personCols.contains("ZMERGETARGETPERSON") { whereClause += " AND p.ZMERGETARGETPERSON IS NULL" }

        let hasKeyFace = personCols.contains("ZKEYFACE")
        let hasCenter = faceCols.contains("ZCENTERX") && faceCols.contains("ZCENTERY")
        let keyJoin = hasKeyFace
            ? "LEFT JOIN ZDETECTEDFACE kf ON kf.Z_PK = p.ZKEYFACE LEFT JOIN \(assetTable) ka ON ka.Z_PK = kf.\(faceAsset)"
            : ""
        let keyCols = hasKeyFace
            ? (hasCenter ? "kf.ZCENTERX, kf.ZCENTERY, ka.ZUUID" : "NULL, NULL, ka.ZUUID")
            : "NULL, NULL, NULL"
        let peopleSQL = "SELECT p.Z_PK, \(full), \(display), \(keyCols) FROM ZPERSON p \(keyJoin) WHERE \(whereClause)"

        var people: [Person] = []
        try query(db, peopleSQL) { stmt in
            let pid = sqlite3_column_int64(stmt, 0)
            guard let assets = map[pid], !assets.isEmpty else { return }
            let name = [text(stmt, 1), text(stmt, 2)]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            if name == nil && (!includeUnnamed || assets.count < 3) { return }
            var center: CGPoint?
            if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
                center = CGPoint(x: sqlite3_column_double(stmt, 3), y: sqlite3_column_double(stmt, 4))
            }
            people.append(Person(id: pid, name: name ?? "Unnamed Person", isNamed: name != nil,
                                 photoCount: assets.count, keyAssetUUID: text(stmt, 5), keyFaceCenter: center))
        }

        people.sort {
            if $0.isNamed != $1.isNamed { return $0.isNamed }
            if $0.isNamed { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return $0.photoCount > $1.photoCount
        }
        let kept = Set(people.map(\.id))
        return Index(people: people, assetsByPerson: map.filter { kept.contains($0.key) })
    }

    // MARK: SQLite helpers

    private static func query(_ db: OpaquePointer, _ sql: String, row: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw PeopleError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private static func strings(_ db: OpaquePointer, _ sql: String) throws -> [String] {
        var out: [String] = []
        try query(db, sql) { if let s = text($0, 0) { out.append(s) } }
        return out
    }

    private static func text(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    // MARK: Avatar

    /// Finds the person's face in an image with Vision and returns a square crop around it.
    static func faceCrop(_ image: NSImage, hint: CGPoint?) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        guard let faces = request.results, !faces.isEmpty else { return nil }

        let chosen: VNFaceObservation
        if let h = hint {
            // Photos' center Y convention varies; accept either orientation and take the closest face.
            func distance(_ f: VNFaceObservation) -> CGFloat {
                let c = CGPoint(x: f.boundingBox.midX, y: f.boundingBox.midY)
                return min(hypot(c.x - h.x, c.y - h.y), hypot(c.x - h.x, c.y - (1 - h.y)))
            }
            chosen = faces.min { distance($0) < distance($1) }!
        } else {
            chosen = faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }!
        }

        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let box = chosen.boundingBox
        let side = max(box.width * w, box.height * h) * 1.9
        let cx = box.midX * w
        let cy = (1 - box.midY) * h          // Vision is bottom-left origin, CGImage is top-left
        let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard rect.width > 8, let cropped = cg.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}
