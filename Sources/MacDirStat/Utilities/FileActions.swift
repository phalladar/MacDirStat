import AppKit

@MainActor
enum FileActions {
    static func revealInFinder(_ node: FileNode) {
        NSWorkspace.shared.selectFile(node.path, inFileViewerRootedAtPath: "")
    }

    static func confirmMoveToTrash(_ node: FileNode, sizeMetric: SizeMetric) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move “\(node.name)” to the Trash?"
        alert.informativeText = "\(ByteFormatter.string(from: node.size(for: sizeMetric))) at \(node.path)"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func moveToTrash(_ node: FileNode) async -> Bool {
        // The menus already disable this; don't rely on them alone.
        guard !node.hasCloudOnlyContent, !node.hasUnscannedFolders else { return false }
        let path = node.path
        // The path may now hold a different item than the one scanned.
        var metadata = Darwin.stat()
        let found = try? withoutDatalessMaterialization { lstat(path, &metadata) == 0 }
        // Fresh flags too: the item may have been evicted to iCloud since the scan.
        guard found == true, UInt64(metadata.st_ino) == node.id,
              metadata.st_flags & UInt32(SF_DATALESS) == 0 else {
            showError("“\(node.name)” changed since the scan", "Rescan its folder and try again.")
            return false
        }
        do {
            _ = try await NSWorkspace.shared.recycle([URL(fileURLWithPath: path)])
            return true
        } catch {
            showError("Couldn't move “\(node.name)” to the Trash", error.localizedDescription)
            return false
        }
    }

    /// True only when the path is known to be gone, not when it just can't be read.
    static func itemIsGone(_ path: String) -> Bool {
        var metadata = Darwin.stat()
        // Read errno inside: restoring the I/O policy afterwards may change it.
        let gone = try? withoutDatalessMaterialization { lstat(path, &metadata) == -1 && errno == ENOENT }
        return gone == true
    }

    static func showError(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    static func copyPath(_ node: FileNode) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(node.path, forType: .string)
    }
}
