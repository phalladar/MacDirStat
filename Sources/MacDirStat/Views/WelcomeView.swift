import SwiftUI

struct VolumeInfo: Identifiable {
    let id: URL
    let url: URL
    let name: String
    let icon: NSImage
    let totalBytes: Int64
    let availableBytes: Int64

    var usedBytes: Int64 { totalBytes - availableBytes }
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
}

struct WelcomeView: View {
    /// Name of the scanned folder still loaded, which offers a way back to its treemap.
    var returnName: String?
    var onReturn: () -> Void = {}
    let onVolumeSelected: (String) -> Void

    @State private var volumes: [VolumeInfo] = []
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted
    @State private var isAccessBannerDismissed = false

    var body: some View {
        VStack(spacing: 32) {
            if !hasFullDiskAccess && !isAccessBannerDismissed {
                FullDiskAccessBanner(onDismiss: { isAccessBannerDismissed = true })
                    .padding(.horizontal, 40)
            }

            // Header
            VStack(spacing: 12) {
                Image(systemName: "chart.bar.doc.horizontal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)

                Text("MacDirStat")
                    .font(.largeTitle.bold())

                Text("Select a drive to visualize disk usage")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            // Volume grid
            if volumes.isEmpty {
                ProgressView("Loading volumes...")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 16)], spacing: 16) {
                    ForEach(volumes) { volume in
                        VolumeCard(volume: volume) {
                            onVolumeSelected(volume.url.path(percentEncoded: false))
                        }
                    }
                }
                .padding(.horizontal, 40)
            }

            if let returnName {
                Button(action: onReturn) {
                    Label("Back to \(returnName)", systemImage: "chevron.left")
                }
                .buttonStyle(.borderedProminent)
            }

            // Custom folder option
            Button(action: selectCustomFolder) {
                Label("Choose a Custom Folder...", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.vertical, 48)
        // Zero minimums keep the content's size out of the window's size limits. Otherwise, with
        // the macOS 26+ SDK, the wrapping banner text feeds back into the window's constraints
        // and AppKit aborts the launch after too many layout passes.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(.regularMaterial)
        .onAppear { loadVolumes() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-check when the user returns from System Settings
            hasFullDiskAccess = FullDiskAccess.isGranted
        }
    }

    private func loadVolumes() {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .effectiveIconKey,
            .volumeIsInternalKey,
            .volumeIsBrowsableKey
        ]

        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return }

        volumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let name = values.volumeName,
                  let total = values.volumeTotalCapacity,
                  let available = values.volumeAvailableCapacity
            else { return nil }

            let icon = (values.effectiveIcon as? NSImage) ?? NSImage(systemSymbolName: "internaldrive.fill", accessibilityDescription: nil)!

            return VolumeInfo(
                id: url,
                url: url,
                name: name,
                icon: icon,
                totalBytes: Int64(total),
                availableBytes: Int64(available)
            )
        }
    }

    private func selectCustomFolder() {
        if let path = FolderPicker.chooseFolder() {
            onVolumeSelected(path)
        }
    }
}

// MARK: - Full Disk Access Banner

struct FullDiskAccessBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text("Full Disk Access is off")
                    .font(.headline)
                Text("Without it, protected folders such as Mail, Messages and other apps' data are skipped and sizes will be under-reported. Enable MacDirStat in System Settings, then relaunch the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                Button("Open System Settings") { FullDiskAccess.openSystemSettings() }
                    .buttonStyle(.borderedProminent)
                HStack(spacing: 6) {
                    if isRunningFromAppBundle {
                        Button("Relaunch") { relaunch() }
                    }
                    Button("Not Now", action: onDismiss)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        )
    }

    /// `swift run` launches a bare executable, which can't be relaunched via NSWorkspace.
    private var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Full Disk Access only takes effect for a fresh process, so reopen the bundle and quit.
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

// MARK: - Volume Card

struct VolumeCard: View {
    let volume: VolumeInfo
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(nsImage: volume.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(volume.name)
                            .font(.headline)
                            .lineLimit(1)

                        Text("\(ByteFormatter.string(from: volume.availableBytes)) available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Usage bar
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.quaternary)

                            Capsule()
                                .fill(usageColor)
                                .frame(width: geo.size.width * volume.usedFraction)
                        }
                    }
                    .frame(height: 8)

                    HStack {
                        Text("\(ByteFormatter.string(from: volume.usedBytes)) used")
                        Spacer()
                        Text("of \(ByteFormatter.string(from: volume.totalBytes))")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovering ? .white.opacity(0.08) : .white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(isHovering ? 0.2 : 0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private var usageColor: Color {
        if volume.usedFraction > 0.9 { return .red }
        if volume.usedFraction > 0.75 { return .orange }
        return .blue
    }
}
