import Foundation
import PencilKit
import UIKit
import WebKit

struct CanvasCoordinateSnapshot: Codable {
    struct Point: Codable {
        let x: Double
        let y: Double
    }

    struct Size: Codable {
        let width: Double
        let height: Double
    }

    struct Rect: Codable {
        let x: Double
        let y: Double
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
    let mostRecentStrokeCenterAxis: Point?
    let mostRecentStrokeBoundsAxis: Rect?
    let mostRecentStrokeUpdatedAt: String?
}

struct CanvasSuggestion: Identifiable {
    let id: UUID
    let title: String
    let summary: String
    let html: String
    var position: CGPoint
    let size: CGSize
    let animateOnPlace: Bool
    let createdAt: Date
}

@MainActor
final class CanvasObjectManager: ObservableObject {
    @Published private(set) var objects: [UUID: CanvasObject] = [:]
    @Published private(set) var suggestions: [UUID: CanvasSuggestion] = [:]
    private(set) var objectViews: [UUID: CanvasObjectWebView] = [:]
    private(set) var imageViews: [UUID: UIImageView] = [:]
    var onWidgetRemoved: ((String) -> Void)?

    let httpServer = AgentHTTPServer.shared

    private weak var canvasView: NoteCanvasView?
    private weak var cursor: AgentCursorController?
    private var mostRecentStrokeBoundsCanvas: CGRect?
    private var mostRecentStrokeUpdatedAt: Date?

    func attach(to canvas: NoteCanvasView, cursor: AgentCursorController) {
        self.canvasView = canvas
        self.cursor = cursor
        httpServer.start(objectManager: self)
    }

    var viewportCenter: CGPoint {
        guard let cv = canvasView, cv.bounds.width > 0 else { return CanvasState.canvasCenter }
        let visibleW = cv.bounds.width / cv.zoomScale
        let visibleH = cv.bounds.height / cv.zoomScale
        let originX = cv.contentOffset.x + cv.adjustedContentInset.left
        let originY = cv.contentOffset.y + cv.adjustedContentInset.top
        return CGPoint(x: originX + visibleW / 2, y: originY + visibleH / 2)
    }

    var documentAxisOrigin: CGPoint { CanvasState.canvasCenter }

    func viewportCanvasRect() -> CGRect {
        guard let cv = canvasView, cv.bounds.width > 0, cv.bounds.height > 0 else {
            return CGRect(origin: documentAxisOrigin, size: .zero)
        }
        let visibleW = cv.bounds.width / cv.zoomScale
        let visibleH = cv.bounds.height / cv.zoomScale
        let originX = cv.contentOffset.x + cv.adjustedContentInset.left
        let originY = cv.contentOffset.y + cv.adjustedContentInset.top
        return CGRect(
            x: originX,
            y: originY,
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

    func canvasPoint(forScreenPoint p: CGPoint) -> CGPoint {
        guard let canvasView else { return p }
        return canvasView.canvasPoint(forScreenPoint: p)
    }

    func updateMostRecentStrokeBounds(_ boundsCanvas: CGRect?) {
        guard let boundsCanvas, boundsCanvas.width > 0, boundsCanvas.height > 0 else {
            return
        }
        mostRecentStrokeBoundsCanvas = boundsCanvas
        mostRecentStrokeUpdatedAt = Date()
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
        let strokeCenterAxis: CanvasCoordinateSnapshot.Point? = {
            guard let b = mostRecentStrokeBoundsCanvas else { return nil }
            let center = axisPoint(forCanvasPoint: CGPoint(x: b.midX, y: b.midY))
            return .init(x: center.x, y: center.y)
        }()
        let strokeBoundsAxis: CanvasCoordinateSnapshot.Rect? = {
            guard let b = mostRecentStrokeBoundsCanvas else { return nil }
            let topLeft = axisPoint(forCanvasPoint: b.origin)
            return .init(x: topLeft.x, y: topLeft.y, width: b.width, height: b.height)
        }()
        let strokeUpdatedAt = mostRecentStrokeUpdatedAt.map {
            ISO8601DateFormatter().string(from: $0)
        }
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
                zoomScale: 1,
                mostRecentStrokeCenterAxis: strokeCenterAxis,
                mostRecentStrokeBoundsAxis: strokeBoundsAxis,
                mostRecentStrokeUpdatedAt: strokeUpdatedAt
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
            zoomScale: cv.zoomScale,
            mostRecentStrokeCenterAxis: strokeCenterAxis,
            mostRecentStrokeBoundsAxis: strokeBoundsAxis,
            mostRecentStrokeUpdatedAt: strokeUpdatedAt
        )
    }

    @discardableResult
    func place(
        html: String,
        at position: CGPoint,
        size: CGSize = CGSize(width: 360, height: 220),
        backendWidgetID: String? = nil,
        animated: Bool = true
    ) async -> CanvasObject {
        let object = CanvasObject(
            position: position,
            size: size,
            htmlContent: html,
            backendWidgetID: backendWidgetID
        )
        guard let canvasView else { return object }

        if animated {
            let widgetCenterCanvas = CGPoint(
                x: position.x + (size.width * 0.5),
                y: position.y + (size.height * 0.5)
            )
            await cursorNavigateAndClick(to: widgetCenterCanvas)
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

    func approveSuggestion(
        id: UUID,
        preferredScreenCenter: CGPoint? = nil
    ) async -> CanvasObject? {
        guard let suggestion = suggestions.removeValue(forKey: id) else { return nil }
        let position: CGPoint = {
            guard let preferredScreenCenter else { return suggestion.position }
            let centerCanvas = canvasPoint(forScreenPoint: preferredScreenCenter)
            return CGPoint(
                x: centerCanvas.x - (suggestion.size.width * 0.5),
                y: centerCanvas.y - (suggestion.size.height * 0.5)
            )
        }()
        return await place(
            html: suggestion.html,
            at: position,
            size: suggestion.size,
            animated: suggestion.animateOnPlace
        )
    }

    func rejectSuggestion(id: UUID) -> Bool {
        suggestions.removeValue(forKey: id) != nil
    }

    func remove(id: UUID) {
        let backendID = objects[id]?.backendWidgetID

        if let imageView = imageViews[id] {
            UIView.animate(withDuration: 0.18, animations: {
                imageView.alpha = 0
                imageView.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
            }, completion: { _ in
                imageView.removeFromSuperview()
            })
            imageViews.removeValue(forKey: id)
            objects.removeValue(forKey: id)
            if let backendID, !backendID.isEmpty {
                onWidgetRemoved?(backendID)
            }
            return
        }

        guard let view = objectViews[id] else { return }
        UIView.animate(withDuration: 0.18, animations: {
            view.alpha = 0
            view.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }, completion: { _ in
            view.removeFromSuperview()
        })
        objectViews.removeValue(forKey: id)
        objects.removeValue(forKey: id)
        if let backendID, !backendID.isEmpty {
            onWidgetRemoved?(backendID)
        }
    }

    func removeAll() {
        let ids = Array(objects.keys)
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

    func translateContent(by delta: CGPoint) {
        guard delta != .zero else { return }

        for id in objects.keys {
            guard var object = objects[id] else { continue }
            object.position.x += delta.x
            object.position.y += delta.y
            objects[id] = object
        }

        for id in suggestions.keys {
            guard var suggestion = suggestions[id] else { continue }
            suggestion.position.x += delta.x
            suggestion.position.y += delta.y
            suggestions[id] = suggestion
        }

        if let bounds = mostRecentStrokeBoundsCanvas {
            mostRecentStrokeBoundsCanvas = bounds.offsetBy(dx: delta.x, dy: delta.y)
        }

        syncLayout()
    }

    func syncLayout() {
        for (id, object) in objects {
            let next = CGRect(origin: object.position, size: object.size)
            if let view = objectViews[id] {
                if view.frame != next { view.frame = next }
            } else if let view = imageViews[id] {
                if view.frame != next { view.frame = next }
            }
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

    /// Moves the cursor to a canvas-space target, clicks, then returns.
    /// If the cursor is already visible it glides from its current position;
    /// otherwise it appears at a slight offset first.
    func cursorNavigateAndClick(to canvasPoint: CGPoint) async {
        guard let canvasView, let cursor else { return }

        let targetScreen = canvasView.screenPoint(forCanvasPoint: canvasPoint)

        if cursor.isVisible {
            // Glide from wherever the cursor currently is
            cursor.moveTo(targetScreen, duration: 0.28)
            try? await Task.sleep(nanoseconds: 300_000_000)
        } else {
            // Appear near target, then glide in
            let startScreen = CGPoint(
                x: targetScreen.x - 48,
                y: targetScreen.y - 56
            )
            cursor.appear(at: startScreen)
            try? await Task.sleep(nanoseconds: 140_000_000)
            cursor.moveTo(targetScreen, duration: 0.24)
            try? await Task.sleep(nanoseconds: 260_000_000)
        }

        cursor.click()
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

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

    // MARK: - SVG Image Placement

    /// Renders an SVG string to a rasterized UIImage and places it on the canvas instantly.
    @discardableResult
    func placeSVGImage(
        svg: String,
        at position: CGPoint,
        scale: CGFloat = 1.0,
        background: UIColor? = nil
    ) async -> (id: UUID, size: CGSize)? {
        guard let canvasView else { return nil }

        let naturalSize = extractSVGSize(from: svg)
        let scaledSize = CGSize(
            width: naturalSize.width * scale,
            height: naturalSize.height * scale
        )

        guard let image = await renderSVGToImage(svg: svg, size: scaledSize, background: background) else {
            return nil
        }

        // Cursor navigates to image center, clicks, then image appears
        let imageCenter = CGPoint(
            x: position.x + scaledSize.width * 0.5,
            y: position.y + scaledSize.height * 0.5
        )
        await cursorNavigateAndClick(to: imageCenter)

        let id = UUID()
        let imageView = UIImageView(image: image)
        imageView.frame = CGRect(origin: position, size: scaledSize)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true

        canvasView.widgetContainerView().addSubview(imageView)

        // Pop in
        imageView.alpha = 0
        imageView.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
            imageView.alpha = 1
            imageView.transform = .identity
        }
        try? await Task.sleep(nanoseconds: 180_000_000)
        cursor?.disappear()

        let object = CanvasObject(
            id: id,
            position: position,
            size: scaledSize,
            htmlContent: ""
        )
        objects[id] = object
        imageViews[id] = imageView

        return (id, scaledSize)
    }

    private func extractSVGSize(from svg: String) -> CGSize {
        // Try viewBox="minX minY width height"
        if let regex = try? NSRegularExpression(pattern: #"viewBox\s*=\s*"([^"]+)""#),
           let match = regex.firstMatch(in: svg, range: NSRange(svg.startIndex..., in: svg)),
           match.numberOfRanges >= 2,
           let range = Range(match.range(at: 1), in: svg) {
            let parts = svg[range].split { $0.isWhitespace || $0 == "," }
                .compactMap { Double($0) }
            if parts.count >= 4 {
                return CGSize(width: parts[2], height: parts[3])
            }
        }

        // Try width/height attributes on the <svg> tag
        var w: Double = 400, h: Double = 300
        if let regex = try? NSRegularExpression(pattern: #"<svg[^>]*?\bwidth\s*=\s*"([^"]+)""#),
           let match = regex.firstMatch(in: svg, range: NSRange(svg.startIndex..., in: svg)),
           match.numberOfRanges >= 2,
           let range = Range(match.range(at: 1), in: svg),
           let val = Double(svg[range].replacingOccurrences(of: "px", with: "")) {
            w = val
        }
        if let regex = try? NSRegularExpression(pattern: #"<svg[^>]*?\bheight\s*=\s*"([^"]+)""#),
           let match = regex.firstMatch(in: svg, range: NSRange(svg.startIndex..., in: svg)),
           match.numberOfRanges >= 2,
           let range = Range(match.range(at: 1), in: svg),
           let val = Double(svg[range].replacingOccurrences(of: "px", with: "")) {
            h = val
        }
        return CGSize(width: w, height: h)
    }

    private func renderSVGToImage(svg: String, size: CGSize, background: UIColor?) async -> UIImage? {
        guard let canvasView else { return nil }

        let webView = WKWebView(frame: CGRect(origin: .zero, size: size))
        webView.isOpaque = background != nil
        webView.backgroundColor = background ?? .clear
        webView.scrollView.backgroundColor = background ?? .clear
        webView.alpha = 0 // hidden during render

        // Must be in view hierarchy for reliable snapshot
        canvasView.addSubview(webView)
        defer { webView.removeFromSuperview() }

        let bgCSS: String
        if let bg = background {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            bg.getRed(&r, green: &g, blue: &b, alpha: &a)
            bgCSS = "rgba(\(Int(r*255)),\(Int(g*255)),\(Int(b*255)),\(a))"
        } else {
            bgCSS = "transparent"
        }

        let html = """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=\(Int(size.width)),initial-scale=1.0">
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        html,body{width:\(Int(size.width))px;height:\(Int(size.height))px;background:\(bgCSS);overflow:hidden}
        body{display:flex;align-items:center;justify-content:center}
        svg{max-width:100%;max-height:100%;display:block}
        </style></head><body>\(svg)</body></html>
        """

        webView.loadHTMLString(html, baseURL: nil)

        // Poll for load completion (up to 3 seconds)
        var loaded = false
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let state = try? await webView.evaluateJavaScript("document.readyState") as? String,
               state == "complete" {
                loaded = true
                try? await Task.sleep(nanoseconds: 100_000_000) // extra time for SVG paint
                break
            }
        }
        guard loaded else { return nil }

        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = webView.bounds
        return try? await webView.takeSnapshot(configuration: snapshotConfig)
    }
}
