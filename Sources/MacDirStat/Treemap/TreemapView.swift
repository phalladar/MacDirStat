import OSLog
import SwiftUI

/// Points of Interest intervals for Instruments: "layout" and "draw".
enum TreemapSignposts {
    static let signposter = OSSignposter(subsystem: "MacDirStat", category: .pointsOfInterest)
}

struct TreemapView: View {
    let root: FileNode
    let selectedNode: FileNode?
    let onSelect: (FileNode) -> Void
    let onDrillDown: (FileNode) -> Void
    let onTrash: (FileNode) -> Void
    let sizeMetric: SizeMetric
    let treeVersion: Int
    let isBusy: Bool
    /// "Macintosh HD · 782 GB used · 81.9 GB free", shown in the status bar when nothing is hovered.
    let volumeSummary: String
    @Environment(AppState.self) private var appState
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var items: [TreemapItem] = []
    @State private var hoveredItemID: Int?
    /// Item index by node, so the shared selection maps to its rectangle without a search.
    @State private var itemIndexByNode: [ObjectIdentifier: Int] = [:]
    /// Each folder's smallerItems item, which itemIndexByNode leaves out since it shares the folder's node.
    @State private var smallerItemsByFolder: [ObjectIdentifier: Int] = [:]
    @State private var cursor = TreemapCursor()
    @State private var lastSize: CGSize = .zero
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGPoint = .zero
    @State private var showLabels: Bool = true
    @State private var labelDebounce: Task<Void, Never>?
    /// Key of this view's layout in AppState.layoutTasks.
    @State private var layoutID = UUID()
    /// From the previous layout to `items`, while it runs; hit testing already uses `items`.
    @State private var transition: TreemapTransition?
    @State private var transitionStart = Date()
    /// Bumped with every new layout, so the accessibility layer rebuilds only then.
    @State private var layoutGeneration = 0

    private var hoveredItem: TreemapItem? {
        guard let id = hoveredItemID, items.indices.contains(id) else { return nil }
        return items[id]
    }

    private var selectedItemID: Int? {
        Self.selectedItemID(of: selectedNode, shown: root, items: itemIndexByNode, smallerItems: smallerItemsByFolder)
    }

    /// The selected node's rectangle; for a folder without one (folders not shown), its own
    /// smallerItems block; the block it was folded into; or its nearest ancestor's, when it sits
    /// inside a closed folder. The shown folder itself has none.
    static func selectedItemID(of selected: FileNode?, shown root: FileNode, items: [ObjectIdentifier: Int],
                               smallerItems: [ObjectIdentifier: Int]) -> Int? {
        var node = selected
        while let current = node, current !== root {
            // With folders shown, a folder with a block of its own has an item, found first.
            if let index = items[ObjectIdentifier(current)] ?? smallerItems[ObjectIdentifier(current)] { return index }
            // Only open folders lay out children, so a block in the parent means it holds this one.
            if let parent = current.parent, let block = smallerItems[ObjectIdentifier(parent)] { return block }
            node = current.parent
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
        GeometryReader { geometry in
            ZStack {
                // Base treemap — only redraws when items change
                if let transition {
                    // In the tree only while a transition runs, so an idle treemap gets no ticks.
                    TimelineView(.animation) { timeline in
                        let elapsed = timeline.date.timeIntervalSince(transitionStart)
                        let frame = transition.frame(at: TreemapTransition.progress(elapsed: elapsed))
                        baseCanvas(items: frame.map { $0.item.moved(to: $0.rect) }, opacities: frame.map(\.opacity))
                    }
                    .task(id: transitionStart) {
                        try? await Task.sleep(for: .seconds(TreemapTransition.duration))
                        if !Task.isCancelled { self.transition = nil }
                    }
                } else {
                    baseCanvas(items: items, opacities: nil)
                }

                // Both overlays trace `items`, where the transition ends; they wait for it.
                TreemapSelectionOverlay(
                    items: items,
                    selectedItemID: transition == nil ? selectedItemID : nil,
                    zoomScale: zoomScale,
                    panOffset: panOffset
                )

                // Lightweight hover overlay — redraws only the single highlight rect
                TreemapHoverOverlay(
                    item: transition == nil ? hoveredItem : nil,
                    zoomScale: zoomScale,
                    panOffset: panOffset
                )

                // Hidden with the labels while zooming or panning.
                if showLabels, let item = hoveredItem {
                    TreemapTooltipLayer(cursor: cursor, item: item, root: root, sizeMetric: sizeMetric)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Treemap")
            .accessibilityChildren {
                // Zoom and pan move the whole layer, so they don't re-evaluate its elements.
                TreemapAccessibilityLayer(generation: layoutGeneration, items: items, root: root, sizeMetric: sizeMetric)
                    .equatable()
                    .scaleEffect(zoomScale, anchor: .topLeading)
                    .offset(x: panOffset.x, y: panOffset.y)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    cursor.location = location
                    hoveredItemID = hitTestID(at: screenToContent(location))
                case .ended:
                    hoveredItemID = nil
                }
            }
            .onTapGesture { location in
                click(at: location)
            }
            .contextMenu {
                Group {
                    if let item = hoveredItem {
                        Button("Reveal in Finder", systemImage: "arrow.right.circle") {
                            FileActions.revealInFinder(item.node)
                        }
                        Button("Copy Path", systemImage: "doc.on.doc") {
                            FileActions.copyPath(item.node)
                        }
                        if let target = drillDownTarget(for: item.node) {
                            Divider()
                            Button("Drill Down into \(target.name)", systemImage: "square.grid.2x2") {
                                onDrillDown(target)
                            }
                        }
                        // A smallerItems item's node is its folder, often the shown one: not for trashing.
                        if item.node.parent != nil, !item.isSmallerItems {
                            Divider()
                            MoveToTrashButton(node: item.node, isBusy: isBusy, action: onTrash)
                        }
                    }
                }
                .labelStyle(.titleAndIcon) // macOS menus show only titles without it
            }
            .overlay {
                ZoomPanOverlay(
                    onZoom: { factor, center in
                        performZoom(by: factor, centeredAt: center, viewSize: geometry.size)
                    },
                    onPanDelta: { dx, dy in
                        panOffset.x += dx
                        panOffset.y += dy
                        clampPan(viewSize: geometry.size)
                        suppressLabelsDuringInteraction()
                    },
                    onMiddleClick: { location in
                        performZoom(by: 0.5, centeredAt: location, viewSize: geometry.size)
                    }
                )
            }
            .onChange(of: geometry.size) { _, newSize in
                recomputeLayout(size: newSize)
            }
            .onAppear {
                recomputeLayout(size: geometry.size)
            }
            .onChange(of: root.id) {
                zoomScale = 1.0
                panOffset = .zero
                recomputeLayout(size: geometry.size, animated: true)
            }
            .onChange(of: sizeMetric) {
                recomputeLayout(size: geometry.size)
            }
            .onChange(of: treeVersion) {
                recomputeLayout(size: geometry.size)
            }
            .onChange(of: appState.detailLevel) {
                recomputeLayout(size: geometry.size)
            }
            .onChange(of: appState.showsFolders) {
                recomputeLayout(size: geometry.size)
            }
            .onChange(of: appState.folderOverrides) {
                recomputeLayout(size: geometry.size, animated: true)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))

        TreemapStatusBar(item: hoveredItem, volumeSummary: volumeSummary, sizeMetric: sizeMetric)
        }
        .focusedSceneValue(\.resetZoomAction) {
            zoomScale = 1.0
            panOffset = .zero
        }
    }

    private func baseCanvas(items: [TreemapItem], opacities: [Double]?) -> TreemapBaseCanvas {
        TreemapBaseCanvas(
            items: items,
            opacities: opacities,
            zoomScale: zoomScale,
            panOffset: panOffset,
            showLabels: showLabels,
            sizeMetric: sizeMetric,
            colorMode: appState.colorMode,
            contrast: contrast
        )
    }

    private func screenToContent(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - panOffset.x) / zoomScale,
            y: (point.y - panOffset.y) / zoomScale
        )
    }

    private func performZoom(by factor: CGFloat, centeredAt point: CGPoint, viewSize: CGSize) {
        let oldScale = zoomScale
        let newScale = max(1.0, min(oldScale * (1 + factor), 50.0))
        guard newScale != oldScale else { return }

        // Keep the point under cursor fixed in screen space
        let contentPoint = CGPoint(
            x: (point.x - panOffset.x) / oldScale,
            y: (point.y - panOffset.y) / oldScale
        )
        zoomScale = newScale
        panOffset = CGPoint(
            x: point.x - contentPoint.x * newScale,
            y: point.y - contentPoint.y * newScale
        )
        clampPan(viewSize: viewSize)
        suppressLabelsDuringInteraction()
    }

    private func suppressLabelsDuringInteraction() {
        showLabels = false
        labelDebounce?.cancel()
        labelDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            showLabels = true
        }
    }

    private func clampPan(viewSize: CGSize) {
        let contentWidth = viewSize.width * zoomScale
        let contentHeight = viewSize.height * zoomScale
        panOffset.x = min(0, max(viewSize.width - contentWidth, panOffset.x))
        panOffset.y = min(0, max(viewSize.height - contentHeight, panOffset.y))
    }

    /// Every click of a double click lands here, so a single click acts at once instead of
    /// waiting out the double-click interval. The second click drills into what the first one
    /// hit: opening that folder in place may have put a different item under the cursor.
    private func click(at location: CGPoint) {
        switch NSApp.currentEvent?.clickCount ?? 1 {
        case 1:
            let point = screenToContent(location)
            // Items laid out before a trash can point at detached nodes; clicking those does nothing.
            guard let item = hitTestItem(at: point), item.node.isInSubtree(of: root) else {
                cursor.clickedNode = nil
                return
            }
            cursor.clickedNode = item.node
            switch item.kind {
            case .closedFolder:
                appState.setFolderOpen(item.node, true)
                onSelect(item.node)
            case .openFolder where isOnChevron(point, of: item, zoomScale: zoomScale):
                appState.setFolderOpen(item.node, false)
            case .openFolder, .file, .smallerItems:
                onSelect(item.node) // a smallerItems item's node is the folder that holds them
            }
        case 2:
            if let node = cursor.clickedNode, let target = drillDownTarget(for: node) { onDrillDown(target) }
        default:
            break
        }
    }

    private func hitTestID(at point: CGPoint) -> Int? {
        hitTestItem(at: point)?.id
    }

    /// Items are drawn in order, so the last one containing the point is the deepest one on top.
    private func hitTestItem(at point: CGPoint) -> TreemapItem? {
        items.last { $0.rect.contains(point: point) }
    }

    private func drillDownTarget(for node: FileNode) -> FileNode? {
        Self.drillDownTarget(for: node, shown: root, sizeMetric: sizeMetric)
    }

    /// Folders drill into themselves. Files, which cover most of the treemap, drill into the
    /// folder that contains them, unless that folder is already the one shown. A folder with
    /// nothing to lay out would show an empty view, so it offers none.
    static func drillDownTarget(for node: FileNode, shown root: FileNode, sizeMetric: SizeMetric) -> FileNode? {
        guard let target = node.isDirectory ? node : node.parent, target !== root,
              target.children.contains(where: { $0.size(for: sizeMetric) > 0 }) else { return nil }
        return target
    }

    /// `animated` is for navigation and opening or closing folders; resizes and metric or detail
    /// changes swap at once, as does everything under Reduce Motion.
    private func recomputeLayout(size: CGSize, animated: Bool = false) {
        guard size.width > 0 && size.height > 0 else { return }
        lastSize = size

        let animated = animated && !reduceMotion
        let metric = sizeMetric
        let level = appState.detailLevel
        let overrides = appState.folderOverrides
        let showsFolders = appState.showsFolders
        let previous = appState.layoutTasks[layoutID]
        previous?.cancel()
        appState.layoutTasks[layoutID] = Task.detached { [root] in
            // One layout per view reads the tree at a time, so replace(_:with:) only waits for the last.
            await previous?.value
            guard !Task.isCancelled else { return }
            let engine = TreemapLayoutEngine()
            let bounds = TreemapRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
            let interval = TreemapSignposts.signposter.beginInterval("layout")
            let newItems = engine.layout(root: root, in: bounds, sizeMetric: metric,
                                         detailLevel: level, overrides: overrides, showsFolders: showsFolders)
            TreemapSignposts.signposter.endInterval("layout", interval)
            // A smallerItems item shares its folder's node, so it goes in a map of its own.
            var index: [ObjectIdentifier: Int] = [:], smaller: [ObjectIdentifier: Int] = [:]
            index.reserveCapacity(newItems.count)
            for item in newItems {
                if case .smallerItems = item.kind {
                    smaller[ObjectIdentifier(item.node)] = item.id
                } else {
                    index[ObjectIdentifier(item.node)] = item.id
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if animated && !items.isEmpty {
                    let now = Date()
                    transition = if let running = transition {
                        TreemapTransition(from: running, at: TreemapTransition.progress(elapsed: now.timeIntervalSince(transitionStart)),
                                          to: newItems)
                    } else {
                        TreemapTransition(from: items, to: newItems)
                    }
                    transitionStart = now
                } else {
                    transition = nil
                }
                items = newItems
                layoutGeneration &+= 1
                itemIndexByNode = index
                smallerItemsByFolder = smaller
                // The layout can move items under a still cursor, as when a click opens a folder.
                if hoveredItemID != nil { hoveredItemID = hitTestID(at: screenToContent(cursor.location)) }
            }
        }
    }
}

/// In the title strip of a framed folder, in layout points.
func isOnTitle(_ point: CGPoint, of item: TreemapItem) -> Bool {
    item.hasTitleStrip && item.rect.contains(point: point) && point.y < item.rect.y + TreemapMetrics.titleHeight
}

/// On the ▾ or ▸ at the start of a folder's title strip. The glyph keeps its screen size at
/// any zoom, so its 16 pt are screen points; `point` is in layout points.
func isOnChevron(_ point: CGPoint, of item: TreemapItem, zoomScale: CGFloat = 1) -> Bool {
    isOnTitle(point, of: item) && point.x < item.rect.x + 16 / zoomScale
}

/// What VoiceOver reads of the treemap: every folder and smaller-items block, and only the
/// largest files, which can number thousands without folders shown.
enum TreemapAccessibility {
    static let maxFiles = 200

    /// The items to expose, in drawing order, so a folder's contents follow it.
    static func items(of items: [TreemapItem]) -> [TreemapItem] {
        let files = items.filter { $0.kind == .file }
        guard files.count > maxFiles else { return items }
        let dropped = Set(files.sorted { $0.rect.area > $1.rect.area }[maxFiles...].map(\.id))
        return items.filter { !dropped.contains($0.id) }
    }

    /// "Library, folder, 266 GB, closed", "1,234 smaller items, 5 KB" or "notes.txt, 4 KB".
    static func label(of item: TreemapItem, sizeMetric: SizeMetric) -> String {
        let name = item.node.name, size = ByteFormatter.string(from: item.node.size(for: sizeMetric))
        return switch item.kind {
        case .openFolder: "\(name), folder, \(size), open"
        case .closedFolder: "\(name), folder, \(size), closed"
        case .smallerItems(let count, let blockSize): "\(count.formatted()) smaller items, \(ByteFormatter.string(from: blockSize))"
        case .file: "\(name), \(size)"
        }
    }
}

/// The treemap's accessibility elements at zoom 1×, over the items they describe. Equal while the
/// layout is the same, so hover and transition ticks, which re-run the treemap's body, skip it.
struct TreemapAccessibilityLayer: View, Equatable {
    let generation: Int
    let items: [TreemapItem]
    let root: FileNode
    let sizeMetric: SizeMetric
    @Environment(AppState.self) var appState

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.generation == rhs.generation && lhs.sizeMetric == rhs.sizeMetric
    }

    var body: some View {
        ZStack {
            ForEach(TreemapAccessibility.items(of: items)) { item in
                let node = item.node, rect = item.rect
                Color.clear
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
                    .accessibilityElement()
                    .accessibilityLabel(TreemapAccessibility.label(of: item, sizeMetric: sizeMetric))
                    .accessibilityAction {
                        // Like a click: a closed folder opens in place; everything selects.
                        guard node.isInSubtree(of: root) else { return }
                        if item.kind == .closedFolder { appState.setFolderOpen(node, true) }
                        appState.selectedNode = node
                    }
                    .accessibilityActions {
                        switch item.kind {
                        case .closedFolder: Button("Open") { appState.setFolderOpen(node, true) }
                        case .openFolder: Button("Close") { appState.setFolderOpen(node, false) }
                        case .file, .smallerItems: EmptyView()
                        }
                        if let target = TreemapView.drillDownTarget(for: node, shown: root, sizeMetric: sizeMetric) {
                            Button("Enter") { appState.drillDown(to: target) }
                        }
                    }
            }
        }
    }
}

/// Heavy canvas that renders all treemap items with fills, borders, labels.
/// Extracted as a separate view so SwiftUI skips re-rendering it when only
/// the hovered item changes.
private struct TreemapBaseCanvas: View {
    let items: [TreemapItem]
    let opacities: [Double]?
    let zoomScale: CGFloat
    let panOffset: CGPoint
    let showLabels: Bool
    let sizeMetric: SizeMetric
    let colorMode: TreemapColorMode
    let contrast: ColorSchemeContrast

    var body: some View {
        Canvas { context, size in
            let interval = TreemapSignposts.signposter.beginInterval("draw")
            defer { TreemapSignposts.signposter.endInterval("draw", interval) }
            let renderer = TreemapRenderer(
                items: items,
                zoomScale: zoomScale,
                panOffset: panOffset,
                showLabels: showLabels,
                sizeMetric: sizeMetric,
                colorMode: colorMode,
                contrast: contrast,
                opacities: opacities
            )
            renderer.draw(in: &context, size: size)
        }
    }
}

/// Lightweight overlay that draws only the hover highlight rectangle.
/// Re-renders on every hover change but only paints a single translucent rect.
private struct TreemapHoverOverlay: View {
    let item: TreemapItem?
    let zoomScale: CGFloat
    let panOffset: CGPoint

    var body: some View {
        Canvas { context, _ in
            guard let item else { return }
            let rect = TreemapRenderer.screenRect(of: item, zoomScale: zoomScale, panOffset: panOffset,
                                                  scale: context.environment.displayScale)
            context.fill(TreemapRenderer.outline(of: item, in: rect), with: .color(.white.opacity(0.25)))
        }
        .allowsHitTesting(false)
    }
}

private struct TreemapSelectionOverlay: View {
    let items: [TreemapItem]
    let selectedItemID: Int?
    let zoomScale: CGFloat
    let panOffset: CGPoint

    var body: some View {
        // An outline only: dimming the rest would hide the frames the user is exploring.
        Canvas { context, _ in
            guard let id = selectedItemID, items.indices.contains(id) else { return }
            let item = items[id]
            let rect = TreemapRenderer.screenRect(of: item, zoomScale: zoomScale, panOffset: panOffset,
                                                  scale: context.environment.displayScale)
            context.stroke(TreemapRenderer.outline(of: item, in: rect, inset: 1), with: .color(.white), lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}

/// Status bar showing the hovered item's path and size, or the scanned volume's usage.
/// Extracted as a separate view so changes only redraw this text, not the canvases.
private struct TreemapStatusBar: View {
    let item: TreemapItem?
    let volumeSummary: String
    let sizeMetric: SizeMetric

    var body: some View {
        HStack(spacing: 0) {
            if let item {
                let (label, size) = switch item.kind {
                case .smallerItems(let count, let size): ("\(count.formatted()) smaller items in \(item.node.path)", size)
                default: (item.node.path, item.node.size(for: sizeMetric))
                }
                Text(verbatim: label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Text(ByteFormatter.string(from: size))
                    .monospacedDigit()
            } else {
                Text(verbatim: volumeSummary.isEmpty ? " " : volumeSummary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
