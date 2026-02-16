import SwiftUI

struct TreemapView: View {
    let root: FileNode
    let onSelect: (FileNode) -> Void
    let onDrillDown: (FileNode) -> Void
    let sizeMetric: SizeMetric

    @State private var items: [TreemapItem] = []
    @State private var hoveredItemID: Int?
    @State private var selectedItemID: Int?
    @State private var lastSize: CGSize = .zero
    @State private var layoutTask: Task<Void, Never>?
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGPoint = .zero
    @State private var showLabels: Bool = true
    @State private var labelDebounce: Task<Void, Never>?

    private var hoveredNode: FileNode? {
        guard let id = hoveredItemID else { return nil }
        return items.first { $0.id == id }?.node
    }

    var body: some View {
        VStack(spacing: 0) {
        GeometryReader { geometry in
            ZStack {
                // Base treemap — only redraws when items or selection change
                TreemapBaseCanvas(
                    items: items,
                    selectedItemID: selectedItemID,
                    zoomScale: zoomScale,
                    panOffset: panOffset,
                    showLabels: showLabels,
                    sizeMetric: sizeMetric
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
                if let item = hitTestItem(at: screenToContent(location)), item.node.isDirectory {
                    onDrillDown(item.node)
                }
            }
            .onTapGesture(count: 1) { location in
                if let item = hitTestItem(at: screenToContent(location)) {
                    selectedItemID = item.id
                    onSelect(item.node)
                }
            }
            .contextMenu {
                if let hoveredID = hoveredItemID,
                   let item = items.first(where: { $0.id == hoveredID }) {
                    Button("Reveal in Finder") {
                        revealInFinder(node: item.node)
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.node.path, forType: .string)
                    }
                    if item.node.isDirectory {
                        Divider()
                        Button("Drill Down") {
                            onDrillDown(item.node)
                        }
                    }
                }
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
        for item in items.reversed() {
            if item.rect.contains(point: point) {
                return item.id
            }
        }
        return nil
    }

    private func hitTestItem(at point: CGPoint) -> TreemapItem? {
        for item in items.reversed() {
            if item.rect.contains(point: point) {
                return item
            }
        }
        return nil
    }

    private func recomputeLayout(size: CGSize) {
        guard size.width > 0 && size.height > 0 else { return }
        lastSize = size

        let metric = sizeMetric
        layoutTask?.cancel()
        layoutTask = Task.detached { [root] in
            let engine = TreemapLayoutEngine()
            let bounds = TreemapRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
            let newItems = engine.layout(root: root, in: bounds, sizeMetric: metric)
            await MainActor.run {
                items = newItems
            }
        }
    }

    private func revealInFinder(node: FileNode) {
        let path = node.path
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }
}

/// Heavy canvas that renders all treemap items with fills, borders, labels.
/// Extracted as a separate view so SwiftUI skips re-rendering it when only
/// the hovered item changes.
private struct TreemapBaseCanvas: View {
    let items: [TreemapItem]
    let selectedItemID: Int?
    let zoomScale: CGFloat
    let panOffset: CGPoint
    let showLabels: Bool
    let sizeMetric: SizeMetric

    var body: some View {
        Canvas { context, size in
            let renderer = TreemapRenderer(
                items: items,
                hoveredItemID: nil,
                selectedItemID: selectedItemID,
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
