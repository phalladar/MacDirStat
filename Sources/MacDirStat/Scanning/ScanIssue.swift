import Darwin

/// Why a folder's contents were not scanned. The kind decides what the user can do about it.
enum ScanIssue: Sendable, Equatable {
    /// EPERM: macOS privacy protection (TCC) or System Integrity Protection refused access.
    case privacyProtected
    /// EACCES: Unix permissions; the folder belongs to another user or to the system.
    case permissionDenied
    /// A cloud-only (dataless) folder; listing it would download it.
    case cloudOnly
    /// The folder was replaced or moved while the scan ran.
    case changedDuringScan
    case other(errno: Int32)

    init(errno code: Int32) {
        switch code {
        case EPERM: self = .privacyProtected
        case EACCES: self = .permissionDenied
        case EDEADLK: self = .cloudOnly // File Provider refuses to enumerate without a download.
        default: self = .other(errno: code)
        }
    }

    var kind: Kind {
        switch self {
        case .privacyProtected: .privacyProtected
        case .permissionDenied: .permissionDenied
        case .cloudOnly: .cloudOnly
        case .changedDuringScan: .changedDuringScan
        case .other: .other
        }
    }

    var message: String {
        switch self {
        case .privacyProtected:
            "macOS privacy protection blocked this folder. Grant Full Disk Access to scan it; some system folders stay protected even then."
        case .permissionDenied:
            "No permission to read this folder; it belongs to another user or to the system."
        case .cloudOnly:
            "Cloud-only folder: contents were not downloaded or scanned."
        case .changedDuringScan:
            "Folder changed during the scan; rescan to measure its contents."
        case .other(let code):
            "Folder contents could not be scanned: \(String(cString: strerror(code)))."
        }
    }

    enum Kind: Int, CaseIterable, Sendable {
        case privacyProtected, permissionDenied, cloudOnly, changedDuringScan, other

        /// Short label for a count of skipped folders of this kind.
        func summary(count: Int) -> String {
            let folders = count == 1 ? "1 folder" : "\(count.formatted()) folders"
            return switch self {
            case .privacyProtected: "\(folders) blocked by macOS privacy protection"
            case .permissionDenied: "\(folders) owned by another user or the system"
            case .cloudOnly: "\(folders) cloud-only, not downloaded"
            case .changedDuringScan: "\(folders) changed during the scan"
            case .other: "\(folders) with other read errors"
            }
        }

        var shortLabel: String {
            switch self {
            case .privacyProtected: "Privacy protected"
            case .permissionDenied: "No permission"
            case .cloudOnly: "Cloud-only"
            case .changedDuringScan: "Changed during scan"
            case .other: "Read error"
            }
        }
    }
}
