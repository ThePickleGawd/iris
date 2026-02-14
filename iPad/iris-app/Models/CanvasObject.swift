import Foundation

struct CanvasObject: Identifiable {
    let id: UUID
    var position: CGPoint
    var size: CGSize
    var htmlContent: String

    init(id: UUID = UUID(), position: CGPoint, size: CGSize, htmlContent: String) {
        self.id = id
        self.position = position
        self.size = size
        self.htmlContent = htmlContent
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
