import AVKit
import SwiftUI

/// Large viewer. When an image exists in both places, the Photos and SSD versions are shown side by side.
struct ViewerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var currentID: String
    @FocusState private var focused: Bool

    init(itemID: String) {
        _currentID = State(initialValue: itemID)
    }

    var body: some View {
        let item = model.item(withID: currentID)
        VStack(spacing: 0) {
            header(item)
            Divider()
            if let item {
                HStack(spacing: 0) {
                    if item.photo != nil { ViewerPane(item: item, source: .photos) }
                    if item.photo != nil && item.file != nil { Divider() }
                    if item.file != nil { ViewerPane(item: item, source: .disk) }
                }
            } else {
                ContentUnavailableView("Image Unavailable", systemImage: "photo")
            }
            Divider()
            footer(item)
        }
        .frame(minWidth: 920, idealWidth: 1200, minHeight: 640, idealHeight: 820)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.space) { dismiss(); return .handled }
        .onAppear { focused = true }
    }

    private func header(_ item: CompareItem?) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 18) }
                    .disabled(model.neighbor(of: currentID, offset: -1) == nil)
                Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 18) }
                    .disabled(model.neighbor(of: currentID, offset: 1) == nil)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item?.name ?? "").font(.headline).lineLimit(1)
                Text(meta(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let item { StatusPill(status: item.status) }
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func footer(_ item: CompareItem?) -> some View {
        HStack(spacing: 10) {
            if let item {
                if item.canCopyToDisk {
                    Button { model.copyToDisk([item]) } label: {
                        Label("Copy to SSD", systemImage: "externaldrive.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.activity != nil)
                }
                if item.canImportToPhotos {
                    Button { model.importToPhotos([item]) } label: {
                        Label("Add to Photos", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.activity != nil)
                }
                if item.file != nil {
                    Button("Reveal in Finder") { model.reveal([item]) }
                }
                let names = model.peopleNames(for: item)
                if !names.isEmpty {
                    Label(names.joined(separator: ", "), systemImage: "person.2")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text("← → to browse · Space or Esc to close")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func meta(_ item: CompareItem?) -> String {
        guard let item else { return "" }
        var parts = [Format.date(item.date)]
        if item.pixelWidth > 0 { parts.append("\(item.pixelWidth) × \(item.pixelHeight)") }
        if let size = item.file?.fileSize { parts.append(Format.bytes(size)) }
        return parts.joined(separator: " · ")
    }

    private func step(_ offset: Int) {
        guard let next = model.neighbor(of: currentID, offset: offset) else { return }
        currentID = next
        model.selection = [next]
    }
}

private struct ViewerPane: View {
    let item: CompareItem
    let source: ImageSource
    @State private var image: NSImage?
    @State private var loading = true
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(source == .photos ? "Photos Library" : "SSD",
                      systemImage: source == .photos ? "photo.on.rectangle.angled" : "externaldrive.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(source == .photos ? .blue : .purple)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ZStack {
                Color.black.opacity(0.9)
                if let player {
                    VideoPlayer(player: player)
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(10)
                }
                if loading {
                    ProgressView().controlSize(.small).tint(.white)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(item.id)|\(source.rawValue)") {
            player?.pause()
            player = nil
            loading = true
            image = ThumbnailLoader.cached(for: item, prefer: source, pixelSize: 512)
            if image == nil, let small = await ThumbnailLoader.image(for: item, prefer: source, pixelSize: 512) {
                image = small
            }
            if item.isVideo {
                // Videos play inline (press play). Both copies can be compared side by side.
                switch source {
                case .photos:
                    if let id = item.photo?.id, let playerItem = await PhotoLibraryService.shared.playerItem(for: id) {
                        player = AVPlayer(playerItem: playerItem)
                    }
                case .disk:
                    if let url = item.file?.url { player = AVPlayer(url: url) }
                }
            } else if let big = await ThumbnailLoader.image(for: item, prefer: source, pixelSize: 2560, highQuality: true) {
                image = big
            }
            loading = false
        }
        .onDisappear { player?.pause() }
    }

    private var detail: String {
        switch source {
        case .photos:
            guard let p = item.photo else { return "" }
            let length = p.isVideo ? " · " + Media.duration(p.duration) : ""
            return "\(p.pixelWidth) × \(p.pixelHeight)\(length)"
        case .disk:
            return item.file?.url.path ?? ""
        }
    }
}
