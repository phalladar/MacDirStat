import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var coordinator: ScanCoordinator?
    @FocusedValue(\.zoomInAction) private var zoomIn
    @FocusedValue(\.zoomOutAction) private var zoomOut
    @FocusedValue(\.resetZoomAction) private var resetZoom

    var body: some View {
        @Bindable var state = appState

        NavigationSplitView {
            if let root = appState.rootNode {
                DirectoryTreeView(root: root, selectedNode: $state.selectedNode)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
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

                            // Treemap
                            TreemapView(
                                root: treemapRoot,
                                onSelect: { node in
                                    appState.selectedNode = node
                                },
                                onDrillDown: { node in
                                    appState.drillDown(to: node)
                                }
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
                DetailPanelView(node: selected)
                    .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
            } else {
                Text("Select an item to view details")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    selectAndScan()
                } label: {
                    Label("Scan Drive", systemImage: "internaldrive.fill")
                }

                Picker("Size", selection: $state.sizeMetric) {
                    ForEach(SizeMetric.allCases, id: \.self) { metric in
                        Text(metric.rawValue).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Button {
                    zoomIn?()
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .disabled(zoomIn == nil)

                Button {
                    zoomOut?()
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .disabled(zoomOut == nil)

                Button {
                    resetZoom?()
                } label: {
                    Label("Reset Zoom", systemImage: "1.magnifyingglass")
                }
                .disabled(resetZoom == nil)

                Button {
                    appState.showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
            }

            ToolbarItem(placement: .navigation) {
                if appState.treemapRoot?.parent != nil {
                    Button {
                        appState.navigateUp()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            }
        }
        .onAppear {
            if coordinator == nil {
                coordinator = ScanCoordinator(appState: appState)
            }
        }
        .focusedSceneValue(\.scanAction, {
            selectAndScan()
        })
    }

    private func selectAndScan() {
        coordinator?.cancel()
        appState.reset()
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

                    Button {
                        onNavigate(node)
                    } label: {
                        Text(node.name)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == breadcrumbs.count - 1 ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

// MARK: - Focused Value for Menu Commands

struct ScanActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ZoomInActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ZoomOutActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ResetZoomActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var scanAction: (() -> Void)? {
        get { self[ScanActionKey.self] }
        set { self[ScanActionKey.self] = newValue }
    }

    var zoomInAction: (() -> Void)? {
        get { self[ZoomInActionKey.self] }
        set { self[ZoomInActionKey.self] = newValue }
    }

    var zoomOutAction: (() -> Void)? {
        get { self[ZoomOutActionKey.self] }
        set { self[ZoomOutActionKey.self] = newValue }
    }

    var resetZoomAction: (() -> Void)? {
        get { self[ResetZoomActionKey.self] }
        set { self[ResetZoomActionKey.self] = newValue }
    }
}
