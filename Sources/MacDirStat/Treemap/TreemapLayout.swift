import SwiftUI

struct TreemapRect: Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var area: Double { width * height }
    var minSide: Double { min(width, height) }

    func fits(_ size: CGSize) -> Bool { width >= size.width && height >= size.height }

    func contains(point: CGPoint) -> Bool {
        point.x >= x && point.x <= x + width &&
        point.y >= y && point.y <= y + height
    }
}

/// Layout sizes in points at zoom 1×.
enum TreemapMetrics {
    static let titleHeight = 18.0, gap = 1.0, padding = 2.0
    static let openByLevel = CGSize(width: 110, height: 70)
    static let openByHand = CGSize(width: 46, height: 40)
    static let titleMinimum = CGSize(width: 60, height: 36)
    static let smallerItemsArea = 144.0, maxDepth = 32
    /// Without folders shown, files tile the whole view, so smaller ones get their own block.
    static let smallerItemsAreaFlat = 64.0
}

struct TreemapItem: Identifiable, Sendable {
    enum Kind: Sendable, Equatable {
        /// Without folders shown, `file` is also a folder with nothing to lay out: a plain block; a
        /// folder that lays out blocks is a `group`, not drawn, under them.
        case file, openFolder, closedFolder, group, smallerItems(count: Int, size: Int64)
    }

    let id: Int
    /// For smallerItems, the folder that holds them.
    let node: FileNode
    let rect: TreemapRect
    let depth: Int
    let kind: Kind
    /// Index of the depth-1 ancestor among the shown folder's children, for folder color mode.
    let branch: Int

    var isSmallerItems: Bool {
        if case .smallerItems = kind { true } else { false }
    }

    /// Open folders, and closed ones with room for a title, are frames with a title strip.
    var hasTitleStrip: Bool {
        switch kind {
        case .openFolder: true
        case .closedFolder: rect.fits(TreemapMetrics.titleMinimum)
        case .file, .group, .smallerItems: false
        }
    }
}

struct TreemapLayoutEngine: Sendable {
    /// Lays out root's children, which have depth 1; root itself is not emitted. Parents come
    /// before their children, so the last item containing a point is the deepest one.
    /// Without `showsFolders`, every folder opens to the depth cap as a `group` whose children fill
    /// its cell; groups aren't drawn, and the smaller-items area is `smallerItemsAreaFlat`.
    func layout(root: FileNode, in bounds: TreemapRect, sizeMetric: SizeMetric,
                detailLevel: Int, overrides: [UInt64: Bool], showsFolders: Bool = true) -> [TreemapItem] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        var pass = LayoutPass(metric: sizeMetric, detailLevel: detailLevel, overrides: overrides,
                              showsFolders: showsFolders)
        let (children, total) = pass.childrenBySize(root)
        pass.place(children, total: total, of: root, in: bounds, depth: 1, branch: nil)
        return pass.items
    }

    private struct LayoutPass {
        let metric: SizeMetric
        let detailLevel: Int
        let overrides: [UInt64: Bool]
        let showsFolders: Bool
        let smallerItemsArea: Double
        var items: [TreemapItem] = []

        init(metric: SizeMetric, detailLevel: Int, overrides: [UInt64: Bool], showsFolders: Bool) {
            self.metric = metric
            self.detailLevel = detailLevel
            self.overrides = overrides
            self.showsFolders = showsFolders
            smallerItemsArea = showsFolders ? TreemapMetrics.smallerItemsArea : TreemapMetrics.smallerItemsAreaFlat
            items.reserveCapacity(4096)
        }

        /// Children with a size, largest first, and their total. Scans leave them sorted by
        /// allocated size, so this is usually a slice of the children with no copy.
        func childrenBySize(_ folder: FileNode) -> (children: ArraySlice<FileNode>, total: Int64) {
            let children = folder.children
            var previous = Int64.max
            var positive = 0
            var total: Int64 = 0
            for child in children {
                let size = child.size(for: metric)
                if size > previous {
                    let sorted = children.filter { $0.size(for: metric) > 0 }
                        .sorted { $0.size(for: metric) > $1.size(for: metric) }
                    return (ArraySlice(sorted), sorted.reduce(0) { $0 + $1.size(for: metric) })
                }
                if size > 0 { positive += 1 }
                total += size
                previous = size
            }
            return (children[..<positive], total)
        }

        /// Lays out a folder's nonempty, sorted children in `content`. A sorted tail of at least
        /// two children each smaller than the pass's smaller-items area becomes one smallerItems item. A
        /// `content` with no area, as a sliver folder's without folders shown, gets nothing.
        mutating func place(_ children: ArraySlice<FileNode>, total: Int64, of folder: FileNode,
                            in content: TreemapRect, depth: Int, branch: Int?) {
            guard !children.isEmpty, content.width > 0, content.height > 0, !Task.isCancelled else { return }
            let scale = content.area / Double(total)

            var sizes: [Double] = []
            sizes.reserveCapacity(min(children.count, Int(content.area / smallerItemsArea) + 2))
            var head = children.startIndex
            var headTotal: Int64 = 0
            while head < children.endIndex {
                let size = children[head].size(for: metric)
                let area = Double(size) * scale
                if area < smallerItemsArea && children.endIndex - head >= 2 { break }
                sizes.append(area)
                headTotal += size
                head += 1
            }
            let smallerCount = children.endIndex - head
            if smallerCount > 0 { sizes.append(Double(total - headTotal) * scale) }

            let rects = TreemapLayoutEngine.squarify(sizes: sizes, in: content)
            let half = TreemapMetrics.gap / 2
            for (offset, laid) in rects.enumerated() {
                // Half the gap on every side, so siblings sit one gap apart and a frame's children
                // sit padding plus half a gap inside it on all four sides, the strip's edge counting as the top.
                let rect = TreemapRect(x: laid.x + half, y: laid.y + half,
                                       width: max(0, laid.width - TreemapMetrics.gap),
                                       height: max(0, laid.height - TreemapMetrics.gap))
                let itemBranch = branch ?? offset
                guard children.startIndex + offset < head else {
                    append(folder, rect, depth, .smallerItems(count: smallerCount, size: total - headTotal), itemBranch)
                    continue
                }
                let child = children[children.startIndex + offset]
                guard child.isDirectory else {
                    append(child, rect, depth, .file, itemBranch)
                    continue
                }
                let (grandchildren, grandTotal) = depth < TreemapMetrics.maxDepth && opens(child, rect, depth)
                    ? childrenBySize(child) : ([], 0)
                // Without folders shown, a folder is a group under its children, which fill the cell
                // it was laid out in, so every block sits one gap from its neighbours at any depth.
                // One with nothing to lay out, empty or at the depth cap, is a plain block.
                guard showsFolders else {
                    append(child, rect, depth, grandchildren.isEmpty ? .file : .group, itemBranch)
                    place(grandchildren, total: grandTotal, of: child, in: laid, depth: depth + 1, branch: itemBranch)
                    continue
                }
                append(child, rect, depth, grandchildren.isEmpty ? .closedFolder : .openFolder, itemBranch)
                let inner = TreemapRect(
                    x: rect.x + TreemapMetrics.padding,
                    y: rect.y + TreemapMetrics.titleHeight + TreemapMetrics.padding,
                    width: rect.width - 2 * TreemapMetrics.padding,
                    height: rect.height - TreemapMetrics.titleHeight - 2 * TreemapMetrics.padding
                )
                place(grandchildren, total: grandTotal, of: child, in: inner, depth: depth + 1, branch: itemBranch)
            }
        }

        /// Whether a folder lays out its children: by hand or by level, given room for them.
        /// Without folders shown, every folder does.
        private func opens(_ folder: FileNode, _ rect: TreemapRect, _ depth: Int) -> Bool {
            guard showsFolders else { return true }
            let (opens, minimum) = overrides[folder.id].map { ($0, TreemapMetrics.openByHand) }
                ?? (depth < detailLevel, TreemapMetrics.openByLevel)
            return opens && rect.fits(minimum)
        }

        private mutating func append(_ node: FileNode, _ rect: TreemapRect, _ depth: Int,
                                     _ kind: TreemapItem.Kind, _ branch: Int) {
            items.append(TreemapItem(id: items.count, node: node, rect: rect, depth: depth, kind: kind, branch: branch))
        }
    }

    static func squarify(sizes: [Double], in bounds: TreemapRect) -> [TreemapRect] {
        guard !sizes.isEmpty else { return [] }

        var rects = [TreemapRect](repeating: TreemapRect(x: 0, y: 0, width: 0, height: 0), count: sizes.count)
        var remaining = bounds
        var index = 0

        while index < sizes.count {
            let shortSide = remaining.minSide

            // Grow the row while the worst aspect ratio keeps improving; O(1) per candidate.
            let s2 = shortSide * shortSide
            func worst(sum: Double, lo: Double, hi: Double) -> Double {
                guard s2 > 0 && sum > 0 else { return .infinity }
                return max(s2 * hi / (sum * sum), sum * sum / (s2 * lo))
            }
            var rowSum = sizes[index]
            var lo = rowSum, hi = rowSum
            var bestWorst = worst(sum: rowSum, lo: lo, hi: hi)

            var next = index + 1
            while next < sizes.count {
                let size = sizes[next]
                let newSum = rowSum + size
                let newLo = min(lo, size), newHi = max(hi, size)
                let newWorst = worst(sum: newSum, lo: newLo, hi: newHi)
                if newWorst > bestWorst {
                    break
                }
                bestWorst = newWorst
                rowSum = newSum
                lo = newLo
                hi = newHi
                next += 1
            }
            let row = index..<next

            // Lay out the row
            let rowFraction = rowSum / (remaining.width * remaining.height)
            let isHorizontal = remaining.width >= remaining.height

            if isHorizontal {
                let rowWidth = remaining.width * rowFraction
                var yOffset = remaining.y
                for idx in row {
                    let itemHeight = (sizes[idx] / rowSum) * remaining.height
                    rects[idx] = TreemapRect(
                        x: remaining.x,
                        y: yOffset,
                        width: rowWidth,
                        height: itemHeight
                    )
                    yOffset += itemHeight
                }
                remaining = TreemapRect(
                    x: remaining.x + rowWidth,
                    y: remaining.y,
                    width: remaining.width - rowWidth,
                    height: remaining.height
                )
            } else {
                let rowHeight = remaining.height * rowFraction
                var xOffset = remaining.x
                for idx in row {
                    let itemWidth = (sizes[idx] / rowSum) * remaining.width
                    rects[idx] = TreemapRect(
                        x: xOffset,
                        y: remaining.y,
                        width: itemWidth,
                        height: rowHeight
                    )
                    xOffset += itemWidth
                }
                remaining = TreemapRect(
                    x: remaining.x,
                    y: remaining.y + rowHeight,
                    width: remaining.width,
                    height: remaining.height - rowHeight
                )
            }

            index = next
        }

        return rects
    }
}
