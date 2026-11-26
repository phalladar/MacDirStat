import SwiftUI

enum FileCategory: String, CaseIterable, Sendable, Identifiable {
    case documents
    case images
    case video
    case audio
    case code
    case archives
    case applications
    case system
    case caches
    case other

    var id: String { rawValue }

    var index: Int { Self.allCases.firstIndex(of: self)! }

    var displayName: String {
        switch self {
        case .documents: "Documents"
        case .images: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .code: "Code"
        case .archives: "Archives"
        case .applications: "Applications"
        case .system: "System"
        case .caches: "Caches"
        case .other: "Other"
        }
    }

    /// System colors, so they follow light, dark and Increase Contrast.
    var color: Color {
        switch self {
        case .documents: .blue
        case .images: .green
        case .video: .red
        case .audio: .orange
        case .code: .purple
        case .archives: .teal
        case .applications: .pink
        case .system: .gray
        case .caches: .brown
        case .other: Self.otherGray
        }
    }

    /// A gray apart from System's: darker in dark mode, lighter in light mode.
    private static let otherGray = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.39, green: 0.39, blue: 0.40, alpha: 1)
            : NSColor(srgbRed: 0.68, green: 0.68, blue: 0.70, alpha: 1)
    })

    var sfSymbol: String {
        switch self {
        case .documents: "doc.text.fill"
        case .images: "photo.fill"
        case .video: "film.fill"
        case .audio: "waveform"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .archives: "archivebox.fill"
        case .applications: "app.fill"
        case .system: "gearshape.fill"
        case .caches: "cylinder.fill"
        case .other: "questionmark.folder.fill"
        }
    }
}
