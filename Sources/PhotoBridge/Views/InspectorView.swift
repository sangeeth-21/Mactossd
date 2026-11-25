import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let item = model.inspectedItem {
                ItemDetails(item: item)
            } else if model.selection.count > 1 {
                MultiSelectionSummary()
            } else {
                ViewSummaryView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ItemDetails: View {
    @Environment(AppModel.self) private var model
    let item: CompareItem
    @State private var preview: NSImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                    if let preview {
                        Image(nsImage: preview).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        ProgressView()
                    }
                }
                .frame(height: 220)
                .onTapGesture(count: 2) { model.openViewer(item.id) }

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name).font(.headline).textSelection(.enabled)
                    HStack(spacing: 6) {
                        StatusPill(status: item.status)
                        let flags = model.junkFlags(for: item)
                        ForEach(JunkCategory.allCases.filter { flags.contains($0.flag) }) { cat in
                            Label(cat.title, systemImage: cat.systemImage)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .foregroundStyle(cat.tint)
                                .background(cat.tint.opacity(0.14), in: Capsule())
                        }
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Format.bytes(item.byteSize))
                                .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                            if item.byteSize == 0 { Text("size unknown").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if !item.fileExtension.isEmpty {
                                Text(item.fileExtension)
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        InfoRow("Pixels", Format.dimensions(item.pixelWidth, item.pixelHeight))
                        InfoRow("Taken", Format.date(item.date))
                    }
                } label: {
                    Label("File", systemImage: "doc.fill")
                }

                if let group = model.duplicateGroup(for: item) {
                    DuplicatesBox(item: item, group: group)
                }

                GroupBox {
                    if let photo = item.photo {
                        VStack(alignment: .leading, spacing: 6) {
                            InfoRow("Date", Format.date(photo.creationDate))
                            InfoRow("Original file", photo.fileSize > 0 ? Format.bytes(photo.fileSize) : "Unknown")
                            InfoRow("Pixels", Format.dimensions(photo.pixelWidth, photo.pixelHeight))
                            if photo.isFavorite { InfoRow("Favorite", "Yes") }
                        }
                    } else {
                        MissingRow(text: "Not in your Photos library.", action: "Add to Photos") {
                            model.importToPhotos([item])
                        }
                    }
                } label: {
                    Label("Photos Library", systemImage: "photo.on.rectangle.angled").foregroundStyle(.blue)
                }

                GroupBox {
                    if let file = item.file {
                        VStack(alignment: .leading, spacing: 6) {
                            InfoRow("Path", file.url.path)
                            InfoRow("File size", Format.bytes(file.fileSize))
                            InfoRow("Pixels", Format.dimensions(file.pixelWidth, file.pixelHeight))
                            InfoRow("Captured", Format.date(file.captureDate))
                            HStack {
                                Button("Reveal in Finder") { model.reveal([item]) }
                                Button("Open") { NSWorkspace.shared.open(file.url) }
                            }
                            .controlSize(.small)
                            .padding(.top, 2)
                        }
                    } else {
                        MissingRow(text: "Not on the SSD yet.", action: "Copy to SSD") {
                            model.copyToDisk([item])
                        }
                    }
                } label: {
                    Label("SSD", systemImage: "externaldrive.fill").foregroundStyle(.purple)
                }

                let names = model.peopleNames(for: item)
                if !names.isEmpty {
                    GroupBox {
                        FlowChips(names: names)
                    } label: {
                        Label("People", systemImage: "person.2.fill")
                    }
                }

                Button(role: .destructive) {
                    model.requestDelete([item])
                } label: {
                    Label("Delete…", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .disabled(model.activity != nil)
            }
            .padding(14)
        }
        .task(id: item.id) {
            preview = ThumbnailLoader.cached(for: item, pixelSize: model.thumbnailSize * 2)
            if let img = await ThumbnailLoader.image(for: item, pixelSize: 640, highQuality: true) {
                preview = img
            }
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MissingRow: View {
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.callout).foregroundStyle(.secondary)
            Button(action, action: perform).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FlowChips: View {
    let names: [String]

    var body: some View {
        // Simple wrapping layout for name chips.
        ChipLayout(spacing: 6) {
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChipLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

/// Right-side panel when several images are selected: count, total size, where they are, and what copying needs.
private struct MultiSelectionSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.selectedItems
        let sum = SizeSummary.of(items)
        let free = model.diskFreeBytes

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SizeHeader(title: "\(sum.total.count.formatted()) Selected",
                           bytes: sum.total.bytes, unknown: sum.unknownSize,
                           subtitle: Format.dateRange(sum.earliest, sum.latest))

                GroupBox {
                    VStack(spacing: 8) {
                        BucketRow(filter: .both, bucket: sum.both)
                        BucketRow(filter: .photosOnly, bucket: sum.photosOnly)
                        BucketRow(filter: .diskOnly, bucket: sum.diskOnly)
                    }
                } label: {
                    Label("Where they are", systemImage: "chart.bar.fill")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        SpaceRow(label: "Needed to copy to SSD", bytes: sum.bytesToCopyToDisk,
                                 free: free, freeLabel: "free on SSD")
                        SpaceRow(label: "Needed to add to Photos", bytes: sum.bytesToImport, free: nil, freeLabel: "")
                    }
                } label: {
                    Label("Space", systemImage: "internaldrive")
                }

                Button {
                    model.copyToDisk(items)
                } label: {
                    Label("Copy \(sum.photosOnly.count.formatted()) to SSD · \(Format.bytes(sum.photosOnly.bytes))",
                          systemImage: "externaldrive.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sum.photosOnly.count == 0 || model.activity != nil)

                Button {
                    model.importToPhotos(items)
                } label: {
                    Label("Add \(sum.diskOnly.count.formatted()) to Photos · \(Format.bytes(sum.diskOnly.bytes))",
                          systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(sum.diskOnly.count == 0 || model.activity != nil)

                Button(role: .destructive) {
                    model.requestDelete(items)
                } label: {
                    Label("Delete \(items.count.formatted())… · \(Format.bytes(sum.total.bytes))", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.activity != nil)

                if model.organizeByDate {
                    Text("Copies go into Year/Month folders on the SSD. You can change this in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }
}

/// Right-side panel when nothing is selected: totals for everything in the current view.
struct ViewSummaryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sum = model.viewSummary
        let free = model.diskFreeBytes
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SizeHeader(title: model.junkFilter?.title ?? model.filter.title,
                           bytes: sum.total.bytes, unknown: sum.unknownSize,
                           subtitle: "\(sum.total.count.formatted()) images · \(Format.dateRange(sum.earliest, sum.latest))")

                SSDStorageBox()

                GroupBox {
                    VStack(spacing: 8) {
                        BucketRow(filter: .both, bucket: sum.both)
                        BucketRow(filter: .photosOnly, bucket: sum.photosOnly)
                        BucketRow(filter: .diskOnly, bucket: sum.diskOnly)
                    }
                } label: {
                    Label("In this view", systemImage: "chart.bar.fill")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        SpaceRow(label: "Not yet on SSD", bytes: sum.bytesToCopyToDisk, free: free, freeLabel: "free on SSD")
                        SpaceRow(label: "Not yet in Photos", bytes: sum.bytesToImport, free: nil, freeLabel: "")
                        if let folder = model.diskFolder {
                            Text(folder.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                } label: {
                    Label("Backup", systemImage: "externaldrive.badge.checkmark")
                }

                Label("Select photos to see their total size, or click one for full details.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
}

// MARK: - Size building blocks

struct SizeHeader: View {
    let title: String
    let bytes: Int64
    let unknown: Int
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
            Text(Format.bytes(bytes))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            if unknown > 0 {
                Text("Size not yet known for \(unknown.formatted()) \(unknown == 1 ? "image" : "images")")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

struct BucketRow: View {
    let filter: CompareFilter
    let bucket: SizeBucket

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: filter.systemImage).foregroundStyle(filter.tint).frame(width: 18)
            Text(filter.title)
            Spacer()
            Text(bucket.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
            Text(Format.bytes(bucket.bytes))
                .monospacedDigit()
                .frame(minWidth: 70, alignment: .trailing)
        }
        .font(.callout)
    }
}

struct SpaceRow: View {
    let label: String
    let bytes: Int64
    let free: Int64?
    let freeLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(Format.bytes(bytes)).monospacedDigit().fontWeight(.medium)
            }
            .font(.callout)
            if let free {
                let fits = bytes <= free
                ProgressView(value: free > 0 ? min(1, Double(bytes) / Double(free)) : 1)
                    .tint(fits ? .accentColor : .red)
                Label(fits ? "\(Format.bytes(free)) \(freeLabel). Enough space."
                           : "Only \(Format.bytes(free)) \(freeLabel). Not enough space.",
                      systemImage: fits ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(fits ? Color.secondary : Color.red)
            }
        }
    }
}

/// Right-side panel: every other copy of the selected photo, with where each copy lives.
private struct DuplicatesBox: View {
    @Environment(AppModel.self) private var model
    let item: CompareItem
    let group: DuplicateGroup

    var body: some View {
        let others = model.duplicates(of: item)
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(group.reason.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(others) { copy in
                    DuplicateRow(copy: copy)
                        .onTapGesture { model.selection = [copy.id] }
                }

                Divider()
                Button {
                    model.requestDelete(others)
                } label: {
                    Label(others.count == 1 ? "Keep This, Delete the Other Copy…"
                                            : "Keep This, Delete \(others.count) Other Copies…",
                          systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .disabled(others.isEmpty || model.activity != nil)
                Button("Select the Other Copies") { model.selectDuplicateCopies(keeping: item) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } label: {
            Label("\(group.reason.title) · \(group.itemIDs.count)", systemImage: "square.on.square.fill")
                .foregroundStyle(.orange)
        }
    }
}

private struct DuplicateRow: View {
    let copy: CompareItem
    @State private var thumb: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let thumb {
                    Image(nsImage: thumb).resizable().scaledToFill()
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .topTrailing) { StatusBadge(status: copy.status).scaleEffect(0.75).offset(x: 6, y: -6) }

            VStack(alignment: .leading, spacing: 2) {
                Text(copy.name).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.head)
                if let size = copy.file?.fileSize {
                    Text(Format.bytes(size)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .help("Show this copy")
        .task(id: copy.id) {
            thumb = await ThumbnailLoader.image(for: copy, pixelSize: 128)
        }
    }

    private var location: String {
        switch copy.status {
        case .both: "In Photos and on SSD"
        case .photosOnly: "In Photos only"
        case .diskOnly: copy.file.map { ($0.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath } ?? "On SSD"
        }
    }
}

/// Right-side "SSD Storage" box: drive name/format, used vs free (as Finder shows it), and how much
/// of it is the media in the chosen folder.
struct SSDStorageBox: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GroupBox {
            if let folder = model.diskFolder {
                if let st = model.diskStorage {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Format.bytes(st.free))
                                .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                            Text("free").foregroundStyle(.secondary)
                            Spacer()
                            Text("of \(Format.bytes(st.total))").foregroundStyle(.secondary).monospacedDigit()
                        }
                        ProgressView(value: st.usedFraction)
                            .tint(st.usedFraction > 0.9 ? .red : st.usedFraction > 0.75 ? .orange : .purple)
                        HStack {
                            Label("\(Format.bytes(st.used)) used", systemImage: "circle.fill")
                                .foregroundStyle(.purple)
                            Spacer()
                            Text("\(Int((st.usedFraction * 100).rounded()))% full").monospacedDigit()
                        }
                        .font(.caption)
                        Divider()
                        row("Drive", st.format.isEmpty ? st.name : "\(st.name) · \(st.format)")
                        row("Folder", (folder.path as NSString).abbreviatingWithTildeInPath)
                        row("Photos & videos in folder",
                            "\(model.diskFiles.count.formatted()) · \(Format.bytes(model.diskMediaBytes))")
                    }
                } else {
                    Label("The SSD isn't connected.", systemImage: "externaldrive.badge.xmark")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Choose an SSD folder to see its storage.").foregroundStyle(.secondary)
            }
        } label: {
            HStack {
                Label("SSD Storage", systemImage: "externaldrive.fill").foregroundStyle(.purple)
                Spacer()
                Button { model.refreshDiskStorage() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh storage")
            }
        }
        .onAppear { model.refreshDiskStorage() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).lineLimit(2).truncationMode(.middle)
        }
        .font(.caption)
    }
}
