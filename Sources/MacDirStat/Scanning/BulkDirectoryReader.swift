import Foundation

enum DirectoryEnumerationMode: Sendable {
    case automatic
    case posix
}

struct BulkDirectoryEntry {
    let name: String
    let metadata: Darwin.stat
}

enum BulkDirectoryBatch {
    case entries([BulkDirectoryEntry], unavailable: Int)
    case end
    case unsupported
    case failure(Int32)
}

struct BulkDirectoryReader {
    // Most folders have few entries. Avoid a large zeroed allocation per folder;
    // dense directories are read in multiple batches from the same descriptor.
    private var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    private var attributes: attrlist
    private var started = false

    init() {
        attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        let common: [UInt32] = [UInt32(ATTR_CMN_RETURNED_ATTRS), UInt32(ATTR_CMN_ERROR), UInt32(ATTR_CMN_NAME),
                                UInt32(ATTR_CMN_DEVID), UInt32(ATTR_CMN_OBJTYPE), UInt32(ATTR_CMN_MODTIME),
                                UInt32(ATTR_CMN_FLAGS), UInt32(ATTR_CMN_FILEID)]
        attributes.commonattr = common.reduce(0, |)
        attributes.fileattr = UInt32(ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH)
    }

    mutating func next(fd: Int32) throws -> BulkDirectoryBatch {
        let count = buffer.withUnsafeMutableBytes {
            getattrlistbulk(fd, &attributes, $0.baseAddress!, $0.count,
                            UInt64(FSOPT_PACK_INVAL_ATTRS | FSOPT_RETURN_REALDEV))
        }
        if count < 0 {
            let code = errno
            if !started && (code == ENOTSUP || code == ENOSYS || code == EINVAL) {
                return .unsupported
            }
            return .failure(code)
        }
        started = true
        if count == 0 { return .end }
        return try buffer.withUnsafeBytes { bytes in
            var offset = 0
            var entries: [BulkDirectoryEntry] = []
            entries.reserveCapacity(Int(count))
            var unavailable = 0
            for _ in 0..<count {
                try Task.checkCancellation()
                guard offset + 4 <= bytes.count else { throw BulkMetadataError.malformed }
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                guard length >= 4, length <= bytes.count - offset else { throw BulkMetadataError.malformed }
                let record = UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + length)])
                if let entry = try decodeBulkDirectoryEntry(record, fd: fd) {
                    entries.append(entry)
                } else {
                    unavailable += 1
                }
                offset += length
            }
            return .entries(entries, unavailable: unavailable)
        }
    }
}

enum BulkMetadataError: Error {
    case malformed
}

// getattrlist buffers pack fields on four-byte boundaries, including 64-bit
// integers and timespec. Swift struct layout cannot safely describe this ABI.
func decodeBulkDirectoryEntry(_ record: UnsafeRawBufferPointer, fd: Int32) throws -> BulkDirectoryEntry? {
    var offset = 4
    func read<T>(_ type: T.Type) throws -> T {
        guard offset <= record.count - MemoryLayout<T>.size else { throw BulkMetadataError.malformed }
        defer { offset += MemoryLayout<T>.size }
        return record.loadUnaligned(fromByteOffset: offset, as: type)
    }
    let returned = try read(attribute_set_t.self)
    let error = try read(UInt32.self)
    let nameOffset = offset
    let nameReference = try read(attrreference_t.self)
    guard returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 else { return nil }
    let start = nameOffset + Int(nameReference.attr_dataoffset)
    let length = Int(nameReference.attr_length)
    guard start >= offset, length > 0, start <= record.count,
          length <= record.count - start, record[start + length - 1] == 0 else {
        throw BulkMetadataError.malformed
    }
    let name = record.baseAddress!.advanced(by: start).assumingMemoryBound(to: CChar.self)
    // Failed entries may contain only an error and name. Never read placeholder
    // fields as valid metadata, or report inaccessible bytes as a zero-sized file.
    if error != 0 { return nil }
    let device = try read(dev_t.self)
    let objectType = try read(fsobj_type_t.self)
    let modified = try read(timespec.self)
    let flags = try read(UInt32.self)
    let inode = try read(UInt64.self)
    guard start >= offset else { throw BulkMetadataError.malformed }
    var metadata = Darwin.stat()
    let requiredFields: [UInt32] = [UInt32(ATTR_CMN_DEVID), UInt32(ATTR_CMN_OBJTYPE), UInt32(ATTR_CMN_MODTIME),
                                    UInt32(ATTR_CMN_FLAGS), UInt32(ATTR_CMN_FILEID)]
    let required = requiredFields.reduce(0, |)
    let fileRequired = UInt32(ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH)
    if objectType == VREG.rawValue,
       returned.commonattr & required == required,
       returned.fileattr & fileRequired == fileRequired {
        let allocated = try read(off_t.self)
        let logical = try read(off_t.self)
        guard start >= offset, allocated >= 0, allocated % 512 == 0, logical >= 0 else {
            throw BulkMetadataError.malformed
        }
        metadata.st_mode = mode_t(S_IFREG)
        metadata.st_dev = device
        metadata.st_ino = ino_t(inode)
        metadata.st_mtimespec = modified
        metadata.st_flags = flags
        metadata.st_blocks = allocated / 512
        metadata.st_size = logical
    } else {
        // Directory attributes describe the underlying mount/firmlink, not its
        // target. fstatat preserves stat's volume, inode and directory-size rules.
        guard fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
    }
    return BulkDirectoryEntry(name: String(cString: name), metadata: metadata)
}
