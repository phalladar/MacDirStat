import SwiftUI

struct TreemapView: View {
    let root: FileNode
    let onSelect: (FileNode) -> Void
    let onDrillDown: (FileNode) -> Void

    @State private var items: [TreemapItem] = []
    @State private var hoveredItemID: Int?
    @State private var selectedItemID: Int?
    @State private var lastSize: CGSize = .zero
    @State private var layoutTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let renderer = TreemapRenderer(
                    items: items,
                    hoveredItemID: hoveredItemID,
                    selectedItemID: selectedItemID
                )
                renderer.draw(in: &context, size: size)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let hitTester = TreemapHitTester(items: items)
                    hoveredItemID = hitTester.itemAt(point: location)?.id
                case .ended:
                    hoveredItemID = nil
                }
            }
            .onTapGesture(count: 2) { location in
                let hitTester = TreemapHitTester(items: items)
                if let item = hitTester.itemAt(point: location), item.node.isDirectory {
                    onDrillDown(item.node)
                }
            }
            .onTapGesture(count: 1) { location in
                let hitTester = TreemapHitTester(items: items)
                if let item = hitTester.itemAt(point: location) {
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
            .onChange(of: geometry.size) { _, newSize in
                recomputeLayout(size: newSize)
            }
            .onAppear {
                recomputeLayout(size: geometry.size)
            }
            .onChange(of: root.id) {
                recomputeLayout(size: geometry.size)
            }
        }
        .background(.black)
    }

    private func recomputeLayout(size: CGSize) {
        guard size.width > 0 && size.height > 0 else { return }
        lastSize = size

        layoutTask?.cancel()
        layoutTask = Task.detached { [root] in
            let engine = TreemapLayoutEngine()
            let bounds = TreemapRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
            let newItems = engine.layout(root: root, in: bounds)
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
