import Foundation
import os

enum ScanEvent: Sendable {
    case progress(fileCount: Int, byteCount: Int64, currentPath: String)
    case completed(root: FileNode)
    case error(String)
}

struct FileScanner: Sendable {
    let rootPath: String

    func scan() -> AsyncStream<ScanEvent> {
        let path = rootPath
        return AsyncStream { continuation in
            Task.detached {
                await performParallelScan(rootPath: path, continuation: continuation)
            }
        }
    }
}

// Thread-safe shared state for parallel scanning
private final class ScanState: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: State())
    let rootDevice: dev_t

    private struct State {
        var fileCount: Int = 0
        var byteCount: Int64 = 0
        var seenInodes = Set<UInt64>()
    }

    init(rootDevice: dev_t) {
        self.rootDevice = rootDevice
    }

    func addFile(inode: UInt64, size: Int64) -> (isNew: Bool, fileCount: Int, byteCount: Int64) {
        lock.withLock { state in
            // Dedup all inodes — catches hardlinks and firmlink duplicates
            if state.seenInodes.contains(inode) {
                return (false, state.fileCount, state.byteCount)
            }
            state.seenInodes.insert(inode)
            state.fileCount += 1
            state.byteCount += size
            return (true, state.fileCount, state.byteCount)
        }
    }

    func checkNewDirectory(inode: UInt64) -> Bool {
        lock.withLock { state in
            if state.seenInodes.contains(inode) { return false }
            state.seenInodes.insert(inode)
            return true
        }
    }

    func currentCounts() -> (files: Int, bytes: Int64) {
        lock.withLock { ($0.fileCount, $0.byteCount) }
    }
}

private func performParallelScan(rootPath: String, continuation: AsyncStream<ScanEvent>.Continuation) async {
    var rootStat = Darwin.stat()
    guard lstat(rootPath, &rootStat) == 0 else {
        continuation.yield(.error("Failed to stat root directory"))
        continuation.finish()
        return
    }

    let state = ScanState(rootDevice: rootStat.st_dev)

    if let root = await scanDirectory(
        atPath: rootPath,
        name: rootPath,
        state: state,
        continuation: continuation
    ) {
        root.computeAggregates()
        root.sortChildrenBySize()
        let counts = state.currentCounts()
        continuation.yield(.progress(
            fileCount: counts.files,
            byteCount: counts.bytes,
            currentPath: rootPath
        ))
        continuation.yield(.completed(root: root))
    } else {
        continuation.yield(.error("Failed to scan directory"))
    }
    continuation.finish()
}

private func scanDirectory(
    atPath path: String,
    name: String,
    state: ScanState,
    continuation: AsyncStream<ScanEvent>.Continuation
) async -> FileNode? {
    var dirStat = Darwin.stat()
    guard lstat(path, &dirStat) == 0 else { return nil }

    // Skip directories we've already scanned (firmlinks create duplicates)
    guard state.checkNewDirectory(inode: UInt64(dirStat.st_ino)) else { return nil }

    let dirNode = FileNode(
        inode: UInt64(dirStat.st_ino),
        name: name,
        isDirectory: true,
        ownSize: Int64(dirStat.st_size),
        allocatedSize: Int64(dirStat.st_blocks) * 512,
        category: .other,
        modificationDate: Date(timeIntervalSince1970: TimeInterval(dirStat.st_mtimespec.tv_sec))
    )

    guard let dir = opendir(path) else { return dirNode }
    let dirFD = dirfd(dir)

    var fileChildren: [FileNode] = []
    var subdirPaths: [(path: String, name: String)] = []

    while let entry = readdir(dir) {
        // Quick skip . and .. without String conversion
        if entry.pointee.d_name.0 == 0x2E {
            let b2 = entry.pointee.d_name.1
            if b2 == 0 { continue }
            if b2 == 0x2E && entry.pointee.d_name.2 == 0 { continue }
        }

        let d_type = entry.pointee.d_type
        // Skip symlinks, sockets, etc. early via d_type
        if d_type != DT_DIR && d_type != DT_REG && d_type != DT_UNKNOWN { continue }

        // Use fstatat with dir FD — avoids building full path for stat
        var childStat = Darwin.stat()
        var d_name = entry.pointee.d_name
        let statOK = withUnsafeBytes(of: &d_name) { buf in
            fstatat(dirFD, buf.baseAddress!.assumingMemoryBound(to: CChar.self),
                    &childStat, AT_SYMLINK_NOFOLLOW) == 0
        }
        guard statOK else { continue }

        // Skip cross-device entries (equivalent to FTS_XDEV)
        if childStat.st_dev != state.rootDevice { continue }

        let mode = childStat.st_mode & S_IFMT

        let entryName = withUnsafeBytes(of: &d_name) { buf in
            String(cString: buf.baseAddress!.assumingMemoryBound(to: CChar.self))
        }

        if mode == S_IFDIR {
            let childPath = path.last == "/" ? path + entryName : path + "/" + entryName
            subdirPaths.append((childPath, entryName))
        } else if mode == S_IFREG {
            let fileSize = Int64(childStat.st_size)
            let inode = UInt64(childStat.st_ino)
            let result = state.addFile(inode: inode, size: fileSize)
            guard result.isNew else { continue }

            let ext = fastPathExtension(of: entryName)
            let category = FileExtensionMap.category(for: ext)

            fileChildren.append(FileNode(
                inode: inode,
                name: entryName,
                isDirectory: false,
                ownSize: fileSize,
                allocatedSize: Int64(childStat.st_blocks) * 512,
                category: category,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(childStat.st_mtimespec.tv_sec))
            ))

            if result.fileCount % 10000 == 0 {
                continuation.yield(.progress(
                    fileCount: result.fileCount,
                    byteCount: result.byteCount,
                    currentPath: path + "/" + entryName
                ))
            }
        }
    }

    // Close directory before spawning parallel work to limit open FDs
    closedir(dir)

    for file in fileChildren {
        dirNode.addChild(file)
    }

    // Scan subdirectories in parallel using structured concurrency
    if subdirPaths.count == 1 {
        // Single subdir — skip TaskGroup overhead
        if let child = await scanDirectory(
            atPath: subdirPaths[0].path,
            name: subdirPaths[0].name,
            state: state,
            continuation: continuation
        ) {
            dirNode.addChild(child)
        }
    } else if !subdirPaths.isEmpty {
        await withTaskGroup(of: FileNode?.self) { group in
            for subdir in subdirPaths {
                group.addTask {
                    await scanDirectory(
                        atPath: subdir.path,
                        name: subdir.name,
                        state: state,
                        continuation: continuation
                    )
                }
            }
            for await childNode in group {
                if let child = childNode {
                    dirNode.addChild(child)
                }
            }
        }
    }

    return dirNode
}

// Fast extension extraction without NSString bridging
@inline(__always)
private func fastPathExtension(of name: String) -> String {
    guard let dotIndex = name.lastIndex(of: ".") else { return "" }
    let afterDot = name.index(after: dotIndex)
    guard afterDot < name.endIndex else { return "" }
    return String(name[afterDot...])
}
