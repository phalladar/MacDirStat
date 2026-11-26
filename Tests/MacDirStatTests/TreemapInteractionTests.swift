import Foundation
import Testing
@testable import MacDirStat

@Test func makeupRowsKeepsFourOrFoldsTheRest() {
    let four: [(category: FileCategory, size: Int64)] = [(.video, 40), (.images, 30), (.code, 20), (.audio, 10)]
    #expect(makeupRows(four, total: 100) == [
        MakeupRow(category: .video, fraction: 0.4, size: 40),
        MakeupRow(category: .images, fraction: 0.3, size: 30),
        MakeupRow(category: .code, fraction: 0.2, size: 20),
        MakeupRow(category: .audio, fraction: 0.1, size: 10),
    ])

    let six: [(category: FileCategory, size: Int64)] =
        [(.video, 50), (.images, 20), (.code, 10), (.audio, 9), (.documents, 6), (.caches, 5)]
    #expect(makeupRows(six, total: 100) == [
        MakeupRow(category: .video, fraction: 0.5, size: 50),
        MakeupRow(category: .images, fraction: 0.2, size: 20),
        MakeupRow(category: .code, fraction: 0.1, size: 10),
        MakeupRow(category: nil, fraction: 0.2, size: 20),
    ])

    let tiny: [(category: FileCategory, size: Int64)] = [(.video, 995), (.code, 4), (.audio, 1)]
    #expect(makeupRows(tiny, total: 1000) == [MakeupRow(category: .video, fraction: 0.995, size: 995)])

    #expect(makeupRows([], total: 0).isEmpty)
}

@Test func chevronAndTitleRegions() {
    let node = FileNode(inode: 1, name: "Library", isDirectory: true)
    let open = TreemapItem(id: 0, node: node, rect: TreemapRect(x: 100, y: 50, width: 200, height: 120),
                           depth: 1, kind: .openFolder, branch: 0)
    #expect(isOnChevron(CGPoint(x: 105, y: 55), of: open))
    #expect(isOnTitle(CGPoint(x: 105, y: 55), of: open))
    // In the title strip, past the chevron: the title, not the chevron.
    #expect(!isOnChevron(CGPoint(x: 120, y: 60), of: open))
    #expect(isOnTitle(CGPoint(x: 120, y: 60), of: open))
    // At 4× the glyph keeps its screen size, so the chevron is 4 layout points wide.
    #expect(isOnChevron(CGPoint(x: 103, y: 55), of: open, zoomScale: 4))
    #expect(!isOnChevron(CGPoint(x: 105, y: 55), of: open, zoomScale: 4))
    // Below the 18 pt strip: inside the frame, on neither.
    #expect(!isOnChevron(CGPoint(x: 105, y: 70), of: open))
    #expect(!isOnTitle(CGPoint(x: 150, y: 70), of: open))

    // Files have no title strip, and neither do closed folders too small for a title.
    let file = TreemapItem(id: 1, node: FileNode(inode: 2, name: "a", isDirectory: false),
                           rect: open.rect, depth: 1, kind: .file, branch: 0)
    #expect(!isOnTitle(CGPoint(x: 105, y: 55), of: file))
    #expect(!isOnChevron(CGPoint(x: 105, y: 55), of: file))
    let small = TreemapItem(id: 2, node: node, rect: TreemapRect(x: 100, y: 50, width: 50, height: 30),
                            depth: 1, kind: .closedFolder, branch: 0)
    #expect(!isOnTitle(CGPoint(x: 105, y: 55), of: small))
}

@MainActor @Test func flatSelectionOutlinesTheFoldersOwnBlock() {
    let root = FileNode(inode: 1, name: "root", isDirectory: true)
    let parent = FileNode(inode: 2, name: "p", isDirectory: true)
    let folder = FileNode(inode: 3, name: "f", isDirectory: true)
    root.addChild(parent)
    parent.addChild(folder)
    // Without folders shown, neither folder has an item; both have a smallerItems block.
    let smaller = [ObjectIdentifier(parent): 7, ObjectIdentifier(folder): 9]
    #expect(TreemapView.selectedItemID(of: folder, shown: root, items: [:], smallerItems: smaller) == 9)
    #expect(TreemapView.selectedItemID(of: root, shown: root, items: [:], smallerItems: smaller) == nil)
}

@Test @MainActor func emptyFolderOffersNoDrillDown() {
    let root = FileNode(inode: 1, name: "root", isDirectory: true)
    let empty = FileNode(inode: 2, name: "empty", isDirectory: true, ownSize: 4096, allocatedSize: 4096)
    let full = FileNode(inode: 3, name: "full", isDirectory: true)
    let file = FileNode(inode: 4, name: "a", isDirectory: false, ownSize: 10, allocatedSize: 10)
    root.addChild(empty)
    root.addChild(full)
    full.addChild(file)
    root.computeAggregates()
    #expect(TreemapView.drillDownTarget(for: empty, shown: root, sizeMetric: .allocatedSize) == nil)
    #expect(TreemapView.drillDownTarget(for: full, shown: root, sizeMetric: .allocatedSize) === full)
    #expect(TreemapView.drillDownTarget(for: file, shown: root, sizeMetric: .allocatedSize) === full)
}

@Test func accessibilityExposesFoldersBlocksAndTheLargestFiles() {
    let library = FileNode(inode: 1, name: "Library", isDirectory: true, ownSize: 2_000_000, allocatedSize: 2_000_000)
    let docs = FileNode(inode: 2, name: "Documents", isDirectory: true, ownSize: 3_000_000, allocatedSize: 3_000_000)
    func item(_ id: Int, _ node: FileNode, _ kind: TreemapItem.Kind, area: Double = 100) -> TreemapItem {
        TreemapItem(id: id, node: node, rect: TreemapRect(x: 0, y: 0, width: area, height: 1),
                    depth: 1, kind: kind, branch: 0)
    }
    var items = [item(0, library, .openFolder), item(1, docs, .closedFolder),
                 item(2, library, .smallerItems(count: 12, size: 5_000))]
    // 201 files, ids 3…203, the largest last: the smallest one, id 3, is left out.
    for i in 0...TreemapAccessibility.maxFiles {
        let file = FileNode(inode: UInt64(10 + i), name: "f\(i)", isDirectory: false, ownSize: 1_000, allocatedSize: 1_000)
        items.append(item(3 + i, file, .file, area: Double(1 + i)))
    }

    let exposed = TreemapAccessibility.items(of: items)
    #expect(exposed.count == 3 + TreemapAccessibility.maxFiles)
    #expect(exposed.map(\.id) == [0, 1, 2] + Array(4...203)) // drawing order kept

    #expect(TreemapAccessibility.label(of: items[0], sizeMetric: .fileSize) == "Library, folder, 2 MB, open")
    #expect(TreemapAccessibility.label(of: items[1], sizeMetric: .fileSize) == "Documents, folder, 3 MB, closed")
    #expect(TreemapAccessibility.label(of: items[2], sizeMetric: .fileSize) == "12 smaller items, 5 KB")
    #expect(TreemapAccessibility.label(of: items[4], sizeMetric: .fileSize) == "f1, 1 KB")
}

// Hover and transition ticks re-run the treemap's body with the same layout: the layer must
// compare equal then, so `.equatable()` skips its body, and unequal once a new layout lands.
@MainActor @Test func accessibilityLayerChangesOnlyWithTheLayout() {
    let root = FileNode(inode: 1, name: "root", isDirectory: true)
    let file = TreemapItem(id: 0, node: FileNode(inode: 2, name: "a", isDirectory: false),
                           rect: TreemapRect(x: 0, y: 0, width: 10, height: 10), depth: 1, kind: .file, branch: 0)
    let layer = TreemapAccessibilityLayer(generation: 4, items: [file], root: root, sizeMetric: .allocatedSize)
    #expect(layer == TreemapAccessibilityLayer(generation: 4, items: [file, file], root: root, sizeMetric: .allocatedSize))
    #expect(layer != TreemapAccessibilityLayer(generation: 5, items: [file], root: root, sizeMetric: .allocatedSize))
    #expect(layer != TreemapAccessibilityLayer(generation: 4, items: [file], root: root, sizeMetric: .fileSize))
}
