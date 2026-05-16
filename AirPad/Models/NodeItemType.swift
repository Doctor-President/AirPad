import Foundation

enum NodeItemType: String, Codable, Equatable {
    case text
    case image
    case audio
    case video
    case link
    case document
}

extension NodeItemType {
    /// Stage 3.1a — base display name an entry of this type defaults to before
    /// per-node sequential numbering is applied (`Voice`, `Voice 2`, …). The
    /// user-facing word for `.audio` is `Voice`, matching the existing capture
    /// surface vocabulary (`VoiceCaptureSheet`, `VoiceWaveformPlayer`).
    var defaultDisplayName: String {
        switch self {
        case .text:     return "Text"
        case .image:    return "Image"
        case .audio:    return "Voice"
        case .video:    return "Video"
        case .link:     return "Link"
        case .document: return "Document"
        }
    }
}
