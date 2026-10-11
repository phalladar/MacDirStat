import Foundation

final class FileNode: Identifiable, @unchecked Sendable {
    let id: UInt64 // inode
    let name: String
    let isDirectory: Bool
    let ownSize: Int64
    let allocatedSize: Int64
    let category: FileCategory
    let modificationDate: Date?
    let isDataless: Bool
    var scanIssue: String?
    var unavailableEntryCount = 0
    private(set) var unscannedDirectoryCount = 0
    private(set) var totalUnavailableEntryCount = 0
    private(set) var cloudOnlyFileCount = 0

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
        let parts = components.reversed()
        guard let root = parts.first else { return "" }
        return parts.dropFirst().reduce(root) { path, name in
            path == "/" ? path + name : path + "/" + name
        }
    }

    init(
        inode: UInt64,
        name: String,
        isDirectory: Bool,
        ownSize: Int64 = 0,
        allocatedSize: Int64 = 0,
        category: FileCategory = .other,
        modificationDate: Date? = nil,
        isDataless: Bool = false
    ) {
        self.id = inode
        self.name = name
        self.isDirectory = isDirectory
        self.ownSize = ownSize
        self.allocatedSize = allocatedSize
        self.category = category
        self.modificationDate = modificationDate
        self.isDataless = isDataless
        self.cloudOnlyFileCount = !isDirectory && isDataless ? 1 : 0
        self.totalSize = ownSize
        self.totalAllocatedSize = allocatedSize
        self.fileCount = isDirectory ? 0 : 1
        self.directoryCount = isDirectory ? 1 : 0
    }

    convenience init(name: String, metadata: Darwin.stat) {
        let isDirectory = metadata.st_mode & S_IFMT == S_IFDIR
        let ext = name.lastIndex(of: ".").map { String(name[name.index(after: $0)...]) } ?? ""
        self.init(
            inode: UInt64(metadata.st_ino),
            name: name,
            isDirectory: isDirectory,
            ownSize: Int64(metadata.st_size),
            allocatedSize: Int64(metadata.st_blocks) * 512,
            category: isDirectory ? .other : FileExtensionMap.category(for: ext),
            modificationDate: Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)),
            isDataless: metadata.st_flags & UInt32(SF_DATALESS) != 0
        )
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
        var unscanned = scanIssue == nil ? 0 : 1
        var unavailable = unavailableEntryCount
        var cloudFiles = 0

        for child in children {
            child.computeAggregates()
            size += child.totalSize
            allocated += child.totalAllocatedSize
            files += child.fileCount
            dirs += child.directoryCount
            unscanned += child.unscannedDirectoryCount
            unavailable += child.totalUnavailableEntryCount
            cloudFiles += child.cloudOnlyFileCount
        }

        totalSize = size
        totalAllocatedSize = allocated
        fileCount = files
        directoryCount = dirs
        unscannedDirectoryCount = unscanned
        totalUnavailableEntryCount = unavailable
        cloudOnlyFileCount = cloudFiles
    }

    func sortChildrenBySize(metric: SizeMetric = .allocatedSize) {
        children.sort { $0.size(for: metric) > $1.size(for: metric) }
        for child in children where child.isDirectory {
            child.sortChildrenBySize(metric: metric)
        }
    }

    func categoryBreakdown(metric: SizeMetric = .allocatedSize) -> [(category: FileCategory, size: Int64)] {
        var breakdown: [FileCategory: Int64] = [:]
        accumulateCategories(into: &breakdown, metric: metric)
        return breakdown
            .sorted { $0.value > $1.value }
            .map { (category: $0.key, size: $0.value) }
    }

    private func accumulateCategories(into breakdown: inout [FileCategory: Int64], metric: SizeMetric) {
        if !isDirectory {
            breakdown[category, default: 0] += size(for: metric)
        }
        for child in children {
            child.accumulateCategories(into: &breakdown, metric: metric)
        }
    }

    func size(for metric: SizeMetric) -> Int64 {
        switch metric {
        case .fileSize: totalSize
        case .allocatedSize: totalAllocatedSize
        }
    }

    var directoryChildren: [FileNode] {
        children.filter(\.isDirectory)
    }
}
