import Foundation

struct CanvasObject: Identifiable, Codable {
    let id: UUID
    var position: CGPoint
    var size: CGSize
    var htmlContent: String
    /// The widget ID from the backend session, used to sync deletions.
    var backendWidgetID: String?

    private enum CodingKeys: String, CodingKey {
        case id, posX, posY, width, height, htmlContent, backendWidgetID
    }

    init(id: UUID = UUID(), position: CGPoint, size: CGSize, htmlContent: String, backendWidgetID: String? = nil) {
        self.id = id
        self.position = position
        self.size = size
        self.htmlContent = htmlContent
        self.backendWidgetID = backendWidgetID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let x = try c.decode(CGFloat.self, forKey: .posX)
        let y = try c.decode(CGFloat.self, forKey: .posY)
        position = CGPoint(x: x, y: y)
        let w = try c.decode(CGFloat.self, forKey: .width)
        let h = try c.decode(CGFloat.self, forKey: .height)
        size = CGSize(width: w, height: h)
        htmlContent = try c.decode(String.self, forKey: .htmlContent)
        backendWidgetID = try c.decodeIfPresent(String.self, forKey: .backendWidgetID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(position.x, forKey: .posX)
        try c.encode(position.y, forKey: .posY)
        try c.encode(size.width, forKey: .width)
        try c.encode(size.height, forKey: .height)
        try c.encode(htmlContent, forKey: .htmlContent)
        try c.encodeIfPresent(backendWidgetID, forKey: .backendWidgetID)
    }
}

struct WidgetSuggestion: Identifiable {
    let id: UUID
    var title: String
    var summary: String
    var htmlContent: String
    var position: CGPoint
    var size: CGSize
    var animateOnPlace: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        summary: String,
        htmlContent: String,
        position: CGPoint,
        size: CGSize,
        animateOnPlace: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.htmlContent = htmlContent
        self.position = position
        self.size = size
        self.animateOnPlace = animateOnPlace
        self.createdAt = createdAt
    }
}
