import SwiftUI

enum ScanStatus: Equatable {
    case idle
    case scanning(fileCount: Int, byteCount: Int64, currentPath: String)
    case completed
    case error(String)

    static func == (lhs: ScanStatus, rhs: ScanStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): true
        case (.completed, .completed): true
        case let (.scanning(lf, lb, lp), .scanning(rf, rb, rp)):
            lf == rf && lb == rb && lp == rp
        case let (.error(l), .error(r)): l == r
        default: false
        }
    }
}

enum SizeMetric: String, CaseIterable, Sendable {
    case fileSize = "File Size"
    case allocatedSize = "Allocated Size"
}

@Observable
@MainActor
final class AppState {
    var scanStatus: ScanStatus = .idle
    var rootNode: FileNode?
    var treemapRoot: FileNode?
    var selectedNode: FileNode? {
        didSet { if let selectedNode { revealInTree(selectedNode) } }
    }
    var breadcrumbs: [FileNode] = []
    var sizeMetric: SizeMetric = .allocatedSize
    var showInspector: Bool = true
    private(set) var expandedIDs: Set<UInt64> = []
    /// Bumped when part of the tree is replaced in place, so views showing its totals refresh.
    private(set) var treeVersion = 0
    /// The item a background change is working on. One at a time, so changes can't overlap in the tree.
    var busyID: UInt64?
    /// Each treemap's latest layout, keyed by view. Layouts read the tree off the main thread;
    /// replace(_:with:) waits for all of them. One entry per view, so windows don't cancel each other.
    @ObservationIgnored var layoutTasks: [UUID: Task<Void, Never>] = [:]

    var isScanning: Bool {
        if case .scanning = scanStatus { return true }
        return false
    }

    var hasData: Bool {
        rootNode != nil
    }

    var selectedDirectory: FileNode? {
        guard let node = selectedNode else { return nil }
        return node.isDirectory ? node : node.parent
    }

    /// Selection made in the sidebar. The treemap keeps its zoom unless the folder is outside
    /// the folder it shows; then it moves to the folder's parent.
    func selectFromTree(_ node: FileNode) {
        selectedNode = node
        if let current = treemapRoot, !node.isInSubtree(of: current) {
            withAnimation(.spring(duration: 0.3)) {
                treemapRoot = node.parent ?? rootNode
                rebuildBreadcrumbs()
            }
        }
    }

    func setExpanded(_ node: FileNode, _ expanded: Bool) {
        if expanded {
            expandedIDs.insert(node.id)
        } else {
            expandedIDs.remove(node.id)
            // Like Finder, collapsing a folder that hides the selection selects the folder.
            if let selected = selectedDirectory, selected !== node, selected.isInSubtree(of: node) {
                selectFromTree(node)
            }
        }
    }

    /// The sidebar folder with this inode. The sidebar only hands back ids of rows it shows,
    /// so the search stays inside expanded folders.
    func visibleDirectory(id: UInt64) -> FileNode? {
        var stack = rootNode.map { [$0] } ?? []
        while let folder = stack.popLast() {
            for child in folder.children where child.isDirectory {
                if child.id == id { return child }
                if expandedIDs.contains(child.id) { stack.append(child) }
            }
        }
        return nil
    }

    private func revealInTree(_ node: FileNode) {
        var ancestor = (node.isDirectory ? node : node.parent)?.parent
        while let current = ancestor, current !== rootNode {
            // Any write to an @Observable property notifies observers, even when nothing changes.
            if !expandedIDs.contains(current.id) { expandedIDs.insert(current.id) }
            ancestor = current.parent
        }
    }

    /// Splices a fresh scan of `old` into the tree, or removes it when `new` is nil, updating only its ancestors.
    func replace(_ old: FileNode, with new: FileNode?) async {
        // A view can start a new layout while we wait, so wait until no task changed.
        var waited: [UUID: Task<Void, Never>]
        repeat {
            waited = layoutTasks
            for task in waited.values { await task.value }
        } while waited != layoutTasks
        // A new scan may have replaced the whole tree meanwhile.
        guard let root = rootNode, old.isInSubtree(of: root), let parent = old.parent,
              let index = parent.children.firstIndex(where: { $0 === old }) else { return }
        if let new {
            new.name = old.name
            new.parent = parent
            parent.children[index] = new
        } else {
            parent.children.remove(at: index)
        }
        // Treemap rects laid out before this still point into the old subtree; detaching it
        // keeps them from passing the isInSubtree(of: root) checks.
        old.parent = nil
        var ancestor: FileNode? = parent
        while let current = ancestor {
            current.computeAggregates(recursing: false)
            current.children.sort { $0.totalAllocatedSize > $1.totalAllocatedSize }
            ancestor = current.parent
        }
        let replacement = new ?? parent
        if selectedNode?.isInSubtree(of: old) == true { selectedNode = replacement }
        if treemapRoot?.isInSubtree(of: old) == true {
            treemapRoot = replacement
            rebuildBreadcrumbs()
        }
        treeVersion += 1
    }

    func drillDown(to node: FileNode) {
        // A treemap rect laid out before replace(_:with:) can point at a detached node.
        guard node.isDirectory, let root = rootNode, node.isInSubtree(of: root) else { return }
        withAnimation(.spring(duration: 0.3)) {
            treemapRoot = node
            selectedNode = node
            rebuildBreadcrumbs()
        }
    }

    func navigateTo(breadcrumb node: FileNode) {
        withAnimation(.spring(duration: 0.3)) {
            treemapRoot = node
            selectedNode = node
            rebuildBreadcrumbs()
        }
    }

    func navigateUp() {
        guard let current = treemapRoot, let parent = current.parent else { return }
        withAnimation(.spring(duration: 0.3)) {
            treemapRoot = parent
            selectedNode = parent
            rebuildBreadcrumbs()
        }
    }

    func setScanCompleted(root: FileNode) {
        rootNode = root
        treemapRoot = root
        selectedNode = root
        scanStatus = .completed
        rebuildBreadcrumbs()
    }

    func reset() {
        scanStatus = .idle
        rootNode = nil
        treemapRoot = nil
        selectedNode = nil
        breadcrumbs = []
        expandedIDs = []
    }

    private func rebuildBreadcrumbs() {
        var crumbs: [FileNode] = []
        var node = treemapRoot
        while let current = node {
            crumbs.insert(current, at: 0)
            node = current.parent
        }
        breadcrumbs = crumbs
    }
}
