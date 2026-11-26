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
