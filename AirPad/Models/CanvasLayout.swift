import Foundation

struct CanvasLayout: Codable {
    let version: Int
    var updatedAt: Date
    var positions: [String: CanvasPosition]

    enum CodingKeys: String, CodingKey {
        case version, positions
        case updatedAt = "updated_at"
    }
}

struct CanvasPosition: Codable {
    var x: Double
    var y: Double
}
