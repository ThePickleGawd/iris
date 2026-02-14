import SwiftUI
import PencilKit

enum DrawingTool: String, CaseIterable {
    case pen
    case highlighter
    case eraser
    case lasso
}

class CanvasState: ObservableObject {
    static let canvasSize: CGFloat = 100_000
    static let canvasCenter = CGPoint(x: canvasSize / 2, y: canvasSize / 2)

    var drawing = PKDrawing()

    @Published var currentTool: DrawingTool = .pen
    @Published var currentColor: UIColor = UIColor(red: 30/255, green: 39/255, blue: 56/255, alpha: 1)
    @Published var strokeWidth: CGFloat = 3
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false

    @Published var isRecording: Bool = false

    static let availableColors: [UIColor] = [
        UIColor(red: 30/255, green: 39/255, blue: 56/255, alpha: 1),
        UIColor(red: 128/255, green: 128/255, blue: 128/255, alpha: 1),
        UIColor(red: 41/255, green: 98/255, blue: 255/255, alpha: 1),
        UIColor(red: 235/255, green: 77/255, blue: 61/255, alpha: 1),
        UIColor(red: 208/255, green: 55/255, blue: 130/255, alpha: 1),
        UIColor(red: 102/255, green: 51/255, blue: 153/255, alpha: 1),
    ]

    var needsDrawingReset = false
    weak var undoManager: UndoManager?

    func undo() { undoManager?.undo() }
    func redo() { undoManager?.redo() }

    func clearCanvas() {
        needsDrawingReset = true
        drawing = PKDrawing()
        canUndo = false
        canRedo = false
    }
}
