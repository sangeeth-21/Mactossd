import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding<CompareFilter?>(
            // While an Unwanted category or the iPhone is shown, no Compare row is highlighted, so clicking
            // any row (even the same one) fires and clears that category.
            get: { model.isBrowsingDevice || model.junkFilter != nil ? nil : model.filter },
            set: { if let f = $0 { model.closeDevice(); model.junkFilter = nil; model.filter = f } }
        )) {
            ShowAllRow()

            Section("Sources") {
                PhotosSourceRow()
                DiskSourceRow()
            }

            Section("Compare") {
                ForEach(CompareFilter.allCases) { f in
                    Label {
                        Text(f.title)
                    } icon: {
                        Image(systemName: f.systemImage).foregroundStyle(f.tint)
                    }
                    .badge(model.counts[f] ?? 0)
                    .tag(f)
                }
            }

            Section("iPhone") {
                DevicesSection()
            }

            if !model.volumes.isEmpty {
                Section("External Drives") {
                    ForEach(model.volumes) { VolumeRow(volume: $0) }
                }
            }

            Section("People") {
                PeopleSection()
            }

            Section("Unwanted Images") {
                JunkSection()
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SourceRow<Trailing: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let progress: ScanProgress?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                trailing
            }
            if let progress {
                if let f = progress.fraction {
                    ProgressView(value: f).controlSize(.small)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct PhotosSourceRow: View {
    @Environment(AppModel.self) private var model
    @State private var showCheck = false

    var body: some View {
        SourceRow(title: "Photos Library", subtitle: subtitle, systemImage: "photo.on.rectangle.angled",
                  tint: model.photosAuth == .limited ? .orange : .blue, progress: model.photosProgress) {
            if model.photosAccessGranted {
                Button { showCheck.toggle() } label: {
                    Image(systemName: model.photosAuth == .limited ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(model.photosAuth == .limited ? .orange : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Library Check: compare these counts with the Photos app")
                .popover(isPresented: $showCheck, arrowEdge: .trailing) { LibraryCheckView().environment(model) }
                Button { model.loadPhotos() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Reload Photos library")
                    .disabled(model.photosProgress != nil)
            } else {
                Button(model.photosAuth == .notDetermined ? "Connect" : "Settings") { model.connectPhotos() }
                    .controlSize(.small)
            }
        }
    }

    private var subtitle: String {
        switch model.photosAuth {
        case .authorized, .limited:
            if let p = model.photosProgress, let f = p.fraction { return "Loading… \(Int(f * 100))%" }
            guard model.photosLoaded else { return "Loading…" }
            let limited = model.photosAuth == .limited ? " · Limited access" : ""
            return "\(model.photoCount.formatted()) photos · \(model.videoCount.formatted()) videos\(limited)"
        case .denied, .restricted: return "Access denied"
        default: return "Not connected"
        }
    }
}

private struct DiskSourceRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SourceRow(title: model.diskFolder?.lastPathComponent ?? "SSD Folder", subtitle: subtitle,
                  systemImage: "externaldrive.fill", tint: .purple, progress: model.diskProgress) {
            HStack(spacing: 6) {
                if model.diskFolder != nil {
                    Button { model.scanDisk() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Rescan folder")
                        .disabled(model.diskProgress != nil)
                }
                Button(model.diskFolder == nil ? "Choose…" : "Change") { model.chooseDiskFolder() }
                    .controlSize(.small)
            }
        }
        .help(model.diskFolder?.path ?? "Choose a folder on your external SSD")
    }

    private var subtitle: String {
        guard model.diskFolder != nil else { return "No folder selected" }
        if !model.diskFolderAvailable { return "Drive not connected" }
        if let p = model.diskProgress { return p.message }
        return model.diskLoaded ? "\(model.diskFiles.count.formatted()) images" : "Not scanned"
    }
}

private struct VolumeRow: View {
    @Environment(AppModel.self) private var model
    let volume: Volume

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(volume.name).lineLimit(1)
                if let free = volume.available, let total = volume.capacity {
                    Text("\(Format.bytes(free)) free of \(Format.bytes(total))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.diskFolder?.path.hasPrefix(volume.url.path) == true {
                Image(systemName: "checkmark").foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.chooseDiskFolder(startingAt: volume.url) }
        .contextMenu {
            Button("Choose Folder on \(volume.name)…") { model.chooseDiskFolder(startingAt: volume.url) }
            Button("Use Entire Drive") { model.setDiskFolder(volume.url) }
            Button("Show in Finder") { NSWorkspace.shared.open(volume.url) }
        }
        .help("Click to choose a folder on \(volume.name)")
    }
}

private struct PeopleSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        switch model.peopleState {
        case .idle:
            if model.photosAccessGranted {
                Button("Load People") { model.loadPeople() }
            } else {
                Text("Connect Photos to browse people.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading people…").foregroundStyle(.secondary)
            }
        case .needsAccess:
            VStack(alignment: .leading, spacing: 8) {
                Label("Full Disk Access needed", systemImage: "lock.shield")
                    .font(.callout.weight(.semibold))
                Text("macOS only shares People from Photos with apps that have Full Disk Access. Turn it on for PhotoBridge, then try again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Settings") { model.openFullDiskAccessSettings() }
                    Button("Try Again") { model.loadPeople() }
                }
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { model.loadPeople() }.controlSize(.small)
            }
        case .loaded:
            if model.people.isEmpty {
                Text("No named people found. Name people in the Photos app to filter by them here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("Find a person", text: $model.peopleSearch)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                if !model.selectedPeople.isEmpty {
                    HStack {
                        Picker("Match", selection: $model.peopleMatchAll) {
                            Text("Any").tag(false)
                            Text("All").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 110)
                        .help("Show photos with any of the selected people, or only photos with all of them")
                        Spacer()
                        Button("Clear") { model.selectedPeople.removeAll() }
                            .buttonStyle(.link)
                    }
                }
                ForEach(model.filteredPeople) { person in
                    PersonRow(person: person, isSelected: model.selectedPeople.contains(person.id))
                        .onTapGesture { model.togglePerson(person.id) }
                }
            }
        }
    }
}

private struct PersonRow: View {
    @Environment(AppModel.self) private var model
    let person: Person
    let isSelected: Bool
    @State private var avatar: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(.quaternary)
                if let avatar {
                    Image(nsImage: avatar).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill").foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))

            VStack(alignment: .leading, spacing: 1) {
                Text(person.name).lineLimit(1)
                    .foregroundStyle(person.isNamed ? .primary : .secondary)
                Text("\(person.photoCount.formatted()) photos")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
        }
        .contentShape(Rectangle())
        .task(id: model.photosLoaded) {
            guard avatar == nil, let assetID = model.avatarAssetID(for: person) else { return }
            avatar = await ThumbnailLoader.avatar(personID: person.id, assetID: assetID, hint: person.keyFaceCenter)
        }
    }
}

private struct JunkSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(JunkCategory.allCases) { category in
            JunkRow(category: category,
                    count: model.junkCounts[category] ?? 0,
                    pending: category == .duplicates ? !model.duplicatesScanned
                                                     : category.needsAnalysis && !model.analysisComplete,
                    isSelected: model.junkFilter == category)
                .onTapGesture { model.toggleJunkFilter(category) }
        }

        if let scan = model.duplicateScan {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: scan.fraction).controlSize(.small)
                HStack {
                    Text("Finding duplicates… \(scan.completed)%")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("Stop") { model.stopDuplicateScan() }.buttonStyle(.link).font(.caption)
                }
            }
            .padding(.vertical, 2)
        } else if !model.items.isEmpty {
            Button {
                model.startDuplicateScan()
            } label: {
                Label(model.duplicatesScanned ? "Rescan Duplicates" : "Find Duplicates",
                      systemImage: "square.on.square.dashed")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
        }

        if let analysis = model.analysis {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: analysis.fraction).controlSize(.small)
                HStack {
                    Text("Checked \(analysis.completed.formatted()) of \(analysis.total.formatted())")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("Stop") { model.stopJunkAnalysis() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            .padding(.vertical, 2)
        } else if !model.analysisComplete && !model.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    model.startJunkAnalysis()
                } label: {
                    Label("Find Bills & Blurry Photos", systemImage: "sparkle.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                Text("Analyzed privately on this Mac. Results are remembered.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }

        if let category = model.junkFilter, !model.visibleItems.isEmpty {
            HStack(spacing: 8) {
                Button(model.allVisibleSelected ? "Deselect" : "Select All \(model.visibleItems.count.formatted())") {
                    model.toggleSelectAll()
                }
                Button(role: .destructive) {
                    model.requestDeleteSelection()      // only what you selected, after confirmation
                } label: {
                    Label(model.selection.isEmpty ? "Delete…" : "Delete \(model.selection.count.formatted())…",
                          systemImage: "trash")
                }
                .disabled(model.selection.isEmpty || model.activity != nil)
            }
            .controlSize(.small)
            .help("Clean up \(category.title.lowercased())")
        }
    }
}

private struct JunkRow: View {
    let category: JunkCategory
    let count: Int
    let pending: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: category.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(category.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(category.title).lineLimit(1)
                Text(category.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if pending && count == 0 {
                Text("–").foregroundStyle(.tertiary)
            } else {
                Text(count.formatted())
                    .font(.caption.weight(.medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Shows exactly what PhotoKit sees, so the numbers can be checked against the Photos app.
struct LibraryCheckView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Library Check", systemImage: "checklist").font(.headline)
            if let s = model.libraryStats {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Photos", s.photos)
                    row("Videos", s.videos)
                    Divider().gridCellColumns(2)
                    row("Total (what Photos shows)", s.total, bold: true)
                    row("Shown in PhotoBridge", model.photos.count, bold: true)
                    Divider().gridCellColumns(2)
                    row("Hidden (not shown, like Photos)", s.hidden)
                    row("Extra burst frames (grouped, like Photos)", s.burstExtras)
                }
                if s.limitedAccess {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Limited access: PhotoBridge only sees the photos you picked.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Choose Full Access for PhotoBridge to see your whole library.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Privacy Settings") { model.connectPhotosSettings() }
                    }
                } else if s.total == model.photos.count {
                    Label("All \(s.total.formatted()) items are loaded.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                Text("Photos counts photos and videos together, hides Hidden items and shows each burst as one photo. Items in Shared Albums aren't part of the library.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView("Counting…").controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func row(_ label: String, _ value: Int, bold: Bool = false) -> some View {
        GridRow {
            Text(label).fontWeight(bold ? .semibold : .regular)
            Text(value.formatted()).monospacedDigit().fontWeight(bold ? .semibold : .regular)
                .gridColumnAlignment(.trailing)
        }
    }
}

/// Always-visible "All Images" button at the top of the sidebar: clears every filter in one click.
private struct ShowAllRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let active = !model.hasActiveFilters && !model.isBrowsingDevice
        Button {
            model.showAllImages()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("All Images").fontWeight(.semibold)
                    Text(active ? "Showing everything" : "Clear filters and show everything")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.items.count.formatted())
                    .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.vertical, 4).padding(.horizontal, 4)
            .background(active ? Color.accentColor.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show every photo and video (clears Unwanted, People, media and search filters)")
    }
}
