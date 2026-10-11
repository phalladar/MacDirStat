import Foundation
import Testing
@testable import MacDirStat

private struct Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func metadata(_ url: URL) throws -> Darwin.stat {
        var result = Darwin.stat()
        #expect(lstat(url.path, &result) == 0)
        return result
    }
}

private func completedScan(_ path: String, limit: Int = 4,
                           mode: DirectoryEnumerationMode = .automatic) async throws -> (FileNode, Int64) {
    var root: FileNode?
    var progressBytes: Int64 = -1
    for await event in FileScanner(rootPath: path, maximumConcurrentDirectories: limit, enumerationMode: mode).scan() {
        switch event {
        case .completed(let node): root = node
        case .progress(_, let bytes, _): progressBytes = bytes
        case .error(let message): Issue.record("Scan error: \(message)")
        }
    }
    return (try #require(root), progressBytes)
}

@Test func bulkAndPosixScansPreserveEveryEntryAndMetadata() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    // More than one bulk buffer, Unicode names, folders, a sparse data fork and
    // a resource fork exercise attributes whose logical/allocation sizes differ.
    for index in 0..<1400 {
        let folder = fixture.root.appendingPathComponent("folder-\(index < 1300 ? 0 : index % 7)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: index % 8193).write(to: folder.appendingPathComponent("ø-📦-\(index).txt"))
    }
    let sparse = fixture.root.appendingPathComponent("sparse.img")
    let fd = open(sparse.path, O_CREAT | O_WRONLY, 0o600)
    #expect(fd >= 0)
    #expect(ftruncate(fd, 3_000_000_000_000) == 0)
    close(fd)
    try Data(repeating: 0x42, count: 8192).write(to: URL(fileURLWithPath: sparse.path + "/..namedfork/rsrc"))
    #expect(symlink(fixture.root.path, fixture.root.appendingPathComponent("cycle").path) == 0)
    #expect(mkfifo(fixture.root.appendingPathComponent("pipe").path, 0o600) == 0)

    let (bulk, _) = try await completedScan(fixture.root.path)
    let (posix, _) = try await completedScan(fixture.root.path, mode: .posix)
    func check(_ lhs: FileNode, _ rhs: FileNode) {
        #expect(lhs.id == rhs.id)
        #expect(lhs.ownSize == rhs.ownSize)
        #expect(lhs.allocatedSize == rhs.allocatedSize)
        #expect(lhs.modificationDate == rhs.modificationDate)
        #expect(lhs.isDataless == rhs.isDataless)
        #expect(lhs.totalSize == rhs.totalSize)
        #expect(lhs.totalAllocatedSize == rhs.totalAllocatedSize)
        #expect(lhs.fileCount == rhs.fileCount)
        #expect(lhs.directoryCount == rhs.directoryCount)
        #expect(lhs.totalUnavailableEntryCount == rhs.totalUnavailableEntryCount)
        let left = lhs.children.sorted { $0.name < $1.name }
        let right = rhs.children.sorted { $0.name < $1.name }
        #expect(left.map(\.name) == right.map(\.name))
        for (child, other) in zip(left, right) { check(child, other) }
    }
    check(bulk, posix)
    #expect(bulk.fileCount == 1401)
}

@Test func malformedBulkRecordsAreRejected() throws {
    let bytes = [UInt8](repeating: 0, count: 8)
    #expect(throws: BulkMetadataError.self) {
        try bytes.withUnsafeBytes { try decodeBulkDirectoryEntry($0, fd: -1) }
    }
}

@Test func localFilesystemReturnsBulkMetadata() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent("local.txt")
    try Data(repeating: 0x41, count: 12345).write(to: file)
    let expected = try fixture.metadata(file)
    try withoutDatalessMaterialization {
        let fd = open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }
        var reader = BulkDirectoryReader()
        guard case .entries(let entries, let unavailable) = try reader.next(fd: fd) else {
            Issue.record("Local filesystem did not return bulk entries")
            return
        }
        #expect(unavailable == 0)
        let entry = try #require(entries.first { $0.name == "local.txt" })
        #expect(entry.metadata.st_ino == expected.st_ino)
        #expect(entry.metadata.st_dev == expected.st_dev)
        #expect(entry.metadata.st_size == expected.st_size)
        #expect(entry.metadata.st_blocks == expected.st_blocks)
        #expect(entry.metadata.st_flags == expected.st_flags)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MACDIRSTAT_BENCHMARK_PATH"] != nil))
func compareDirectoryEnumerationPerformance() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["MACDIRSTAT_BENCHMARK_PATH"])
    var reference: (files: Int, directories: Int, logical: Int64, allocated: Int64, cloud: Int, incomplete: Int)?
    // Alternate order so both implementations see warm and cold metadata caches.
    for mode in [DirectoryEnumerationMode.posix, .automatic, .automatic, .posix] {
        let started = ContinuousClock.now
        let (root, _) = try await completedScan(path, mode: mode)
        let elapsed = ContinuousClock.now - started
        let totals = (root.fileCount, root.directoryCount, root.totalSize, root.totalAllocatedSize,
                      root.cloudOnlyFileCount, root.unscannedDirectoryCount)
        if let reference {
            #expect(totals == reference)
        } else { reference = totals }
        print("Enumeration benchmark: mode=\(mode), files=\(root.fileCount), directories=\(root.directoryCount), logical=\(root.totalSize), allocated=\(root.totalAllocatedSize), cloud=\(root.cloudOnlyFileCount), incomplete=\(root.unscannedDirectoryCount), elapsed=\(elapsed)")
    }
}

@Test func sparseFilesUseAllocatedProgressAndPreserveLogicalSize() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent("sparse.img")
    let fd = open(file.path, O_CREAT | O_WRONLY, 0o600)
    #expect(fd >= 0)
    #expect(ftruncate(fd, 3_000_000_000_000) == 0)
    close(fd)
    let metadata = try fixture.metadata(file)
    let directoryMetadata = try fixture.metadata(fixture.root)
    let (root, bytes) = try await completedScan(fixture.root.path)
    #expect(root.fileCount == 1)
    #expect(root.children.first?.ownSize == 3_000_000_000_000)
    #expect(root.children.first?.allocatedSize == Int64(metadata.st_blocks) * 512)
    #expect(bytes == root.totalAllocatedSize)
    #expect(bytes == Int64(metadata.st_blocks + directoryMetadata.st_blocks) * 512)
    #expect(bytes < 1_000_000)
}

@Test func hardLinksAreCountedOnceAndSymlinksAreNotFollowed() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent("original.txt")
    try Data(repeating: 0x41, count: 16_384).write(to: file)
    #expect(link(file.path, fixture.root.appendingPathComponent("hardlink.txt").path) == 0)
    #expect(symlink(fixture.root.path, fixture.root.appendingPathComponent("cycle").path) == 0)
    let (root, bytes) = try await completedScan(fixture.root.path)
    #expect(root.fileCount == 1)
    #expect(root.children.count == 1)
    #expect(root.totalSize >= 16_384 && root.totalSize < 32_768)
    #expect(bytes == root.totalAllocatedSize)
}

@Test func wideAndDeepTreesFinishWithSingleWorker() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    for index in 0..<80 {
        let folder = fixture.root.appendingPathComponent("branch-\(index)/child/grandchild")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0x41]).write(to: folder.appendingPathComponent("file.txt"))
    }
    let (root, bytes) = try await completedScan(fixture.root.path, limit: 1)
    #expect(root.fileCount == 80)
    #expect(root.directoryCount == 241)
    #expect(root.unscannedDirectoryCount == 0)
    #expect(bytes == root.totalAllocatedSize)
}

@Test func inaccessibleFoldersAreReportedAsIncomplete() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let folder = fixture.root.appendingPathComponent("restricted")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try Data([0x41]).write(to: folder.appendingPathComponent("hidden.txt"))
    #expect(chmod(folder.path, 0) == 0)
    defer { chmod(folder.path, 0o700) }
    let (root, _) = try await completedScan(fixture.root.path)
    #expect(root.fileCount == 0)
    #expect(root.unscannedDirectoryCount == 1)
    #expect(root.children.first?.scanIssue != nil)
}

@Test func nonexistentAndSymlinkRootsFailInsteadOfCompleting() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let alias = fixture.root.appendingPathComponent("alias")
    #expect(symlink(fixture.root.path, alias.path) == 0)
    for path in [fixture.root.appendingPathComponent("missing").path, alias.path] {
        var errors = 0
        for await event in FileScanner(rootPath: path).scan() {
            switch event {
            case .error: errors += 1
            case .completed: Issue.record("Invalid root was reported as completed")
            case .progress: break
            }
        }
        #expect(errors == 1)
    }
}

@Test func materializationPolicyIsDisabledAndRestoredEvenOnError() throws {
    let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
    let scope = IOPOL_SCOPE_THREAD
    let previous = getiopolicy_np(type, scope)
    try withoutDatalessMaterialization {
        #expect(getiopolicy_np(type, scope) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }
    #expect(getiopolicy_np(type, scope) == previous)
    struct ExpectedError: Error {}
    do {
        try withoutDatalessMaterialization {
            #expect(getiopolicy_np(type, scope) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            throw ExpectedError()
        }
        Issue.record("Expected the test error")
    } catch is ExpectedError {}
    #expect(getiopolicy_np(type, scope) == previous)
}

@Test func cloudMetadataAndIncompleteCountsArePreserved() {
    var metadata = Darwin.stat()
    metadata.st_mode = mode_t(S_IFREG | 0o600)
    metadata.st_size = 2_800_000_000_000
    metadata.st_flags = UInt32(SF_DATALESS)
    metadata.st_ino = 2
    let file = FileNode(name: "cloud.pdf", metadata: metadata)
    #expect(file.isDataless)
    #expect(file.allocatedSize == 0)
    #expect(file.ownSize == 2_800_000_000_000)
    metadata.st_mode = mode_t(S_IFDIR | 0o700)
    metadata.st_ino = 3
    let cloudFolder = FileNode(name: "online", metadata: metadata)
    cloudFolder.scanIssue = "Cloud-only folder"
    let root = FileNode(inode: 1, name: "/", isDirectory: true)
    root.unavailableEntryCount = 2
    root.addChild(file)
    root.addChild(cloudFolder)
    root.computeAggregates()
    #expect(root.cloudOnlyFileCount == 1)
    #expect(root.unscannedDirectoryCount == 1)
    #expect(root.totalUnavailableEntryCount == 2)
    #expect(file.path == "/cloud.pdf")
}

@Test func categoryBreakdownAndSortFollowSelectedMetric() {
    let root = FileNode(inode: 1, name: "/", isDirectory: true)
    root.addChild(FileNode(inode: 2, name: "sparse.pdf", isDirectory: false,
                           ownSize: 1_000_000, allocatedSize: 0, category: .documents))
    root.addChild(FileNode(inode: 3, name: "local.mp4", isDirectory: false,
                           ownSize: 100, allocatedSize: 4096, category: .video))
    root.computeAggregates()
    root.sortChildrenBySize()
    #expect(root.children.first?.name == "local.mp4")
    #expect(root.categoryBreakdown().first?.category == .video)
    #expect(root.categoryBreakdown(metric: .fileSize).first?.category == .documents)
}

@Test @MainActor func allocatedSizeIsTheDefaultMetric() {
    #expect(AppState().sizeMetric == .allocatedSize)
}

// Opt in with a locally available File Provider placeholder. CI does not have
// cloud accounts; the test reads metadata only and never requests hydration.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACDIRSTAT_CLOUD_TEST_PATH"] != nil))
func realCloudOnlyFolderIsNotMaterialized() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["MACDIRSTAT_CLOUD_TEST_PATH"])
    let before = try withoutDatalessMaterialization {
        var metadata = Darwin.stat()
        #expect(lstat(path, &metadata) == 0)
        return metadata
    }
    #expect(before.st_flags & UInt32(SF_DATALESS) != 0)
    let (root, bytes) = try await completedScan(path)
    #expect(root.isDataless)
    #expect(root.children.isEmpty)
    #expect(root.unscannedDirectoryCount == 1)
    #expect(root.scanIssue != nil)
    #expect(bytes == Int64(before.st_blocks) * 512)
    try withoutDatalessMaterialization {
        var after = Darwin.stat()
        #expect(lstat(path, &after) == 0)
        #expect(after.st_flags & UInt32(SF_DATALESS) != 0)
        #expect(after.st_blocks == before.st_blocks)
    }
}

@Test func cancellingConsumerDoesNotPublishCompletedTree() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    for index in 0..<200 {
        let folder = fixture.root.appendingPathComponent("branch-\(index)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for file in 0..<20 {
            try Data([0x41]).write(to: folder.appendingPathComponent("file-\(file).txt"))
        }
    }
    let (ready, signal) = AsyncStream<Void>.makeStream()
    let consumer = Task {
        let stream = FileScanner(rootPath: fixture.root.path, maximumConcurrentDirectories: 1).scan()
        signal.yield(())
        signal.finish()
        for await event in stream {
            if Task.isCancelled { break }
            if case .completed = event { Issue.record("Cancelled scan completed") }
        }
    }
    for await _ in ready { break }
    consumer.cancel()
    await consumer.value
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MACDIRSTAT_SCAN_TEST_PATH"] != nil))
func localIntegrationScan() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["MACDIRSTAT_SCAN_TEST_PATH"])
    let started = ContinuousClock.now
    let (root, bytes) = try await completedScan(path)
    #expect(bytes == root.totalAllocatedSize)
    print("Scan summary: files=\(root.fileCount), directories=\(root.directoryCount), logicalBytes=\(root.totalSize), allocatedBytes=\(bytes), cloudOnlyFiles=\(root.cloudOnlyFileCount), unscannedDirectories=\(root.unscannedDirectoryCount), unavailableEntries=\(root.totalUnavailableEntryCount), elapsed=\(ContinuousClock.now - started)")
}
