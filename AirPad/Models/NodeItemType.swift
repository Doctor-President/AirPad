import Foundation

enum NodeItemType: String, Codable, Equatable {
    case text
    case image
    case audio
    case video
    case link
    case document
}
