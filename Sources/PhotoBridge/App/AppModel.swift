import AppKit
import Photos
import SwiftUI

@MainActor
@Observable
final class AppModel {
    private enum Keys {
        static let folder = "diskFolder"
        static let thumb = "thumbnailSize"
        static let organize = "organizeByDate"
        static let unnamed = "includeUnnamedPeople"
        static let library = "photosLibraryPath"
        static let sort = "sortOrder"
    }

    @ObservationIgnored private let photoService = PhotoLibraryService.shared
    @ObservationIgnored private let defaults = UserDefaults.standard

    // MARK: Photos source
    var photosAuth: PHAuthorizationStatus
    private(set) var photos: [PhotoAsset] = []
    private(set) var photosProgress: ScanProgress?
    private(set) var photosLoaded = false
    var photosAccessGranted: Bool { photosAuth == .authorized || photosAuth == .limited }
    /// Counts straight from PhotoKit (photos, videos, hidden…) to compare with the Photos app.
    private(set) var libraryStats: LibraryStats?
    var photoCount: Int { photos.lazy.filter { !$0.isVideo }.count }
    var videoCount: Int { photos.lazy.filter(\.isVideo).count }

    // MARK: SSD source
    private(set) var diskFolder: URL?
    private(set) var diskFiles: [DiskFile] = []
    private(set) var diskProgress: ScanProgress?
    private(set) var diskLoaded = false
    private(set) var volumes: [Volume] = []

    // MARK: Comparison
    private(set) var items: [CompareItem] = []
    @ObservationIgnored private var indexByID: [String: Int] = [:]
    private(set) var visibleItems: [CompareItem] = []
    private(set) var counts: [CompareFilter: Int] = [:]
    private(set) var isMatching = false
    @ObservationIgnored private var matchGeneration = 0

    var filter: CompareFilter = .all { didSet { if oldValue != filter { applyFilters() } } }
    var mediaFilter: MediaFilter = .all { didSet { if oldValue != mediaFilter { applyFilters() } } }
    var searchText = "" { didSet { if oldValue != searchText { applyFilters(); applyDeviceFilters() } } }
    var sortOrder: SortOrder {
        didSet {
            guard oldValue != sortOrder else { return }
            defaults.set(sortOrder.rawValue, forKey: Keys.sort)
            items = sorted(items)
            rebuildIndex()
            applyFilters()
        }
    }

    // MARK: Selection & UI
    var selection: Set<String> = []
    @ObservationIgnored private var selectionAnchor: String?
    var thumbnailSize: Double { didSet { defaults.set(thumbnailSize, forKey: Keys.thumb) } }
    var showInspector = true
    var viewerItemID: String?
    var banner: Banner?

    // MARK: People
    private(set) var people: [Person] = []
    @ObservationIgnored private var assetsByPerson: [Int64: Set<String>] = [:]
    @ObservationIgnored private var peopleByAsset: [String: [Int64]] = [:]
    @ObservationIgnored private var personNames: [Int64: String] = [:]
    private(set) var peopleState: PeopleState = .idle
    var selectedPeople: Set<Int64> = [] { didSet { if oldValue != selectedPeople { applyFilters() } } }
    var peopleMatchAll = false { didSet { if oldValue != peopleMatchAll { applyFilters() } } }
    var peopleSearch = ""

    // MARK: Unwanted images
    var junkFilter: JunkCategory? { didSet { if oldValue != junkFilter { applyFilters() } } }
    private(set) var junkCounts: [JunkCategory: Int] = [:]
    private(set) var analyzedCount = 0
    private(set) var analysis: Activity?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var visionFlags: [String: JunkFlags] = [:]
    @ObservationIgnored private var metaFlagCache: [String: JunkFlags] = [:]


    // MARK: Sizes
    /// Totals for everything currently shown in the grid (updated with every filter change).
    private(set) var viewSummary = SizeSummary()

    var selectionSummary: SizeSummary { SizeSummary.of(selectedItems) }
    var deviceViewSummary: DeviceSizeSummary { DeviceSizeSummary.of(visibleDeviceFiles) }
    var deviceSelectionSummary: DeviceSizeSummary { DeviceSizeSummary.of(selectedDeviceFiles) }

    /// Free space on the drive that holds the SSD folder.
    var diskFreeBytes: Int64? {
        guard let folder = diskFolder, FileManager.default.fileExists(atPath: folder.path) else { return nil }
        let v = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? v?.volumeAvailableCapacity.map(Int64.init)
    }

    // MARK: Select mode
    /// When on, a single click adds/removes a photo from the selection (no modifier keys needed).
    var selectMode = false

    // MARK: Duplicates
    private(set) var duplicateGroups: [DuplicateGroup] = []
    @ObservationIgnored private var duplicateGroupOf: [String: Int] = [:]
    private(set) var duplicateScan: Activity?
    private(set) var duplicatesScanned = false
    @ObservationIgnored private var duplicateTask: Task<Void, Never>?

    // MARK: iPhone / cameras
    @ObservationIgnored let deviceService = DeviceService()
    private(set) var devices: [DeviceInfo] = []
    private(set) var deviceStates: [String: DeviceState] = [:]
    /// The device being browsed. nil = the normal Photos ⇄ SSD comparison.
    private(set) var openDeviceID: String?
    private(set) var deviceFiles: [DeviceFile] = []
    private(set) var visibleDeviceFiles: [DeviceFile] = []
    private(set) var deviceCounts: [DeviceFilter: Int] = [:]
    var deviceFilter: DeviceFilter = .notOnDisk { didSet { if oldValue != deviceFilter { applyDeviceFilters() } } }
    var deviceSelection: Set<String> = []
    @ObservationIgnored private var deviceAnchor: String?

    var filteredPeople: [Person] {
        let q = peopleSearch.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return people }
        return people.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    // MARK: Settings
    var organizeByDate: Bool { didSet { defaults.set(organizeByDate, forKey: Keys.organize) } }
    var includeUnnamedPeople: Bool {
        didSet {
            guard oldValue != includeUnnamedPeople else { return }
            defaults.set(includeUnnamedPeople, forKey: Keys.unnamed)
            loadPeople()
        }
    }
    var photosLibraryPath: String {
        didSet {
            guard oldValue != photosLibraryPath else { return }
            defaults.set(photosLibraryPath, forKey: Keys.library)
            loadPeople()
        }
    }

    // MARK: Activity
    private(set) var activity: Activity?
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var photosTask: Task<Void, Never>?
    @ObservationIgnored private var diskTask: Task<Void, Never>?
    @ObservationIgnored private var peopleTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false

    init() {
        let d = UserDefaults.standard
        photosAuth = PhotoLibraryService.shared.authorizationStatus
        thumbnailSize = d.object(forKey: Keys.thumb) as? Double ?? 170
        organizeByDate = d.object(forKey: Keys.organize) as? Bool ?? true
        includeUnnamedPeople = d.bool(forKey: Keys.unnamed)
        photosLibraryPath = d.string(forKey: Keys.library) ?? PeopleService.defaultLibraryPath
        sortOrder = SortOrder(rawValue: d.string(forKey: Keys.sort) ?? "") ?? .newest
        if let path = d.string(forKey: Keys.folder) { diskFolder = URL(fileURLWithPath: path, isDirectory: true) }
        volumes = DiskScanner.externalVolumes()
        visionFlags = JunkDetector.loadCache().mapValues { JunkFlags(rawValue: $0) }
        setUpDevices()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.volumesChanged() }
            })
        }
    }

    func start() {
        guard !started else { return }
        started = true
        if photosAccessGranted { loadPhotos() }
        if let folder = diskFolder, FileManager.default.fileExists(atPath: folder.path) { scanDisk() }
    }

    func refreshAll() {
        if photosAccessGranted { loadPhotos() }
        scanDisk()
        if photosAccessGranted { loadPeople() }
    }

    private func volumesChanged() {
        volumes = DiskScanner.externalVolumes()
        if let folder = diskFolder {
            let available = FileManager.default.fileExists(atPath: folder.path)
            if available && !diskLoaded && diskProgress == nil { scanDisk() }
        }
    }

    var diskFolderAvailable: Bool {
        guard let diskFolder else { return false }
        return FileManager.default.fileExists(atPath: diskFolder.path)
    }

    // MARK: - Loading

    func connectPhotos() {
        switch photosAuth {
        case .denied, .restricted:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
        default:
            loadPhotos()
        }
    }

    func connectPhotosSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
    }

    func loadPhotos() {
        photosTask?.cancel()
        photosTask = Task { [weak self] in
            guard let self else { return }
            if photosAuth == .notDetermined { photosAuth = await photoService.requestAuthorization() }
            guard photosAccessGranted else { return }
            photosProgress = ScanProgress(message: "Reading Photos library…", fraction: 0)
            let result = await photoService.fetchAllImages { fraction in
                Task { @MainActor [weak self] in self?.photosProgress?.fraction = fraction }
            }
            guard !Task.isCancelled else { return }
            photos = result
            photosLoaded = true
            photosProgress = nil
            libraryStats = await Task.detached(priority: .utility) { PhotoLibraryService.shared.libraryStats() }.value
            await rematch()
            if peopleState == .idle { loadPeople() }
        }
    }

    func chooseDiskFolder(startingAt start: URL? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder on your external SSD to compare with your Photos library."
        panel.directoryURL = start ?? diskFolder ?? volumes.first?.url
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDiskFolder(url)
    }

    func setDiskFolder(_ url: URL) {
        diskFolder = url
        defaults.set(url.path, forKey: Keys.folder)
        diskFiles = []
        diskLoaded = false
        scanDisk()
    }

    func scanDisk() {
        guard let folder = diskFolder else { return }
        diskTask?.cancel()
        guard FileManager.default.fileExists(atPath: folder.path) else {
            diskFiles = []
            diskLoaded = false
            Task { await rematch() }
            return
        }
        diskTask = Task { [weak self] in
            guard let self else { return }
            diskProgress = ScanProgress(message: "Scanning \(folder.lastPathComponent)…", fraction: nil)
            do {
                let files = try await DiskScanner.scan(root: folder) { message, fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.diskProgress != nil else { return }
                        self.diskProgress = ScanProgress(message: message, fraction: fraction)
                    }
                }
                guard !Task.isCancelled else { return }
                diskFiles = files
                diskLoaded = true
                diskProgress = nil
                await rematch()
            } catch is CancellationError {
            } catch {
                diskProgress = nil
                showBanner(error.localizedDescription, isError: true)
            }
        }
    }

    private func rematch() async {
        matchGeneration += 1
        let generation = matchGeneration
        isMatching = true
        let p = photos, f = diskFiles, order = sortOrder
        let result = await Task.detached(priority: .userInitiated) {
            Self.sort(await Matcher.match(photos: p, files: f), by: order)
        }.value
        guard generation == matchGeneration else { return }
        isMatching = false
        refreshDeviceMatches()
        items = result
        metaFlagCache.removeAll()
        rebuildIndex()
        if !duplicateGroups.isEmpty { setDuplicateGroups(duplicateGroups) }
        if !selection.isEmpty { selection = selection.filter { indexByID[$0] != nil } }
        applyFilters()
    }

    // MARK: - Filtering

    private func rebuildIndex() {
        var index = [String: Int](minimumCapacity: items.count)
        for (i, item) in items.enumerated() { index[item.id] = i }
        indexByID = index
    }

    private func sorted(_ list: [CompareItem]) -> [CompareItem] { Self.sort(list, by: sortOrder) }

    nonisolated private static func sort(_ list: [CompareItem], by order: SortOrder) -> [CompareItem] {
        switch order {
        case .newest: list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .oldest: list.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        case .name: list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func applyFilters() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let personAssets = selectedPeopleAssets()
        let junkFlag = junkFilter?.flag
        var c: [CompareFilter: Int] = [.all: 0, .both: 0, .photosOnly: 0, .diskOnly: 0]
        var jc: [JunkCategory: Int] = [:]
        var analyzed = 0
        var out: [CompareItem] = []
        out.reserveCapacity(items.count)

        for item in items {
            let flags = junkFlags(for: item)
            if flags.contains(.analyzed) { analyzed += 1 }
            if !mediaFilter.includes(item) { continue }
            if let personAssets {
                guard let uuid = item.photo?.uuid, personAssets.contains(uuid) else { continue }
            }
            if !query.isEmpty {
                let hit = (item.photo?.filename.localizedCaseInsensitiveContains(query) ?? false)
                    || (item.file?.url.path.localizedCaseInsensitiveContains(query) ?? false)
                guard hit else { continue }
            }
            let f = item.status.filter
            let passesCompare = filter == .all || filter == f
            let passesJunk = junkFlag.map { flags.contains($0) } ?? true
            if passesJunk {
                c[.all, default: 0] += 1
                c[f, default: 0] += 1
            }
            if passesCompare && !flags.subtracting(.analyzed).isEmpty {
                for cat in JunkCategory.allCases where flags.contains(cat.flag) { jc[cat, default: 0] += 1 }
            }
            if passesCompare && passesJunk { out.append(item) }
        }
        if junkFilter == .duplicates {
            // Keep each group's copies next to each other, in group order.
            let order = duplicateGroupOf
            out = out.enumerated().sorted {
                let ga = order[$0.element.id] ?? .max, gb = order[$1.element.id] ?? .max
                return ga != gb ? ga < gb : $0.offset < $1.offset
            }.map(\.element)
        }
        counts = c
        junkCounts = jc
        analyzedCount = analyzed
        visibleItems = out
        viewSummary = SizeSummary.of(out)
    }

    func junkFlags(for item: CompareItem) -> JunkFlags {
        let meta: JunkFlags
        if let cached = metaFlagCache[item.id] {
            meta = cached
        } else {
            meta = JunkDetector.metadataFlags(for: item)
            metaFlagCache[item.id] = meta
        }
        var flags = meta.union(visionFlags[JunkDetector.analysisKey(for: item)] ?? [])
        if duplicateGroupOf[item.id] != nil { flags.insert(.duplicate) }
        return flags
    }

    func toggleJunkFilter(_ category: JunkCategory) {
        junkFilter = junkFilter == category ? nil : category
        if junkFilter == .duplicates && !duplicatesScanned { startDuplicateScan() }
    }

    // MARK: Duplicates

    func duplicateGroup(for item: CompareItem) -> DuplicateGroup? {
        guard let g = duplicateGroupOf[item.id], duplicateGroups.indices.contains(g) else { return nil }
        return duplicateGroups[g]
    }

    /// The other copies of `item`, excluding items that no longer exist.
    func duplicates(of item: CompareItem) -> [CompareItem] {
        duplicateGroup(for: item)?.itemIDs.filter { $0 != item.id }.compactMap { self.item(withID: $0) } ?? []
    }

    func startDuplicateScan() {
        guard duplicateTask == nil, !items.isEmpty else { return }
        let snapshot = items
        duplicateScan = Activity(title: "Finding duplicates", total: 100)
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.duplicateScan?.completed = Int(fraction * 100) }
        }
        duplicateTask = Task { [weak self] in
            let groups = await DuplicateFinder.find(items: snapshot, progress: report)
            guard let self else { return }
            let cancelled = Task.isCancelled
            duplicateScan = nil
            duplicateTask = nil
            guard !cancelled else { return }
            setDuplicateGroups(groups)
            duplicatesScanned = true
            let copies = groups.reduce(0) { $0 + $1.itemIDs.count - 1 }
            showBanner(groups.isEmpty ? "No duplicates found."
                       : "Found \(groups.count.formatted()) photos with \(copies.formatted()) extra copies.")
        }
    }

    func stopDuplicateScan() { duplicateTask?.cancel() }

    private func setDuplicateGroups(_ groups: [DuplicateGroup]) {
        // Drop ids that no longer exist and groups that are no longer duplicates.
        var cleaned: [DuplicateGroup] = []
        for g in groups {
            let ids = g.itemIDs.filter { indexByID[$0] != nil }
            if ids.count > 1 { cleaned.append(DuplicateGroup(id: cleaned.count, itemIDs: ids, reason: g.reason)) }
        }
        duplicateGroups = cleaned
        var map: [String: Int] = [:]
        for (i, g) in cleaned.enumerated() { for id in g.itemIDs { map[id] = i } }
        duplicateGroupOf = map
        applyFilters()
    }

    func selectDuplicateCopies(keeping item: CompareItem) {
        selection = Set(duplicates(of: item).map(\.id))
    }

    var analysisComplete: Bool { !items.isEmpty && analyzedCount >= items.count }

    /// Runs on-device Vision analysis for every image not analyzed yet. Results are cached on disk.
    func startJunkAnalysis() {
        guard analysisTask == nil else { return }
        let todo = items.filter { visionFlags[JunkDetector.analysisKey(for: $0)] == nil }
        guard !todo.isEmpty else {
            showBanner("All images have already been checked.")
            return
        }
        analysis = Activity(title: "Checking images", total: todo.count)
        analysisTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: (String, JunkFlags?).self) { group in
                let width = 3
                var next = 0
                func job(_ item: CompareItem) -> @Sendable () async -> (String, JunkFlags?) {
                    {
                        let key = JunkDetector.analysisKey(for: item)
                        if item.isVideo { return (key, [.analyzed]) }   // bills/blurry checks are for photos
                        var image: CGImage?
                        if let photo = item.photo {
                            image = await PhotoLibraryService.shared.analysisImage(for: photo.id)
                        } else if let file = item.file {
                            image = JunkDetector.diskThumbnail(file.url)
                        }
                        guard let image else { return (key, nil) }
                        return (key, JunkDetector.analyze(image))
                    }
                }
                while next < min(width, todo.count) {
                    group.addTask(operation: job(todo[next]))
                    next += 1
                }
                var sinceUpdate = 0
                while let result = await group.next() {
                    let (key, flags) = result
                    self.visionFlags[key] = flags ?? [.analyzed]
                    self.analysis?.completed += 1
                    sinceUpdate += 1
                    if sinceUpdate >= 150 {
                        sinceUpdate = 0
                        self.applyFilters()
                        self.saveJunkCache()
                    }
                    if next < todo.count, !Task.isCancelled {
                        group.addTask(operation: job(todo[next]))
                        next += 1
                    }
                }
            }
            let checked = analysis?.completed ?? 0
            analysis = nil
            analysisTask = nil
            saveJunkCache()
            applyFilters()
            showBanner("Checked \(checked.formatted()) images for bills, documents and blurry shots.")
        }
    }

    func stopJunkAnalysis() { analysisTask?.cancel() }

    private func saveJunkCache() {
        JunkDetector.saveCache(visionFlags.mapValues(\.rawValue))
    }

    private func selectedPeopleAssets() -> Set<String>? {
        guard !selectedPeople.isEmpty else { return nil }
        let sets = selectedPeople.compactMap { assetsByPerson[$0] }
        guard var result = sets.first else { return [] }
        for s in sets.dropFirst() {
            if peopleMatchAll { result.formIntersection(s) } else { result.formUnion(s) }
        }
        return result
    }

    // MARK: - Selection

    func item(withID id: String) -> CompareItem? { indexByID[id].map { items[$0] } }

    var selectedItems: [CompareItem] { selection.compactMap { item(withID: $0) } }

    var inspectedItem: CompareItem? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return item(withID: id)
    }

    func handleClick(on item: CompareItem) {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        if selectMode && !flags.contains(.shift) {
            // Select mode: every click toggles. The 2nd click of a double-click is ignored so it doesn't undo the 1st.
            guard (event?.clickCount ?? 1) < 2 else { return }
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            selectionAnchor = item.id
            return
        }
        if (event?.clickCount ?? 1) >= 2 {
            selection = [item.id]
            openViewer(item.id)
            return
        }
        if flags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else if flags.contains(.shift), let anchor = selectionAnchor,
                  let a = visibleItems.firstIndex(where: { $0.id == anchor }),
                  let b = visibleItems.firstIndex(where: { $0.id == item.id }) {
            selection.formUnion(visibleItems[min(a, b) ... max(a, b)].map(\.id))
            return
        } else {
            selection = [item.id]
        }
        selectionAnchor = item.id
    }

    func selectAllVisible() { selection = Set(visibleItems.map(\.id)) }

    var allVisibleSelected: Bool {
        !visibleItems.isEmpty && selection.count >= visibleItems.count
            && visibleItems.allSatisfy { selection.contains($0.id) }
    }

    func toggleSelectAll() {
        if allVisibleSelected { clearSelection() } else { selectAllVisible() }
    }
    func clearSelection() { selection.removeAll() }

    /// Items a context-menu action applies to: the whole selection if the clicked item is in it.
    func targets(for item: CompareItem) -> [CompareItem] {
        selection.contains(item.id) ? selectedItems : [item]
    }

    func openViewer(_ id: String? = nil) {
        guard let id = id ?? selection.first ?? visibleItems.first?.id else { return }
        viewerItemID = id
    }

    func neighbor(of id: String, offset: Int) -> String? {
        guard let i = visibleItems.firstIndex(where: { $0.id == id }) else { return nil }
        let j = i + offset
        return visibleItems.indices.contains(j) ? visibleItems[j].id : nil
    }

    // MARK: - Transfers

    var copyableCount: Int { selectedItems.filter(\.canCopyToDisk).count }
    var importableCount: Int { selectedItems.filter(\.canImportToPhotos).count }

    func copySelectionToDisk() { copyToDisk(selectedItems) }
    func importSelectionToPhotos() { importToPhotos(selectedItems) }

    func copyToDisk(_ list: [CompareItem]) {
        let todo = list.filter(\.canCopyToDisk)
        guard !todo.isEmpty else {
            showBanner("Nothing to copy. The selected photos are already on the SSD.")
            return
        }
        guard activity == nil else { return }
        guard let root = diskFolder else { chooseDiskFolder(); return }
        guard FileManager.default.fileExists(atPath: root.path) else {
            showBanner(AppError.folderUnavailable(root.path).localizedDescription, isError: true)
            return
        }

        let organize = organizeByDate
        activity = Activity(title: "Copying to SSD", total: todo.count)
        activityTask = Task { [weak self] in
            guard let self else { return }
            var errors: [String] = []
            await withTaskGroup(of: (String, Result<DiskFile, Error>).self) { group in
                let width = 4
                var next = 0
                while next < min(width, todo.count) {
                    let item = todo[next]
                    next += 1
                    group.addTask { await TransferService.exportToDisk(item, root: root, organizeByDate: organize) }
                }
                var pending: [(String, DiskFile)] = []
                while let next_ = await group.next() {
                    let (id, result) = next_
                    switch result {
                    case .success(let file):
                        pending.append((id, file))
                        self.activity?.completed += 1
                    case .failure(let error):
                        errors.append(error.localizedDescription)
                        self.activity?.failed += 1
                    }
                    if pending.count >= 24 {
                        self.attach(files: pending)
                        pending.removeAll()
                    }
                    if next < todo.count, !Task.isCancelled {
                        let item = todo[next]
                        next += 1
                        group.addTask { await TransferService.exportToDisk(item, root: root, organizeByDate: organize) }
                    }
                }
                self.attach(files: pending)
            }
            finishActivity(verb: "Copied", destination: "to the SSD", errors: errors)
        }
    }

    func importToPhotos(_ list: [CompareItem]) {
        let todo = list.filter(\.canImportToPhotos)
        guard !todo.isEmpty else {
            showBanner("Nothing to add. The selected images are already in Photos.")
            return
        }
        guard activity == nil else { return }
        guard photosAccessGranted else { connectPhotos(); return }

        activity = Activity(title: "Adding to Photos", total: todo.count)
        activityTask = Task { [weak self] in
            guard let self else { return }
            var errors: [String] = []
            for batch in todo.chunked(into: 12) {
                if Task.isCancelled { break }
                let urls = batch.compactMap { $0.file?.url }
                let created = await photoService.importFiles(urls)
                var attached: [(String, PhotoAsset)] = []
                for item in batch {
                    if let url = item.file?.url, let asset = created[url] {
                        attached.append((item.id, asset))
                        activity?.completed += 1
                    } else {
                        errors.append("\(item.name) could not be imported")
                        activity?.failed += 1
                    }
                }
                attach(photos: attached)
            }
            finishActivity(verb: "Added", destination: "to Photos", errors: errors)
        }
    }

    func cancelActivity() { activityTask?.cancel() }

    // MARK: - Delete

    /// The ONLY entry point to deletion. Nothing is deleted unless the user picks a delete button in this
    /// alert. "Cancel" is the default button, so pressing Return or Esc never deletes anything.
    func requestDelete(_ list: [CompareItem]) {
        guard !list.isEmpty, activity == nil else { return }
        let request = DeleteRequest(items: list)
        let photoCount = request.photoCount
        let fileCount = request.fileCount
        let notBackedUp = list.filter { $0.photo != nil && $0.file == nil }.count
        let onlyOnSSD = list.filter { $0.file != nil && $0.photo == nil }.count
        let inBoth = list.filter { $0.status == .both }.count

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete \(list.count.formatted()) \(list.count == 1 ? "image" : "images")?"
        var info = ["Photos go to “Recently Deleted” in Photos (restorable for 30 days). SSD files go to the Trash."]
        if notBackedUp > 0 {
            info.append("⚠️ \(notBackedUp.formatted()) of these are NOT on the SSD. Deleting them from Photos removes your only copy.")
        }
        if onlyOnSSD > 0 {
            info.append("⚠️ \(onlyOnSSD.formatted()) of these are NOT in Photos. Trashing them removes your only copy.")
        }
        alert.informativeText = info.joined(separator: "\n\n")

        enum Choice { case photos, disk, both }
        var choices: [Choice] = []
        alert.addButton(withTitle: "Cancel")          // first button = default (Return) and Esc
        if photoCount > 0 {
            alert.addButton(withTitle: "Delete \(photoCount.formatted()) from Photos").hasDestructiveAction = true
            choices.append(.photos)
        }
        if fileCount > 0 {
            alert.addButton(withTitle: "Move \(fileCount.formatted()) SSD Files to Trash").hasDestructiveAction = true
            choices.append(.disk)
        }
        if inBoth > 0 && photoCount > 0 && fileCount > 0 {
            alert.addButton(withTitle: "Delete Everywhere").hasDestructiveAction = true
            choices.append(.both)
        }

        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard index >= 1, index - 1 < choices.count else { return }   // Cancel / closed: do nothing
        switch choices[index - 1] {
        case .photos: performDelete(request, fromPhotos: true, fromDisk: false)
        case .disk: performDelete(request, fromPhotos: false, fromDisk: true)
        case .both: performDelete(request, fromPhotos: true, fromDisk: true)
        }
    }

    func requestDeleteSelection() { requestDelete(selectedItems) }

    /// Photos go to "Recently Deleted" (recoverable for 30 days); SSD files go to the Trash.
    private func performDelete(_ request: DeleteRequest, fromPhotos: Bool, fromDisk: Bool) {
        let photoIDs = fromPhotos ? request.items.compactMap { $0.photo?.id } : []
        let fileURLs = fromDisk ? request.items.compactMap { $0.file?.url } : []
        guard !photoIDs.isEmpty || !fileURLs.isEmpty else { return }

        activity = Activity(title: "Deleting", total: photoIDs.count + fileURLs.count)
        activityTask = Task { [weak self] in
            guard let self else { return }
            var deletedPhotos = Set<String>()
            var trashed = Set<String>()
            var errors: [String] = []

            if !photoIDs.isEmpty {
                do {
                    try await photoService.deleteAssets(ids: photoIDs)
                    deletedPhotos = Set(photoIDs)
                    activity?.completed += photoIDs.count
                } catch {
                    activity?.failed += photoIDs.count
                    errors.append("Photos deletion was cancelled")
                }
            }
            if !fileURLs.isEmpty {
                let result = await Task.detached(priority: .userInitiated) { () -> (Set<String>, [String]) in
                    var ok = Set<String>()
                    var failed: [String] = []
                    for url in fileURLs {
                        do {
                            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                            ok.insert(url.path)
                        } catch {
                            failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                    return (ok, failed)
                }.value
                trashed = result.0
                errors += result.1
                activity?.completed += result.0.count
                activity?.failed += result.1.count
            }

            removeDeleted(photoIDs: deletedPhotos, filePaths: trashed)
            activity = nil
            activityTask = nil
            var parts: [String] = []
            if !deletedPhotos.isEmpty { parts.append("\(deletedPhotos.count) moved to Recently Deleted in Photos") }
            if !trashed.isEmpty { parts.append("\(trashed.count) SSD files moved to Trash") }
            if errors.isEmpty {
                showBanner(parts.joined(separator: " · ") + ".")
            } else {
                let done = parts.isEmpty ? "Nothing deleted" : parts.joined(separator: " · ")
                showBanner("\(done). \(errors.count) problem(s): \(errors[0])", isError: true)
            }
        }
    }

    private func removeDeleted(photoIDs: Set<String>, filePaths: Set<String>) {
        guard !photoIDs.isEmpty || !filePaths.isEmpty else { return }
        items = items.compactMap { item in
            var item = item
            if let p = item.photo, photoIDs.contains(p.id) { item.photo = nil }
            if let f = item.file, filePaths.contains(f.url.path) { item.file = nil }
            metaFlagCache.removeValue(forKey: item.id)
            return item.photo == nil && item.file == nil ? nil : item
        }
        photos.removeAll { photoIDs.contains($0.id) }
        diskFiles.removeAll { filePaths.contains($0.url.path) }
        rebuildIndex()
        if !duplicateGroups.isEmpty { setDuplicateGroups(duplicateGroups) }
        selection = selection.filter { indexByID[$0] != nil }
        applyFilters()
    }

    private func attach(files list: [(String, DiskFile)]) {
        guard !list.isEmpty else { return }
        for (id, file) in list {
            if let i = indexByID[id] { items[i].file = file }
            metaFlagCache.removeValue(forKey: id)
            diskFiles.append(file)
        }
        applyFilters()
    }

    private func attach(photos list: [(String, PhotoAsset)]) {
        guard !list.isEmpty else { return }
        for (id, asset) in list {
            if let i = indexByID[id] { items[i].photo = asset }
            metaFlagCache.removeValue(forKey: id)
            photos.append(asset)
        }
        applyFilters()
    }

    private func finishActivity(verb: String, destination: String, errors: [String]) {
        let done = activity?.completed ?? 0
        let cancelled = activityTask?.isCancelled ?? false
        activity = nil
        activityTask = nil
        let noun = done == 1 ? "image" : "images"
        if errors.isEmpty {
            showBanner("\(verb) \(done) \(noun) \(destination)\(cancelled ? " (stopped)" : "").")
        } else {
            showBanner("\(verb) \(done) \(noun). \(errors.count) failed: \(errors[0])", isError: true)
        }
    }

    // MARK: - People

    func loadPeople() {
        peopleTask?.cancel()
        peopleState = .loading
        let url = URL(fileURLWithPath: photosLibraryPath)
        let unnamed = includeUnnamedPeople
        peopleTask = Task { [weak self] in
            do {
                let index = try await Task.detached(priority: .utility) {
                    try await PeopleService.load(libraryURL: url, includeUnnamed: unnamed)
                }.value
                guard let self, !Task.isCancelled else { return }
                people = index.people
                assetsByPerson = index.assetsByPerson
                personNames = Dictionary(uniqueKeysWithValues: index.people.map { ($0.id, $0.name) })
                var reverse: [String: [Int64]] = [:]
                for (pid, uuids) in index.assetsByPerson {
                    for u in uuids { reverse[u, default: []].append(pid) }
                }
                peopleByAsset = reverse
                selectedPeople = selectedPeople.filter { index.assetsByPerson[$0] != nil }
                peopleState = .loaded
                applyFilters()
            } catch PeopleService.PeopleError.noAccess {
                self?.peopleState = .needsAccess
            } catch {
                guard !(error is CancellationError) else { return }
                self?.peopleState = .failed(error.localizedDescription)
            }
        }
    }

    func togglePerson(_ id: Int64) {
        if selectedPeople.contains(id) { selectedPeople.remove(id) } else { selectedPeople.insert(id) }
    }

    func peopleNames(for item: CompareItem) -> [String] {
        guard let uuid = item.photo?.uuid, let ids = peopleByAsset[uuid] else { return [] }
        return ids.compactMap { personNames[$0] }.sorted()
    }

    func avatarAssetID(for person: Person) -> String? {
        if let u = person.keyAssetUUID, let id = photoService.localIdentifier(forUUID: u) { return id }
        for u in assetsByPerson[person.id] ?? [] {
            if let id = photoService.localIdentifier(forUUID: u) { return id }
        }
        return nil
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(PeopleService.fullDiskAccessSettingsURL())
    }

    func choosePhotosLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.package, .folder]
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Pictures")
        panel.prompt = "Use Library"
        if panel.runModal() == .OK, let url = panel.url { photosLibraryPath = url.path }
    }

    // MARK: - Misc

    func reveal(_ items: [CompareItem]) {
        let urls = items.compactMap { $0.file?.url }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func dragProvider(for item: CompareItem) -> NSItemProvider {
        if let url = item.file?.url, let provider = NSItemProvider(contentsOf: url) { return provider }
        return NSItemProvider(object: item.name as NSString)
    }

    func showBanner(_ message: String, isError: Bool = false) {
        let b = Banner(message: message, isError: isError)
        banner = b
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 7 : 4))
            if self?.banner?.id == b.id { self?.banner = nil }
        }
    }

    func clearCaches() {
        AppPaths.clearCaches()
        showBanner("Caches cleared. They will rebuild on the next scan.")
    }
}

// MARK: - iPhone

extension AppModel {
    private func setUpDevices() {
        deviceService.onDevicesChanged = { [weak self] list in
            guard let self else { return }
            devices = list
            if let open = openDeviceID, !list.contains(where: { $0.id == open }) { closeDevice() }
        }
        deviceService.onStateChanged = { [weak self] id, state in
            self?.deviceStates[id] = state
        }
        deviceService.onCatalog = { [weak self] id, files in
            guard let self, id == openDeviceID else { return }
            let selected = deviceSelection
            deviceFiles = files
            refreshDeviceMatches()
            deviceSelection = selected.filter { sid in files.contains { $0.id == sid } }
        }
        deviceService.start()
    }

    var openDevice: DeviceInfo? { devices.first { $0.id == openDeviceID } }
    var isBrowsingDevice: Bool { openDeviceID != nil }

    func openDevice(_ id: String) {
        guard openDeviceID != id else { return }
        openDeviceID = id
        deviceFiles = []
        visibleDeviceFiles = []
        deviceSelection = []
        deviceService.open(id)
    }

    func closeDevice() {
        openDeviceID = nil
        deviceFiles = []
        visibleDeviceFiles = []
        deviceSelection = []
    }

    /// Re-checks every iPhone photo against Photos and the SSD with the strict matching rules.
    func refreshDeviceMatches() {
        guard !deviceFiles.isEmpty else { applyDeviceFilters(); return }
        let photoIndex = MatchIndex(photos)
        let diskIndex = MatchIndex(diskFiles)
        for i in deviceFiles.indices {
            deviceFiles[i].photoMatchID = photoIndex.find(deviceFiles[i])?.id
            deviceFiles[i].diskMatchPath = diskIndex.find(deviceFiles[i])?.url.path
        }
        applyDeviceFilters()
    }

    func applyDeviceFilters() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var c: [DeviceFilter: Int] = [:]
        var out: [DeviceFile] = []
        for f in deviceFiles {
            if !q.isEmpty && !f.name.localizedCaseInsensitiveContains(q) { continue }
            for filter in DeviceFilter.allCases where filter.includes(f) { c[filter, default: 0] += 1 }
            if deviceFilter.includes(f) { out.append(f) }
        }
        deviceCounts = c
        visibleDeviceFiles = out
    }

    func deviceFile(withID id: String) -> DeviceFile? { deviceFiles.first { $0.id == id } }
    var selectedDeviceFiles: [DeviceFile] { deviceFiles.filter { deviceSelection.contains($0.id) } }

    func handleDeviceClick(on file: DeviceFile) {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        if selectMode && !flags.contains(.shift) {
            guard (event?.clickCount ?? 1) < 2 else { return }
            if deviceSelection.contains(file.id) { deviceSelection.remove(file.id) } else { deviceSelection.insert(file.id) }
            deviceAnchor = file.id
            return
        }
        if flags.contains(.command) {
            if deviceSelection.contains(file.id) { deviceSelection.remove(file.id) } else { deviceSelection.insert(file.id) }
        } else if flags.contains(.shift), let anchor = deviceAnchor,
                  let a = visibleDeviceFiles.firstIndex(where: { $0.id == anchor }),
                  let b = visibleDeviceFiles.firstIndex(where: { $0.id == file.id }) {
            deviceSelection.formUnion(visibleDeviceFiles[min(a, b) ... max(a, b)].map(\.id))
            return
        } else {
            deviceSelection = [file.id]
        }
        deviceAnchor = file.id
    }

    // MARK: Mode-aware helpers used by the toolbar

    var allCurrentSelected: Bool {
        if isBrowsingDevice {
            return !visibleDeviceFiles.isEmpty && visibleDeviceFiles.allSatisfy { deviceSelection.contains($0.id) }
        }
        return allVisibleSelected
    }

    var currentIsEmpty: Bool { isBrowsingDevice ? visibleDeviceFiles.isEmpty : visibleItems.isEmpty }

    func toggleSelectAllCurrent() {
        if isBrowsingDevice {
            deviceSelection = allCurrentSelected ? [] : Set(visibleDeviceFiles.map(\.id))
        } else {
            toggleSelectAll()
        }
    }

    var currentCopyableCount: Int {
        isBrowsingDevice ? selectedDeviceFiles.filter { !$0.onDisk }.count : copyableCount
    }

    var currentImportableCount: Int {
        isBrowsingDevice ? selectedDeviceFiles.filter { !$0.inPhotos }.count : importableCount
    }

    func copyCurrentSelectionToDisk() {
        if isBrowsingDevice { copyDeviceFilesToDisk(selectedDeviceFiles) } else { copySelectionToDisk() }
    }

    func importCurrentSelectionToPhotos() {
        if isBrowsingDevice { importDeviceFilesToPhotos(selectedDeviceFiles) } else { importSelectionToPhotos() }
    }

    // MARK: Transfers from the iPhone (originals, byte-exact)

    func copyDeviceFilesToDisk(_ list: [DeviceFile]) {
        let todo = list.filter { !$0.onDisk }
        guard !todo.isEmpty else { showBanner("Nothing to copy. These photos are already on the SSD."); return }
        guard activity == nil else { return }
        guard let root = diskFolder else { chooseDiskFolder(); return }
        guard FileManager.default.fileExists(atPath: root.path) else {
            showBanner(AppError.folderUnavailable(root.path).localizedDescription, isError: true)
            return
        }
        let organize = organizeByDate
        activity = Activity(title: "Copying from iPhone", total: todo.count)
        activityTask = Task { [weak self] in
            guard let self else { return }
            var errors: [String] = []
            var added: [DiskFile] = []
            for file in todo {
                if Task.isCancelled { break }
                var folder = root
                if organize, let d = file.date {
                    folder = root.appendingPathComponent(FileUtils.dateFolder(for: d), isDirectory: true)
                }
                do {
                    let url = try await downloadSafely(file, into: folder)
                    let meta = DiskScanner.readMetadata(url)
                    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? file.fileSize
                    added.append(DiskFile(url: url, fileSize: size, modified: file.date,
                                          captureDate: meta.date ?? file.date,
                                          pixelWidth: meta.width > 0 ? meta.width : file.width,
                                          pixelHeight: meta.height > 0 ? meta.height : file.height))
                    activity?.completed += 1
                } catch {
                    errors.append("\(file.name): \(error.localizedDescription)")
                    activity?.failed += 1
                }
            }
            diskFiles.append(contentsOf: added)
            finishDeviceActivity(verb: "Copied", destination: "from the iPhone to the SSD", errors: errors)
            await rematch()
        }
    }

    func importDeviceFilesToPhotos(_ list: [DeviceFile]) {
        let todo = list.filter { !$0.inPhotos }
        guard !todo.isEmpty else { showBanner("Nothing to add. These photos are already in Photos."); return }
        guard activity == nil else { return }
        guard photosAccessGranted else { connectPhotos(); return }

        activity = Activity(title: "Adding iPhone photos to Photos", total: todo.count)
        activityTask = Task { [weak self] in
            guard let self else { return }
            var errors: [String] = []
            // Our own private staging folder; only this folder is ever cleaned up.
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("PhotoBridge-import-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }

            for batch in todo.chunked(into: 10) {
                if Task.isCancelled { break }
                var urls: [URL] = []
                var names: [URL: String] = [:]
                for file in batch {
                    do {
                        let dir = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let url = try await deviceService.download(file.id, into: dir, as: file.name)
                        urls.append(url)
                        names[url] = file.name
                    } catch {
                        errors.append("\(file.name): \(error.localizedDescription)")
                        activity?.failed += 1
                    }
                }
                let created = await photoService.importFiles(urls)
                for url in urls {
                    if let asset = created[url] {
                        photos.append(asset)
                        activity?.completed += 1
                    } else {
                        errors.append("\(names[url] ?? url.lastPathComponent) could not be added to Photos")
                        activity?.failed += 1
                    }
                    try? FileManager.default.removeItem(at: url)   // staging copy only
                }
            }
            finishDeviceActivity(verb: "Added", destination: "from the iPhone to Photos", errors: errors)
            await rematch()
        }
    }

    /// Downloads into a hidden temp name inside `folder`, then moves it to a free name. Never overwrites.
    private func downloadSafely(_ file: DeviceFile, into folder: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let tempName = ".photobridge-\(UUID().uuidString).partial"
        let temp: URL
        do {
            temp = try await deviceService.download(file.id, into: folder, as: tempName)
        } catch {
            let maybe = folder.appendingPathComponent(tempName)
            if fm.fileExists(atPath: maybe.path) { try? fm.removeItem(at: maybe) }
            throw error
        }
        var lastError: Error?
        for _ in 0 ..< 5 {
            let destination = FileUtils.reserveUniqueURL(in: folder, filename: file.name)
            defer { FileUtils.release(destination) }
            do {
                try fm.moveItem(at: temp, to: destination)
                if let d = file.date {
                    try? fm.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: destination.path)
                }
                return destination
            } catch {
                lastError = error
            }
        }
        try? fm.removeItem(at: temp)
        throw lastError ?? AppError.noResource
    }

    private func finishDeviceActivity(verb: String, destination: String, errors: [String]) {
        let done = activity?.completed ?? 0
        activity = nil
        activityTask = nil
        let noun = done == 1 ? "photo" : "photos"
        if errors.isEmpty {
            showBanner("\(verb) \(done) \(noun) \(destination) at original quality.")
        } else {
            showBanner("\(verb) \(done) \(noun). \(errors.count) failed: \(errors[0])", isError: true)
        }
    }
}
