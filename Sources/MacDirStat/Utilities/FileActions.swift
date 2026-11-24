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
        let path = node.path
        // The path may now hold a different item than the one scanned.
        var metadata = Darwin.stat()
        guard lstat(path, &metadata) == 0, UInt64(metadata.st_ino) == node.id else {
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
