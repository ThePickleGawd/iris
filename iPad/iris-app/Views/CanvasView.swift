import SwiftUI
import PencilKit
import UIKit

struct CanvasView: UIViewRepresentable {
    @EnvironmentObject var canvasState: CanvasState
    let document: Document?
    let objectManager: CanvasObjectManager
    let cursor: AgentCursorController

    func makeUIView(context: Context) -> NoteCanvasView {
        let view = NoteCanvasView()
        view.delegate = context.coordinator
        view.objectManager = objectManager

        view.backgroundColor = UIColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1)
        view.isOpaque = true
        view.drawingPolicy = .pencilOnly
        view.overrideUserInterfaceStyle = .light

        view.minimumZoomScale = 0.5
        view.maximumZoomScale = 3.0
        view.bouncesZoom = false
        view.alwaysBounceVertical = true
        view.alwaysBounceHorizontal = true
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false

        view.configureForInfiniteCanvas()

        if let document {
            view.drawing = document.loadDrawing()
            canvasState.drawing = view.drawing
        }

        applyTool(to: view)
        objectManager.attach(to: view, cursor: cursor)

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        view.addInteraction(pencilInteraction)

        DispatchQueue.main.async {
            view.centerViewport()
            view.setZoomScale(1.0, animated: false)
            self.canvasState.currentZoomScale = 1.0
        }

        return view
    }

    func updateUIView(_ view: NoteCanvasView, context: Context) {
        context.coordinator.parent = self
        applyTool(to: view)
    }

    private func applyTool(to canvasView: PKCanvasView) {
        switch canvasState.currentTool {
        case .pen:
            canvasView.tool = PKInkingTool(.pen, color: canvasState.currentColor, width: canvasState.strokeWidth)
        case .highlighter:
            canvasView.tool = PKInkingTool(.marker, color: canvasState.currentColor.withAlphaComponent(0.35), width: canvasState.strokeWidth * 3)
        case .eraser:
            canvasView.tool = PKEraserTool(.vector)
        case .lasso:
            canvasView.tool = PKLassoTool()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        var parent: CanvasView
        private var saveTimer: Timer?
        private var squeezePreviousTool: DrawingTool?

        init(_ parent: CanvasView) {
            self.parent = parent
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let canvas = scrollView as? NoteCanvasView else { return }
            canvas.updateWidgetOverlayTransform()
            parent.objectManager.updateZoomScale(canvas.zoomScale)
            parent.objectManager.syncLayout()
            DispatchQueue.main.async {
                self.parent.canvasState.currentZoomScale = canvas.zoomScale
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? NoteCanvasView)?.updateWidgetOverlayTransform()
            parent.objectManager.syncLayout()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.canvasState.drawing = canvasView.drawing
            parent.canvasState.undoManager = canvasView.undoManager
            parent.canvasState.canUndo = canvasView.undoManager?.canUndo ?? false
            parent.canvasState.canRedo = canvasView.undoManager?.canRedo ?? false
            parent.canvasState.lastStrokeActivityAt = Date()
            if let recentStroke = canvasView.drawing.strokes.last {
                parent.objectManager.updateMostRecentStrokeBounds(recentStroke.renderBounds)
            }

            saveTimer?.invalidate()
            guard let doc = parent.document else { return }
            saveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in
                doc.saveDrawing(canvasView.drawing)
            }
        }

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            registerPencilTap()
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            registerPencilTap()
        }

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
                    if let previousTool = self.squeezePreviousTool {
                        self.parent.canvasState.currentTool = previousTool
                        self.squeezePreviousTool = nil
                    }
                @unknown default:
                    break
                }
            }
        }

        private func registerPencilTap() {
            DispatchQueue.main.async {
                // Apple Pencil flat-side double tap is treated as an explicit AI request trigger.
                self.parent.canvasState.lastPencilDoubleTapAt = Date()
            }
        }
    }
}

final class NoteCanvasView: PKCanvasView {
    private let gridView = InfiniteCanvasBackgroundView()
    private let widgetOverlay = WidgetOverlayView()

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
        gridView.isUserInteractionEnabled = false
        gridView.layer.zPosition = -2
        insertSubview(gridView, at: 0)

        widgetOverlay.isUserInteractionEnabled = true
        widgetOverlay.backgroundColor = .clear
        widgetOverlay.layer.zPosition = 10
        widgetOverlay.layer.anchorPoint = .zero
        widgetOverlay.layer.position = .zero
        addSubview(widgetOverlay)
    }

    func configureForInfiniteCanvas() {
        let size = CanvasState.canvasSize
        contentSize = CGSize(width: size, height: size)
        gridView.frame = CGRect(x: 0, y: 0, width: size, height: size)
        widgetOverlay.frame = CGRect(origin: .zero, size: bounds.size)
        updateWidgetOverlayTransform()
    }

    func centerViewport() {
        let center = CanvasState.canvasCenter
        let ox = center.x - bounds.width / 2
        let oy = center.y - bounds.height / 2
        setContentOffset(CGPoint(x: ox, y: oy), animated: false)
        updateWidgetOverlayTransform()
    }

    func widgetContainerView() -> UIView { widgetOverlay }

    func screenPoint(forCanvasPoint point: CGPoint) -> CGPoint {
        point.applying(widgetOverlay.transform)
    }

    func canvasPoint(forScreenPoint point: CGPoint) -> CGPoint {
        point.applying(widgetOverlay.transform.inverted())
    }

    func updateWidgetOverlayTransform() {
        let z = zoomScale
        let ox = contentOffset.x
        let oy = contentOffset.y
        widgetOverlay.transform = CGAffineTransform(a: z, b: 0, c: 0, d: z, tx: -ox * z, ty: -oy * z)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        widgetOverlay.frame = CGRect(origin: .zero, size: bounds.size)
        updateWidgetOverlayTransform()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let event, let touch = event.allTouches?.first, touch.type == .pencil {
            return super.hitTest(point, with: event)
        }
        if let event, (event.allTouches?.count ?? 0) >= 2 {
            return super.hitTest(point, with: event)
        }
        let local = widgetOverlay.convert(point, from: self)
        if let target = widgetOverlay.hitTest(local, with: event) {
            return target
        }
        return super.hitTest(point, with: event)
    }
}

final class WidgetOverlayView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        for subview in subviews where !subview.isHidden && subview.alpha > 0.01 {
            let p = convert(point, to: subview)
            if subview.point(inside: p, with: event) { return true }
        }
        return false
    }
}

final class InfiniteCanvasBackgroundView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.makeGrid()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = Self.makeGrid()
    }

    private static func makeGrid() -> UIColor {
        let spacing: CGFloat = 24
        let size = CGSize(width: spacing, height: spacing)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            UIColor(white: 0.80, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: spacing/2 - 1, y: spacing/2 - 1, width: 2, height: 2))
        }
        return UIColor(patternImage: image)
    }
}
