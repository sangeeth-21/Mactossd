import AppKit
import Foundation

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PhotoBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func file(_ name: String) -> URL { support.appendingPathComponent(name) }

    static func clearCaches() {
        for name in ["photo-meta.plist", "disk-metadata.plist", "junk-analysis.plist"] {
            try? FileManager.default.removeItem(at: file(name))
        }
    }
}

/// Small binary-plist persistence helper for caches.
enum PlistStore {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        if let data = try? enc.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Thread-safe mutable box.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&_value)
    }
}

enum FileUtils {
    private static let reserved = Locked(Set<String>())

    /// Returns a URL in `folder` that does not exist yet ("name (1).ext" style) and reserves it,
    /// so concurrent exports never pick the same name.
    static func reserveUniqueURL(in folder: URL, filename: String) -> URL {
        let ns = filename as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        return reserved.mutate { set in
            var candidate = folder.appendingPathComponent(filename)
            var n = 1
            while set.contains(candidate.path) || FileManager.default.fileExists(atPath: candidate.path) {
                let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
                candidate = folder.appendingPathComponent(name)
                n += 1
            }
            set.insert(candidate.path)
            return candidate
        }
    }

    static func release(_ url: URL) {
        reserved.mutate { _ = $0.remove(url.path) }
    }

    static func dateFolder(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        let y = c.year ?? 0, m = c.month ?? 0
        return String(format: "%04d/%04d-%02d", y, y, m)
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func date(_ d: Date?) -> String {
        guard let d else { return "Unknown date" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    static func dimensions(_ w: Int, _ h: Int) -> String {
        guard w > 0, h > 0 else { return "—" }
        let mp = Double(w * h) / 1_000_000
        return "\(w) × \(h)  (\(String(format: "%.1f", mp)) MP)"
    }
}

/// Shared output buffer for `DispatchQueue.concurrentPerform`; each iteration writes distinct indices.
struct UnsafeSendablePointer<T>: @unchecked Sendable {
    let base: UnsafeMutablePointer<T>
}

// NSImage instances are never mutated after creation in this app, so sharing them across tasks is safe.
extension NSImage: @retroactive @unchecked Sendable {}
