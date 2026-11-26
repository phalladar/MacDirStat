import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Set before the Dock tile appears so it never flashes the generic executable icon.
        if let icon = Self.appIcon() {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }

    // Same lookup as SPM's Bundle.module, which calls fatalError when the resource bundle
    // isn't beside the binary (e.g. the binary was copied elsewhere). A missing icon shouldn't crash.
    private static func appIcon() -> NSImage? {
        [Bundle.main.resourceURL, Bundle.main.bundleURL]
            .lazy
            .compactMap { $0.flatMap { Bundle(url: $0.appendingPathComponent("MacDirStat_MacDirStat.bundle")) } }
            .first?
            .image(forResource: "AppIcon")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct MacDirStatApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            OpenFolderCommands()
            TreemapCommands(appState: appState)
        }
    }
}

/// Menu commands read focused values from the key window, so ⌘O acts on the window in front.
struct OpenFolderCommands: Commands {
    @FocusedValue(\.openFolderAction) private var openFolder

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Folder...") {
                openFolder?()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(openFolder == nil)
        }
    }
}

/// The treemap's View menu items. Detail, color, Back and the inspector live in the shared
/// `AppState`; zoom and rescan belong to a window, so they come from the key window's focused values.
struct TreemapCommands: Commands {
    let appState: AppState
    @FocusedValue(\.resetZoomAction) private var resetZoom
    @FocusedValue(\.rescanAction) private var rescan

    var body: some Commands {
        let hasTree = appState.scanStatus == .completed
        CommandGroup(before: .sidebar) {
            Button("More Detail") { appState.moreDetail() }
                .keyboardShortcut("+")
                .disabled(!hasTree || !appState.canMoreDetail)
            Button("Less Detail") { appState.lessDetail() }
                .keyboardShortcut("-")
                .disabled(!hasTree || !appState.canLessDetail)
            Button("Collapse All") { appState.collapseAll() }
                .disabled(!hasTree || !appState.canCollapseAll)
            Toggle("Show Folders", isOn: Bindable(appState).showsFolders)

            Divider()

            Picker("Color", selection: Bindable(appState).colorMode) {
                Text("Color by Type").tag(TreemapColorMode.type)
                Text("Color by Folder").tag(TreemapColorMode.folder)
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()

            Button("Actual Size") { resetZoom?() }
                .keyboardShortcut("0")
                .disabled(resetZoom == nil)
            Button("Back") { appState.navigateUp() }
                .keyboardShortcut("[")
                .disabled(!hasTree || appState.treemapRoot?.parent == nil)
            Button(appState.treemapRoot.map { "Rescan \u{201C}\($0.displayName)\u{201D}" } ?? "Rescan") { rescan?(false) }
                .keyboardShortcut("r")
                .disabled(rescan == nil)
            Button("Rescan Everything") { rescan?(true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(rescan == nil)

            Divider()

            Button(appState.showInspector ? "Hide Inspector" : "Show Inspector", action: appState.toggleInspector)
            .keyboardShortcut("i", modifiers: [.command, .option])

            Divider()
        }
    }
}
