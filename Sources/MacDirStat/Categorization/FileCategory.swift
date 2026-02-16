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

    var color: Color {
        switch self {
        case .documents: Color(red: 0.35, green: 0.60, blue: 0.95)
        case .images: Color(red: 0.55, green: 0.85, blue: 0.40)
        case .video: Color(red: 0.95, green: 0.45, blue: 0.35)
        case .audio: Color(red: 0.95, green: 0.70, blue: 0.25)
        case .code: Color(red: 0.65, green: 0.45, blue: 0.95)
        case .archives: Color(red: 0.45, green: 0.80, blue: 0.80)
        case .applications: Color(red: 0.95, green: 0.50, blue: 0.70)
        case .system: Color(red: 0.60, green: 0.60, blue: 0.65)
        case .caches: Color(red: 0.75, green: 0.55, blue: 0.40)
        case .other: Color(red: 0.50, green: 0.50, blue: 0.55)
        }
    }

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
