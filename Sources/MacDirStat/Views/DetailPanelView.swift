import SwiftUI

struct DetailPanelView: View {
    @Environment(AppState.self) private var appState
    let node: FileNode
    let sizeMetric: SizeMetric
    /// Totals change in place (see AppState.replace); a new value redraws the panel.
    let treeVersion: Int

    var body: some View {
        // A List, not a ScrollView: on macOS 27, binaries that record SDK 15 (local SwiftPM builds)
        // ignore clicks on ScrollView content in the inspector. SDK 26 builds (CI) work either way.
        List {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 10) {
                    Image(systemName: node.isDirectory ? "folder.fill" : node.category.sfSymbol)
                        .font(.title2)
                        .foregroundStyle(node.category.color)

                    VStack(alignment: .leading) {
                        Text(node.name)
                            .font(.headline)
                            .lineLimit(2)
                        Text(node.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                Divider()

                // Size info
                LabeledContent("File Size", value: ByteFormatter.string(from: node.totalSize))
                LabeledContent("Allocated", value: ByteFormatter.string(from: node.totalAllocatedSize))

                if node.isDirectory {
                    LabeledContent("Files", value: "\(node.fileCount.formatted())")
                    let files = node.children.lazy.filter { !$0.isDirectory }
                    LabeledContent("Files directly inside", value: "\(files.count.formatted()) · \(ByteFormatter.string(from: files.reduce(0) { $0 + $1.size(for: sizeMetric) }))")
                    LabeledContent("Directories", value: "\(node.directoryCount.formatted())")
                }

                if node.isDataless {
                    Label("Cloud-only: contents are not stored locally", systemImage: "icloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if node.cloudOnlyFileCount > 0 {
                    LabeledContent("Cloud-only files", value: node.cloudOnlyFileCount.formatted())
                }
                if let issue = node.scanIssue {
                    Text(issue.message).font(.caption).foregroundStyle(.orange)
                }
                if node.unscannedDirectoryCount > 0 || node.totalUnavailableEntryCount > 0 {
                    Label("Incomplete scan", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    if appState.isIncompleteBannerDismissed {
                        Button("Show Banner") { appState.showIncompleteBannerAgain() }
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
                    Text("\(node.unscannedDirectoryCount.formatted()) folders and \(node.totalUnavailableEntryCount.formatted()) entries could not be fully scanned. Sizes leave them out; the banner above the treemap lists them by cause.")
                        .font(.caption)
                }

                if let date = node.modificationDate {
                    LabeledContent("Modified", value: date.formatted(date: .abbreviated, time: .shortened))
                }

                if node.isDirectory {
                    Divider()

                    // Category breakdown
                    Text("Category Breakdown")
                        .font(.headline)

                    let breakdown = node.categoryBreakdown(metric: sizeMetric)
                    let total = max(1, breakdown.reduce(0) { $0 + $1.size })

                    // Bar chart
                    VStack(spacing: 2) {
                        GeometryReader { geo in
                            HStack(spacing: 1) {
                                ForEach(breakdown, id: \.category) { item in
                                    let fraction = CGFloat(item.size) / CGFloat(total)
                                    if fraction > 0.005 {
                                        Rectangle()
                                            .fill(item.category.color)
                                            .frame(width: geo.size.width * fraction)
                                    }
                                }
                            }
                        }
                        .frame(height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    // Legend
                    ForEach(breakdown, id: \.category) { item in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(item.category.color)
                                .frame(width: 10, height: 10)
                            Image(systemName: item.category.sfSymbol)
                                .frame(width: 16)
                                .foregroundStyle(.secondary)
                            Text(item.category.displayName)
                            Spacer()
                            Text(ByteFormatter.string(from: item.size))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }

                Divider()

                // Actions
                Button {
                    FileActions.revealInFinder(node)
                } label: {
                    Label("Reveal in Finder", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.bordered)

                Button {
                    FileActions.copyPath(node)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8) // With the List's own 8 pt inset, keeps the 16 pt side margins.
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}
