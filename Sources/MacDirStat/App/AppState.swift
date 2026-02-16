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
    var selectedNode: FileNode?
    var breadcrumbs: [FileNode] = []
    var sizeMetric: SizeMetric = .fileSize
    var showInspector: Bool = true

    var isScanning: Bool {
        if case .scanning = scanStatus { return true }
        return false
    }

    var hasData: Bool {
        rootNode != nil
    }

    func drillDown(to node: FileNode) {
        guard node.isDirectory else { return }
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
