import UIKit

@MainActor
class CanvasObjectManager: ObservableObject {
    @Published private(set) var objects: [UUID: CanvasObject] = [:]
    private(set) var objectViews: [UUID: CanvasObjectWebView] = [:]

    let httpServer = AgentHTTPServer()
    private weak var canvasView: NoteCanvasView?
    private weak var cursor: AgentCursorController?
    private var currentZoomScale: CGFloat = 1.0

    func attach(to canvas: NoteCanvasView, cursor: AgentCursorController) {
        self.canvasView = canvas
        self.cursor = cursor
        httpServer.start(objectManager: self)
    }

    /// Center of what the user is currently looking at, in canvas content coordinates.
    var viewportCenter: CGPoint {
        guard let cv = canvasView, cv.bounds.width > 0 else {
            return CanvasState.canvasCenter
        }
        let visibleW = cv.bounds.width / cv.zoomScale
        let visibleH = cv.bounds.height / cv.zoomScale
        return CGPoint(
            x: cv.contentOffset.x + visibleW / 2,
            y: cv.contentOffset.y + visibleH / 2
        )
    }

    // MARK: - Place object

    @discardableResult
    func place(html: String, at position: CGPoint, size: CGSize = CGSize(width: 320, height: 220), animated: Bool = true) async -> CanvasObject {
        let object = CanvasObject(position: position, size: size, htmlContent: html)

        guard let canvasView else { return object }

        // Cursor choreography (skip when not animated)
        if animated, let cursor {
            let screenPoint = canvasToScreenPoint(position, in: canvasView)
            cursor.appear(at: CGPoint(x: screenPoint.x - 60, y: screenPoint.y - 60))
            try? await Task.sleep(nanoseconds: 300_000_000)

            cursor.moveTo(screenPoint, duration: 0.5)
            try? await Task.sleep(nanoseconds: 450_000_000)

            cursor.click()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // Create and insert web view
        let webView = CanvasObjectWebView(id: object.id, size: size, htmlContent: html)
        webView.frame = CGRect(origin: position, size: size)

        if animated {
            webView.alpha = 0
            webView.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        }

        canvasView.addSubview(webView)

        objects[object.id] = object
        objectViews[object.id] = webView

        // Wire drag callback
        webView.onDragEnded = { [weak self] id, newOrigin in
            self?.objects[id]?.position = newOrigin
        }

        // Spring fade-in
        UIView.animate(withDuration: animated ? 0.45 : 0.15, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.8, options: []) {
            webView.alpha = 1
            webView.transform = .identity
        }

        webView.updateForZoomScale(currentZoomScale)

        // Cursor disappear after placement
        if animated {
            try? await Task.sleep(nanoseconds: 400_000_000)
            cursor?.disappear()
        }

        return object
    }

    // MARK: - Remove object

    func remove(id: UUID) {
        guard let webView = objectViews[id] else { return }

        UIView.animate(withDuration: 0.3, animations: {
            webView.alpha = 0
            webView.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        }, completion: { _ in
            webView.removeFromSuperview()
        })

        objects.removeValue(forKey: id)
        objectViews.removeValue(forKey: id)
    }

    // MARK: - Zoom

    func updateZoomScale(_ scale: CGFloat) {
        currentZoomScale = scale
        for (_, webView) in objectViews {
            webView.updateForZoomScale(scale)
        }
    }

    // MARK: - Cursor Control

    func cursorAppear(at point: CGPoint) {
        guard let canvasView, let cursor else { return }
        let screenPoint = canvasToScreenPoint(point, in: canvasView)
        cursor.appear(at: screenPoint)
    }

    func cursorMove(to point: CGPoint) {
        guard let canvasView, let cursor else { return }
        let screenPoint = canvasToScreenPoint(point, in: canvasView)
        cursor.moveTo(screenPoint)
    }

    func cursorClick() {
        cursor?.click()
    }

    func cursorDisappear() {
        cursor?.disappear()
    }

    // MARK: - Helpers

    private func canvasToScreenPoint(_ canvasPoint: CGPoint, in scrollView: UIScrollView) -> CGPoint {
        let x = (canvasPoint.x - scrollView.contentOffset.x) * scrollView.zoomScale
        let y = (canvasPoint.y - scrollView.contentOffset.y) * scrollView.zoomScale
        return CGPoint(x: x, y: y)
    }
}
