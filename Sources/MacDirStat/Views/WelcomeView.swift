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
    let onVolumeSelected: (String) -> Void

    @State private var volumes: [VolumeInfo] = []

    var body: some View {
        VStack(spacing: 32) {
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

            // Custom folder option
            Button(action: selectCustomFolder) {
                Label("Choose a Custom Folder...", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .onAppear { loadVolumes() }
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
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to scan"
        panel.prompt = "Scan"

        if panel.runModal() == .OK, let url = panel.url {
            onVolumeSelected(url.path(percentEncoded: false))
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
