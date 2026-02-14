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
