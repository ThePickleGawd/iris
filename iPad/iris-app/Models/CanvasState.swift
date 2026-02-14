import SwiftUI
import PencilKit

enum DrawingTool: String, CaseIterable {
    case pen
    case highlighter
    case eraser
    case lasso
}

final class CanvasState: ObservableObject {
    static let canvasSize: CGFloat = 80_000
    static let canvasCenter = CGPoint(x: canvasSize / 2, y: canvasSize / 2)

    @Published var drawing: PKDrawing = PKDrawing()
    @Published var currentTool: DrawingTool = .pen
    @Published var currentColor: UIColor = UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1)
    @Published var strokeWidth: CGFloat = 3
    @Published var currentZoomScale: CGFloat = 1.0

    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    weak var undoManager: UndoManager?

    static let availableColors: [UIColor] = [
        UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1),
        UIColor(red: 0.08, green: 0.35, blue: 0.74, alpha: 1),
        UIColor(red: 0.10, green: 0.58, blue: 0.36, alpha: 1),
        UIColor(red: 0.82, green: 0.20, blue: 0.20, alpha: 1),
        UIColor(red: 0.51, green: 0.25, blue: 0.89, alpha: 1)
    ]

    func undo() { undoManager?.undo() }
    func redo() { undoManager?.redo() }

    func clearCanvas() {
        drawing = PKDrawing()
        canUndo = false
        canRedo = false
    }
}
