import SwiftUI

struct PhotoGridView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        let size = model.thumbnailSize
        let columns = [GridItem(.adaptive(minimum: size, maximum: size * 1.45), spacing: 12)]
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.visibleItems) { item in
                    ThumbnailCell(item: item, size: size, isSelected: model.selection.contains(item.id),
                                  selectMode: model.selectMode,
                                  copies: model.duplicateGroup(for: item)?.itemIDs.count ?? 0)
                        .onTapGesture { model.handleClick(on: item); focused = true }
                        .onDrag { model.dragProvider(for: item) }
                        .contextMenu { ItemContextMenu(item: item) }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { model.openViewer(); return .handled }
        .onKeyPress(.return) { model.openViewer(); return .handled }
        .onKeyPress(.escape) {
            if model.selectMode { model.selectMode = false } else { model.clearSelection() }
            return .handled
        }
        .onKeyPress(.delete) { model.requestDeleteSelection(); return .handled }
        .onCommand(#selector(NSResponder.selectAll(_:))) { model.selectAllVisible() }
        .onAppear { focused = true }
    }
}

struct ThumbnailCell: View {
    let item: CompareItem
    let size: Double
    let isSelected: Bool
    @State private var image: NSImage?

    var selectMode = false
    var copies = 0

    init(item: CompareItem, size: Double, isSelected: Bool, selectMode: Bool = false, copies: Int = 0) {
        self.item = item
        self.size = size
        self.isSelected = isSelected
        self.selectMode = selectMode
        self.copies = copies
        _image = State(initialValue: ThumbnailLoader.cached(for: item, pixelSize: size * 2))
    }

    private var pixelBucket: Int { ThumbnailLoader.bucket(size * 2) }

    var body: some View {
        VStack(spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay { ProgressView().controlSize(.small) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    StatusBadge(status: item.status).padding(6)
                }
                .overlay(alignment: .topLeading) {
                    if selectMode { SelectCheck(isSelected: isSelected).padding(6) }
                }
                .overlay(alignment: .bottomLeading) {
                    if item.isVideo {
                        Label(Media.duration(item.duration).isEmpty ? "Video" : Media.duration(item.duration),
                              systemImage: "play.fill")
                            .font(.system(size: 10, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(6)
                    } else if item.photo?.isFavorite == true {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if copies > 1 {
                        Label("\(copies)", systemImage: "square.on.square.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.yellow, in: Capsule())
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .padding(6)
                            .help("This photo exists \(copies) times")
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                      lineWidth: isSelected ? 3 : 1)
                }
                .shadow(color: .black.opacity(isSelected ? 0.18 : 0.06), radius: isSelected ? 6 : 2, y: 1)

            VStack(spacing: 1) {
                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                if size >= 120, item.byteSize > 0 {
                    Text(Format.bytes(item.byteSize))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .task(id: "\(item.id)|\(pixelBucket)") {
            if let loaded = await ThumbnailLoader.image(for: item, pixelSize: size * 2) {
                image = loaded
            }
        }
    }
}

struct StatusBadge: View {
    let status: MatchStatus

    var body: some View {
        let (icon, color, help): (String, Color, String) = switch status {
        case .both: ("checkmark", .green, "In Photos and on the SSD")
        case .photosOnly: ("photo.fill", .blue, "Only in Photos")
        case .diskOnly: ("externaldrive.fill", .purple, "Only on the SSD")
        }
        Image(systemName: icon)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color.gradient, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .help(help)
    }
}

struct StatusPill: View {
    let status: MatchStatus

    var body: some View {
        let f = status.filter
        Label(f.title, systemImage: f.systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(f.tint)
            .background(f.tint.opacity(0.14), in: Capsule())
    }
}

struct ItemContextMenu: View {
    @Environment(AppModel.self) private var model
    let item: CompareItem

    var body: some View {
        let targets = model.targets(for: item)
        let copyable = targets.filter(\.canCopyToDisk).count
        let importable = targets.filter(\.canImportToPhotos).count

        Button("Open Viewer") { model.openViewer(item.id) }
        Divider()
        Button(copyable > 1 ? "Copy \(copyable) to SSD" : "Copy to SSD") { model.copyToDisk(targets) }
            .disabled(copyable == 0)
        Button(importable > 1 ? "Add \(importable) to Photos" : "Add to Photos") { model.importToPhotos(targets) }
            .disabled(importable == 0)
        Divider()
        if item.file != nil {
            Button("Reveal in Finder") { model.reveal(targets) }
            Button("Open with Default App") {
                if let url = item.file?.url { NSWorkspace.shared.open(url) }
            }
        }
        Button("Copy File Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.name, forType: .string)
        }
        Divider()
        Button(targets.count > 1 ? "Delete \(targets.count)…" : "Delete…", role: .destructive) {
            model.requestDelete(targets)
        }
    }
}

/// Round checkbox shown on thumbnails while Select Mode is on.
struct SelectCheck: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.black.opacity(0.25)))
            Circle().strokeBorder(.white, lineWidth: 2)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .animation(.snappy(duration: 0.15), value: isSelected)
    }
}
