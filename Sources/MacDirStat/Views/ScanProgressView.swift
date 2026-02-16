import SwiftUI

struct ScanProgressView: View {
    let fileCount: Int
    let byteCount: Int64
    let currentPath: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .padding(.bottom, 8)

            Text("Scanning...")
                .font(.title2.bold())

            VStack(spacing: 8) {
                HStack(spacing: 24) {
                    Label {
                        Text("\(fileCount.formatted()) files")
                    } icon: {
                        Image(systemName: "doc.fill")
                    }

                    Label {
                        Text(ByteFormatter.string(from: byteCount))
                    } icon: {
                        Image(systemName: "internaldrive.fill")
                    }
                }
                .font(.title3)

                Text(currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 400)
            }

            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
