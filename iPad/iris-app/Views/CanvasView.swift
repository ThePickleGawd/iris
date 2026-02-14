import SwiftUI
import PencilKit
import UIKit

struct CanvasView: UIViewRepresentable {
    @EnvironmentObject var canvasState: CanvasState
    let document: Document

    func makeUIView(context: Context) -> NoteCanvasView {
        let canvasView = NoteCanvasView()
        canvasView.delegate = context.coordinator
        canvasView.backgroundColor = UIColor(white: 0.92, alpha: 1)
        canvasView.isOpaque = true
        canvasView.drawingPolicy = .pencilOnly
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.minimumZoomScale = 0.5
        canvasView.maximumZoomScale = 3.0
        canvasView.alwaysBounceVertical = true
        canvasView.alwaysBounceHorizontal = false
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.undoManager?.levelsOfUndo = 50

        canvasView.drawing = document.loadDrawing()
        canvasState.drawing = canvasView.drawing

        let initialWidth = max(UIScreen.main.bounds.width, 1)
        let initialPageHeight = canvasState.pageHeight(for: initialWidth)
        let initialTotalHeight = canvasState.totalContentHeight(for: initialWidth)
        canvasView.contentSize = CGSize(width: initialWidth, height: initialTotalHeight)
        canvasView.updatePages(
            count: canvasState.pageCount,
            height: initialPageHeight,
            gap: canvasState.pageGap,
            contentWidth: initialWidth,
            contentHeight: initialTotalHeight
        )

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

        context.coordinator.needsInitialLayout = true
        return canvasView
    }

    func updateUIView(_ canvasView: NoteCanvasView, context: Context) {
        context.coordinator.parent = self
        applyTool(to: canvasView)

        let screenWidth = canvasView.bounds.width
        guard screenWidth > 0 else { return }

        let pageHeight = canvasState.pageHeight(for: screenWidth)
        let totalHeight = canvasState.totalContentHeight(for: screenWidth)
        let newSize = CGSize(width: screenWidth, height: totalHeight)

        if canvasView.contentSize != newSize {
            canvasView.contentSize = newSize
        }

        canvasView.updatePages(
            count: canvasState.pageCount,
            height: pageHeight,
            gap: canvasState.pageGap,
            contentWidth: screenWidth,
            contentHeight: totalHeight
        )

        if canvasState.needsDrawingReset {
            canvasState.needsDrawingReset = false
            canvasView.drawing = canvasState.drawing
        }

        if context.coordinator.needsInitialLayout {
            context.coordinator.needsInitialLayout = false
            if !canvasView.drawing.strokes.isEmpty {
                var needed = 1
                for stroke in canvasView.drawing.strokes {
                    let pageIndex = Int(stroke.renderBounds.maxY / (pageHeight + canvasState.pageGap)) + 1
                    needed = max(needed, pageIndex)
                }
                canvasState.pageCount = max(canvasState.pageCount, needed + 1)
            }
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
        var needsInitialLayout = false
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
            let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width * scrollView.zoomScale) / 2, 0)
            let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height * scrollView.zoomScale) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
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

            let screenWidth = canvasView.bounds.width
            if screenWidth > 0 {
                parent.canvasState.checkAndSpawnPage(screenWidth: screenWidth)
            }
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
    private let pageBackgroundView = PageBackgroundView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        pageBackgroundView.isUserInteractionEnabled = false
        pageBackgroundView.backgroundColor = .clear
        pageBackgroundView.layer.zPosition = -1
        insertSubview(pageBackgroundView, at: 0)
    }

    func updatePages(count: Int, height: CGFloat, gap: CGFloat, contentWidth: CGFloat, contentHeight: CGFloat) {
        let newFrame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        if pageBackgroundView.frame != newFrame {
            pageBackgroundView.frame = newFrame
        }
        let needsRedraw = pageBackgroundView.pageCount != count
            || pageBackgroundView.pageHeight != height
            || pageBackgroundView.pageGap != gap
        pageBackgroundView.pageCount = count
        pageBackgroundView.pageHeight = height
        pageBackgroundView.pageGap = gap
        if needsRedraw {
            pageBackgroundView.setNeedsDisplay()
        }
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

// MARK: - Page Background View

class PageBackgroundView: UIView {
    var pageCount: Int = 1
    var pageHeight: CGFloat = 0
    var pageGap: CGFloat = 20

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), pageHeight > 0 else { return }

        for i in 0..<pageCount {
            let y = CGFloat(i) * (pageHeight + pageGap)
            let pageRect = CGRect(x: 0, y: y, width: bounds.width, height: pageHeight)

            guard pageRect.intersects(rect) else { continue }

            // Page shadow + fill
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: UIColor.black.withAlphaComponent(0.15).cgColor)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(pageRect)
            ctx.restoreGState()

            // Page border
            ctx.setStrokeColor(UIColor(white: 0.82, alpha: 1).cgColor)
            ctx.setLineWidth(0.5)
            ctx.stroke(pageRect)

            // Separator between pages
            if i < pageCount - 1 {
                let separatorY = y + pageHeight + pageGap / 2
                ctx.setStrokeColor(UIColor(red: 0.68, green: 0.72, blue: 0.82, alpha: 0.5).cgColor)
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: 0, y: separatorY))
                ctx.addLine(to: CGPoint(x: bounds.width, y: separatorY))
                ctx.strokePath()
            }
        }
    }
}
