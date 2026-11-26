import SwiftUI

struct TreemapRect: Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var area: Double { width * height }
    var minSide: Double { min(width, height) }

    func contains(point: CGPoint) -> Bool {
        point.x >= x && point.x <= x + width &&
        point.y >= y && point.y <= y + height
    }
}

struct TreemapItem: Identifiable, Sendable {
    let id: Int
    let node: FileNode
    let rect: TreemapRect
    let depth: Int
    let color: CGColor
}

struct TreemapLayoutEngine: Sendable {
    let maxDepth: Int
    let minPixelArea: Double

    init(maxDepth: Int = 12, minPixelArea: Double = 4) {
        self.maxDepth = maxDepth
        self.minPixelArea = minPixelArea
    }

    func layout(root: FileNode, in bounds: TreemapRect, sizeMetric: SizeMetric = .allocatedSize) -> [TreemapItem] {
        var items: [TreemapItem] = []
        items.reserveCapacity(8192)
        var nextID = 0
        layoutNode(root, in: bounds, depth: 0, sizeMetric: sizeMetric, items: &items, nextID: &nextID)
        return items
    }

    private func colorForNode(_ node: FileNode, depth: Int) -> CGColor {
        let darkenFactor = max(0.5, 1.0 - Double(depth) * 0.08)
        let baseColor = node.category.color.resolve(in: .init())
        return CGColor(
            red: Double(baseColor.red) * darkenFactor,
            green: Double(baseColor.green) * darkenFactor,
            blue: Double(baseColor.blue) * darkenFactor,
            alpha: 1.0
        )
    }

    private func layoutNode(
        _ node: FileNode,
        in bounds: TreemapRect,
        depth: Int,
        sizeMetric: SizeMetric,
        items: inout [TreemapItem],
        nextID: inout Int
    ) {
        guard bounds.area >= minPixelArea, !Task.isCancelled else { return }

        // Leaf node (file or empty/childless directory)
        if !node.isDirectory || node.children.isEmpty || depth >= maxDepth {
            let itemID = nextID; nextID += 1
            items.append(TreemapItem(
                id: itemID,
                node: node,
                rect: bounds,
                depth: depth,
                color: colorForNode(node, depth: depth)
            ))
            return
        }

        // Filter children with positive size
        let children = node.children.filter { $0.size(for: sizeMetric) > 0 }
            .sorted { $0.size(for: sizeMetric) > $1.size(for: sizeMetric) }
        guard !children.isEmpty else {
            let itemID = nextID; nextID += 1
            items.append(TreemapItem(
                id: itemID,
                node: node,
                rect: bounds,
                depth: depth,
                color: colorForNode(node, depth: depth)
            ))
            return
        }

        // Render directory as background so gaps show its color, not black
        let itemID = nextID; nextID += 1
        items.append(TreemapItem(
            id: itemID,
            node: node,
            rect: bounds,
            depth: depth,
            color: colorForNode(node, depth: depth)
        ))

        let totalSize = Double(children.reduce(0) { $0 + $1.size(for: sizeMetric) })
        guard totalSize > 0 else { return }

        // Compute normalized sizes proportional to area
        let sizes = children.map { Double($0.size(for: sizeMetric)) / totalSize * bounds.area }

        let rects = squarify(sizes: sizes, in: bounds)

        for (i, child) in children.enumerated() where i < rects.count {
            layoutNode(child, in: rects[i], depth: depth + 1, sizeMetric: sizeMetric, items: &items, nextID: &nextID)
        }
    }

    func squarify(sizes: [Double], in bounds: TreemapRect) -> [TreemapRect] {
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
