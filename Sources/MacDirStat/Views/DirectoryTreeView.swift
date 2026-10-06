import SwiftUI

struct DirectoryTreeView: View {
    let root: FileNode
    @Binding var selectedNode: FileNode?
    let sizeMetric: SizeMetric

    var body: some View {
        List(selection: Binding(
            get: { selectedNode?.id },
            set: { id in
                if let id {
                    selectedNode = findNode(id: id, in: root)
                }
            }
        )) {
            OutlineGroup(DirectoryTreeEntry(node: root, metric: sizeMetric).children ?? [],
                         children: \.children) { entry in
                DirectoryRow(node: entry.node, sizeMetric: sizeMetric)
            }
        }
        .listStyle(.sidebar)
    }

    private func findNode(id: UInt64, in node: FileNode) -> FileNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = findNode(id: id, in: child) {
                return found
            }
        }
        return nil
    }
}

struct DirectoryRow: View {
    let node: FileNode
    let sizeMetric: SizeMetric

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.scanIssue != nil ? "folder.badge.questionmark" : "folder.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))

            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(ByteFormatter.string(from: node.size(for: sizeMetric)))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct DirectoryTreeEntry: Identifiable {
    let node: FileNode
    let metric: SizeMetric
    var id: UInt64 { node.id }

    var children: [DirectoryTreeEntry]? {
        let directories = node.directoryChildren.sorted { $0.size(for: metric) > $1.size(for: metric) }
        return directories.isEmpty ? nil : directories.map { DirectoryTreeEntry(node: $0, metric: metric) }
    }
}
