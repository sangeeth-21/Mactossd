import CoreGraphics
import CryptoKit
import Foundation

enum DuplicateReason: Int, Comparable, Sendable {
    case lookalike = 0, sameShot = 1, exactCopy = 2
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .exactCopy: "Exact copies"
        case .sameShot: "Same photo saved twice"
        case .lookalike: "Look-alike copies"
        }
    }

    var detail: String {
        switch self {
        case .exactCopy: "The files are byte-for-byte identical (SHA-256 checksum)."
        case .sameShot: "Same name, same capture second and same size."
        case .lookalike: "Taken in the same second at the same size and visually identical."
        }
    }
}

struct DuplicateGroup: Identifiable, Sendable {
    let id: Int
    var itemIDs: [String]
    let reason: DuplicateReason
}

/// Finds duplicate images among comparison items.
///
/// SAFETY: duplicates become delete candidates, so a group is only formed on strong evidence. When in
/// doubt, images are NOT grouped (a missed duplicate is harmless, a wrongly flagged unique photo is not):
/// - Exact copy: SSD files with identical size + pixel size AND identical SHA-256 checksum.
/// - Same shot: identical capture second + pixel size + same base file name (e.g. imported twice, "IMG_1 (1).jpg").
/// - Look-alike: identical capture second + pixel size, different names, and an almost identical
///   perceptual hash. Large same-second groups (bursts) are skipped entirely.
enum DuplicateFinder {
    static let lookalikeMaxDistance = 6       // out of 256 bits; recompressed copies are ~0–5
    private static let maxBurstBucket = 6

    static func find(items: [CompareItem], progress: @escaping @Sendable (Double) -> Void) async -> [DuplicateGroup] {
        let n = items.count
        guard n > 1 else { return [] }
        var uf = UnionFind(n)
        var reasonAt = [Int: DuplicateReason]()   // strongest reason per union, keyed later by root

        func join(_ a: Int, _ b: Int, _ r: DuplicateReason) {
            let ra = uf.find(a), rb = uf.find(b)
            let merged = max(r, max(reasonAt[ra] ?? r, reasonAt[rb] ?? r))
            uf.union(a, b)
            reasonAt[uf.find(a)] = merged
        }

        // 1. Same moment (second + pixel size) buckets.
        var byMoment: [String: [Int]] = [:]
        for (i, item) in items.enumerated() {
            let date = item.photo?.creationDate ?? item.file?.captureDate
            if let k = Matcher.momentKey(date, item.pixelWidth, item.pixelHeight) { byMoment[k, default: []].append(i) }
        }
        var lookalikeBuckets: [[Int]] = []
        for bucket in byMoment.values where bucket.count > 1 {
            var byStem: [String: [Int]] = [:]
            for i in bucket { byStem[Matcher.stem(items[i].name), default: []].append(i) }
            for same in byStem.values where same.count > 1 {
                for j in same.dropFirst() { join(same[0], j, .sameShot) }
            }
            if byStem.count > 1 && bucket.count <= maxBurstBucket { lookalikeBuckets.append(bucket) }
        }

        // 2. SSD files with the same byte size and pixel size → checksum.
        var bySize: [String: [Int]] = [:]
        for (i, item) in items.enumerated() {
            guard let f = item.file, f.fileSize > 0 else { continue }
            bySize["\(f.fileSize)|\(f.pixelWidth)x\(f.pixelHeight)", default: []].append(i)
        }
        let sizeBuckets = bySize.values.filter { $0.count > 1 }

        let totalWork = Double(max(1, sizeBuckets.count + lookalikeBuckets.count))
        var done = 0.0

        for bucket in sizeBuckets {
            if Task.isCancelled { return [] }
            var byHash: [String: [Int]] = [:]
            for i in bucket {
                if let url = items[i].file?.url, let h = sha256(url) { byHash[h, default: []].append(i) }
            }
            for same in byHash.values where same.count > 1 {
                for j in same.dropFirst() { join(same[0], j, .exactCopy) }
            }
            done += 1
            progress(done / totalWork)
        }

        // 3. Look-alikes inside small same-second buckets.
        for bucket in lookalikeBuckets {
            if Task.isCancelled { return [] }
            var hashes: [(Int, [UInt64])] = []
            for i in bucket {
                if let img = await thumbnail(items[i]) { hashes.append((i, dHash(img))) }
            }
            for a in 0 ..< hashes.count {
                for b in (a + 1) ..< hashes.count where hamming(hashes[a].1, hashes[b].1) <= lookalikeMaxDistance {
                    join(hashes[a].0, hashes[b].0, .lookalike)
                }
            }
            done += 1
            progress(done / totalWork)
        }

        // Collect groups.
        var members: [Int: [Int]] = [:]
        for i in 0 ..< n { members[uf.find(i), default: []].append(i) }
        var groups: [DuplicateGroup] = []
        for (root, list) in members where list.count > 1 {
            let ids = list
                .sorted { (items[$0].date ?? .distantPast) < (items[$1].date ?? .distantPast) }
                .map { items[$0].id }
            groups.append(DuplicateGroup(id: groups.count, itemIDs: ids, reason: reasonAt[root] ?? .lookalike))
        }
        return groups.sorted { $0.itemIDs.count > $1.itemIDs.count }
            .enumerated().map { DuplicateGroup(id: $0.offset, itemIDs: $0.element.itemIDs, reason: $0.element.reason) }
    }

    // MARK: Helpers

    private static func thumbnail(_ item: CompareItem) async -> CGImage? {
        if let photo = item.photo { return await PhotoLibraryService.shared.analysisImage(for: photo.id, maxPixel: 256) }
        if let file = item.file { return await ThumbnailLoader.diskCGImage(file.url, maxPixel: 256) }
        return nil
    }

    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { try? handle.read(upToCount: 4 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 256-bit gradient hash on a 17×16 grayscale downsample.
    static func dHash(_ image: CGImage) -> [UInt64] {
        let w = 17, h = 16
        var px = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var bits = [UInt64](repeating: 0, count: 4)
        for y in 0 ..< h {
            for x in 0 ..< 16 where px[y * w + x] > px[y * w + x + 1] {
                let i = y * 16 + x
                bits[i / 64] |= 1 << UInt64(i % 64)
            }
        }
        return bits
    }

    static func hamming(_ a: [UInt64], _ b: [UInt64]) -> Int {
        zip(a, b).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
    }
}

private struct UnionFind {
    private var parent: [Int]
    init(_ n: Int) { parent = Array(0 ..< n) }
    mutating func find(_ x: Int) -> Int {
        var r = x
        while parent[r] != r { r = parent[r] }
        var c = x
        while parent[c] != r { let next = parent[c]; parent[c] = r; c = next }
        return r
    }
    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[rb] = ra }
    }
}
