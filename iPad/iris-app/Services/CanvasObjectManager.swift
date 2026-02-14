import UIKit

@MainActor
final class CanvasObjectManager: ObservableObject {
    @Published private(set) var objects: [UUID: CanvasObject] = [:]
    private(set) var objectViews: [UUID: CanvasObjectWebView] = [:]

    let httpServer = AgentHTTPServer()

    private weak var canvasView: NoteCanvasView?
    private weak var cursor: AgentCursorController?

    func attach(to canvas: NoteCanvasView, cursor: AgentCursorController) {
        self.canvasView = canvas
        self.cursor = cursor
        httpServer.start(objectManager: self)
    }

    var viewportCenter: CGPoint {
        guard let cv = canvasView, cv.bounds.width > 0 else { return CanvasState.canvasCenter }
        let visibleW = cv.bounds.width / cv.zoomScale
        let visibleH = cv.bounds.height / cv.zoomScale
        return CGPoint(x: cv.contentOffset.x + visibleW / 2, y: cv.contentOffset.y + visibleH / 2)
    }

    @discardableResult
    func place(
        html: String,
        at position: CGPoint,
        size: CGSize = CGSize(width: 360, height: 220),
        animated: Bool = true
    ) async -> CanvasObject {
        let object = CanvasObject(position: position, size: size, htmlContent: html)
        guard let canvasView else { return object }

        if animated, let cursor {
            let p = canvasView.screenPoint(forCanvasPoint: position)
            cursor.appear(at: CGPoint(x: p.x - 54, y: p.y - 54))
            try? await Task.sleep(nanoseconds: 160_000_000)
            cursor.moveTo(p, duration: 0.34)
            try? await Task.sleep(nanoseconds: 300_000_000)
            cursor.click()
        }

        let widget = CanvasObjectWebView(id: object.id, size: size, htmlContent: html)
        widget.frame = CGRect(origin: position, size: size)
        widget.alpha = animated ? 0 : 1

        widget.onDragEnded = { [weak self] id, origin in
            self?.objects[id]?.position = origin
        }

        widget.onResizeEnded = { [weak self] id, frame in
            self?.objects[id]?.position = frame.origin
            self?.objects[id]?.size = frame.size
        }

        canvasView.widgetContainerView().addSubview(widget)
        objects[object.id] = object
        objectViews[object.id] = widget

        if animated {
            widget.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut]) {
                widget.alpha = 1
                widget.transform = .identity
            }
            try? await Task.sleep(nanoseconds: 220_000_000)
            cursor?.disappear()
        }

        return object
    }

    func remove(id: UUID) {
        guard let view = objectViews[id] else { return }
        UIView.animate(withDuration: 0.18, animations: {
            view.alpha = 0
            view.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }, completion: { _ in
            view.removeFromSuperview()
        })
        objectViews.removeValue(forKey: id)
        objects.removeValue(forKey: id)
    }

    func removeAll() {
        let ids = Array(objectViews.keys)
        for id in ids { remove(id: id) }
    }

    func updateZoomScale(_ scale: CGFloat) {
        for view in objectViews.values {
            view.updateForZoomScale(scale)
        }
    }

    func setZoomScale(_ scale: CGFloat, animated: Bool = true) {
        guard let canvasView else { return }
        let clamped = min(canvasView.maximumZoomScale, max(canvasView.minimumZoomScale, scale))
        canvasView.setZoomScale(clamped, animated: animated)
    }

    func zoom(by delta: CGFloat, animated: Bool = true) {
        guard let canvasView else { return }
        setZoomScale(canvasView.zoomScale + delta, animated: animated)
    }

    func syncLayout() {
        for (id, object) in objects {
            guard let view = objectViews[id] else { continue }
            let next = CGRect(origin: object.position, size: object.size)
            if view.frame != next { view.frame = next }
        }
    }

    func cursorAppear(at point: CGPoint) {
        guard let canvasView, let cursor else { return }
        cursor.appear(at: canvasView.screenPoint(forCanvasPoint: point))
    }

    func cursorMove(to point: CGPoint) {
        guard let canvasView, let cursor else { return }
        cursor.moveTo(canvasView.screenPoint(forCanvasPoint: point), duration: 0.28)
    }

    func cursorClick() { cursor?.click() }
    func cursorDisappear() { cursor?.disappear() }
}
