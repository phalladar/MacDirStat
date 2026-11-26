import SwiftUI

struct DetailPanelView: View {
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
                            .truncationMode(.middle)
                    }
                }

                Divider()

                // The size by the chosen metric, the other one under it, then when it changed.
                VStack(alignment: .leading, spacing: 2) {
                    let file = ByteFormatter.string(from: node.totalSize)
                    let allocated = ByteFormatter.string(from: node.totalAllocatedSize)
                    Text(sizeMetric == .allocatedSize ? allocated : file)
                        .font(.system(size: 26, weight: .semibold))
                        .monospacedDigit()
                    Group {
                        Text(sizeMetric == .allocatedSize ? "On disk · \(file) file size" : "File size · \(allocated) on disk")
                        if let date = node.modificationDate {
                            Text("Modified \(date.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if node.isDirectory {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("Contents")
                        row("Files", node.fileCount.formatted())
                        row("Folders", node.directoryCount.formatted())
                        let files = node.children.lazy.filter { !$0.isDirectory }
                        row("Directly inside", "\(files.count.formatted()) · \(ByteFormatter.string(from: files.reduce(0) { $0 + $1.size(for: sizeMetric) }))")
                        if node.cloudOnlyFileCount > 0 {
                            row("Cloud-only", node.cloudOnlyFileCount.formatted())
                        }
                    }
                } else if node.cloudOnlyFileCount > 0 {
                    row("Cloud-only files", node.cloudOnlyFileCount.formatted())
                }

                if node.isDataless {
                    Label("Cloud-only: contents are not stored locally", systemImage: "icloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let issue = node.scanIssue {
                    Text(issue.message).font(.caption).foregroundStyle(.orange)
                }
                if node.unscannedDirectoryCount > 0 || node.totalUnavailableEntryCount > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Incomplete scan", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("\(node.unscannedDirectoryCount.formatted()) folders and \(node.totalUnavailableEntryCount.formatted()) entries could not be fully scanned. Sizes leave them out; the banner above the treemap lists them by cause.")
                            .font(.caption)
                    }
                }

                if node.isDirectory {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("Category Breakdown")

                        let breakdown = node.categoryBreakdown(metric: sizeMetric)
                        let total = max(1, breakdown.reduce(0) { $0 + $1.size })

                        // Bar chart
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
                        .padding(.bottom, 2)

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
                                    .monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }

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

    /// Small and secondary, as in Finder's Get Info and Xcode's inspectors.
    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    /// A label in secondary and its value at the trailing edge.
    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}
