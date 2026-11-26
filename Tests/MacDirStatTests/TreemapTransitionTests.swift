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
