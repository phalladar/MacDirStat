import Foundation
import os

enum ScanEvent: Sendable {
    case progress(fileCount: Int, byteCount: Int64, currentPath: String)
    case completed(root: FileNode)
    case error(String)
}

struct FileScanner: Sendable {
    let rootPath: String
    var maximumConcurrentDirectories: Int = 4
    var enumerationMode: DirectoryEnumerationMode = .automatic

    func scan() -> AsyncStream<ScanEvent> {
        let path = rootPath
        let limit = max(1, maximumConcurrentDirectories)
        let mode = enumerationMode
        return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            // The app cannot show its treemap until this requested scan finishes.
            // Keep directory concurrency bounded while prioritizing its results.
            let task = Task.detached(priority: .userInitiated) {
                await performScan(rootPath: path, limit: limit, mode: mode, continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

// The policy is thread-local. The body must be synchronous so Swift cannot resume
// it on another thread. Restore the previous policy before returning to the pool.
// Apple TN3150: even stat can materialize intermediate directories in a path.
func withoutDatalessMaterialization<T>(_ body: () throws -> T) throws -> T {
    let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
    let scope = IOPOL_SCOPE_THREAD
    let previous = getiopolicy_np(type, scope)
    guard previous >= 0,
          setiopolicy_np(type, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
        throw ScanFailure(message: "Cannot disable cloud downloads; scan stopped for safety.")
    }
    defer { setiopolicy_np(type, scope, previous) }
    return try body()
}

private struct ScanFailure: Error {
    let message: String
}

private final class ScanState: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: State())
    let rootDevice: dev_t

    private struct State {
        var fileCount = 0
        var byteCount: Int64 = 0
        var seenInodes = Set<UInt64>()
        var lastProgress = ContinuousClock.now
    }

    init(rootDevice: dev_t) {
        self.rootDevice = rootDevice
    }

    func record(_ metadata: Darwin.stat) -> Bool {
        lock.withLock { state in
            guard state.seenInodes.insert(UInt64(metadata.st_ino)).inserted else { return false }
            if metadata.st_mode & S_IFMT == S_IFREG { state.fileCount += 1 }
            state.byteCount += Int64(metadata.st_blocks) * 512
            return true
        }
    }

    func progress(path: String, force: Bool = false) -> ScanEvent? {
        lock.withLock { state in
            let now = ContinuousClock.now
            guard force || now - state.lastProgress >= .milliseconds(100) else { return nil }
            state.lastProgress = now
            return .progress(fileCount: state.fileCount, byteCount: state.byteCount, currentPath: path)
        }
    }
}

private struct DirectoryJob: Sendable {
    let path: String
    let node: FileNode
}

private struct DirectoryResult: Sendable {
    let job: DirectoryJob
    var children: [FileNode] = []
    var subdirectories: [DirectoryJob] = []
    var issue: String?
    var unavailableEntries = 0
}

private func performScan(
    rootPath: String,
    limit: Int,
    mode: DirectoryEnumerationMode,
    continuation: AsyncStream<ScanEvent>.Continuation
) async {
    defer { continuation.finish() }
    do {
        try Task.checkCancellation()
        // Normalize before lstat so relative roots and trailing separators refer
        // to the same path used for directory opens and Finder actions.
        let path = URL(fileURLWithPath: rootPath).path
        let rootStat = try withoutDatalessMaterialization {
            var metadata = Darwin.stat()
            guard lstat(path, &metadata) == 0 else {
                throw ScanFailure(message: "Cannot inspect the scan folder: \(String(cString: strerror(errno))). Cloud-only parent folders are not downloaded.")
            }
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                throw ScanFailure(message: "The scan path must be a directory, not a file or symbolic link.")
            }
            return metadata
        }
        let state = ScanState(rootDevice: rootStat.st_dev)
        _ = state.record(rootStat)
        let root = FileNode(name: path, metadata: rootStat)
        var pending = [DirectoryJob(path: path, node: root)]

        try await withThrowingTaskGroup(of: DirectoryResult.self) { group in
            var active = 0
            while !pending.isEmpty || active > 0 {
                try Task.checkCancellation()
                while active < limit, let job = pending.popLast() {
                    group.addTask {
                        try scanDirectory(job, mode: mode, state: state, continuation: continuation)
                    }
                    active += 1
                }
                if let result = try await group.next() {
                    active -= 1
                    result.job.node.scanIssue = result.issue
                    result.job.node.unavailableEntryCount = result.unavailableEntries
                    for child in result.children { result.job.node.addChild(child) }
                    pending.append(contentsOf: result.subdirectories)
                }
            }
        }
        try Task.checkCancellation()
        root.computeAggregates()
        root.sortChildrenBySize(metric: .allocatedSize)
        try Task.checkCancellation()
        if let progress = state.progress(path: path, force: true) { continuation.yield(progress) }
        continuation.yield(.completed(root: root))
    } catch is CancellationError {
        // Cancellation is terminal: never publish a partial tree as completed.
    } catch let error as ScanFailure {
        continuation.yield(.error(error.message))
    } catch {
        continuation.yield(.error(error.localizedDescription))
    }
}

private func scanDirectory(
    _ job: DirectoryJob,
    mode: DirectoryEnumerationMode,
    state: ScanState,
    continuation: AsyncStream<ScanEvent>.Continuation
) throws -> DirectoryResult {
    try withoutDatalessMaterialization {
        try Task.checkCancellation()
        var result = DirectoryResult(job: job)
        if let progress = state.progress(path: job.path) { continuation.yield(progress) }

        // Cloud-only directories have no locally enumerated children. Opening
        // them could fetch a remote listing, so retain a visible placeholder.
        guard !job.node.isDataless else {
            result.issue = "Cloud-only folder: contents were not downloaded or scanned."
            return result
        }
        // Do not follow a directory replaced with a symlink after enumeration.
        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            result.issue = directoryError(errno)
            return result
        }
        defer { close(fd) }
        var currentStat = Darwin.stat()
        guard fstat(fd, &currentStat) == 0,
              currentStat.st_dev == state.rootDevice,
              UInt64(currentStat.st_ino) == job.node.id else {
            result.issue = "Folder changed during the scan; rescan to measure its contents."
            return result
        }

        func append(name: String, metadata: Darwin.stat) {
            guard metadata.st_dev == state.rootDevice else { return }
            let type = metadata.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG, state.record(metadata) else { return }
            let child = FileNode(name: name, metadata: metadata)
            result.children.append(child)
            if child.isDirectory {
                let childPath = job.path == "/" ? "/" + name : job.path + "/" + name
                result.subdirectories.append(DirectoryJob(path: childPath, node: child))
            }
        }

        if mode == .automatic {
            var reader = BulkDirectoryReader()
            bulk: while true {
                try Task.checkCancellation()
                switch try reader.next(fd: fd) {
                case .entries(let entries, let unavailable):
                    result.unavailableEntries += unavailable
                    for entry in entries { append(name: entry.name, metadata: entry.metadata) }
                    if let progress = state.progress(path: job.path) { continuation.yield(progress) }
                case .end: return result
                case .failure(let code):
                    result.issue = directoryError(code)
                    return result
                case .unsupported: break bulk
                }
            }
        }
        // Never mix getattrlistbulk and readdir on one open file description.
        // A fresh descriptor also lets unsupported filesystems use POSIX safely.
        let enumerationFD = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard enumerationFD >= 0 else {
            result.issue = directoryError(errno)
            return result
        }
        guard let dir = fdopendir(enumerationFD) else {
            let error = errno
            close(enumerationFD)
            result.issue = directoryError(error)
            return result
        }
        defer { closedir(dir) }
        var entries = 0
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { result.issue = directoryError(errno) }
                break
            }
            entries += 1
            if entries % 256 == 0, let progress = state.progress(path: job.path) {
                continuation.yield(progress)
            }
            if entry.pointee.d_name.0 == 0x2E {
                let second = entry.pointee.d_name.1
                if second == 0 || (second == 0x2E && entry.pointee.d_name.2 == 0) { continue }
            }
            let type = entry.pointee.d_type
            if type != DT_DIR && type != DT_REG && type != DT_UNKNOWN { continue }

            var metadata = Darwin.stat()
            var nameBytes = entry.pointee.d_name
            let statOK = withUnsafeBytes(of: &nameBytes) { bytes in
                fstatat(fd, bytes.baseAddress!.assumingMemoryBound(to: CChar.self),
                        &metadata, AT_SYMLINK_NOFOLLOW) == 0
            }
            guard statOK else {
                result.unavailableEntries += 1
                continue
            }
            let name = withUnsafeBytes(of: &nameBytes) { bytes in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            append(name: name, metadata: metadata)
        }
        return result
    }
}

private func directoryError(_ code: Int32) -> String {
    if code == EDEADLK {
        return "Cloud folder needs a download to enumerate; contents were not scanned."
    }
    return "Folder contents could not be scanned: \(String(cString: strerror(code)))."
}
