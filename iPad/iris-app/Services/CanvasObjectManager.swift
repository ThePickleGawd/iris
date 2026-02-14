import UIKit

struct CanvasCoordinateSnapshot: Codable {
    struct Point: Codable {
        let x: Double
        let y: Double
    }

    struct Size: Codable {
        let width: Double
        let height: Double
    }

    let documentID: String?
    let axis: String
    let canvasCenter: Point
    let viewportCenterCanvas: Point
    let viewportCenterAxis: Point
    let viewportTopLeftAxis: Point
    let viewportTopRightAxis: Point
    let viewportBottomLeftAxis: Point
    let viewportBottomRightAxis: Point
    let viewportSizeCanvas: Size
    let zoomScale: Double
}

struct CanvasSuggestion: Identifiable {
    let id: UUID
    let title: String
    let summary: String
    let html: String
    let position: CGPoint
    let size: CGSize
    let animateOnPlace: Bool
    let createdAt: Date
}

@MainActor
final class CanvasObjectManager: ObservableObject {
    @Published private(set) var objects: [UUID: CanvasObject] = [:]
    @Published private(set) var suggestions: [UUID: CanvasSuggestion] = [:]
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

    var documentAxisOrigin: CGPoint { CanvasState.canvasCenter }

    func viewportCanvasRect() -> CGRect {
        guard let cv = canvasView, cv.bounds.width > 0, cv.bounds.height > 0 else {
            return CGRect(origin: documentAxisOrigin, size: .zero)
        }
        let visibleW = cv.bounds.width / cv.zoomScale
        let visibleH = cv.bounds.height / cv.zoomScale
        return CGRect(
            x: cv.contentOffset.x,
            y: cv.contentOffset.y,
            width: visibleW,
            height: visibleH
        )
    }

    func axisPoint(forCanvasPoint p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - documentAxisOrigin.x, y: p.y - documentAxisOrigin.y)
    }

    func canvasPoint(forAxisPoint p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + documentAxisOrigin.x, y: p.y + documentAxisOrigin.y)
    }

    func screenPoint(forCanvasPoint p: CGPoint) -> CGPoint {
        guard let canvasView else { return p }
        return canvasView.screenPoint(forCanvasPoint: p)
    }

    func makeCoordinateSnapshot(documentID: UUID?) -> CanvasCoordinateSnapshot {
        let viewport = viewportCanvasRect()
        let topLeftAxis = axisPoint(forCanvasPoint: viewport.origin)
        let topRightAxis = axisPoint(
            forCanvasPoint: CGPoint(x: viewport.maxX, y: viewport.minY)
        )
        let bottomLeftAxis = axisPoint(
            forCanvasPoint: CGPoint(x: viewport.minX, y: viewport.maxY)
        )
        let bottomRightAxis = axisPoint(
            forCanvasPoint: CGPoint(x: viewport.maxX, y: viewport.maxY)
        )
        let viewportCenter = viewportCenter
        let viewportCenterAxis = axisPoint(forCanvasPoint: viewportCenter)
        guard let cv = canvasView else {
            return CanvasCoordinateSnapshot(
                documentID: documentID?.uuidString,
                axis: "document_axis",
                canvasCenter: .init(x: documentAxisOrigin.x, y: documentAxisOrigin.y),
                viewportCenterCanvas: .init(x: viewportCenter.x, y: viewportCenter.y),
                viewportCenterAxis: .init(x: viewportCenterAxis.x, y: viewportCenterAxis.y),
                viewportTopLeftAxis: .init(x: topLeftAxis.x, y: topLeftAxis.y),
                viewportTopRightAxis: .init(x: topRightAxis.x, y: topRightAxis.y),
                viewportBottomLeftAxis: .init(x: bottomLeftAxis.x, y: bottomLeftAxis.y),
                viewportBottomRightAxis: .init(x: bottomRightAxis.x, y: bottomRightAxis.y),
                viewportSizeCanvas: .init(width: viewport.width, height: viewport.height),
                zoomScale: 1
            )
        }
        return CanvasCoordinateSnapshot(
            documentID: documentID?.uuidString,
            axis: "document_axis",
            canvasCenter: .init(x: documentAxisOrigin.x, y: documentAxisOrigin.y),
            viewportCenterCanvas: .init(x: viewportCenter.x, y: viewportCenter.y),
            viewportCenterAxis: .init(x: viewportCenterAxis.x, y: viewportCenterAxis.y),
            viewportTopLeftAxis: .init(x: topLeftAxis.x, y: topLeftAxis.y),
            viewportTopRightAxis: .init(x: topRightAxis.x, y: topRightAxis.y),
            viewportBottomLeftAxis: .init(x: bottomLeftAxis.x, y: bottomLeftAxis.y),
            viewportBottomRightAxis: .init(x: bottomRightAxis.x, y: bottomRightAxis.y),
            viewportSizeCanvas: .init(width: viewport.width, height: viewport.height),
            zoomScale: cv.zoomScale
        )
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

        let syncObjectFrame: (UUID, CGRect) -> Void = { [weak self] id, frame in
            self?.objects[id]?.position = frame.origin
            self?.objects[id]?.size = frame.size
        }
        widget.onResizeEnded = syncObjectFrame
        widget.onAutoResize = syncObjectFrame

        widget.onCloseRequested = { [weak self] id in
            self?.remove(id: id)
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

    @discardableResult
    func addSuggestion(
        title: String,
        summary: String,
        html: String,
        at position: CGPoint,
        size: CGSize,
        animateOnPlace: Bool
    ) -> CanvasSuggestion {
        let suggestion = CanvasSuggestion(
            id: UUID(),
            title: title,
            summary: summary,
            html: html,
            position: position,
            size: size,
            animateOnPlace: animateOnPlace,
            createdAt: Date()
        )
        suggestions[suggestion.id] = suggestion
        return suggestion
    }

    func approveSuggestion(id: UUID) async -> CanvasObject? {
        guard let suggestion = suggestions.removeValue(forKey: id) else { return nil }
        return await place(
            html: suggestion.html,
            at: suggestion.position,
            size: suggestion.size,
            animated: suggestion.animateOnPlace
        )
    }

    func rejectSuggestion(id: UUID) -> Bool {
        suggestions.removeValue(forKey: id) != nil
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

    /// Called by canvas scroll/zoom delegate hooks to keep widget layout in sync with viewport updates.
    func notifyViewportChanged() {
        syncLayout()
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

    /// Captures the current visible canvas viewport as PNG data.
    func captureViewportPNGData() -> Data? {
        guard let canvasView, canvasView.bounds.width > 0, canvasView.bounds.height > 0 else {
            return nil
        }

        let renderer = UIGraphicsImageRenderer(bounds: canvasView.bounds)
        let image = renderer.image { _ in
            canvasView.drawHierarchy(in: canvasView.bounds, afterScreenUpdates: true)
        }
        return image.pngData()
    }
}
