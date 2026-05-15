import Foundation

/// Minimal mirrors of the AirPad node JSON shape — only the fields needed to
/// reproduce production `extractContent` and to log per-node diagnostic data.
struct NodeItem: Decodable {
    let id: String
    let type: String
    let content: String?
    let transcript: String?
    let description: String?
    let title: String?
    let preview: String?
    let url: String?
}

struct Node: Decodable {
    let id: String
    let title: String?
    let tags: [String]?
    let items: [NodeItem]
}

/// Mirrors `AIService.extractContent` exactly — text → content, audio/video
/// → transcript, image/document → description, link → title + preview joined.
/// Empty per-item strings filtered, then joined with newline.
func extractContent(from node: Node) -> String {
    node.items.compactMap { item -> String? in
        switch item.type {
        case "text":              return item.content
        case "audio", "video":    return item.transcript
        case "image", "document": return item.description
        case "link":              return [item.title, item.preview].compactMap { $0 }.joined(separator: " ")
        default:                  return nil
        }
    }.filter { !$0.isEmpty }.joined(separator: "\n")
}
