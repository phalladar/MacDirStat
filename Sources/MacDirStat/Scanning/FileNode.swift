import Foundation

final class FileNode: Identifiable, @unchecked Sendable {
    let id: UInt64 // inode
    let name: String
    let isDirectory: Bool
    let ownSize: Int64
    let allocatedSize: Int64
    let category: FileCategory
    let modificationDate: Date?

    weak var parent: FileNode?
    var children: [FileNode] = []
    private(set) var totalSize: Int64 = 0
    private(set) var totalAllocatedSize: Int64 = 0
    private(set) var fileCount: Int = 0
    private(set) var directoryCount: Int = 0

    var path: String {
        var components: [String] = []
        var node: FileNode? = self
        while let current = node {
            components.append(current.name)
            node = current.parent
        }
        return components.reversed().joined(separator: "/")
    }

    init(
        inode: UInt64,
        name: String,
        isDirectory: Bool,
        ownSize: Int64 = 0,
        allocatedSize: Int64 = 0,
        category: FileCategory = .other,
        modificationDate: Date? = nil
    ) {
        self.id = inode
        self.name = name
        self.isDirectory = isDirectory
        self.ownSize = ownSize
        self.allocatedSize = allocatedSize
        self.category = category
        self.modificationDate = modificationDate
        self.totalSize = ownSize
        self.totalAllocatedSize = allocatedSize
        self.fileCount = isDirectory ? 0 : 1
        self.directoryCount = isDirectory ? 1 : 0
    }

    func addChild(_ child: FileNode) {
        child.parent = self
        children.append(child)
    }

    func computeAggregates() {
        guard isDirectory else { return }
        var size: Int64 = ownSize
        var allocated: Int64 = allocatedSize
        var files = 0
        var dirs = 1 // count self

        for child in children {
            child.computeAggregates()
            size += child.totalSize
            allocated += child.totalAllocatedSize
            files += child.fileCount
            dirs += child.directoryCount
        }

        totalSize = size
        totalAllocatedSize = allocated
        fileCount = files
        directoryCount = dirs
    }

    func sortChildrenBySize() {
        children.sort { $0.totalSize > $1.totalSize }
        for child in children where child.isDirectory {
            child.sortChildrenBySize()
        }
    }

    func categoryBreakdown() -> [(category: FileCategory, size: Int64)] {
        var breakdown: [FileCategory: Int64] = [:]
        accumulateCategories(into: &breakdown)
        return breakdown
            .sorted { $0.value > $1.value }
            .map { (category: $0.key, size: $0.value) }
    }

    private func accumulateCategories(into breakdown: inout [FileCategory: Int64]) {
        if !isDirectory {
            breakdown[category, default: 0] += ownSize
        }
        for child in children {
            child.accumulateCategories(into: &breakdown)
        }
    }

    var directoryChildren: [FileNode] {
        children.filter(\.isDirectory)
    }
}
