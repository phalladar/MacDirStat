import Foundation

/// Moves the treemap from one layout to the next. Items in both move between their rects; new
/// items grow out of their nearest ancestor's old rect and fade in; removed items shrink into
/// their nearest surviving ancestor's new rect and fade out. The shown folder, which is not drawn,
/// counts as an ancestor that fills the view, so drilling in grows a folder to fill it.
struct TreemapTransition: Sendable {
    typealias Frame = [(item: TreemapItem, rect: TreemapRect, opacity: Double)]

    static let duration = 0.25

    /// Ease-out cubic over `duration`: a spring's quick start and soft stop, never past 1.
    static func progress(elapsed: Double) -> Double {
        let t = min(max(elapsed / duration, 0), 1)
        return 1 - (1 - t) * (1 - t) * (1 - t)
    }

    private struct Entry: Sendable {
        let item: TreemapItem
        let from: TreemapRect, to: TreemapRect
        let fromOpacity: Double, toOpacity: Double
    }

    /// The shown folder and the rect it fills.
    private struct Shown: Sendable {
        let node: FileNode
        let rect: TreemapRect
    }

    /// A folder and the smallerItems block inside it share a node, so the kind is part of the key.
    private struct Key: Hashable {
        let node: ObjectIdentifier
        let smaller: Bool
        init(_ item: TreemapItem) { node = ObjectIdentifier(item.node); smaller = item.isSmallerItems }
        init(folder: FileNode, smaller: Bool = false) { node = ObjectIdentifier(folder); self.smaller = smaller }
    }

    /// In draw order: each removed item right after the ancestor it shrinks into, so it stays on top of it.
    private let entries: [Entry]
    private let shown: Shown?

    init(from old: [TreemapItem], to new: [TreemapItem]) {
        self.init(from: old.map { ($0, $0.rect, 1) }, shown: Self.shown(in: old), to: new)
    }

    /// Starts from where `running` is at `progress`, so a layout landing mid-flight doesn't jump.
    init(from running: TreemapTransition, at progress: Double, to new: [TreemapItem]) {
        self.init(from: running.frame(at: progress), shown: running.shown, to: new)
    }

    private init(from old: Frame, shown oldShown: Shown?, to new: [TreemapItem]) {
        let newShown = Self.shown(in: new)
        // Items laid out before replace(_:with:) can hold a node it detached; they have nowhere to go.
        let old = old.filter { $0.item.node.parent != nil || $0.item.node === oldShown?.node }
        let new = new.filter { $0.node.parent != nil || $0.node === newShown?.node }

        var oldIndex: [Key: Int] = [:], newIndex: [Key: Int] = [:]
        oldIndex.reserveCapacity(old.count)
        newIndex.reserveCapacity(new.count)
        for (index, entry) in old.enumerated() { oldIndex[Key(entry.item)] = index }
        for (index, item) in new.enumerated() { newIndex[Key(item)] = index }

        /// The rect of `node`, or of its nearest ancestor or the smallerItems block inside it, in a
        /// layout, and its index there; nil for the shown folder. Without folders shown, folders
        /// have no item, so a folded file comes from its folder's block.
        func nearest(_ node: FileNode, in index: [Key: Int], shown: Shown?,
                     rect: (Int) -> TreemapRect) -> (index: Int?, rect: TreemapRect)? {
            var current: FileNode? = node
            while let folder = current {
                if let found = index[Key(folder: folder)] { return (found, rect(found)) }
                // The shown folder's own block is one of its items, not where the folder is.
                if folder === shown?.node { return (nil, shown!.rect) }
                if let found = index[Key(folder: folder, smaller: true)] { return (found, rect(found)) }
                current = folder.parent
            }
            return nil
        }

        // Removed items go after the new item they shrink into, or first when that is the shown folder.
        var removedFirst: [Entry] = [], removedAfter: [Int: [Entry]] = [:]
        for entry in old where newIndex[Key(entry.item)] == nil {
            let target = nearest(entry.item.node, in: newIndex, shown: newShown) { new[$0].rect }
            let removed = Entry(item: entry.item, from: entry.rect, to: target?.rect ?? entry.rect,
                                fromOpacity: entry.opacity, toOpacity: 0)
            if let after = target?.index { removedAfter[after, default: []].append(removed) } else { removedFirst.append(removed) }
        }

        var entries = removedFirst
        entries.reserveCapacity(old.count + new.count)
        for (index, item) in new.enumerated() {
            if let match = oldIndex[Key(item)] {
                entries.append(Entry(item: item, from: old[match].rect, to: item.rect,
                                     fromOpacity: old[match].opacity, toOpacity: 1))
            } else {
                let source = nearest(item.node, in: oldIndex, shown: oldShown) { old[$0].rect }
                entries.append(Entry(item: item, from: source?.rect ?? item.rect, to: item.rect, fromOpacity: 0, toOpacity: 1))
            }
            if let removed = removedAfter[index] { entries += removed }
        }
        self.entries = entries
        shown = newShown
    }

    /// Every item visible at `progress` (0 is the old layout, 1 the new), in draw order.
    func frame(at progress: Double) -> Frame {
        let t = min(max(progress, 0), 1)
        var frame: Frame = []
        frame.reserveCapacity(entries.count)
        for entry in entries {
            let opacity = entry.fromOpacity + (entry.toOpacity - entry.fromOpacity) * t
            guard opacity > 0 else { continue }
            let a = entry.from, b = entry.to
            frame.append((entry.item, TreemapRect(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t,
                                                  width: a.width + (b.width - a.width) * t,
                                                  height: a.height + (b.height - a.height) * t), opacity))
        }
        return frame
    }

    /// The folder a layout shows and the bounds its items fill. Without folders shown there may be
    /// no depth-1 item, so the folder is found up from the first item and the bounds span all of them.
    private static func shown(in items: [TreemapItem]) -> Shown? {
        guard let first = items.first else { return nil }
        // A smallerItems item's node is the folder that holds it, one level up.
        var node: FileNode? = first.node
        for _ in 0..<(first.isSmallerItems ? first.depth - 1 : first.depth) { node = node?.parent }
        guard let node else { return nil }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for item in items {
            minX = min(minX, item.rect.x); minY = min(minY, item.rect.y)
            maxX = max(maxX, item.rect.x + item.rect.width); maxY = max(maxY, item.rect.y + item.rect.height)
        }
        return Shown(node: node, rect: TreemapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }
}

extension TreemapItem {
    /// The same item at `rect`, for drawing a transition frame.
    func moved(to rect: TreemapRect) -> TreemapItem {
        TreemapItem(id: id, node: node, rect: rect, depth: depth, kind: kind, branch: branch)
    }
}
