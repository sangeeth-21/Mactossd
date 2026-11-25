import Foundation

/// Pairs Photos assets with SSD files in O(n) using hash indexes.
///
/// SAFETY RULE: a pair is only made when the evidence agrees. A doubtful pair is left unmatched
/// (shown as "Only in Photos" + "Only on SSD"), never matched wrongly. A wrong match could make a photo
/// look backed up when it isn't, so the matcher is deliberately conservative:
///
/// 1. Same file name stem (case-insensitive, ignoring extension and " (1)" copy suffixes — so
///    `IMG_1234.HEIC` in Photos matches `IMG_1234.jpg` on disk), AND
///    - no contradiction: pixel sizes must agree (unless capture times agree to the second, e.g. a
///      cropped edit), and capture times must agree when both are known (allowing whole time-zone
///      offsets, since EXIF dates often lack a zone), AND
///    - at least one positive confirmation: equal pixel size or agreeing capture time.
///    iPhones reuse names (IMG_0001 every 10,000 shots), so name + size alone is not enough when dates disagree.
/// 2. Renamed files: identical capture second AND identical pixel size, and only when exactly one
///    candidate exists (burst shots share the same second, so ambiguity means no match).
enum Matcher {
    static func match(photos: [PhotoAsset], files: [DiskFile]) async -> [CompareItem] {
        var byStem: [String: [Int]] = [:]
        byStem.reserveCapacity(photos.count)
        var byMoment: [String: [Int]] = [:]
        for (i, p) in photos.enumerated() {
            byStem[stem(p.filename), default: []].append(i)
            if let k = momentKey(p.creationDate, p.pixelWidth, p.pixelHeight) {
                byMoment[k, default: []].append(i)
            }
        }
        var filesPerMoment: [String: Int] = [:]
        for f in files {
            if let k = momentKey(f.captureDate, f.pixelWidth, f.pixelHeight) { filesPerMoment[k, default: 0] += 1 }
        }

        var used = [Bool](repeating: false, count: photos.count)
        var items: [CompareItem] = []
        items.reserveCapacity(photos.count + files.count)

        for file in files {
            var chosen: Int?
            if let candidates = byStem[stem(file.filename)] {
                chosen = best(candidates, for: file, photos: photos, used: used)
            }
            if chosen == nil, let k = momentKey(file.captureDate, file.pixelWidth, file.pixelHeight),
               filesPerMoment[k] == 1, let candidates = byMoment[k] {
                let free = candidates.filter { !used[$0] }
                if free.count == 1, candidates.count == 1 { chosen = free[0] }
            }
            if let c = chosen {
                used[c] = true
                items.append(CompareItem(photo: photos[c], file: file))
            } else {
                items.append(CompareItem(photo: nil, file: file))
            }
        }
        for (i, p) in photos.enumerated() where !used[i] {
            items.append(CompareItem(photo: p, file: nil))
        }
        return items
    }

    enum DateAgreement { case unknown, exact, zoneShift, conflict }

    static func compareDates(_ a: Date?, _ b: Date?) -> DateAgreement {
        guard let a, let b else { return .unknown }
        let d = abs(a.timeIntervalSince(b))
        if d <= 2 { return .exact }
        // EXIF dates without a zone are read in local time: allow whole quarter-hour offsets up to 14 h.
        if d <= 14 * 3600 + 2 {
            let r = d.truncatingRemainder(dividingBy: 900)
            if r <= 2 || r >= 898 { return .zoneShift }
        }
        return .conflict
    }

    static func isConfirmedMatch(_ p: some Matchable, _ f: some Matchable) -> Bool {
        let dims: Bool? = (p.matchWidth > 0 && f.matchWidth > 0)
            ? sameDimensions(p.matchWidth, p.matchHeight, f.matchWidth, f.matchHeight) : nil
        let dates = compareDates(p.matchDate, f.matchDate)
        if dates == .conflict { return false }                       // different moment = different photo
        if dims == false && dates != .exact { return false }         // different size, not provably same shot
        return dims == true || dates == .exact || dates == .zoneShift // need positive evidence
    }

    private static func best(_ candidates: [Int], for file: DiskFile, photos: [PhotoAsset], used: [Bool]) -> Int? {
        var bestIndex: Int?
        var bestScore = Double.greatestFiniteMagnitude
        for i in candidates where !used[i] {
            let p = photos[i]
            guard isConfirmedMatch(p, file) else { continue }
            let dimsEqual = p.pixelWidth > 0 && file.pixelWidth > 0
                && sameDimensions(p.pixelWidth, p.pixelHeight, file.pixelWidth, file.pixelHeight)
            var delta = 1e9
            if let a = p.creationDate, let b = file.captureDate { delta = abs(a.timeIntervalSince(b)) }
            let score = (dimsEqual ? 0 : 1e10) + delta
            if score < bestScore {
                bestScore = score
                bestIndex = i
            }
        }
        return bestIndex
    }

    static func stem(_ filename: String) -> String {
        var s = (filename as NSString).deletingPathExtension.lowercased()
        if s.hasSuffix(")"), let r = s.range(of: #" \(\d+\)$"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s
    }

    private static func sameDimensions(_ w1: Int, _ h1: Int, _ w2: Int, _ h2: Int) -> Bool {
        (max(w1, h1), min(w1, h1)) == (max(w2, h2), min(w2, h2))
    }

    static func momentKey(_ date: Date?, _ w: Int, _ h: Int) -> String? {
        guard let date, w > 0, h > 0 else { return nil }
        return "\(Int(date.timeIntervalSince1970))|\(max(w, h))x\(min(w, h))"
    }
}

/// Anything that can be compared: Photos assets, SSD files and iPhone files.
protocol Matchable {
    var matchName: String { get }
    var matchDate: Date? { get }
    var matchWidth: Int { get }
    var matchHeight: Int { get }
}

extension PhotoAsset: Matchable {
    var matchName: String { filename }
    var matchDate: Date? { creationDate }
    var matchWidth: Int { pixelWidth }
    var matchHeight: Int { pixelHeight }
}

extension DiskFile: Matchable {
    var matchName: String { filename }
    var matchDate: Date? { captureDate }
    var matchWidth: Int { pixelWidth }
    var matchHeight: Int { pixelHeight }
}

/// Hash index for fast "is this already there?" lookups, using the same strict rules as `Matcher`.
struct MatchIndex<T: Matchable> {
    private let items: [T]
    private var byStem: [String: [Int]] = [:]
    private var byMoment: [String: [Int]] = [:]

    init(_ items: [T]) {
        self.items = items
        for (i, item) in items.enumerated() {
            byStem[Matcher.stem(item.matchName), default: []].append(i)
            if let k = Matcher.momentKey(item.matchDate, item.matchWidth, item.matchHeight) {
                byMoment[k, default: []].append(i)
            }
        }
    }

    func find(_ x: some Matchable) -> T? {
        if let candidates = byStem[Matcher.stem(x.matchName)] {
            for i in candidates where Matcher.isConfirmedMatch(items[i], x) { return items[i] }
        }
        // Renamed copy: identical second + size, only when unambiguous.
        if let k = Matcher.momentKey(x.matchDate, x.matchWidth, x.matchHeight),
           let candidates = byMoment[k], candidates.count == 1 {
            return items[candidates[0]]
        }
        return nil
    }
}
