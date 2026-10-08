import SwiftUI

enum ClipKind: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case text
    case richText
    case link
    case image
    case file
    case color

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich Text"
        case .link: "Link"
        case .image: "Image"
        case .file: "File"
        case .color: "Color"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "doc.richtext"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        }
    }

    var tint: Color {
        switch self {
        case .text: Color(red: 0.33, green: 0.53, blue: 0.94)
        case .richText: Color(red: 0.56, green: 0.42, blue: 0.94)
        case .link: Color(red: 0.12, green: 0.66, blue: 0.52)
        case .image: Color(red: 0.93, green: 0.55, blue: 0.17)
        case .file: Color(red: 0.86, green: 0.35, blue: 0.39)
        case .color: Color(red: 0.43, green: 0.66, blue: 0.22)
        }
    }
}
