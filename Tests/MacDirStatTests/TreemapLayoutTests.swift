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
    let engine = TreemapLayoutEngine()
    let bounds = TreemapRect(x: 10, y: 20, width: 1200, height: 800)
    var generator = SeededGenerator(state: 42)
    for _ in 0..<200 {
        let count = Int.random(in: 1...500, using: &generator)
        var sizes = (0..<count).map { _ in Double.random(in: 1...1e9, using: &generator) }
        sizes.sort(by: >)
        let total = sizes.reduce(0, +)
        sizes = sizes.map { $0 / total * bounds.area }

        let rects = engine.squarify(sizes: sizes, in: bounds)
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

// Opt in with a path to scan. Prints median layout and offscreen draw times.
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

    var items: [TreemapItem] = []
    var layoutTimes: [Double] = []
    for _ in 0..<5 {
        layoutTimes.append(milliseconds(clock.measure { items = engine.layout(root: root, in: bounds) }))
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
    print("BENCH path=\(path) items=\(items.count) layout_ms_median=\(median(layoutTimes)) draw_ms_median=\(median(drawTimes))")
}
