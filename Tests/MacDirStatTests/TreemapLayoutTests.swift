import Foundation
import SwiftUI
import Testing
@testable import MacDirStat

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Test func squarifyInvariants() {
    let bounds = TreemapRect(x: 10, y: 20, width: 1200, height: 800)
    var generator = SeededGenerator(state: 42)
    for _ in 0..<200 {
        let count = Int.random(in: 1...500, using: &generator)
        var sizes = (0..<count).map { _ in Double.random(in: 1...1e9, using: &generator) }
        sizes.sort(by: >)
        let total = sizes.reduce(0, +)
        sizes = sizes.map { $0 / total * bounds.area }

        let rects = TreemapLayoutEngine.squarify(sizes: sizes, in: bounds)
        #expect(rects.count == count)
        let eps = 1e-6
        for (rect, size) in zip(rects, sizes) {
            #expect(rect.x >= bounds.x - eps && rect.y >= bounds.y - eps)
            #expect(rect.x + rect.width <= bounds.x + bounds.width + eps)
            #expect(rect.y + rect.height <= bounds.y + bounds.height + eps)
            #expect(abs(rect.area - size) <= eps * size)
        }
        // Sweep by x so overlap checks stay near-linear.
        let order = rects.indices.sorted { rects[$0].x < rects[$1].x }
        for (n, i) in order.enumerated() {
            for j in order[(n + 1)...] {
                if rects[j].x >= rects[i].x + rects[i].width { break }
                let a = rects[i], b = rects[j]
                let w: Double = min(a.x + a.width, b.x + b.width) - b.x
                let h: Double = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
                #expect(w * h <= eps * bounds.area)
            }
        }
    }
}

private indirect enum Spec {
    case file(Int64)
    case folder([Spec], own: Int64 = 0)
}

/// Builds a tree from a spec with unique inodes, sizes in both metrics, and aggregates computed.
private func tree(_ spec: Spec) -> FileNode {
    var inode: UInt64 = 0
    func build(_ spec: Spec) -> FileNode {
        inode += 1
        switch spec {
        case .file(let size):
            return FileNode(inode: inode, name: "f\(inode)", isDirectory: false, ownSize: size, allocatedSize: size)
        case .folder(let children, let own):
            let node = FileNode(inode: inode, name: "d\(inode)", isDirectory: true, ownSize: own, allocatedSize: own)
            for child in children { node.addChild(build(child)) }
            return node
        }
    }
    let root = build(spec)
    root.computeAggregates()
    return root
}

private let screen = TreemapRect(x: 0, y: 0, width: 1200, height: 800)

private func lay(_ root: FileNode, in bounds: TreemapRect = screen, level: Int = 3,
                 overrides: [UInt64: Bool] = [:]) -> [TreemapItem] {
    TreemapLayoutEngine().layout(root: root, in: bounds, sizeMetric: .allocatedSize,
                                 detailLevel: level, overrides: overrides)
}

private func item(_ node: FileNode, in items: [TreemapItem]) -> TreemapItem? {
    items.first { $0.node === node && !$0.isSmallerItems }
}

private extension TreemapItem {
    var isSmallerItems: Bool { if case .smallerItems = kind { true } else { false } }
}

/// root → a → b → c → file, one child each.
private func chain(_ count: Int) -> (root: FileNode, folders: [FileNode]) {
    var spec = Spec.file(1000)
    for _ in 0..<count { spec = .folder([spec]) }
    let root = tree(.folder([spec]))
    var folders: [FileNode] = []
    var node = root.children.first
    while let current = node, current.isDirectory { folders.append(current); node = current.children.first }
    return (root, folders)
}

@Test func rootIsNotDrawnAndChildrenAreDepthOne() {
    let root = tree(.folder([.file(100), .file(50), .folder([.file(30)])]))
    let items = lay(root)
    #expect(!items.contains { $0.node === root })
    #expect(items.filter { $0.depth == 1 }.count == 3)
    #expect(items.map(\.depth).min() == 1)
    #expect(items.enumerated().allSatisfy { $0.offset == $0.element.id })
}

@Test func defaultLevelOpensTwoLevels() {
    let (root, folders) = chain(3)
    let items = lay(root)
    #expect(item(folders[0], in: items)?.kind == .openFolder)
    #expect(item(folders[1], in: items)?.kind == .openFolder)
    #expect(item(folders[2], in: items)?.kind == .closedFolder)
    #expect(item(folders[2], in: items)?.depth == 3)
    #expect(items.count == 3)
}

@Test func levelOneClosesEveryFolder() {
    let root = mixedTree()
    let items = lay(root, level: 1)
    #expect(items.contains { $0.kind == .closedFolder })
    #expect(items.allSatisfy { $0.depth == 1 && $0.kind != .openFolder })
}

@Test func handOpenedFolderOpensPastLevel() {
    let (root, folders) = chain(3)
    let items = lay(root, overrides: [folders[2].id: true])
    #expect(item(folders[2], in: items)?.kind == .openFolder)
    #expect(items.contains { $0.kind == .file && $0.depth == 4 })
}

@Test func handClosedFolderClosesBeforeLevel() {
    let (root, folders) = chain(3)
    let items = lay(root, overrides: [folders[0].id: false])
    #expect(item(folders[0], in: items)?.kind == .closedFolder)
    #expect(items.count == 1)
}

@Test func roomRules() {
    let root = tree(.folder([.folder([.file(10), .file(5)])]))
    let folder = root.children[0]
    let medium = TreemapRect(x: 0, y: 0, width: 100, height: 60)
    #expect(item(folder, in: lay(root, in: medium))?.kind == .closedFolder)
    #expect(item(folder, in: lay(root, in: medium, overrides: [folder.id: true]))?.kind == .openFolder)
    let small = TreemapRect(x: 0, y: 0, width: 40, height: 30)
    #expect(item(folder, in: lay(root, in: small, overrides: [folder.id: true]))?.kind == .closedFolder)
}

private func mixedTree() -> FileNode {
    func files(_ seed: Int64) -> [Spec] { (1...12).map { .file($0 * 7_919 * seed % 100_000 + 1) } }
    let folders: [Spec] = (1...6).map { n in
        .folder(files(Int64(n)) + (1...3).map { m in .folder(files(Int64(n * 10 + m))) })
    }
    return tree(.folder(folders + files(99)))
}

@Test func childrenStayInsideFrameBelowTitle() throws {
    let items = lay(mixedTree(), level: 8)
    #expect(items.contains { $0.depth == 3 })
    let eps = 1e-9
    for child in items where child.depth > 1 {
        let container = child.isSmallerItems ? child.node : child.node.parent
        let parent = try #require(items.first { $0.node === container && $0.kind == .openFolder })
        let p = parent.rect, c = child.rect
        #expect(c.x >= p.x + TreemapMetrics.padding - eps)
        #expect(c.x + c.width <= p.x + p.width - TreemapMetrics.padding + eps)
        #expect(c.y >= p.y + TreemapMetrics.titleHeight - eps)
        #expect(c.y + c.height <= p.y + p.height - TreemapMetrics.padding + eps)
    }
}

@Test func smallerItemsSumAndMinimumCount() {
    let pair = lay(tree(.folder([.file(1_000_000_000), .file(1)])))
    #expect(pair.count == 2)
    #expect(!pair.contains { $0.isSmallerItems })

    let many = lay(tree(.folder([.file(1_000_000_000)] + Array(repeating: .file(3), count: 50))))
    #expect(many.count == 2)
    #expect(many.filter(\.isSmallerItems).map(\.kind) == [.smallerItems(count: 50, size: 150)])
}

@Test func tensOfThousandsOfTinyFilesStayBounded() {
    let root = tree(.folder([.folder(Array(repeating: .file(1), count: 50_000))]))
    let items = lay(root)
    #expect(items.count < 10_000)
}

@Test func zeroSizedChildrenDrawAsClosedFolder() {
    let root = tree(.folder([.file(100), .folder([.file(0), .file(0)], own: 4096), .file(0), .folder([])]))
    let items = lay(root, overrides: [root.children[1].id: true])
    #expect(items.count == 2)
    #expect(item(root.children[1], in: items)?.kind == .closedFolder)
    for item in items {
        let r = item.rect
        #expect([r.x, r.y, r.width, r.height].allSatisfy { $0.isFinite })
    }
}

@Test func tinyBoundsEmitNoNegativeRects() {
    let root = mixedTree()
    var everything: [UInt64: Bool] = [:]
    func openAll(_ node: FileNode) { for c in node.children where c.isDirectory { everything[c.id] = true; openAll(c) } }
    openAll(root)
    for bounds in [TreemapRect(x: 0, y: 0, width: 30, height: 12), TreemapRect(x: 0, y: 0, width: 200, height: 17)] {
        let items = lay(root, in: bounds, level: 8, overrides: everything)
        #expect(!items.isEmpty)
        for item in items {
            #expect(item.rect.width >= 0 && item.rect.height >= 0)
            #expect(item.rect.width.isFinite && item.rect.height.isFinite)
        }
    }
    // A hand-opened folder just over the 46×40 minimum (after the gap) gets the smallest inner rect.
    let edge = tree(.folder([.folder([.file(5), .file(3), .file(1), .folder([.file(2)])])]))
    let folder = edge.children[0]
    let items = lay(edge, in: TreemapRect(x: 0, y: 0, width: 47.5, height: 41.5), overrides: [folder.id: true])
    #expect(item(folder, in: items)?.kind == .openFolder)
    #expect(items.contains { $0.depth == 2 })
    for item in items {
        #expect(item.rect.width >= 0 && item.rect.height >= 0)
    }
}

@Test func depthCapStopsAt32() {
    let (root, folders) = chain(40)
    let overrides = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, true) })
    let items = lay(root, overrides: overrides)
    #expect(items.map(\.depth).max() == TreemapMetrics.maxDepth)
    #expect(items.last?.kind == .closedFolder)
}

@Test func branchIndexFollowsDepthOneAncestor() {
    // Unsorted on purpose: branches follow the size order.
    let root = tree(.folder([
        .file(50_000),
        .folder([.file(100_000), .file(80_000)]),
        .folder([.file(400_000), .folder([.file(300_000), .file(200_000)])]),
    ]))
    let items = lay(root)
    let big = root.children[2], middle = root.children[1], file = root.children[0]
    for item in items {
        let expected = item.node.isInSubtree(of: big) ? 0 : item.node.isInSubtree(of: middle) ? 1 : 2
        #expect(item.branch == expected)
    }
    #expect(item(file, in: items)?.branch == 2)
    #expect(items.contains { $0.depth == 3 && $0.branch == 0 })
}

// Opt in with a path to scan. Prints median layout and offscreen draw times at levels 3 and 8.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACDIRSTAT_BENCH_PATH"] != nil))
@MainActor func layoutBenchmark() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["MACDIRSTAT_BENCH_PATH"])
    var scanned: FileNode?
    for await event in FileScanner(rootPath: path).scan() {
        if case .completed(let node) = event { scanned = node }
    }
    let root = try #require(scanned)
    let engine = TreemapLayoutEngine()
    let bounds = TreemapRect(x: 0, y: 0, width: 1200, height: 800)
    let clock = ContinuousClock()
    func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    func milliseconds(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    for level in [3, 8] {
        var items: [TreemapItem] = []
        var layoutTimes: [Double] = []
        for _ in 0..<5 {
            layoutTimes.append(milliseconds(clock.measure {
                items = engine.layout(root: root, in: bounds, sizeMetric: .allocatedSize,
                                      detailLevel: level, overrides: [:])
            }))
        }

        let laidOut = items
        var drawTimes: [Double] = []
        for _ in 0..<5 {
            let canvas = Canvas { context, size in
                TreemapRenderer(items: laidOut, hoveredItemID: nil, zoomScale: 1, panOffset: .zero,
                                showLabels: true, sizeMetric: .allocatedSize).draw(in: &context, size: size)
            }.frame(width: 1200, height: 800)
            drawTimes.append(milliseconds(clock.measure { _ = ImageRenderer(content: canvas).cgImage }))
        }
        print("BENCH path=\(path) level=\(level) items=\(items.count) layout_ms_median=\(median(layoutTimes)) draw_ms_median=\(median(drawTimes))")
    }
}
