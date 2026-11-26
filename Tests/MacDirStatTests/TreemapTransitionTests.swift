import Foundation
import Testing
@testable import MacDirStat

private let bounds = TreemapRect(x: 0, y: 0, width: 1200, height: 800)

private func folder(_ inode: UInt64, _ children: [FileNode]) -> FileNode {
    let node = FileNode(inode: inode, name: "d\(inode)", isDirectory: true)
    for child in children { node.addChild(child) }
    return node
}

private func file(_ inode: UInt64, _ size: Int64) -> FileNode {
    FileNode(inode: inode, name: "f\(inode)", isDirectory: false, ownSize: size, allocatedSize: size)
}

/// root → { big → { a, b, c }, other → { d }, e }. At level 1 every folder is closed.
private func sample() -> (root: FileNode, big: FileNode, other: FileNode) {
    let big = folder(2, [file(3, 4000), file(4, 3000), file(5, 2000)])
    let other = folder(6, [file(7, 3000)])
    let root = folder(1, [big, other, file(8, 2000)])
    root.computeAggregates()
    return (root, big, other)
}

private func lay(_ root: FileNode, level: Int = 1, overrides: [UInt64: Bool] = [:]) -> [TreemapItem] {
    TreemapLayoutEngine().layout(root: root, in: bounds, sizeMetric: .allocatedSize,
                                 detailLevel: level, overrides: overrides)
}

private func entry(_ node: FileNode, in frame: TreemapTransition.Frame) -> TreemapTransition.Frame.Element? {
    frame.first { $0.item.node === node && !$0.item.isSmallerItems }
}

private func lerp(_ a: TreemapRect, _ b: TreemapRect, _ t: Double) -> TreemapRect {
    TreemapRect(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t,
                width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
}

private func close(_ a: TreemapRect, _ b: TreemapRect) -> Bool {
    abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
}

/// The frame's visible entries match `items` one for one, at full opacity and their own rects.
/// Kinds may differ: an opening folder is drawn open from the start.
private func matches(_ frame: TreemapTransition.Frame, _ items: [TreemapItem]) -> Bool {
    frame.count == items.count && items.allSatisfy { item in
        frame.contains { $0.item.node === item.node && $0.item.isSmallerItems == item.isSmallerItems
            && close($0.rect, item.rect) && $0.opacity == 1 }
    }
}

@Test func progressZeroEqualsOld() {
    let (root, big, _) = sample()
    let old = lay(root), new = lay(root, overrides: [big.id: true])
    #expect(matches(TreemapTransition(from: old, to: new).frame(at: 0), old))
}

@Test func progressOneEqualsNew() {
    let (root, big, _) = sample()
    let old = lay(root), new = lay(root, overrides: [big.id: true])
    let frame = TreemapTransition(from: old, to: new).frame(at: 1)
    #expect(matches(frame, new))
    // In the new layout's order, so the deepest item is still drawn last.
    #expect(frame.map { ObjectIdentifier($0.item.node) } == new.map { ObjectIdentifier($0.node) })
}

@Test func newItemGrowsFromAncestor() {
    let (root, big, _) = sample()
    let old = lay(root), new = lay(root, overrides: [big.id: true])
    let child = big.children[0]
    let from = try! #require(old.first { $0.node === big }).rect
    let to = try! #require(new.first { $0.node === child }).rect
    let half = try! #require(entry(child, in: TreemapTransition(from: old, to: new).frame(at: 0.5)))
    #expect(close(half.rect, lerp(from, to, 0.5)))
    #expect(half.opacity == 0.5)
}

@Test func removedItemShrinksIntoAncestor() {
    let (root, big, _) = sample()
    let old = lay(root, overrides: [big.id: true]), new = lay(root)
    let child = big.children[0]
    let from = try! #require(old.first { $0.node === child }).rect
    let to = try! #require(new.first { $0.node === big }).rect
    let frame = TreemapTransition(from: old, to: new).frame(at: 0.5)
    let half = try! #require(entry(child, in: frame))
    #expect(close(half.rect, lerp(from, to, 0.5)))
    #expect(half.opacity == 0.5)
    // Drawn over the folder it shrinks into, not hidden under it.
    let folderIndex = try! #require(frame.firstIndex { $0.item.node === big })
    let childIndex = try! #require(frame.firstIndex { $0.item.node === child })
    #expect(childIndex > folderIndex)
}

@Test func detachedNodesAreDropped() {
    let (root, big, other) = sample()
    let old = lay(root, overrides: [big.id: true, other.id: true])
    // As replace(_:with:) leaves a trashed folder: out of its parent, its parent cleared.
    root.children.removeAll { $0 === other }
    other.parent = nil
    let new = lay(root, overrides: [big.id: true])
    let transition = TreemapTransition(from: old, to: new)
    for progress in [0, 0.5, 1] {
        #expect(entry(other, in: transition.frame(at: progress)) == nil)
    }
    // Its children are not detached themselves; they fade where they are.
    #expect(entry(other.children[0], in: transition.frame(at: 0)) != nil)
}

@Test func drillingDownGrowsTheFolderToFillTheView() {
    let (root, big, _) = sample()
    let old = lay(root), new = lay(big)
    let frame = TreemapTransition(from: old, to: new).frame(at: 1)
    // The folder becomes the shown one, which is not drawn: it fades out as it fills the view.
    #expect(entry(big, in: TreemapTransition(from: old, to: new).frame(at: 0.5)) != nil)
    #expect(entry(big, in: frame) == nil)
    let child = big.children[0]
    let from = try! #require(old.first { $0.node === big }).rect
    let to = try! #require(new.first { $0.node === child }).rect
    let half = try! #require(entry(child, in: TreemapTransition(from: old, to: new).frame(at: 0.5)))
    #expect(close(half.rect, lerp(from, to, 0.5)))
}

@Test func goingUpShrinksTheShownFolderIntoItsPlace() {
    let (root, big, _) = sample()
    let old = lay(big), new = lay(root)
    let shown = try! #require(entry(big, in: TreemapTransition(from: old, to: new).frame(at: 0.5)))
    let to = try! #require(new.first { $0.node === big }).rect
    // It starts as the whole view, the space the shown folder filled.
    #expect(shown.rect.area > to.area * 1.2)
    #expect(shown.opacity == 0.5)
}

@Test func aNewTransitionStartsWhereTheRunningOneIs() {
    let (root, big, _) = sample()
    let closed = lay(root), open = lay(root, overrides: [big.id: true])
    let opening = TreemapTransition(from: closed, to: open)
    let midway = opening.frame(at: 0.5)
    let closing = TreemapTransition(from: opening, at: 0.5, to: closed)
    let start = closing.frame(at: 0)
    let child = big.children[0]
    let before = try! #require(entry(child, in: midway)), after = try! #require(entry(child, in: start))
    #expect(close(before.rect, after.rect))
    #expect(before.opacity == after.opacity)
}

@Test func easingStartsFastAndSettlesWithoutOvershoot() {
    #expect(TreemapTransition.progress(elapsed: 0) == 0)
    #expect(TreemapTransition.progress(elapsed: TreemapTransition.duration / 2) > 0.5)
    #expect(TreemapTransition.progress(elapsed: TreemapTransition.duration) == 1)
    #expect(TreemapTransition.progress(elapsed: 10) == 1)
}

/// root → { f → { big, 20 tiny }, e }. Without folders shown, f's tiny files fold into its
/// smaller-items block at root (48 pt² each) and get their own blocks inside f (96 pt²).
private func flatSample() -> (root: FileNode, f: FileNode) {
    let f = folder(2, [file(3, 9_980)] + (0..<20).map { file(10 + UInt64($0), 1) })
    let root = folder(1, [f, file(4, 10_000)])
    root.computeAggregates()
    return (root, f)
}

private func flat(_ root: FileNode) -> [TreemapItem] {
    TreemapLayoutEngine().layout(root: root, in: bounds, sizeMetric: .allocatedSize,
                                 detailLevel: 3, overrides: [:], showsFolders: false)
}

@Test func flatDrillAndBackUseTheFoldersSmallerItemsBlock() throws {
    let (root, f) = flatSample()
    let outside = flat(root), inside = flat(f)
    let tiny = f.children.last!
    let block = try #require(outside.first { $0.isSmallerItems && $0.node === f }).rect
    let own = try #require(inside.first { $0.node === tiny }).rect
    #expect(!outside.contains { $0.node === tiny })

    // Drilling in, a folded file grows out of the block that held it.
    let grown = try #require(entry(tiny, in: TreemapTransition(from: outside, to: inside).frame(at: 0.5)))
    #expect(close(grown.rect, lerp(block, own, 0.5)))
    // Going back, it shrinks into that block again.
    let shrunk = try #require(entry(tiny, in: TreemapTransition(from: inside, to: outside).frame(at: 0.5)))
    #expect(close(shrunk.rect, lerp(own, block, 0.5)))
}

@Test func flatShownFolderFillsTheView() throws {
    // f's only child is a folder, so no item has depth 1; g lays out where f was.
    let g = folder(3, [file(4, 6_000), file(5, 4_000)])
    let f = folder(2, [g])
    let root = folder(1, [f])
    root.computeAggregates()
    let outside = flat(root)
    #expect(!outside.contains { $0.depth == 1 })
    // A new file in g, from a layout of g, grows out of the old shown folder: the whole view.
    let extra = file(6, 1)
    let inside = flat(g) + [TreemapItem(id: 99, node: extra, rect: TreemapRect(x: 0, y: 0, width: 10, height: 10),
                                         depth: 1, kind: .file, branch: 0)]
    g.addChild(extra)
    let half = try #require(entry(extra, in: TreemapTransition(from: outside, to: inside).frame(at: 0.5)))
    let rects = outside.map(\.rect)
    let minX: Double = rects.map(\.x).min()!, minY: Double = rects.map(\.y).min()!
    let maxX: Double = rects.map { $0.x + $0.width }.max()!
    let maxY: Double = rects.map { $0.y + $0.height }.max()!
    let all = TreemapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    #expect(close(half.rect, lerp(all, TreemapRect(x: 0, y: 0, width: 10, height: 10), 0.5)))
}

@Test func goingUpFromAFolderWithItsOwnBlockStillFillsTheView() throws {
    // big's tiny files fold into a block at big's own level.
    let big = folder(2, [file(3, 1_000_000)] + (0..<20).map { file(10 + UInt64($0), 1) })
    let root = folder(1, [big, file(4, 500_000)])
    root.computeAggregates()
    let inside = lay(big)
    #expect(inside.contains { $0.isSmallerItems && $0.node === big })
    let outside = lay(root)
    let to = try #require(outside.first { $0.node === big }).rect
    let shown = try #require(entry(big, in: TreemapTransition(from: inside, to: outside).frame(at: 0.5)))
    // Halfway from the whole view, not from the block.
    let union = TreemapRect(x: inside.map(\.rect.x).min()!, y: inside.map(\.rect.y).min()!,
                            width: inside.map { $0.rect.x + $0.rect.width }.max()! - inside.map(\.rect.x).min()!,
                            height: inside.map { $0.rect.y + $0.rect.height }.max()! - inside.map(\.rect.y).min()!)
    #expect(close(shown.rect, lerp(union, to, 0.5)))
}
