import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var coordinator: ScanCoordinator?
    /// The scanned volume's usage for the status bar, read once per scan.
    @State private var volumeSummary = ""

    var body: some View {
        @Bindable var state = appState

        NavigationSplitView {
            if appState.rootNode != nil {
                DirectoryTreeView(
                    onRescan: { node in coordinator?.rescan(node) },
                    onTrash: { node in coordinator?.moveToTrash(node) }
                )
                    .navigationSplitViewColumnWidth(min: 200, ideal: 300, max: 400)
            } else {
                Text("No data")
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            }
        } detail: {
            ZStack {
                switch appState.scanStatus {
                case .idle:
                    WelcomeView { path in
                        coordinator?.startScan(path: path)
                    }
                    .transition(.opacity)

                case let .scanning(fileCount, byteCount, currentPath):
                    ScanProgressView(
                        fileCount: fileCount,
                        byteCount: byteCount,
                        currentPath: currentPath
                    ) {
                        coordinator?.cancel()
                        appState.scanStatus = .idle
                    }

                case .completed:
                    if let treemapRoot = appState.treemapRoot {
                        VStack(spacing: 0) {
                            // Breadcrumb bar
                            BreadcrumbBar(
                                breadcrumbs: appState.breadcrumbs,
                                onNavigate: { node in
                                    appState.navigateTo(breadcrumb: node)
                                }
                            )

                            if let root = appState.rootNode,
                               root.unscannedDirectoryCount > 0 || root.totalUnavailableEntryCount > 0 {
                                IncompleteScanBanner(root: root) {
                                    coordinator?.startScan(path: root.path)
                                }
                            }

                            // Treemap
                            TreemapView(
                                root: treemapRoot,
                                selectedNode: appState.selectedNode,
                                onSelect: { node in
                                    appState.selectedNode = node
                                },
                                onDrillDown: { node in
                                    appState.drillDown(to: node)
                                },
                                onTrash: { node in
                                    coordinator?.moveToTrash(node)
                                },
                                sizeMetric: appState.sizeMetric,
                                treeVersion: appState.treeVersion,
                                isBusy: appState.busyID != nil,
                                volumeSummary: volumeSummary
                            )
                        }
                    }

                case let .error(message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.red)
                        Text("Scan Error")
                            .font(.title2.bold())
                        Text(message)
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            appState.reset()
                        }
                    }
                }
            }
        }
        .inspector(isPresented: $state.showInspector) {
            if let selected = appState.selectedNode {
                DetailPanelView(node: selected, sizeMetric: appState.sizeMetric, treeVersion: appState.treeVersion)
                    .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
            } else {
                Text("Select an item to view details")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onExitCommand {
            // Esc selects the folder the treemap shows, which draws no outline.
            if let root = appState.treemapRoot { appState.selectedNode = root }
        }
        .toolbar { toolbar }
        .task(id: appState.rootNode.map(ObjectIdentifier.init)) {
            let path = appState.rootNode?.path
            volumeSummary = await Task.detached { path.map(Self.volumeSummary) ?? "" }.value
        }
        .onAppear {
            if coordinator == nil {
                coordinator = ScanCoordinator(appState: appState)
            }
        }
        .background {
            // ⌘= beside the View menu's ⌘+, which AppKit matches only with Shift held.
            Button("", action: appState.moreDetail)
                .keyboardShortcut("=")
                .disabled(!appState.canMoreDetail)
                .hidden()
        }
        .focusedSceneValue(\.openFolderAction, openFolder)
        .focusedSceneValue(\.rescanAction, canRescan ? { rescan(everything: $0) } : nil)
    }

    /// "Macintosh HD · 782 GB used · 81.9 GB free" for the volume holding `path`.
    nonisolated private static func volumeSummary(for path: String) -> String {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let name = values.volumeName, let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacityForImportantUsage else { return "" }
        let used = ByteFormatter.string(from: Int64(total) - free)
        return "\(name) · \(used) used · \(ByteFormatter.string(from: free)) free"
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if appState.treemapRoot?.parent != nil {
                Button("Back", systemImage: "chevron.left") { appState.navigateUp() }
            }
        }

        ToolbarItem(placement: .navigation) {
            Menu {
                Button("Open Folder...") { openFolder() }
            } label: {
                Label("Scan", systemImage: "plus.circle")
            } primaryAction: {
                selectAndScan()
            }
            .help("Choose a drive to scan")
        }

        ToolbarItem(placement: .navigation) {
            Button("Rescan", systemImage: "arrow.clockwise") {
                rescan(everything: NSEvent.modifierFlags.contains(.option))
            }
            .help(appState.treemapRoot.map { "Rescan \($0.displayName)" } ?? "Rescan")
            .disabled(!canRescan)
        }

        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button("Less Detail", systemImage: "minus") { appState.lessDetail() }
                    .disabled(!appState.canLessDetail)
                Button("More Detail", systemImage: "plus") { appState.moreDetail() }
                    .disabled(!appState.canMoreDetail)
            } label: {
                Label("Detail", systemImage: "square.grid.3x3")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Picker("Color", selection: Bindable(appState).colorMode) {
                Label("Color by Type", systemImage: "square.grid.2x2").tag(TreemapColorMode.type)
                Label("Color by Folder", systemImage: "folder").tag(TreemapColorMode.folder)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
        }

        ToolbarItem(placement: .primaryAction) {
            Toggle("Show Folders", systemImage: "rectangle.3.group", isOn: Bindable(appState).showsFolders)
                .help("Show Folders")
        }

        ToolbarItem(placement: .primaryAction) {
            Picker("Size", selection: Binding(get: { appState.sizeMetric }, set: { metric in
                appState.sizeMetric = metric
                // Picking a metric after Scan Drive goes back to the scanned tree.
                if appState.scanStatus == .idle, appState.rootNode != nil {
                    appState.scanStatus = .completed
                }
            })) {
                ForEach(SizeMetric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
        }

        ToolbarItem(placement: .primaryAction) {
            Button("Inspector", systemImage: "sidebar.right", action: appState.toggleInspector)
        }
    }

    private var canRescan: Bool {
        appState.scanStatus == .completed && appState.busyID == nil
    }

    /// Rescans the folder the treemap shows, or the whole scan when it shows the root or `everything` is set.
    private func rescan(everything: Bool) {
        guard let root = appState.rootNode, let shown = appState.treemapRoot else { return }
        if everything || shown === root {
            coordinator?.startScan(path: root.path)
        } else {
            coordinator?.rescan(shown)
        }
    }

    private func selectAndScan() {
        coordinator?.cancel()
        appState.scanStatus = .idle
    }

    private func openFolder() {
        if let path = FolderPicker.chooseFolder() {
            coordinator?.startScan(path: path)
        }
    }
}

// MARK: - Breadcrumb Bar

struct BreadcrumbBar: View {
    let breadcrumbs: [FileNode]
    let onNavigate: (FileNode) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(breadcrumbs.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    let isLast = index == breadcrumbs.count - 1
                    Button {
                        onNavigate(node)
                    } label: {
                        Text(node.displayName)
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .foregroundStyle(isLast ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .background(isLast ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(node.path)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }
}

// MARK: - Focused Values for Menu Commands

struct OpenFolderActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ResetZoomActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct RescanActionKey: FocusedValueKey {
    typealias Value = (_ everything: Bool) -> Void
}

extension FocusedValues {
    var openFolderAction: (() -> Void)? {
        get { self[OpenFolderActionKey.self] }
        set { self[OpenFolderActionKey.self] = newValue }
    }

    var resetZoomAction: (() -> Void)? {
        get { self[ResetZoomActionKey.self] }
        set { self[ResetZoomActionKey.self] = newValue }
    }

    /// Rescans the front window's shown folder, or everything when passed `true`.
    var rescanAction: ((_ everything: Bool) -> Void)? {
        get { self[RescanActionKey.self] }
        set { self[RescanActionKey.self] = newValue }
    }
}
