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
    @Environment(AppState.self) private var appState

    @State private var items: [TreemapItem] = []
    @State private var hoveredItemID: Int?
    /// Item index by node, so the shared selection maps to its rectangle without a search.
    @State private var itemIndexByNode: [ObjectIdentifier: Int] = [:]
    @State private var lastSize: CGSize = .zero
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGPoint = .zero
    @State private var showLabels: Bool = true
    @State private var labelDebounce: Task<Void, Never>?
    /// Key of this view's layout in AppState.layoutTasks.
    @State private var layoutID = UUID()

    private var hoveredNode: FileNode? {
        guard let id = hoveredItemID else { return nil }
        return items.first { $0.id == id }?.node
    }

    /// The selected node's rectangle, or its nearest ancestor's when the node itself is too
    /// small or too deep to have been laid out.
    private var selectedItemID: Int? {
        var node = selectedNode
        while let current = node {
            if let index = itemIndexByNode[ObjectIdentifier(current)] { return index }
            node = current.parent
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
        GeometryReader { geometry in
            ZStack {
                // Base treemap — only redraws when items change
                TreemapBaseCanvas(
                    items: items,
                    zoomScale: zoomScale,
                    panOffset: panOffset,
                    showLabels: showLabels,
                    sizeMetric: sizeMetric
                )

                TreemapSelectionOverlay(
                    items: items,
                    selectedItemID: selectedItemID,
                    zoomScale: zoomScale,
                    panOffset: panOffset
                )

                // Lightweight hover overlay — redraws only the single highlight rect
                TreemapHoverOverlay(
                    items: items,
                    hoveredItemID: hoveredItemID,
                    zoomScale: zoomScale,
                    panOffset: panOffset
                )
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoveredItemID = hitTestID(at: screenToContent(location))
                case .ended:
                    hoveredItemID = nil
                }
            }
            .onTapGesture(count: 2) { location in
                if let item = hitTestItem(at: screenToContent(location)),
                   let target = drillDownTarget(for: item.node) {
                    onDrillDown(target)
                }
            }
            .onTapGesture(count: 1) { location in
                if let item = hitTestItem(at: screenToContent(location)) {
                    onSelect(item.node)
                }
            }
            .contextMenu {
                Group {
                    if let hoveredID = hoveredItemID,
                       let item = items.first(where: { $0.id == hoveredID }) {
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
                        if item.node.parent != nil {
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
                recomputeLayout(size: geometry.size)
            }
            .onChange(of: sizeMetric) {
                recomputeLayout(size: geometry.size)
            }
            .onChange(of: treeVersion) {
                recomputeLayout(size: geometry.size)
            }
        }
        .background(.black)

        TreemapStatusBar(node: hoveredNode, sizeMetric: sizeMetric)
        }
        .focusedSceneValue(\.zoomInAction) {
            let center = CGPoint(x: lastSize.width / 2, y: lastSize.height / 2)
            performZoom(by: 0.3, centeredAt: center, viewSize: lastSize)
        }
        .focusedSceneValue(\.zoomOutAction) {
            let center = CGPoint(x: lastSize.width / 2, y: lastSize.height / 2)
            performZoom(by: -0.3, centeredAt: center, viewSize: lastSize)
        }
        .focusedSceneValue(\.resetZoomAction) {
            zoomScale = 1.0
            panOffset = .zero
        }
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

    private func hitTestID(at point: CGPoint) -> Int? {
        hitTestItem(at: point)?.id
    }

    /// Items are drawn in order, so the last one containing the point is the deepest one on top.
    private func hitTestItem(at point: CGPoint) -> TreemapItem? {
        items.last { $0.rect.contains(point: point) }
    }

    /// Folders drill into themselves. Files, which cover most of the treemap, drill into the
    /// folder that contains them, unless that folder is already the one shown.
    private func drillDownTarget(for node: FileNode) -> FileNode? {
        let target = node.isDirectory ? node : node.parent
        return target === root ? nil : target
    }

    private func recomputeLayout(size: CGSize) {
        guard size.width > 0 && size.height > 0 else { return }
        lastSize = size

        let metric = sizeMetric
        let previous = appState.layoutTasks[layoutID]
        previous?.cancel()
        appState.layoutTasks[layoutID] = Task.detached { [root] in
            // One layout per view reads the tree at a time, so replace(_:with:) only waits for the last.
            await previous?.value
            guard !Task.isCancelled else { return }
            let engine = TreemapLayoutEngine()
            let bounds = TreemapRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
            let interval = TreemapSignposts.signposter.beginInterval("layout")
            let newItems = engine.layout(root: root, in: bounds, sizeMetric: metric)
            TreemapSignposts.signposter.endInterval("layout", interval)
            let index = Dictionary(uniqueKeysWithValues: newItems.enumerated().map { (ObjectIdentifier($1.node), $0) })
            guard !Task.isCancelled else { return }
            await MainActor.run {
                items = newItems
                itemIndexByNode = index
            }
        }
    }
}

/// Heavy canvas that renders all treemap items with fills, borders, labels.
/// Extracted as a separate view so SwiftUI skips re-rendering it when only
/// the hovered item changes.
private struct TreemapBaseCanvas: View {
    let items: [TreemapItem]
    let zoomScale: CGFloat
    let panOffset: CGPoint
    let showLabels: Bool
    let sizeMetric: SizeMetric

    var body: some View {
        Canvas { context, size in
            let interval = TreemapSignposts.signposter.beginInterval("draw")
            defer { TreemapSignposts.signposter.endInterval("draw", interval) }
            let renderer = TreemapRenderer(
                items: items,
                hoveredItemID: nil,
                zoomScale: zoomScale,
                panOffset: panOffset,
                showLabels: showLabels,
                sizeMetric: sizeMetric
            )
            renderer.draw(in: &context, size: size)
        }
    }
}

/// Lightweight overlay that draws only the hover highlight rectangle.
/// Re-renders on every hover change but only paints a single translucent rect.
private struct TreemapHoverOverlay: View {
    let items: [TreemapItem]
    let hoveredItemID: Int?
    let zoomScale: CGFloat
    let panOffset: CGPoint

    var body: some View {
        Canvas { context, _ in
            guard let hoveredID = hoveredItemID,
                  let item = items.first(where: { $0.id == hoveredID }) else { return }

            let screenRect = CGRect(
                x: panOffset.x + item.rect.x * zoomScale,
                y: panOffset.y + item.rect.y * zoomScale,
                width: item.rect.width * zoomScale,
                height: item.rect.height * zoomScale
            )
            let path = Path(roundedRect: screenRect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1)
            context.fill(path, with: .color(.white.opacity(0.25)))
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
        Canvas { context, size in
            guard let id = selectedItemID, items.indices.contains(id) else { return }
            let item = items[id]
            let rect = CGRect(
                x: panOffset.x + item.rect.x * zoomScale,
                y: panOffset.y + item.rect.y * zoomScale,
                width: item.rect.width * zoomScale,
                height: item.rect.height * zoomScale
            )
            // Item 0 is the treemap root, so there is nothing outside it to dim. A folder outside
            // the zoomed-in view isn't dimmed around either, or the whole view would go dark.
            if item.node.isDirectory && id != 0 && rect.intersects(CGRect(origin: .zero, size: size)) {
                var outside = Path(CGRect(origin: .zero, size: size))
                outside.addRect(rect)
                context.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
            }
            context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(.white), lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}

/// Status bar showing hovered item path and size.
/// Extracted as a separate view so changes only redraw this text, not the canvases.
private struct TreemapStatusBar: View {
    let node: FileNode?
    let sizeMetric: SizeMetric

    var body: some View {
        HStack(spacing: 0) {
            if let node {
                Text(node.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Text(ByteFormatter.string(from: node.size(for: sizeMetric)))
                    .monospacedDigit()
            } else {
                Text(" ")
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
