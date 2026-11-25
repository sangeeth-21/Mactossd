import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 360)
        } detail: {
            BrowserView()
                .inspector(isPresented: $model.showInspector) {
                    Group {
                        if model.isBrowsingDevice { DeviceInspectorView() } else { InspectorView() }
                    }
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
                }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search file names")
        .sheet(isPresented: Binding(
            get: { model.viewerItemID != nil },
            set: { if !$0 { model.viewerItemID = nil } }
        )) {
            if let id = model.viewerItemID {
                ViewerView(itemID: id)
                    .environment(model)
            }
        }
    }
}

struct BrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar()
        }
        .overlay(alignment: .top) { BannerView() }
        .navigationTitle(model.openDevice?.name ?? model.filter.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $model.selectMode) {
                    Label(model.selectMode ? "Selecting" : "Select Mode",
                          systemImage: model.selectMode ? "checkmark.circle.fill" : "hand.tap")
                }
                .toggleStyle(.button)
                .labelStyle(.titleAndIcon)
                .tint(.accentColor)
                .help("Select Mode: click photos to add or remove them from the selection (Esc to finish)")

                Button {
                    model.toggleSelectAllCurrent()
                } label: {
                    Label(model.allCurrentSelected ? "Deselect All" : "Select All",
                          systemImage: model.allCurrentSelected ? "rectangle.stack.badge.minus" : "rectangle.stack.badge.plus")
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.currentIsEmpty)
                .help("Select every image in this view (⌘A)")

                Button {
                    model.copyCurrentSelectionToDisk()
                } label: {
                    Label("Copy to SSD", systemImage: "externaldrive.badge.plus")
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.currentCopyableCount == 0 || model.activity != nil)
                .help("Copy the selected Photos originals to the SSD folder (⇧⌘E)")

                Button {
                    model.importCurrentSelectionToPhotos()
                } label: {
                    Label("Add to Photos", systemImage: "photo.badge.plus")
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.currentImportableCount == 0 || model.activity != nil)
                .help("Import the selected SSD images into Photos (⇧⌘I)")

                Button(role: .destructive) {
                    model.requestDeleteSelection()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(model.isBrowsingDevice || model.selection.isEmpty || model.activity != nil)
                .help(model.isBrowsingDevice ? "PhotoBridge never deletes anything on your iPhone"
                                             : "Delete the selected images (⌘⌫)")

                Picker(selection: $model.mediaFilter) {
                    ForEach(MediaFilter.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                } label: {
                    Label("Media", systemImage: model.mediaFilter.systemImage)
                }
                .pickerStyle(.menu)
                .help("Show photos, videos, or both")

                Menu {
                    Picker("Sort", selection: $model.sortOrder) {
                        ForEach(SortOrder.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort order")

                Slider(value: $model.thumbnailSize, in: 90 ... 340)
                    .frame(width: 110)
                    .help("Thumbnail size")

                Button {
                    model.refreshAll()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Rescan Photos and the SSD (⌘R)")

                Button {
                    model.showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the inspector")
            }
        }
    }

    private var subtitle: String {
        if model.isBrowsingDevice {
            let n = model.visibleDeviceFiles.count
            return "\(n.formatted()) \(n == 1 ? "photo" : "photos") · \(model.deviceFilter.title)"
        }
        let n = model.visibleItems.count
        var s = "\(n.formatted()) \(n == 1 ? "image" : "images")"
        if let junk = model.junkFilter { s += " · " + junk.title }
        if !model.selectedPeople.isEmpty {
            let names = model.people.filter { model.selectedPeople.contains($0.id) }.map(\.name)
            s += " · " + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? "…" : "")
        }
        return s
    }

    @ViewBuilder
    private var content: some View {
        if model.isBrowsingDevice {
            DeviceBrowserView()
        } else if !model.photosAccessGranted && model.diskFolder == nil {
            WelcomeView()
        } else if model.visibleItems.isEmpty {
            if model.photosProgress != nil || model.diskProgress != nil || model.isMatching {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(model.photosProgress?.message ?? model.diskProgress?.message ?? "Comparing…")
                        .foregroundStyle(.secondary)
                }
            } else {
                EmptyFilterView()
            }
        } else {
            VStack(spacing: 0) {
                ActiveFiltersBar()
                PhotoGridView()
            }
        }
    }
}

struct EmptyFilterView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if !model.selectedPeople.isEmpty {
            ContentUnavailableView("No Matching Photos", systemImage: "person.crop.rectangle.stack",
                                   description: Text("No images in this view contain the selected people."))
        } else {
            switch model.filter {
            case .photosOnly where model.diskLoaded:
                ContentUnavailableView("Everything Is Backed Up", systemImage: "checkmark.seal.fill",
                                       description: Text("Every photo in your library is also on the SSD."))
            case .diskOnly where model.photosLoaded:
                ContentUnavailableView("Nothing Missing from Photos", systemImage: "checkmark.seal.fill",
                                       description: Text("Every image on the SSD is already in Photos."))
            case .both:
                ContentUnavailableView("No Matches Yet", systemImage: "square.on.square.dashed",
                                       description: Text("No images were found in both places."))
            default:
                ContentUnavailableView("No Images", systemImage: "photo.on.rectangle",
                                       description: Text("Connect Photos and choose an SSD folder to start comparing."))
            }
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if let activity = model.activity {
                ProgressView(value: activity.fraction)
                    .frame(width: 160)
                Text("\(activity.title): \(activity.completed + activity.failed) of \(activity.total)")
                    .monospacedDigit()
                if activity.failed > 0 {
                    Text("\(activity.failed) failed").foregroundStyle(.red)
                }
                Button("Stop") { model.cancelActivity() }
                    .controlSize(.small)
            } else if let p = model.photosProgress ?? model.diskProgress {
                ProgressView().controlSize(.small)
                Text(p.message).foregroundStyle(.secondary)
            } else {
                if model.selectMode {
                    Label("Select Mode: click photos to select them · Esc to finish", systemImage: "hand.tap")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text(summary).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isBrowsingDevice {
                if !model.deviceSelection.isEmpty {
                    Text("\(model.deviceSelection.count.formatted()) selected · \(Format.bytes(model.deviceSelectionSummary.total.bytes))")
                        .foregroundStyle(.secondary).monospacedDigit()
                    Button("Deselect") { model.deviceSelection = [] }.buttonStyle(.link)
                }
            } else if !model.selection.isEmpty {
                Text("\(model.selection.count.formatted()) selected · \(Format.bytes(model.selectionSummary.total.bytes))")
                    .foregroundStyle(.secondary).monospacedDigit()
                Button("Deselect") { model.clearSelection() }
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.bar)
    }

    private var summary: String {
        let c = model.counts
        if model.isBrowsingDevice {
            let d = model.deviceViewSummary
            return "\(d.total.count.formatted()) photos · \(Format.bytes(d.total.bytes))"
        }
        return "\(model.viewSummary.total.count.formatted()) images · \(Format.bytes(model.viewSummary.total.bytes)) · \((c[.both] ?? 0).formatted()) matched · \((c[.photosOnly] ?? 0).formatted()) only in Photos · \((c[.diskOnly] ?? 0).formatted()) only on SSD"
    }
}

struct BannerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let banner = model.banner {
            HStack(spacing: 8) {
                Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(banner.isError ? .orange : .green)
                Text(banner.message)
                    .lineLimit(2)
                Button {
                    model.banner = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(banner.id)
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                Text("Compare Photos with Your SSD")
                    .font(.largeTitle.weight(.semibold))
                Text("See which images are in both places, which are missing, and copy them either way.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                StepCard(number: 1, title: "Connect Photos",
                         detail: "Allow access to your Photos library.",
                         systemImage: "photo.on.rectangle.angled", tint: .blue,
                         done: model.photosAccessGranted, action: "Connect") { model.connectPhotos() }
                StepCard(number: 2, title: "Choose SSD Folder",
                         detail: "Pick the folder on your external drive.",
                         systemImage: "externaldrive.fill", tint: .purple,
                         done: model.diskFolder != nil, action: "Choose…") { model.chooseDiskFolder() }
            }
        }
        .padding(40)
    }
}

private struct StepCard: View {
    let number: Int
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let done: Bool
    let action: String
    let perform: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: systemImage).font(.title2).foregroundStyle(tint)
                Spacer()
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                } else {
                    Text("Step \(number)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action, action: perform)
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .disabled(done)
        }
        .padding(18)
        .frame(width: 250, height: 170)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
    }
}

/// Shows which filters are active above the grid, each removable, plus "Show All Images".
struct ActiveFiltersBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.hasActiveFilters {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Color.accentColor)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if model.filter != .all {
                            chip(model.filter.title, model.filter.systemImage) { model.filter = .all }
                        }
                        if let junk = model.junkFilter {
                            chip(junk.title, junk.systemImage) { model.junkFilter = nil }
                        }
                        if !model.selectedPeople.isEmpty {
                            let names = model.people.filter { model.selectedPeople.contains($0.id) }.map(\.name)
                            chip(names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " +\(names.count - 2)" : ""),
                                 "person.2.fill") { model.selectedPeople = [] }
                        }
                        if model.mediaFilter != .all {
                            chip(model.mediaFilter.title, model.mediaFilter.systemImage) { model.mediaFilter = .all }
                        }
                        let q = model.searchText.trimmingCharacters(in: .whitespaces)
                        if !q.isEmpty {
                            chip("“\(q)”", "magnifyingglass") { model.searchText = "" }
                        }
                    }
                }
                Spacer(minLength: 8)
                Button {
                    model.showAllImages()
                } label: {
                    Label("Show All Images", systemImage: "photo.stack")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func chip(_ title: String, _ icon: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption)
            Text(title).font(.caption.weight(.medium)).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove this filter")
        }
        .padding(.leading, 8).padding(.trailing, 5).padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.13), in: Capsule())
    }
}
