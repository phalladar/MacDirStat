import SwiftUI

/// Explains why a scan is incomplete, broken down by cause, with the action each cause needs.
struct IncompleteScanBanner: View {
    @Environment(AppState.self) private var appState
    let root: FileNode
    let onRescan: () -> Void
    @State private var showFolders = false
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted

    var body: some View {
        let counts = kindCounts
        let entries = root.totalUnavailableEntryCount

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text("Some folders couldn't be read, so the sizes shown leave them out.")
                    .font(.callout.weight(.medium))
                Text(summary(counts: counts, entries: entries))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(hints(counts: counts), id: \.self) { hint in
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // Zero minimum and ideal widths: long text must wrap, never widen the detail
            // column and squeeze the sidebar and inspector out of the split view.
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if counts[.privacyProtected, default: 0] > 0, !hasFullDiskAccess {
                    Button("Grant Full Disk Access…") { FullDiskAccess.openSystemSettings() }
                }
                if counts[.changedDuringScan, default: 0] > 0 {
                    Button("Rescan", action: onRescan)
                }
                Button("List Skipped Folders…") { showFolders.toggle() }
                    .popover(isPresented: $showFolders, arrowEdge: .bottom) {
                        SkippedFoldersList(root: root, folders: appState.skippedFolders)
                    }
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFullDiskAccess = FullDiskAccess.isGranted
        }
    }

    private var kindCounts: [ScanIssue.Kind: Int] {
        var counts: [ScanIssue.Kind: Int] = [:]
        for folder in appState.skippedFolders {
            if let kind = folder.scanIssue?.kind { counts[kind, default: 0] += 1 }
        }
        return counts
    }

    private func summary(counts: [ScanIssue.Kind: Int], entries: Int) -> String {
        var parts = ScanIssue.Kind.allCases.compactMap { kind in
            counts[kind].map { kind.summary(count: $0) }
        }
        if entries > 0 {
            parts.append(entries == 1 ? "1 item unreadable" : "\(entries.formatted()) items unreadable")
        }
        return parts.joined(separator: " · ")
    }

    private func hints(counts: [ScanIssue.Kind: Int]) -> [String] {
        var hints: [String] = []
        if counts[.privacyProtected, default: 0] > 0 {
            hints.append(hasFullDiskAccess
                ? "Full Disk Access is on, so the privacy-protected folders are ones macOS hides from every app. Nothing needs fixing."
                : "To include privacy-protected folders, turn on Full Disk Access for MacDirStat, relaunch it, and scan again.")
        }
        if counts[.permissionDenied, default: 0] > 0 {
            hints.append("Folders owned by another user or the system are readable only by that account; this is normal when scanning a whole disk.")
        }
        if counts[.cloudOnly, default: 0] > 0 {
            hints.append("Cloud-only folders take no local space. Download them in Finder to measure them.")
        }
        return hints
    }
}

/// Lists skipped folders by cause. Clicking a row selects the folder in the sidebar and treemap.
private struct SkippedFoldersList: View {
    @Environment(AppState.self) private var appState
    let root: FileNode
    let folders: [FileNode]

    /// Rows per section; a whole-disk scan can skip thousands of folders.
    private let sectionLimit = 500

    var body: some View {
        let sections = groupedSections
        List {
            ForEach(sections, id: \.title) { section in
                Section {
                    ForEach(section.folders.prefix(sectionLimit)) { folder in
                        row(folder, detail: section.detail(folder))
                    }
                    if section.folders.count > sectionLimit {
                        Text("\((section.folders.count - sectionLimit).formatted()) more not shown")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("\(section.title) (\(section.folders.count.formatted()))")
                } footer: {
                    if let note = section.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: 460, height: 380)
    }

    private func row(_ folder: FileNode, detail: String?) -> some View {
        Button {
            appState.selectFromTree(folder)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(relativePath(folder))
                    .lineLimit(1)
                    .truncationMode(.head)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(folder.path)
        .contextMenu {
            Button("Reveal in Finder") { FileActions.revealInFinder(folder) }
            Button("Copy Path") { FileActions.copyPath(folder) }
        }
    }

    private func relativePath(_ folder: FileNode) -> String {
        if folder === root { return folder.path }
        let rootPath = root.path
        let path = folder.path
        guard path.hasPrefix(rootPath) else { return path }
        let rest = path.dropFirst(rootPath.count).drop { $0 == "/" }
        return rest.isEmpty ? path : String(rest)
    }

    private struct SectionData {
        let title: String
        let note: String?
        let folders: [FileNode]
        let detail: (FileNode) -> String?
    }

    private var groupedSections: [SectionData] {
        var byKind: [ScanIssue.Kind: [FileNode]] = [:]
        var partial: [FileNode] = []
        for folder in folders {
            if let kind = folder.scanIssue?.kind {
                byKind[kind, default: []].append(folder)
            } else {
                partial.append(folder)
            }
        }
        var sections = ScanIssue.Kind.allCases.compactMap { kind -> SectionData? in
            guard let folders = byKind[kind] else { return nil }
            return SectionData(
                title: kind.shortLabel,
                note: kind == .other ? nil : folders.first?.scanIssue?.message,
                folders: folders,
                detail: { folder in
                    if case .other = folder.scanIssue { return folder.scanIssue?.message }
                    return nil
                }
            )
        }
        if !partial.isEmpty {
            sections.append(SectionData(
                title: "Some items unreadable",
                note: "These folders were listed, but some items inside could not be measured.",
                folders: partial,
                detail: { folder in
                    let count = folder.unavailableEntryCount
                    return count == 1 ? "1 item" : "\(count.formatted()) items"
                }
            ))
        }
        return sections
    }
}
