import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PhotoBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("PhotoBridge", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
                .task { model.start() }
        }
        .defaultSize(width: 1380, height: 880)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Choose SSD Folder…") { model.chooseDiskFolder() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Rescan Everything") { model.refreshAll() }
                .keyboardShortcut("r", modifiers: .command)
        }
        CommandMenu("Transfer") {
            Button("Copy Selection to SSD") { model.copyCurrentSelectionToDisk() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Add Selection to Photos") { model.importCurrentSelectionToPhotos() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Select All Images") { if !model.allCurrentSelected { model.toggleSelectAllCurrent() } }
            Button("Deselect All") { model.clearSelection() }
                .keyboardShortcut("d", modifiers: [.command])
            Button("Delete Selection…") { if !model.isBrowsingDevice { model.requestDeleteSelection() } }
                .keyboardShortcut(.delete, modifiers: .command)
            Divider()
            Button("Find Bills & Blurry Photos") { model.startJunkAnalysis() }
            Divider()
            Button("Open Viewer") { model.openViewer() }
                .keyboardShortcut("y", modifiers: .command)
            Button("Reveal in Finder") { model.reveal(model.selectedItems) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            ForEach(Array(CompareFilter.allCases.enumerated()), id: \.element) { index, filter in
                Button(filter.title) { model.filter = filter }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button("Larger Thumbnails") { model.thumbnailSize = min(340, model.thumbnailSize + 30) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Thumbnails") { model.thumbnailSize = max(90, model.thumbnailSize - 30) }
                .keyboardShortcut("-", modifiers: .command)
        }
    }
}
