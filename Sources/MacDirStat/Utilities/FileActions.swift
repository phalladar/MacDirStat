import AppKit

@MainActor
enum FileActions {
    static func revealInFinder(_ node: FileNode) {
        NSWorkspace.shared.selectFile(node.path, inFileViewerRootedAtPath: "")
    }

    static func copyPath(_ node: FileNode) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(node.path, forType: .string)
    }
}
