import Foundation

enum ByteFormatter {
    nonisolated(unsafe) private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func string(from bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }

    static func string(from bytes: UInt64) -> String {
        formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}
