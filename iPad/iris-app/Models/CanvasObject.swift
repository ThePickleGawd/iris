import Foundation

struct CanvasObject: Identifiable {
    let id: UUID
    var position: CGPoint
    var size: CGSize
    var htmlContent: String
    /// The widget ID from the backend session, used to sync deletions.
    var backendWidgetID: String?

    init(id: UUID = UUID(), position: CGPoint, size: CGSize, htmlContent: String, backendWidgetID: String? = nil) {
        self.id = id
        self.position = position
        self.size = size
        self.htmlContent = htmlContent
        self.backendWidgetID = backendWidgetID
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
