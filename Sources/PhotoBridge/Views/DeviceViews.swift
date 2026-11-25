import SwiftUI

// MARK: - Sidebar

struct DevicesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.devices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("No iPhone connected", systemImage: "iphone.slash")
                    .foregroundStyle(.secondary)
                Text("Connect it with a cable, unlock it and tap “Trust”.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        } else {
            ForEach(model.devices) { device in
                DeviceRow(device: device,
                          state: model.deviceStates[device.id] ?? .idle,
                          isOpen: model.openDeviceID == device.id,
                          count: model.openDeviceID == device.id ? model.deviceFiles.count : nil)
                    .onTapGesture { model.openDevice(device.id) }
            }
        }
    }
}

private struct DeviceRow: View {
    let device: DeviceInfo
    let state: DeviceState
    let isOpen: Bool
    let count: Int?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isPhone ? "iphone.gen3" : "camera.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if state == .opening || state == .loading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(isOpen ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .help("Browse and compare the photos on \(device.name)")
    }

    private var subtitle: String {
        switch state {
        case .idle: "Click to browse"
        case .opening: "Connecting…"
        case .locked: "Unlock your iPhone"
        case .loading: "Reading photos…"
        case .ready: count.map { "\($0.formatted()) photos" } ?? "Ready"
        case .failed: "Couldn't connect"
        }
    }
}

// MARK: - Browser

struct DeviceBrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    model.closeDevice()
                } label: {
                    Label("Library", systemImage: "chevron.left")
                }
                .help("Back to the Photos ⇄ SSD comparison")

                Picker("Show", selection: $model.deviceFilter) {
                    ForEach(DeviceFilter.allCases) { f in
                        Text("\(f.title) \((model.deviceCounts[f] ?? 0).formatted())").tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(model.deviceFilter.help)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        let state = model.openDeviceID.flatMap { model.deviceStates[$0] } ?? .idle
        switch state {
        case .locked:
            ContentUnavailableView {
                Label("Unlock Your iPhone", systemImage: "lock.iphone")
            } description: {
                Text("Unlock the iPhone and tap “Trust This Computer” if asked. The photos will appear automatically.")
            }
        case .failed(let message):
            ContentUnavailableView("Couldn't Connect", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .opening, .loading:
            DeviceLoadingView()
        case .idle where model.deviceFiles.isEmpty:
            DeviceLoadingView()
        default:
            deviceContent
        }
    }

    @ViewBuilder
    private var deviceContent: some View {
        if model.visibleDeviceFiles.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: "checkmark.seal.fill",
                                   description: Text(model.deviceFilter.help))
        } else {
            DeviceGrid()
        }
    }

    private var emptyTitle: String {
        switch model.deviceFilter {
        case .notOnDisk: "Everything Is on the SSD"
        case .notInPhotos: "Everything Is in Photos"
        case .newEverywhere: "Nothing New"
        default: "No Photos"
        }
    }
}

private struct DeviceGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let size = model.thumbnailSize
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: size, maximum: size * 1.45), spacing: 12)], spacing: 16) {
                ForEach(model.visibleDeviceFiles) { file in
                    DeviceCell(file: file, size: size, isSelected: model.deviceSelection.contains(file.id))
                        .onTapGesture { model.handleDeviceClick(on: file) }
                        .contextMenu {
                            let targets = model.deviceSelection.contains(file.id) ? model.selectedDeviceFiles : [file]
                            Button("Copy to SSD") { model.copyDeviceFilesToDisk(targets) }
                                .disabled(!targets.contains { !$0.onDisk })
                            Button("Add to Photos") { model.importDeviceFilesToPhotos(targets) }
                                .disabled(!targets.contains { !$0.inPhotos })
                        }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct DeviceCell: View {
    @Environment(AppModel.self) private var model
    let file: DeviceFile
    let size: Double
    let isSelected: Bool
    @State private var image: NSImage?

    init(file: DeviceFile, size: Double, isSelected: Bool) {
        self.file = file
        self.size = size
        self.isSelected = isSelected
        _image = State(initialValue: ThumbnailLoader.cachedDevice(file.id, pixelSize: size * 2))
    }

    var body: some View {
        VStack(spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary).overlay { ProgressView().controlSize(.small) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if model.selectMode { SelectCheck(isSelected: isSelected).padding(6) }
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 3) {
                        Dot(on: file.inPhotos, icon: "photo.fill", color: .blue,
                            help: file.inPhotos ? "Already in Photos" : "Not in Photos")
                        Dot(on: file.onDisk, icon: "externaldrive.fill", color: .purple,
                            help: file.onDisk ? "Already on the SSD" : "Not on the SSD")
                    }
                    .padding(6)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                      lineWidth: isSelected ? 3 : 1)
                }
            Text(file.name)
                .font(.caption).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .task(id: "\(file.id)|\(ThumbnailLoader.bucket(size * 2))") {
            if let img = await ThumbnailLoader.deviceImage(file.id, service: model.deviceService, pixelSize: size * 2) {
                image = img
            }
        }
    }
}

/// Small status dot: filled = present there, hollow = missing.
private struct Dot: View {
    let on: Bool
    let icon: String
    let color: Color
    let help: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(on ? .white : color)
            .frame(width: 20, height: 20)
            .background(on ? AnyShapeStyle(color.gradient) : AnyShapeStyle(.white.opacity(0.9)), in: Circle())
            .overlay(Circle().strokeBorder(on ? .white.opacity(0.85) : color, lineWidth: 1.5))
            .opacity(on ? 1 : 0.85)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .help(help)
    }
}

// MARK: - Inspector

struct DeviceInspectorView: View {
    @Environment(AppModel.self) private var model
    @State private var preview: NSImage?

    var body: some View {
        let selected = model.selectedDeviceFiles
        if selected.count == 1, let file = selected.first {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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

                    Text(file.name).font(.headline).textSelection(.enabled)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            row("Taken", Format.date(file.date))
                            row("Pixels", Format.dimensions(file.width, file.height))
                            row("File size", Format.bytes(file.fileSize))
                        }
                    } label: {
                        Label("On iPhone", systemImage: "iphone.gen3").foregroundStyle(.indigo)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            status(file.inPhotos, yes: "In your Photos library", no: "Not in Photos")
                            status(file.onDisk, yes: "On the SSD", no: "Not on the SSD")
                            if let path = file.diskMatchPath {
                                Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    } label: {
                        Label("Backup Status", systemImage: "checkmark.shield")
                    }
                    HStack {
                        Button("Copy to SSD") { model.copyDeviceFilesToDisk([file]) }
                            .disabled(file.onDisk || model.activity != nil)
                        Button("Add to Photos") { model.importDeviceFilesToPhotos([file]) }
                            .disabled(file.inPhotos || model.activity != nil)
                    }
                    Text("Copies are the untouched originals, at full quality. Nothing on the iPhone is ever changed or deleted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
            }
            .task(id: file.id) {
                preview = ThumbnailLoader.cachedDevice(file.id, pixelSize: model.thumbnailSize * 2)
                if let big = await ThumbnailLoader.deviceImage(file.id, service: model.deviceService, pixelSize: 1024) {
                    preview = big
                }
            }
        } else if selected.count > 1 {
            let toDisk = selected.filter { !$0.onDisk }.count
            let toPhotos = selected.filter { !$0.inPhotos }.count
            VStack(alignment: .leading, spacing: 12) {
                let sum = DeviceSizeSummary.of(selected)
                SizeHeader(title: "\(selected.count.formatted()) Selected", bytes: sum.total.bytes, unknown: 0,
                           subtitle: "\(sum.notOnDisk.count.formatted()) not on SSD · \(sum.notInPhotos.count.formatted()) not in Photos")
                SpaceRow(label: "Needed to copy to SSD", bytes: sum.notOnDisk.bytes,
                         free: model.diskFreeBytes, freeLabel: "free on SSD")
                Button {
                    model.copyDeviceFilesToDisk(selected)
                } label: {
                    Label("Copy \(toDisk.formatted()) to SSD", systemImage: "externaldrive.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(toDisk == 0 || model.activity != nil)
                Button {
                    model.importDeviceFilesToPhotos(selected)
                } label: {
                    Label("Add \(toPhotos.formatted()) to Photos", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(toPhotos == 0 || model.activity != nil)
                Text("Photos already in a destination are skipped automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
        } else {
            let sum = model.deviceViewSummary
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SizeHeader(title: model.openDevice?.name ?? "iPhone", bytes: sum.total.bytes, unknown: 0,
                               subtitle: "\(sum.total.count.formatted()) photos · \(model.deviceFilter.title)")
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            SpaceRow(label: "Not on SSD (\(sum.notOnDisk.count.formatted()))", bytes: sum.notOnDisk.bytes,
                                     free: model.diskFreeBytes, freeLabel: "free on SSD")
                            SpaceRow(label: "Not in Photos (\(sum.notInPhotos.count.formatted()))",
                                     bytes: sum.notInPhotos.bytes, free: nil, freeLabel: "")
                        }
                    } label: {
                        Label("Backup", systemImage: "externaldrive.badge.checkmark")
                    }
                    Label("Select photos to see their total size, or click one for details.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func status(_ ok: Bool, yes: String, no: String) -> some View {
        Label(ok ? yes : no, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(ok ? .green : .secondary)
    }
}

private struct DeviceLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Reading photos from the iPhone…").foregroundStyle(.secondary)
            Text("This can take a minute for large libraries.").font(.caption).foregroundStyle(.tertiary)
        }
    }
}
