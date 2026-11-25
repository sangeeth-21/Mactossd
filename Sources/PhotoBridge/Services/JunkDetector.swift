import AppKit
import ImageIO
import SwiftUI
import Vision

/// Categories of images people usually don't want to keep.
enum JunkCategory: String, CaseIterable, Identifiable, Sendable {
    case duplicates, screenshots, documents, messaging, lowQuality
    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshots: "Screenshots"
        case .documents: "Bills & Documents"
        case .messaging: "Chat & Forwarded"
        case .lowQuality: "Blurry & Low Quality"
        case .duplicates: "Duplicates"
        }
    }

    var detail: String {
        switch self {
        case .screenshots: "Phone and Mac screen captures"
        case .documents: "Receipts, bills, papers, notes"
        case .messaging: "WhatsApp, Telegram & saved images"
        case .lowQuality: "Dark, blurry or accidental shots"
        case .duplicates: "Same photo saved more than once"
        }
    }

    var systemImage: String {
        switch self {
        case .screenshots: "iphone.gen3"
        case .documents: "doc.text.fill"
        case .messaging: "bubble.left.and.bubble.right.fill"
        case .lowQuality: "camera.metering.unknown"
        case .duplicates: "square.on.square.fill"
        }
    }

    var tint: Color {
        switch self {
        case .screenshots: .teal
        case .documents: .orange
        case .messaging: .green
        case .lowQuality: .pink
        case .duplicates: .yellow
        }
    }

    var flag: JunkFlags {
        switch self {
        case .screenshots: .screenshot
        case .documents: .document
        case .messaging: .messaging
        case .lowQuality: .lowQuality
        case .duplicates: .duplicate
        }
    }

    /// Needs the on-device image analysis pass (the others come from metadata instantly).
    var needsAnalysis: Bool { self == .documents || self == .lowQuality }
}

struct JunkFlags: OptionSet, Hashable, Sendable, Codable {
    let rawValue: UInt8
    static let screenshot = JunkFlags(rawValue: 1 << 0)
    static let document = JunkFlags(rawValue: 1 << 1)
    static let messaging = JunkFlags(rawValue: 1 << 2)
    static let lowQuality = JunkFlags(rawValue: 1 << 3)
    static let duplicate = JunkFlags(rawValue: 1 << 4)   // computed, never cached
    static let analyzed = JunkFlags(rawValue: 1 << 7)
}

enum JunkDetector {
    // MARK: Instant (metadata / file name)

    private static let screenshotNames = ["screenshot", "screen shot", "screen_shot", "screencapture", "scr_", "snip_"]
    private static let messagingPatterns: [NSRegularExpression] = [
        #"^(img|vid|pxl)-\d{8}-wa\d+"#,          // WhatsApp Android: IMG-20240101-WA0001
        #"^whatsapp image"#,                      // WhatsApp iOS / desktop
        #"^photo_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}"#, // Telegram desktop
        #"^telegram"#, #"^signal-\d{4}"#, #"^received_\d+"#, #"^fb_img_\d+"#,
        #"^snapchat-\d+"#, #"^messenger_creation"#, #"^inshot_"#, #"^image_\d{6,}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func metadataFlags(for item: CompareItem) -> JunkFlags {
        var flags: JunkFlags = []
        if item.photo?.isScreenshot == true { flags.insert(.screenshot) }
        let names = [item.photo?.filename, item.file?.filename].compactMap { $0?.lowercased() }
        for name in names {
            if screenshotNames.contains(where: name.contains) { flags.insert(.screenshot) }
            let range = NSRange(name.startIndex..., in: name)
            if messagingPatterns.contains(where: { $0.firstMatch(in: name, range: range) != nil }) {
                flags.insert(.messaging)
            }
        }
        // Tall PNG with no capture date on the SSD = almost always a phone screenshot.
        if let f = item.file, item.photo == nil, f.url.pathExtension.lowercased() == "png",
           f.captureDate == nil, f.pixelWidth > 0, Double(f.pixelHeight) / Double(f.pixelWidth) > 1.9 {
            flags.insert(.screenshot)
        }
        return flags
    }

    // MARK: On-device Vision analysis

    private static let documentLabels: Set<String> = [
        "document", "receipt", "printed_page", "handwriting", "whiteboard", "checkbook",
        "credit_card", "gift_card", "ticket", "newspaper", "envelope", "flipchart", "diagram", "chart",
    ]

    /// Classifies a small thumbnail. ~10–50 ms per image on Apple silicon (Neural Engine).
    static func analyze(_ image: CGImage) -> JunkFlags {
        var flags: JunkFlags = [.analyzed]
        let classify = VNClassifyImageRequest()
        var requests: [VNRequest] = [classify]
        var aesthetics: VNRequest?
        if #available(macOS 15.0, *) {
            let r = VNCalculateImageAestheticsScoresRequest()
            aesthetics = r
            requests.append(r)
        }
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform(requests)
        } catch {
            return flags
        }

        for obs in classify.results ?? [] where obs.confidence >= 0.35 {
            if documentLabels.contains(obs.identifier) { flags.insert(.document) }
            if obs.identifier == "screenshot" && obs.confidence >= 0.6 { flags.insert(.screenshot) }
        }
        if #available(macOS 15.0, *), let r = aesthetics as? VNCalculateImageAestheticsScoresRequest,
           let obs = r.results?.first {
            if obs.isUtility && !flags.contains(.screenshot) { flags.insert(.document) }
            if !obs.isUtility && obs.overallScore < -0.45 { flags.insert(.lowQuality) }
        }
        return flags
    }

    static func diskThumbnail(_ url: URL, maxPixel: Int = 360) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Key used for caching analysis results; the same image matched in both places is analyzed once.
    static func analysisKey(for item: CompareItem) -> String {
        if let p = item.photo { return "p:" + p.id }
        if let f = item.file { return "d:\(f.url.path)|\(f.fileSize)" }
        return item.id
    }

    // MARK: Cache

    private static let cacheURL = AppPaths.file("junk-analysis.plist")
    static func loadCache() -> [String: UInt8] { PlistStore.load([String: UInt8].self, from: cacheURL) ?? [:] }
    static func saveCache(_ cache: [String: UInt8]) { PlistStore.save(cache, to: cacheURL) }
}
