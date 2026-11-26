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

@MainActor @Test func flatSelectionOutlinesTheFoldersGroup() {
    let root = FileNode(inode: 1, name: "root", isDirectory: true)
    let folder = FileNode(inode: 2, name: "f", isDirectory: true)
    root.addChild(folder)
    for inode in 3...4 { folder.addChild(FileNode(inode: UInt64(inode), name: "a\(inode)", isDirectory: false, ownSize: 10, allocatedSize: 10)) }
    root.addChild(FileNode(inode: 5, name: "b", isDirectory: false, ownSize: 30, allocatedSize: 30))
    root.computeAggregates()
    let items = TreemapLayoutEngine().layout(root: root, in: TreemapRect(x: 0, y: 0, width: 400, height: 300),
                                             sizeMetric: .allocatedSize, detailLevel: 3, overrides: [:], showsFolders: false)
    let index = Dictionary(uniqueKeysWithValues: items.filter { !$0.isSmallerItems }.map { (ObjectIdentifier($0.node), $0.id) })
    // Without folders shown, a folder is a group item, so selection outlines and dims around it.
    let id = TreemapView.selectedItemID(of: folder, shown: root, items: index, smallerItems: [:])!
    #expect(items[id].kind == .group && items[id].node === folder)
    #expect(TreemapView.dimsAround(items[id], selected: folder))
    #expect(TreemapView.selectedItemID(of: root, shown: root, items: index, smallerItems: [:]) == nil)
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

@Test func accessibilityExposesFoldersAndTheLargestBlocks() {
    let library = FileNode(inode: 1, name: "Library", isDirectory: true, ownSize: 2_000_000, allocatedSize: 2_000_000)
    let docs = FileNode(inode: 2, name: "Documents", isDirectory: true, ownSize: 3_000_000, allocatedSize: 3_000_000)
    func item(_ id: Int, _ node: FileNode, _ kind: TreemapItem.Kind, area: Double = 100) -> TreemapItem {
        TreemapItem(id: id, node: node, rect: TreemapRect(x: 0, y: 0, width: area, height: 1),
                    depth: 1, kind: kind, branch: 0)
    }
    var items = [item(0, library, .openFolder), item(1, docs, .closedFolder),
                 item(2, library, .smallerItems(count: 12, size: 5_000)), item(3, docs, .group, area: 1_000)]
    // 201 files, ids 4…204, the largest last. With the block, 202 blocks compete for 200 places:
    // the two smallest files, ids 4 and 5, are left out, and the group is never exposed.
    for i in 0...TreemapAccessibility.maxBlocks {
        let file = FileNode(inode: UInt64(10 + i), name: "f\(i)", isDirectory: false, ownSize: 1_000, allocatedSize: 1_000)
        items.append(item(4 + i, file, .file, area: Double(1 + i)))
    }

    let exposed = TreemapAccessibility.items(of: items)
    #expect(exposed.count == 2 + TreemapAccessibility.maxBlocks)
    #expect(exposed.map(\.id) == [0, 1, 2] + Array(6...204)) // drawing order kept

    #expect(TreemapAccessibility.label(of: items[0], sizeMetric: .fileSize) == "Library, folder, 2 MB, open")
    #expect(TreemapAccessibility.label(of: items[1], sizeMetric: .fileSize) == "Documents, folder, 3 MB, closed")
    #expect(TreemapAccessibility.label(of: items[2], sizeMetric: .fileSize) == "12 smaller items, 5 KB")
    #expect(TreemapAccessibility.label(of: items[5], sizeMetric: .fileSize) == "f1, 1 KB")
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

@MainActor @Test func smallerItemsHintNamesTheFolderUnlessItIsShown() {
    let root = FileNode(inode: 1, name: "root", isDirectory: true)
    let folder = FileNode(inode: 2, name: "Caches", isDirectory: true)
    root.addChild(folder)
    for inode in 3...4 { folder.addChild(FileNode(inode: UInt64(inode), name: "f\(inode)", isDirectory: false, ownSize: 10, allocatedSize: 10)) }
    root.computeAggregates()
    let block = TreemapItem(id: 0, node: folder, rect: TreemapRect(x: 0, y: 0, width: 10, height: 10),
                            depth: 2, kind: .smallerItems(count: 2, size: 20), branch: 0)
    #expect(smallerItemsHint(for: block, shown: root, sizeMetric: .allocatedSize) == "Double-click to open Caches")
    // Already the shown folder: a double click does nothing, so no hint.
    #expect(smallerItemsHint(for: block, shown: folder, sizeMetric: .allocatedSize) == nil)
    let file = TreemapItem(id: 1, node: folder.children[0], rect: block.rect, depth: 3, kind: .file, branch: 0)
    #expect(smallerItemsHint(for: file, shown: root, sizeMetric: .allocatedSize) == nil)
}

@Test func selectionTravelSettlesWithoutOvershoot() {
    let samples = stride(from: 0.0, through: 0.5, by: 0.01).map { TreemapSelectionOverlay.progress(elapsed: $0) }
    #expect(samples.first == 0 && samples.last == 1)
    #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 && $1 <= 1 })
    #expect(TreemapSelectionOverlay.progress(elapsed: TreemapSelectionOverlay.response) > 0.98)

    let folder = SelectionShape(rect: TreemapRect(x: 0, y: 0, width: 100, height: 40), radius: 6, dim: 1)
    let file = SelectionShape(rect: TreemapRect(x: 100, y: 40, width: 20, height: 20), radius: 4, dim: 0)
    let half = folder.interpolated(to: file, 0.5)
    #expect([half.rect.x, half.rect.y, half.rect.width, half.rect.height, half.radius, half.dim] == [50, 20, 60, 30, 5, 0.5])
}

@MainActor @Test func onlyTheFoldersOwnItemDimsTheRest() {
    let parent = FileNode(inode: 1, name: "p", isDirectory: true)
    let folder = FileNode(inode: 2, name: "f", isDirectory: true)
    let file = FileNode(inode: 3, name: "a", isDirectory: false)
    parent.addChild(folder)
    folder.addChild(file)
    func item(_ node: FileNode, _ kind: TreemapItem.Kind) -> TreemapItem {
        TreemapItem(id: 0, node: node, rect: TreemapRect(x: 0, y: 0, width: 10, height: 10), depth: 1, kind: kind, branch: 0)
    }
    #expect(TreemapView.dimsAround(item(folder, .openFolder), selected: folder))
    #expect(TreemapView.dimsAround(item(folder, .closedFolder), selected: folder))
    // Flat mode: the folder's smaller-items block stands for it, but isn't it.
    #expect(!TreemapView.dimsAround(item(folder, .smallerItems(count: 2, size: 2)), selected: folder))
    // An ancestor standing in for a folder inside it, and a file.
    #expect(!TreemapView.dimsAround(item(parent, .closedFolder), selected: folder))
    #expect(!TreemapView.dimsAround(item(file, .file), selected: file))
}
