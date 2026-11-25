import SwiftUI

/// Folder outline in the sidebar. Expansion lives in AppState, not in OutlineGroup, so a
/// selection made in the treemap can expand the outline down to its folder and scroll to it.
struct DirectoryTreeView: View {
    let onRescan: (FileNode) -> Void
    let onTrash: (FileNode) -> Void
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: selection) {
                if let root = appState.rootNode {
                    DirectoryChildren(parent: root)
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: UInt64.self) { ids in
                Group {
                    if let node = ids.first.flatMap(appState.visibleDirectory(id:)) {
                        Button("Reveal in Finder", systemImage: "arrow.right.circle") { FileActions.revealInFinder(node) }
                        Button("Copy Path", systemImage: "doc.on.doc") { FileActions.copyPath(node) }
                        Divider()
                        Button("Show in Treemap", systemImage: "square.grid.2x2") { appState.drillDown(to: node) }
                        Divider()
                        Button("Rescan Folder", systemImage: "arrow.clockwise") { onRescan(node) }
                            .disabled(appState.busyID != nil)
                        MoveToTrashButton(node: node, isBusy: appState.busyID != nil, action: onTrash)
                    }
                }
                .labelStyle(.titleAndIcon) // macOS menus show only titles without it
            } primaryAction: { ids in
                if let node = ids.first.flatMap(appState.visibleDirectory(id:)) {
                    appState.drillDown(to: node)
                }
            }
            .onChange(of: appState.selectedDirectory?.id) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id) }
            }
        }
    }

    private var selection: Binding<UInt64?> {
        Binding(
            get: { appState.selectedDirectory?.id },
            set: { id in
                guard let id, let node = appState.visibleDirectory(id: id) else { return }
                appState.selectFromTree(node)
            }
        )
    }
}

private struct DirectoryChildren: View {
    let parent: FileNode
    @Environment(AppState.self) private var appState

    var body: some View {
        let metric = appState.sizeMetric
        // Folders change in place, so the version is what tells SwiftUI a row changed.
        let version = appState.treeVersion
        // The scanner already sorts children by allocated size.
        let folders = metric == .allocatedSize
            ? parent.directoryChildren
            : parent.directoryChildren.sorted { $0.size(for: metric) > $1.size(for: metric) }
        ForEach(folders) { folder in
            let row = DirectoryRow(node: folder, sizeMetric: metric, treeVersion: version,
                                   isBusy: appState.busyID == folder.id)
            if folder.directoryCount > 1 {
                DisclosureGroup(isExpanded: Binding(
                    get: { appState.expandedIDs.contains(folder.id) },
                    set: { appState.setExpanded(folder, $0) }
                )) {
                    DirectoryChildren(parent: folder)
                } label: {
                    row
                }
            } else {
                row
            }
        }
    }
}

struct DirectoryRow: View {
    let node: FileNode
    let sizeMetric: SizeMetric
    let treeVersion: Int
    let isBusy: Bool

    private var fractionOfParent: Double {
        let parentSize = node.parent?.size(for: sizeMetric) ?? 0
        return parentSize > 0 ? Double(node.size(for: sizeMetric)) / Double(parentSize) : 0
    }

    var body: some View {
        HStack(spacing: 6) {
            if let issue = node.scanIssue {
                Image(systemName: "folder.badge.questionmark")
                    .foregroundStyle(.orange)
                    .font(.system(size: 13))
                    .help(issue.message)
            } else {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
            }

            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            // Marks the path down to skipped folders so they can be found by expanding.
            if node.scanIssue == nil, node.unscannedDirectoryCount > 0 || node.totalUnavailableEntryCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("Contains folders or items that couldn't be read")
            }

            Spacer()

            if isBusy {
                ProgressView().controlSize(.mini).frame(width: 44)
            } else {
                SizeSparkline(segments: node.categoryBreakdown(metric: sizeMetric), fractionOfParent: fractionOfParent)
            }

            Text(ByteFormatter.string(from: node.size(for: sizeMetric)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }
}
