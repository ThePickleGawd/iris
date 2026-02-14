import SwiftUI
import PencilKit
import UIKit

struct CanvasView: UIViewRepresentable {
    @EnvironmentObject var canvasState: CanvasState
    let document: Document
    let objectManager: CanvasObjectManager
    let cursor: AgentCursorController

    func makeUIView(context: Context) -> NoteCanvasView {
        let canvasView = NoteCanvasView()
        canvasView.delegate = context.coordinator
        canvasView.backgroundColor = InfiniteCanvasBackgroundView.baseColor
        canvasView.isOpaque = true
        canvasView.drawingPolicy = .pencilOnly
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.minimumZoomScale = 0.25
        canvasView.maximumZoomScale = 4.0
        canvasView.alwaysBounceVertical = true
        canvasView.alwaysBounceHorizontal = true
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.showsVerticalScrollIndicator = false
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.undoManager?.levelsOfUndo = 50

        canvasView.drawing = document.loadDrawing()
        canvasState.drawing = canvasView.drawing

        canvasView.configureForInfiniteCanvas()
        canvasView.objectManager = objectManager

        applyTool(to: canvasView)

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        canvasView.addInteraction(pencilInteraction)

        // Two-finger tap -> undo
        let twoFingerTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.requiresExclusiveTouchType = false
        canvasView.addGestureRecognizer(twoFingerTap)

        // Three-finger tap -> redo
        let threeFingerTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleThreeFingerTap(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.requiresExclusiveTouchType = false
        canvasView.addGestureRecognizer(threeFingerTap)

        twoFingerTap.require(toFail: threeFingerTap)

        objectManager.attach(to: canvasView, cursor: cursor)

        // Center viewport after layout
        DispatchQueue.main.async {
            canvasView.centerViewport()
        }

        return canvasView
    }

    func updateUIView(_ canvasView: NoteCanvasView, context: Context) {
        context.coordinator.parent = self
        applyTool(to: canvasView)

        if canvasState.needsDrawingReset {
            canvasState.needsDrawingReset = false
            canvasView.drawing = canvasState.drawing
        }
    }

    private func applyTool(to canvasView: PKCanvasView) {
        switch canvasState.currentTool {
        case .pen:
            canvasView.tool = PKInkingTool(.pen, color: canvasState.currentColor, width: canvasState.strokeWidth)
        case .highlighter:
            canvasView.tool = PKInkingTool(.marker, color: canvasState.currentColor.withAlphaComponent(0.3), width: canvasState.strokeWidth * 5)
        case .eraser:
            canvasView.tool = PKEraserTool(.vector)
        case .lasso:
            canvasView.tool = PKLassoTool()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Coordinator

    class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        var parent: CanvasView
        private var previousTool: DrawingTool = .pen
        private var squeezePreviousTool: DrawingTool?
        private var saveTimer: Timer?

        init(_ parent: CanvasView) {
            self.parent = parent
        }

        // MARK: - Multi-finger tap gestures

        @objc func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
            parent.canvasState.undo()
        }

        @objc func handleThreeFingerTap(_ gesture: UITapGestureRecognizer) {
            parent.canvasState.redo()
        }

        // MARK: - Scroll

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            parent.objectManager.updateZoomScale(scrollView.zoomScale)
        }

        // MARK: - PKCanvasViewDelegate

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.canvasState.drawing = canvasView.drawing

            saveTimer?.invalidate()
            saveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.parent.document.saveDrawing(canvasView.drawing)
            }
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            parent.canvasState.canUndo = canvasView.undoManager?.canUndo ?? false
            parent.canvasState.canRedo = canvasView.undoManager?.canRedo ?? false
            parent.canvasState.undoManager = canvasView.undoManager
        }

        // MARK: - UIPencilInteractionDelegate

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            switch UIPencilInteraction.preferredTapAction {
            case .ignore:
                break
            case .switchEraser:
                DispatchQueue.main.async {
                    if self.parent.canvasState.currentTool == .eraser {
                        self.parent.canvasState.currentTool = self.previousTool
                    } else {
                        self.previousTool = self.parent.canvasState.currentTool
                        self.parent.canvasState.currentTool = .eraser
                    }
                }
            case .switchPrevious:
                DispatchQueue.main.async {
                    let current = self.parent.canvasState.currentTool
                    self.parent.canvasState.currentTool = self.previousTool
                    self.previousTool = current
                }
            case .showColorPalette:
                DispatchQueue.main.async {
                    self.cycleToNextColor()
                }
            case .showInkAttributes:
                break
            @unknown default:
                break
            }
        }

        // MARK: - Apple Pencil Pro Squeeze

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            DispatchQueue.main.async {
                switch squeeze.phase {
                case .began, .changed:
                    if self.squeezePreviousTool == nil {
                        self.squeezePreviousTool = self.parent.canvasState.currentTool
                        self.parent.canvasState.currentTool = .eraser
                    }
                case .ended, .cancelled:
                    if let tool = self.squeezePreviousTool {
                        self.parent.canvasState.currentTool = tool
                        self.squeezePreviousTool = nil
                    }
                @unknown default:
                    break
                }
            }
        }

        private func cycleToNextColor() {
            let colors = CanvasState.availableColors
            if let currentIndex = colors.firstIndex(where: {
                $0.isApproximatelyEqual(to: parent.canvasState.currentColor)
            }) {
                let nextIndex = (currentIndex + 1) % colors.count
                parent.canvasState.currentColor = colors[nextIndex]
            } else {
                parent.canvasState.currentColor = colors[0]
            }
        }
    }
}

// MARK: - NoteCanvasView

class NoteCanvasView: PKCanvasView {
    private let infiniteBackground = InfiniteCanvasBackgroundView()
    weak var objectManager: CanvasObjectManager?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        infiniteBackground.isUserInteractionEnabled = false
        infiniteBackground.backgroundColor = .clear
        infiniteBackground.layer.zPosition = -2
        insertSubview(infiniteBackground, at: 0)
    }

    func configureForInfiniteCanvas() {
        let size = CanvasState.canvasSize
        contentSize = CGSize(width: size, height: size)
        infiniteBackground.frame = CGRect(x: 0, y: 0, width: size, height: size)
    }

    func centerViewport() {
        let center = CanvasState.canvasCenter
        let offsetX = center.x - bounds.width / 2
        let offsetY = center.y - bounds.height / 2
        setContentOffset(CGPoint(x: offsetX, y: offsetY), animated: false)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Pencil always goes to PencilKit for drawing
        if let event = event, let touch = event.allTouches?.first, touch.type == .pencil {
            return super.hitTest(point, with: event)
        }

        // For finger touches, check if a widget is under the point — return it
        // so its pan gesture recognizer handles the drag instead of canvas scroll
        if let manager = objectManager {
            for (_, widgetView) in manager.objectViews {
                let localPoint = widgetView.convert(point, from: self)
                if widgetView.bounds.contains(localPoint) {
                    return widgetView
                }
            }
        }

        // Fallback to default (scroll/zoom)
        return super.hitTest(point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.type == .pencil {
            setContentOffset(contentOffset, animated: false)
            break
        }
        super.touchesBegan(touches, with: event)
    }

    // MARK: - Duplicate menu item

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                _ = self?.becomeFirstResponder()
            }
        }
        UIMenuController.shared.menuItems = [
            UIMenuItem(title: "Duplicate", action: #selector(duplicateSelection(_:)))
        ]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(duplicateSelection(_:)) {
            return super.canPerformAction(#selector(copy(_:)), withSender: sender)
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func duplicateSelection(_ sender: Any?) {
        copy(sender)
        paste(sender)
    }
}

// MARK: - Infinite Canvas Background (pattern-based dot grid)

class InfiniteCanvasBackgroundView: UIView {
    static let baseColor = UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.makeDotPatternColor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = Self.makeDotPatternColor()
    }

    private static func makeDotPatternColor() -> UIColor {
        let spacing: CGFloat = 24
        let dotRadius: CGFloat = 1.0
        let tileSize = CGSize(width: spacing, height: spacing)

        let renderer = UIGraphicsImageRenderer(size: tileSize)
        let image = renderer.image { ctx in
            // Fill tile with base color
            baseColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: tileSize))

            // Draw dot at center of tile
            UIColor(white: 0.78, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(
                x: spacing / 2 - dotRadius,
                y: spacing / 2 - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
        }

        return UIColor(patternImage: image)
    }
}
