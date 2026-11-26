import Testing
@testable import MacDirStat

@MainActor
private struct Tree {
    let state = AppState()
    let root, a, b, c, d, file: FileNode

    init() {
        func node(_ id: UInt64, _ name: String, dir: Bool, size: Int64 = 0) -> FileNode {
            FileNode(inode: id, name: name, isDirectory: dir, ownSize: size, allocatedSize: size, category: .other)
        }
        root = node(1, "root", dir: true)
        a = node(2, "a", dir: true)
        b = node(3, "b", dir: true)
        file = node(4, "file", dir: false, size: 10)
        c = node(5, "c", dir: true)
        d = node(6, "d", dir: true)
        root.addChild(a)
        root.addChild(c)
        c.addChild(d)
        a.addChild(b)
        b.addChild(file)
        root.computeAggregates()
        state.setScanCompleted(root: root)
    }
}

@MainActor
struct AppStateTreemapTests {
    @Test func selectingDoesNotExpandSidebar() {
        let t = Tree()
        t.state.selectedNode = t.file
        #expect(t.state.expandedIDs.isEmpty)
    }

    @Test func drillDownRevealsAndOpensTheFolderInSidebar() {
        let t = Tree()
        t.state.drillDown(to: t.b)
        #expect(t.state.expandedIDs == [t.a.id, t.b.id])
        t.state.navigateUp()
        #expect(t.state.expandedIDs.contains(t.b.id))
    }

    @Test func detailClampsToRange() {
        let state = AppState()
        for _ in 0..<10 { state.moreDetail() }
        #expect(state.detailLevel == 8)
        for _ in 0..<10 { state.lessDetail() }
        #expect(state.detailLevel == 1)
    }

    @Test func overridesSurviveNavigationAndClearOnScanAndCollapse() {
        let t = Tree()
        t.state.setFolderOpen(t.b, true)
        t.state.drillDown(to: t.a)
        t.state.navigateUp()
        #expect(t.state.folderOverrides[t.b.id] == true)
        t.state.collapseAll()
        #expect(t.state.folderOverrides.isEmpty)
        t.state.setFolderOpen(t.b, true)
        t.state.setScanCompleted(root: t.root)
        #expect(t.state.folderOverrides.isEmpty)
    }

    @Test func togglingShowsFoldersKeepsOverrides() {
        let t = Tree()
        #expect(t.state.showsFolders)
        t.state.setFolderOpen(t.b, true)
        t.state.showsFolders = false
        #expect(!t.state.canMoreDetail && !t.state.canLessDetail && !t.state.canCollapseAll)
        t.state.showsFolders = true
        #expect(t.state.folderOverrides == [t.b.id: true])
        #expect(t.state.canMoreDetail && t.state.canLessDetail && t.state.canCollapseAll)
    }

    @Test func replaceLeavesStaleOverridesHarmless() async {
        let t = Tree()
        t.state.drillDown(to: t.b)
        t.state.setFolderOpen(t.b, true)
        await t.state.replace(t.a, with: nil)
        #expect(t.state.treemapRoot === t.root)
        #expect(t.state.selectedNode === t.root)
        #expect(t.state.folderOverrides[t.b.id] == true)
    }

    @Test func selectFromTreeOutsideTreemapRootRevealsAncestors() {
        let t = Tree()
        t.state.drillDown(to: t.b)
        t.state.selectFromTree(t.d)
        #expect(t.state.treemapRoot === t.c)
        #expect(t.state.expandedIDs.contains(t.c.id))
    }

    @Test func pickingAFolderInsideTheShownOneRevealsIt() {
        let t = Tree()
        t.state.selectFromTree(t.b)
        #expect(t.state.treemapRoot === t.root)
        #expect(t.state.expandedIDs == [t.a.id])
    }

    @Test func treeControlsNeedATreeOnScreen() {
        let fresh = AppState()
        #expect(!fresh.hasTree && !fresh.canMoreDetail && !fresh.canLessDetail)
        let t = Tree()
        #expect(t.state.hasTree && t.state.canMoreDetail)
        // The welcome screen over a scanned tree: nothing on screen for them to act on.
        t.state.scanStatus = .idle
        #expect(!t.state.hasTree && !t.state.canMoreDetail && !t.state.canLessDetail)
        t.state.setFolderOpen(t.a, true)
        #expect(!t.state.canCollapseAll)
    }
}
