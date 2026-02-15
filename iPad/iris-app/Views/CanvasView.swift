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

        view.backgroundColor = Self.makeDotPattern()
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
            _ = view.expandCanvasIfNeeded(for: view.drawing.bounds, allowLeadingExpansion: false)
            canvasState.drawing = view.drawing
        }

        applyTool(to: view)
        objectManager.attach(to: view, cursor: cursor)

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        view.addInteraction(pencilInteraction)

        let twoFingerTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.numberOfTapsRequired = 1
        view.addGestureRecognizer(twoFingerTap)

        let threeFingerTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleThreeFingerTap))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.numberOfTapsRequired = 1
        view.addGestureRecognizer(threeFingerTap)

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

    private static func makeDotPattern() -> UIColor {
        let spacing: CGFloat = 28
        let dotRadius: CGFloat = 1.5
        let size = CGSize(width: spacing, height: spacing)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            UIColor(white: 0.72, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(
                x: spacing / 2 - dotRadius,
                y: spacing / 2 - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
        }
        return UIColor(patternImage: image)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        var parent: CanvasView
        private var saveTimer: Timer?

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
            // Always keep canvasState.drawing in sync for UI
            parent.canvasState.drawing = canvasView.drawing

            // During SVG draw animation, skip save timers and proactive triggers
            if parent.objectManager.isAnimatingDraw { return }

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

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            guard let noteCanvas = canvasView as? NoteCanvasView else { return }
            guard let recentStroke = canvasView.drawing.strokes.last else { return }
            let adjustedBounds = noteCanvas.expandCanvasIfNeeded(for: recentStroke.renderBounds)
            parent.objectManager.updateMostRecentStrokeBounds(adjustedBounds)
        }

        // MARK: - Finger tap gestures

        @objc func handleTwoFingerTap() {
            parent.canvasState.undo()
        }

        @objc func handleThreeFingerTap() {
            parent.canvasState.redo()
        }

        // MARK: - Pencil interaction


        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            toggleEraser()
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            toggleEraser()
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            DispatchQueue.main.async {
                switch squeeze.phase {
                case .began, .changed:
                    self.parent.canvasState.isRecording = true
                case .ended, .cancelled:
                    self.parent.canvasState.isRecording = false
                @unknown default:
                    break
                }
            }
        }

        private func toggleEraser() {
            DispatchQueue.main.async {
                // Apple Pencil flat-side double tap is treated as an explicit AI request trigger.
                self.parent.canvasState.lastPencilDoubleTapAt = Date()
            }
        }
    }
}

final class NoteCanvasView: PKCanvasView {
    private let widgetOverlay = WidgetOverlayView()
    private let edgeTriggerInset: CGFloat = 540
    private let expansionChunk: CGFloat = 1_536

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
        widgetOverlay.isUserInteractionEnabled = true
        widgetOverlay.backgroundColor = .clear
        widgetOverlay.layer.zPosition = 10
        widgetOverlay.layer.anchorPoint = .zero
        widgetOverlay.layer.position = .zero
        addSubview(widgetOverlay)
    }

    func configureForInfiniteCanvas() {
        CanvasState.resetCanvasGeometry()
        contentSize = CanvasState.canvasContentSize
        widgetOverlay.frame = CGRect(origin: .zero, size: bounds.size)
        updateWidgetOverlayTransform()
    }

    func centerViewport() {
        let center = CanvasState.canvasCenter
        let visibleW = bounds.width / max(zoomScale, 0.0001)
        let visibleH = bounds.height / max(zoomScale, 0.0001)
        let visibleOrigin = CGPoint(
            x: center.x - visibleW / 2,
            y: center.y - visibleH / 2
        )
        let ox = visibleOrigin.x - adjustedContentInset.left
        let oy = visibleOrigin.y - adjustedContentInset.top
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
        let ox = contentOffset.x + adjustedContentInset.left
        let oy = contentOffset.y + adjustedContentInset.top
        widgetOverlay.transform = CGAffineTransform(a: z, b: 0, c: 0, d: z, tx: -ox * z, ty: -oy * z)
    }

    @discardableResult
    func expandCanvasIfNeeded(
        for strokeBounds: CGRect,
        allowLeadingExpansion: Bool = true
    ) -> CGRect {
        guard strokeBounds.width > 0, strokeBounds.height > 0 else { return strokeBounds }

        let leftNeed = max(0, edgeTriggerInset - strokeBounds.minX)
        let rightNeed = max(0, strokeBounds.maxX - (contentSize.width - edgeTriggerInset))
        let topNeed = max(0, edgeTriggerInset - strokeBounds.minY)
        let bottomNeed = max(0, strokeBounds.maxY - (contentSize.height - edgeTriggerInset))

        let addLeft = allowLeadingExpansion ? roundedExpansionAmount(for: leftNeed) : 0
        let addRight = roundedExpansionAmount(for: rightNeed)
        let addTop = allowLeadingExpansion ? roundedExpansionAmount(for: topNeed) : 0
        let addBottom = roundedExpansionAmount(for: bottomNeed)

        guard addLeft > 0 || addRight > 0 || addTop > 0 || addBottom > 0 else {
            return strokeBounds
        }

        let translation = CGPoint(x: addLeft, y: addTop)
        if translation != .zero {
            drawing = drawing.transformed(using: CGAffineTransform(translationX: translation.x, y: translation.y))
            objectManager?.translateContent(by: translation)
            CanvasState.shiftCanvasCenter(by: translation)
        }

        let updatedContentSize = CGSize(
            width: contentSize.width + addLeft + addRight,
            height: contentSize.height + addTop + addBottom
        )
        contentSize = updatedContentSize
        CanvasState.updateCanvasContentSize(updatedContentSize)

        if translation != .zero {
            let adjustedOffset = CGPoint(
                x: contentOffset.x + (translation.x * zoomScale),
                y: contentOffset.y + (translation.y * zoomScale)
            )
            setContentOffset(adjustedOffset, animated: false)
        }

        updateWidgetOverlayTransform()
        return strokeBounds.offsetBy(dx: translation.x, dy: translation.y)
    }

    private func roundedExpansionAmount(for requiredMargin: CGFloat) -> CGFloat {
        guard requiredMargin > 0 else { return 0 }
        return ceil(requiredMargin / expansionChunk) * expansionChunk
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
