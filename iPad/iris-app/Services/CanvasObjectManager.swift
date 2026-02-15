import Foundation
import CoreText
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

struct HandwrittenInkResult {
    let strokes: [PKStroke]
    let size: CGSize
}

enum HandwrittenInkRenderer {

    static func measure(text: String, fontSize: CGFloat) -> CGSize {
        let font = UIFont(name: "BradleyHandITCTT-Bold", size: fontSize)
            ?? UIFont.italicSystemFont(ofSize: fontSize)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        let lineHeight = font.lineHeight * 1.2
        return CGSize(width: width, height: lineHeight)
    }

    static func render(
        text: String,
        origin: CGPoint,
        maxWidth: CGFloat,
        color: UIColor,
        fontSize: CGFloat = 30,
        strokeWidth: CGFloat = 2.2
    ) -> HandwrittenInkResult {
        let normalized = normalize(text)
        guard !normalized.isEmpty else {
            return HandwrittenInkResult(strokes: [], size: .zero)
        }

        let font = UIFont(name: "BradleyHandITCTT-Bold", size: fontSize)
            ?? UIFont.italicSystemFont(ofSize: fontSize)
        let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        let lines = wrap(normalized, font: font, maxWidth: max(120, maxWidth))

        let ink = PKInk(.pen, color: color)
        let lineHeight = font.lineHeight * 1.2
        let baselineStart = origin.y + font.ascender
        let maxLineWidth = lines.reduce(CGFloat.zero) { partial, line in
            max(partial, (line as NSString).size(withAttributes: [.font: font]).width)
        }

        var strokes: [PKStroke] = []
        for (lineIndex, line) in lines.enumerated() {
            let baselineY = baselineStart + (CGFloat(lineIndex) * lineHeight)
            let outlines = glyphOutlines(for: line, ctFont: ctFont, origin: CGPoint(x: origin.x, y: baselineY))
            for contour in outlines where contour.count >= 2 {
                let points = contour.enumerated().map { idx, point in
                    let jitter = handwritingJitter(index: idx)
                    return PKStrokePoint(
                        location: CGPoint(x: point.x + jitter.x, y: point.y + jitter.y),
                        timeOffset: TimeInterval(idx) / 90.0,
                        size: CGSize(width: strokeWidth, height: strokeWidth),
                        opacity: 1,
                        force: 1,
                        azimuth: 0,
                        altitude: .pi / 2
                    )
                }
                let path = PKStrokePath(controlPoints: points, creationDate: Date())
                strokes.append(PKStroke(ink: ink, path: path))
            }
        }

        let height = max(lineHeight, CGFloat(lines.count) * lineHeight)
        let size = CGSize(width: min(maxWidth, maxLineWidth), height: height)
        return HandwrittenInkResult(strokes: strokes, size: size)
    }

    private static func wrap(_ text: String, font: UIFont, maxWidth: CGFloat) -> [String] {
        var wrapped: [String] = []

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if wrapped.last != "" { wrapped.append("") }
                continue
            }

            var current = ""
            for word in line.split(separator: " ") {
                let token = String(word)
                let candidate = current.isEmpty ? token : "\(current) \(token)"
                let width = (candidate as NSString).size(withAttributes: [.font: font]).width
                if width <= maxWidth || current.isEmpty {
                    current = candidate
                } else {
                    wrapped.append(current)
                    current = token
                }
            }

            if !current.isEmpty {
                wrapped.append(current)
            }
        }

        if wrapped.isEmpty {
            return [text]
        }
        return wrapped
    }

    private static func glyphOutlines(for line: String, ctFont: CTFont, origin: CGPoint) -> [[CGPoint]] {
        let chars = Array(line.utf16)
        guard !chars.isEmpty else { return [] }

        var glyphs = Array(repeating: CGGlyph(), count: chars.count)
        let mapped = CTFontGetGlyphsForCharacters(ctFont, chars, &glyphs, chars.count)
        guard mapped else { return [] }

        var advances = Array(repeating: CGSize.zero, count: chars.count)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, glyphs.count)

        var contours: [[CGPoint]] = []
        var cursorX: CGFloat = 0

        for idx in glyphs.indices {
            let glyph = glyphs[idx]
            defer { cursorX += advances[idx].width }
            guard glyph != 0, let path = CTFontCreatePathForGlyph(ctFont, glyph, nil) else { continue }

            var transform = CGAffineTransform(translationX: origin.x + cursorX, y: origin.y)
            transform = transform.scaledBy(x: 1, y: -1)
            guard let transformed = path.copy(using: &transform) else { continue }

            contours.append(contentsOf: flatten(transformed))
        }

        return contours
    }

    private static func flatten(_ path: CGPath) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        var currentPoint = CGPoint.zero
        var subpathStart = CGPoint.zero

        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                if current.count >= 2 { result.append(current) }
                let p = element.points[0]
                current = [p]
                currentPoint = p
                subpathStart = p

            case .addLineToPoint:
                let p = element.points[0]
                current.append(p)
                currentPoint = p

            case .addQuadCurveToPoint:
                let c = element.points[0]
                let end = element.points[1]
                current.append(contentsOf: sampleQuad(from: currentPoint, control: c, to: end, steps: 8))
                currentPoint = end

            case .addCurveToPoint:
                let c1 = element.points[0]
                let c2 = element.points[1]
                let end = element.points[2]
                current.append(contentsOf: sampleCubic(from: currentPoint, c1: c1, c2: c2, to: end, steps: 10))
                currentPoint = end

            case .closeSubpath:
                current.append(subpathStart)
                if current.count >= 2 { result.append(current) }
                current = []
                currentPoint = subpathStart

            @unknown default:
                break
            }
        }

        if current.count >= 2 {
            result.append(current)
        }

        return result
    }

    private static func sampleQuad(from p0: CGPoint, control p1: CGPoint, to p2: CGPoint, steps: Int) -> [CGPoint] {
        guard steps > 0 else { return [p2] }
        return (1...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps)
            let mt = 1 - t
            let x = (mt * mt * p0.x) + (2 * mt * t * p1.x) + (t * t * p2.x)
            let y = (mt * mt * p0.y) + (2 * mt * t * p1.y) + (t * t * p2.y)
            return CGPoint(x: x, y: y)
        }
    }

    private static func sampleCubic(from p0: CGPoint, c1: CGPoint, c2: CGPoint, to p3: CGPoint, steps: Int) -> [CGPoint] {
        guard steps > 0 else { return [p3] }
        return (1...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps)
            let mt = 1 - t
            let x = (mt * mt * mt * p0.x)
                + (3 * mt * mt * t * c1.x)
                + (3 * mt * t * t * c2.x)
                + (t * t * t * p3.x)
            let y = (mt * mt * mt * p0.y)
                + (3 * mt * mt * t * c1.y)
                + (3 * mt * t * t * c2.y)
                + (t * t * t * p3.y)
            return CGPoint(x: x, y: y)
        }
    }

    private static func handwritingJitter(index: Int) -> CGPoint {
        let t = CGFloat(index)
        return CGPoint(
            x: sin(t * 0.43) * 0.18,
            y: cos(t * 0.37) * 0.14
        )
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
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
    @Published var isAnimatingDraw: Bool = false
    private(set) var objectViews: [UUID: CanvasObjectWebView] = [:]
    private(set) var imageViews: [UUID: UIImageView] = [:]
    var onWidgetRemoved: ((String) -> Void)?

    let httpServer = AgentHTTPServer.shared

    private weak var canvasView: NoteCanvasView?
    private var mostRecentStrokeBoundsCanvas: CGRect?
    private var mostRecentStrokeUpdatedAt: Date?

    func attach(to canvas: NoteCanvasView) {
        self.canvasView = canvas
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
        _ = point
    }

    func cursorMove(to point: CGPoint) {
        _ = point
    }

    func cursorClick() {}
    func cursorDisappear() {}

    /// Moves the cursor to a canvas-space target, clicks, then returns.
    /// If the cursor is already visible it glides from its current position;
    /// otherwise it appears at a slight offset first.
    func cursorNavigateAndClick(to canvasPoint: CGPoint) async {
        _ = canvasPoint
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

    @discardableResult
    func drawHandwrittenText(
        _ text: String,
        at position: CGPoint,
        maxWidth: CGFloat = 420,
        color: UIColor = UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1),
        fontSize: CGFloat = 30,
        strokeWidth: CGFloat = 2.2
    ) async -> CGSize {
        guard let canvasView else { return .zero }

        let result = HandwrittenInkRenderer.render(
            text: text,
            origin: position,
            maxWidth: maxWidth,
            color: color,
            fontSize: fontSize,
            strokeWidth: strokeWidth
        )
        guard !result.strokes.isEmpty else { return .zero }

        var drawing = canvasView.drawing
        for stroke in result.strokes {
            drawing.strokes.append(stroke)
        }
        canvasView.drawing = drawing

        if let recentStroke = drawing.strokes.last {
            updateMostRecentStrokeBounds(recentStroke.renderBounds)
        }

        return result.size
    }

    @discardableResult
    func drawHandwrittenTextStreaming(
        _ text: String,
        at position: CGPoint,
        maxWidth: CGFloat = 420,
        color: UIColor = UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1),
        wordsPerBatch: Int = 2
    ) async -> CGSize {
        guard let canvasView else { return .zero }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .zero }

        let font = UIFont(name: "BradleyHandITCTT-Bold", size: 30)
            ?? UIFont.italicSystemFont(ofSize: 30)
        let lineHeight = font.lineHeight * 1.2
        let normalizedMaxWidth = max(140, maxWidth)
        let lines = streamingWrappedLines(trimmed, font: font, maxWidth: normalizedMaxWidth)
        guard !lines.isEmpty else { return .zero }

        var drawing = canvasView.drawing
        var cursorY = position.y
        var maxLineWidth: CGFloat = 0
        let batchSize = max(1, wordsPerBatch)

        for lineWords in lines {
            if lineWords.isEmpty {
                cursorY += lineHeight
                continue
            }

            var lineX = position.x
            for start in stride(from: 0, to: lineWords.count, by: batchSize) {
                let end = min(start + batchSize, lineWords.count)
                let segmentWords = Array(lineWords[start..<end])
                var segment = segmentWords.joined(separator: " ")
                if end < lineWords.count {
                    segment += " "
                }

                let rendered = HandwrittenInkRenderer.render(
                    text: segment,
                    origin: CGPoint(x: lineX, y: cursorY),
                    maxWidth: max(120, normalizedMaxWidth - (lineX - position.x)),
                    color: color
                )

                if !rendered.strokes.isEmpty {
                    for stroke in rendered.strokes {
                        drawing.strokes.append(stroke)
                    }
                    canvasView.drawing = drawing
                    if let recentStroke = drawing.strokes.last {
                        updateMostRecentStrokeBounds(recentStroke.renderBounds)
                    }
                }

                lineX += (segment as NSString).size(withAttributes: [.font: font]).width
                maxLineWidth = max(maxLineWidth, lineX - position.x)
                try? await Task.sleep(nanoseconds: 35_000_000)
            }

            cursorY += lineHeight
        }
        return CGSize(
            width: min(normalizedMaxWidth, maxLineWidth),
            height: max(lineHeight, cursorY - position.y)
        )
    }

    private func streamingWrappedLines(_ text: String, font: UIFont, maxWidth: CGFloat) -> [[String]] {
        var output: [[String]] = []
        let rawLines = text.components(separatedBy: .newlines)
        for raw in rawLines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                output.append([])
                continue
            }
            var currentWords: [String] = []
            var currentText = ""
            for token in line.split(separator: " ") {
                let word = String(token)
                let candidate = currentText.isEmpty ? word : "\(currentText) \(word)"
                let width = (candidate as NSString).size(withAttributes: [.font: font]).width
                if width <= maxWidth || currentWords.isEmpty {
                    currentWords.append(word)
                    currentText = candidate
                } else {
                    output.append(currentWords)
                    currentWords = [word]
                    currentText = word
                }
            }
            if !currentWords.isEmpty {
                output.append(currentWords)
            }
        }
        return output
    }

    func drawHandwrittenLaTeX(
        _ latex: String,
        at position: CGPoint,
        maxWidth: CGFloat = 420,
        color: UIColor = .black
    ) async -> CGSize {
        guard let canvasView else { return .zero }

        let source = sanitizeLaTeXSource(latex)
        let root = parseLaTeXExpression(source)
        let rendered = renderLaTeXNode(
            root,
            at: position,
            maxWidth: maxWidth,
            color: color,
            fontSize: 34,
            strokeWidth: 3.2
        )

        guard !rendered.strokes.isEmpty else {
            return await drawHandwrittenText(
                latex,
                at: position,
                maxWidth: maxWidth,
                color: color,
                fontSize: 34,
                strokeWidth: 3.0
            )
        }

        var drawing = canvasView.drawing
        for stroke in rendered.strokes { drawing.strokes.append(stroke) }
        canvasView.drawing = drawing

        if let recentStroke = drawing.strokes.last {
            updateMostRecentStrokeBounds(recentStroke.renderBounds)
        }

        return rendered.size
    }

    private indirect enum LaTeXNode {
        case text(String)
        case symbol(Character)
        case sequence([LaTeXNode])
        case fraction(numerator: LaTeXNode, denominator: LaTeXNode)
        case sqrt(index: LaTeXNode?, radicand: LaTeXNode)
        case script(base: LaTeXNode, sub: LaTeXNode?, sup: LaTeXNode?)
        case operatorSymbol(symbol: String, sub: LaTeXNode?, sup: LaTeXNode?)
    }

    private struct LaTeXRenderResult {
        let strokes: [PKStroke]
        let size: CGSize
        let baseline: CGFloat
    }

    private struct LaTeXMetrics {
        let size: CGSize
        let baseline: CGFloat
    }

    private func sanitizeLaTeXSource(_ raw: String) -> String {
        let normalizedEscapes = raw.replacingOccurrences(
            of: #"\\\\([A-Za-z])"#,
            with: #"\\$1"#,
            options: .regularExpression
        )
        return normalizedEscapes
            .replacingOccurrences(of: #"\\begin\{[^}]+\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\\end\{[^}]+\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\\displaystyle"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\\textstyle"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\\\\\s*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "$$", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "\\(", with: "")
            .replacingOccurrences(of: "\\)", with: "")
            .replacingOccurrences(of: "\\[", with: "")
            .replacingOccurrences(of: "\\]", with: "")
            .replacingOccurrences(of: "\\left", with: "")
            .replacingOccurrences(of: "\\right", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseLaTeXExpression(_ source: String) -> LaTeXNode {
        guard !source.isEmpty else { return .text("") }
        var index = source.startIndex
        let nodes = parseLaTeXSequence(in: source, index: &index, stopAt: nil)
        return collapseLaTeXNodes(nodes)
    }

    private func parseLaTeXSequence(
        in source: String,
        index: inout String.Index,
        stopAt stopChar: Character?
    ) -> [LaTeXNode] {
        var nodes: [LaTeXNode] = []
        var buffer = ""

        func flushBuffer() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                nodes.append(.text(trimmed))
            }
            buffer.removeAll(keepingCapacity: true)
        }

        while index < source.endIndex {
            let ch = source[index]
            if let stopChar, ch == stopChar {
                break
            }

            if ch == "\\" {
                if latexHasPrefix(source, at: index, token: "\\frac")
                    || latexHasPrefix(source, at: index, token: "\\dfrac") {
                    flushBuffer()
                    let token = latexHasPrefix(source, at: index, token: "\\dfrac") ? "\\dfrac" : "\\frac"
                    index = source.index(index, offsetBy: token.count)
                    skipLaTeXWhitespace(in: source, index: &index)
                    let numerator = parseLaTeXGroupOrToken(in: source, index: &index)
                    skipLaTeXWhitespace(in: source, index: &index)
                    let denominator = parseLaTeXGroupOrToken(in: source, index: &index)
                    nodes.append(.fraction(numerator: numerator, denominator: denominator))
                    continue
                }

                if latexHasPrefix(source, at: index, token: "\\sqrt") {
                    flushBuffer()
                    index = source.index(index, offsetBy: "\\sqrt".count)
                    skipLaTeXWhitespace(in: source, index: &index)
                    var rootIndex: LaTeXNode?
                    if index < source.endIndex, source[index] == "[" {
                        let idxRaw = consumeBracketGroup(in: source, index: &index, open: "[", close: "]")
                        rootIndex = parseLaTeXExpression(idxRaw)
                        skipLaTeXWhitespace(in: source, index: &index)
                    }
                    let radicand = parseLaTeXGroupOrToken(in: source, index: &index)
                    nodes.append(.sqrt(index: rootIndex, radicand: radicand))
                    continue
                }

                if let operatorSymbol = parseLargeOperatorToken(in: source, index: &index) {
                    flushBuffer()
                    let (sub, sup) = parseOptionalScripts(in: source, index: &index)
                    nodes.append(.operatorSymbol(symbol: operatorSymbol, sub: sub, sup: sup))
                    continue
                }

                if latexHasPrefix(source, at: index, token: "\\pm") {
                    flushBuffer()
                    index = source.index(index, offsetBy: "\\pm".count)
                    nodes.append(.symbol("±"))
                    continue
                }

                if latexHasPrefix(source, at: index, token: "\\over") {
                    flushBuffer()
                    index = source.index(index, offsetBy: "\\over".count)
                    skipLaTeXWhitespace(in: source, index: &index)
                    let numerator = collapseLaTeXNodes(nodes)
                    nodes.removeAll(keepingCapacity: true)
                    let denominatorNodes = parseLaTeXSequence(in: source, index: &index, stopAt: stopChar)
                    let denominator = collapseLaTeXNodes(denominatorNodes)
                    nodes.append(.fraction(numerator: numerator, denominator: denominator))
                    return nodes
                }
            }

            if ch == "{" {
                flushBuffer()
                index = source.index(after: index)
                let inner = parseLaTeXSequence(in: source, index: &index, stopAt: "}")
                if index < source.endIndex, source[index] == "}" {
                    index = source.index(after: index)
                }
                nodes.append(collapseLaTeXNodes(inner))
                continue
            }

            if ch == "^" || ch == "_" {
                flushBuffer()
                let marker = ch
                index = source.index(after: index)
                let script = parseLaTeXGroupOrToken(in: source, index: &index)
                if let last = nodes.popLast() {
                    nodes.append(applyScript(base: last, marker: marker, script: script))
                } else {
                    // No explicit base: keep as literal fallback.
                    let literal = marker == "^" ? "^" : "_"
                    nodes.append(.text(literal))
                }
                continue
            }

            if ch == "+" || ch == "-" || ch == "=" || ch == "±" {
                flushBuffer()
                nodes.append(.symbol(ch))
                index = source.index(after: index)
                continue
            }

            if ch == "}" {
                break
            }

            buffer.append(ch)
            index = source.index(after: index)
        }

        flushBuffer()
        return nodes
    }

    private func parseLaTeXGroupOrToken(
        in source: String,
        index: inout String.Index
    ) -> LaTeXNode {
        skipLaTeXWhitespace(in: source, index: &index)
        guard index < source.endIndex else { return .text("") }

        if source[index] == "{" {
            index = source.index(after: index)
            let inner = parseLaTeXSequence(in: source, index: &index, stopAt: "}")
            if index < source.endIndex, source[index] == "}" {
                index = source.index(after: index)
            }
            return collapseLaTeXNodes(inner)
        }

        if source[index] == "\\" {
            let token = consumeCommandToken(in: source, index: &index)
            return .text(token)
        }

        let char = source[index]
        index = source.index(after: index)
        return .text(String(char))
    }

    private func parseOptionalScripts(
        in source: String,
        index: inout String.Index
    ) -> (sub: LaTeXNode?, sup: LaTeXNode?) {
        var sub: LaTeXNode?
        var sup: LaTeXNode?
        while index < source.endIndex {
            skipLaTeXWhitespace(in: source, index: &index)
            guard index < source.endIndex else { break }
            let ch = source[index]
            if ch == "_" {
                index = source.index(after: index)
                sub = parseLaTeXGroupOrToken(in: source, index: &index)
                continue
            }
            if ch == "^" {
                index = source.index(after: index)
                sup = parseLaTeXGroupOrToken(in: source, index: &index)
                continue
            }
            break
        }
        return (sub, sup)
    }

    private func parseLargeOperatorToken(
        in source: String,
        index: inout String.Index
    ) -> String? {
        let table: [(token: String, symbol: String)] = [
            ("\\sum", "∑"),
            ("\\prod", "∏"),
            ("\\coprod", "∐"),
            ("\\int", "∫"),
            ("\\oint", "∮"),
            ("\\bigcap", "⋂"),
            ("\\bigcup", "⋃")
        ]
        for entry in table {
            if latexHasPrefix(source, at: index, token: entry.token) {
                index = source.index(index, offsetBy: entry.token.count)
                return entry.symbol
            }
        }
        return nil
    }

    private func applyScript(
        base: LaTeXNode,
        marker: Character,
        script: LaTeXNode
    ) -> LaTeXNode {
        switch base {
        case .script(let innerBase, let sub, let sup):
            if marker == "^" {
                return .script(base: innerBase, sub: sub, sup: script)
            }
            return .script(base: innerBase, sub: script, sup: sup)
        case .operatorSymbol(let symbol, let sub, let sup):
            if marker == "^" {
                return .operatorSymbol(symbol: symbol, sub: sub, sup: script)
            }
            return .operatorSymbol(symbol: symbol, sub: script, sup: sup)
        default:
            if marker == "^" {
                return .script(base: base, sub: nil, sup: script)
            }
            return .script(base: base, sub: script, sup: nil)
        }
    }

    private func consumeCommandToken(
        in source: String,
        index: inout String.Index
    ) -> String {
        guard index < source.endIndex, source[index] == "\\" else { return "" }
        let start = index
        index = source.index(after: index)
        while index < source.endIndex, source[index].isLetter {
            index = source.index(after: index)
        }
        if index == source.index(after: start), index < source.endIndex {
            index = source.index(after: index)
        }
        return String(source[start..<index])
    }

    private func consumeBracketGroup(
        in source: String,
        index: inout String.Index,
        open: Character,
        close: Character
    ) -> String {
        guard index < source.endIndex, source[index] == open else { return "" }
        index = source.index(after: index)
        var depth = 1
        var result = ""
        while index < source.endIndex {
            let ch = source[index]
            if ch == open {
                depth += 1
                result.append(ch)
            } else if ch == close {
                depth -= 1
                if depth == 0 {
                    index = source.index(after: index)
                    continue
                }
                result.append(ch)
            } else {
                result.append(ch)
            }
            index = source.index(after: index)
        }
        return result
    }

    private func collapseLaTeXNodes(_ nodes: [LaTeXNode]) -> LaTeXNode {
        let compact = nodes.filter { node in
            if case .text(let text) = node {
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
        if compact.isEmpty { return .text("") }
        if compact.count == 1 { return compact[0] }
        return .sequence(compact)
    }

    private func latexHasPrefix(_ source: String, at index: String.Index, token: String) -> Bool {
        source[index...].hasPrefix(token)
    }

    private func skipLaTeXWhitespace(
        in source: String,
        index: inout String.Index
    ) {
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
    }

    private func renderLaTeXNode(
        _ node: LaTeXNode,
        at origin: CGPoint,
        maxWidth: CGFloat,
        color: UIColor,
        fontSize: CGFloat,
        strokeWidth: CGFloat
    ) -> LaTeXRenderResult {
        switch node {
        case .text(let raw):
            let text = normalizeLaTeXText(raw)
            guard !text.isEmpty else { return LaTeXRenderResult(strokes: [], size: .zero, baseline: 0) }
            let rendered = HandwrittenInkRenderer.render(
                text: text,
                origin: origin,
                maxWidth: maxWidth,
                color: color,
                fontSize: fontSize,
                strokeWidth: strokeWidth
            )
            let baseline = max(1, rendered.size.height * 0.78)
            return LaTeXRenderResult(strokes: rendered.strokes, size: rendered.size, baseline: baseline)

        case .symbol(let symbol):
            let rendered = renderMathSymbol(
                symbol,
                at: origin,
                color: color,
                fontSize: fontSize,
                strokeWidth: strokeWidth
            )
            return rendered

        case .sequence(let children):
            let childMetrics = children.map { measureLaTeXMetrics($0, fontSize: fontSize) }
            let maxAscent = childMetrics.map(\.baseline).max() ?? 0
            let maxDescent = childMetrics.map { $0.size.height - $0.baseline }.max() ?? 0
            var x = origin.x
            var all: [PKStroke] = []
            var renderedCount = 0

            for (idx, child) in children.enumerated() {
                let metrics = childMetrics[idx]
                let remaining = max(100, maxWidth - (x - origin.x))
                let childY = origin.y + max(0, maxAscent - metrics.baseline)
                let childResult = renderLaTeXNode(
                    child,
                    at: CGPoint(x: x, y: childY),
                    maxWidth: remaining,
                    color: color,
                    fontSize: fontSize,
                    strokeWidth: strokeWidth
                )
                guard childResult.size.width > 0 || childResult.size.height > 0 else { continue }
                all.append(contentsOf: childResult.strokes)
                x += childResult.size.width + latexNodeSpacing(for: child, fontSize: fontSize)
                renderedCount += 1
            }

            if renderedCount > 0 {
                x -= latexNodeSpacing(for: children.last ?? .text(""), fontSize: fontSize)
            }

            return LaTeXRenderResult(
                strokes: all,
                size: CGSize(width: max(1, x - origin.x), height: max(1, maxAscent + maxDescent)),
                baseline: max(1, maxAscent)
            )

        case .fraction(let numerator, let denominator):
            let childFont = max(20, fontSize * 0.84)
            let childStroke = max(2.8, strokeWidth * 1.0)
            let numMeasure = measureLaTeXMetrics(numerator, fontSize: childFont)
            let denMeasure = measureLaTeXMetrics(denominator, fontSize: childFont)
            let rawWidth = max(numMeasure.size.width, denMeasure.size.width) + 28
            let fracWidth = max(44, min(maxWidth, rawWidth))
            let numX = origin.x + max(0, (fracWidth - numMeasure.size.width) * 0.5)
            let denX = origin.x + max(0, (fracWidth - denMeasure.size.width) * 0.5)
            let numY = origin.y
            let barY = numY + max(numMeasure.size.height, childFont) + 7.5
            let denY = barY + 9

            let numeratorRendered = renderLaTeXNode(
                numerator,
                at: CGPoint(x: numX, y: numY),
                maxWidth: fracWidth - 8,
                color: color,
                fontSize: childFont,
                strokeWidth: childStroke
            )
            let denominatorRendered = renderLaTeXNode(
                denominator,
                at: CGPoint(x: denX, y: denY),
                maxWidth: fracWidth - 8,
                color: color,
                fontSize: childFont,
                strokeWidth: childStroke
            )

            var strokes = numeratorRendered.strokes
            strokes.append(contentsOf: denominatorRendered.strokes)
            strokes.append(
                makeLineStroke(
                    from: CGPoint(x: origin.x + 2, y: barY),
                    to: CGPoint(x: origin.x + fracWidth - 2, y: barY),
                    color: color,
                    width: max(2.95, strokeWidth * 1.06)
                )
            )

            let totalHeight = (denY - origin.y) + max(denominatorRendered.size.height, denMeasure.size.height)
            return LaTeXRenderResult(
                strokes: strokes,
                size: CGSize(width: fracWidth, height: max(1, totalHeight)),
                baseline: max(1, barY - origin.y + 2)
            )

        case .sqrt(let rootIndex, let radicand):
            let childFont = max(20, fontSize * 0.92)
            let childStroke = max(2.8, strokeWidth * 1.0)
            let radMeasure = measureLaTeXMetrics(radicand, fontSize: childFont)

            let rootPrefix = max(30, fontSize * 0.86)
            let radX = origin.x + rootPrefix
            let radY = origin.y + max(8, fontSize * 0.16)
            let indexFont = max(12, fontSize * 0.45)

            let radRendered = renderLaTeXNode(
                radicand,
                at: CGPoint(x: radX, y: radY),
                maxWidth: max(100, maxWidth - rootPrefix),
                color: color,
                fontSize: childFont,
                strokeWidth: childStroke
            )

            let overbarY = radY + max(1.5, childFont * 0.045)
            let overbarStartX = origin.x + rootPrefix - 6
            let radWidth = max(radMeasure.size.width, radRendered.size.width)
            let overbarEndX = overbarStartX + max(18, radWidth + 20)

            var strokes = radRendered.strokes
            var indexWidth: CGFloat = 0
            var indexHeight: CGFloat = 0
            if let rootIndex {
                let indexResult = renderLaTeXNode(
                    rootIndex,
                    at: CGPoint(x: origin.x - 2, y: origin.y - indexFont * 0.15),
                    maxWidth: 60,
                    color: color,
                    fontSize: indexFont,
                    strokeWidth: max(2.35, strokeWidth * 0.84)
                )
                strokes.append(contentsOf: indexResult.strokes)
                indexWidth = indexResult.size.width
                indexHeight = indexResult.size.height
            }
            let radicalPoints = [
                CGPoint(x: origin.x + 2, y: overbarY + 14),
                CGPoint(x: origin.x + 10, y: overbarY + 21),
                CGPoint(x: origin.x + 18, y: overbarY + 4),
                CGPoint(x: overbarStartX, y: overbarY)
            ]
            strokes.append(
                makePolylineStroke(
                    points: radicalPoints,
                    color: color,
                    width: max(3.0, strokeWidth * 1.08)
                )
            )
            strokes.append(
                makeLineStroke(
                    from: CGPoint(x: overbarStartX, y: overbarY),
                    to: CGPoint(x: overbarEndX, y: overbarY),
                    color: color,
                    width: max(3.0, strokeWidth * 1.08)
                )
            )

            let totalWidth = max(1, max((overbarEndX - origin.x) + 2, rootPrefix + radWidth + indexWidth * 0.2))
            let totalHeight = max(
                radY - origin.y + max(radRendered.size.height, radMeasure.size.height),
                fontSize + 18 + (indexHeight * 0.1)
            )
            return LaTeXRenderResult(
                strokes: strokes,
                size: CGSize(width: totalWidth, height: totalHeight),
                baseline: max(1, (radY - origin.y) + radMeasure.baseline)
            )

        case .script(let base, let sub, let sup):
            let baseMetrics = measureLaTeXMetrics(base, fontSize: fontSize)
            let scriptFont = max(15, fontSize * 0.65)
            let supMetrics = sup.map { measureLaTeXMetrics($0, fontSize: scriptFont) } ?? LaTeXMetrics(size: .zero, baseline: 0)
            let supLift = sup == nil ? CGFloat(0) : max(6, scriptFont * 0.72)
            let baseResult = renderLaTeXNode(
                base,
                at: CGPoint(x: origin.x, y: origin.y + supLift),
                maxWidth: maxWidth,
                color: color,
                fontSize: fontSize,
                strokeWidth: strokeWidth
            )
            let baseSize = baseResult.size
            let scriptStroke = max(2.45, strokeWidth * 0.94)
            var strokes = baseResult.strokes
            var maxRight = origin.x + baseSize.width
            var maxBottom = origin.y + supLift + baseSize.height

            if let sup {
                let supOrigin = CGPoint(
                    x: origin.x + baseSize.width + 2,
                    y: origin.y
                )
                let supResult = renderLaTeXNode(
                    sup,
                    at: supOrigin,
                    maxWidth: max(80, maxWidth - baseSize.width),
                    color: color,
                    fontSize: scriptFont,
                    strokeWidth: scriptStroke
                )
                strokes.append(contentsOf: supResult.strokes)
                maxRight = max(maxRight, supOrigin.x + supResult.size.width)
                maxBottom = max(maxBottom, supOrigin.y + supResult.size.height)
            }

            if let sub {
                let subOrigin = CGPoint(
                    x: origin.x + baseSize.width + 2,
                    y: origin.y + supLift + max(2, baseSize.height * 0.52)
                )
                let subResult = renderLaTeXNode(
                    sub,
                    at: subOrigin,
                    maxWidth: max(80, maxWidth - baseSize.width),
                    color: color,
                    fontSize: scriptFont,
                    strokeWidth: scriptStroke
                )
                strokes.append(contentsOf: subResult.strokes)
                maxRight = max(maxRight, subOrigin.x + subResult.size.width)
                maxBottom = max(maxBottom, subOrigin.y + subResult.size.height)
            }

            return LaTeXRenderResult(
                strokes: strokes,
                size: CGSize(width: max(1, maxRight - origin.x), height: max(1, maxBottom - origin.y)),
                baseline: max(1, supLift + baseMetrics.baseline + max(0, supMetrics.size.height * 0.03))
            )

        case .operatorSymbol(let symbol, let sub, let sup):
            let opFont = max(22, fontSize * 1.25)
            let opStroke = max(2.85, strokeWidth * 1.02)
            let limitFont = max(14, fontSize * 0.56)
            let limitStroke = max(2.35, strokeWidth * 0.9)
            let supMetrics = sup.map { measureLaTeXMetrics($0, fontSize: limitFont) } ?? LaTeXMetrics(size: .zero, baseline: 0)
            let subMetrics = sub.map { measureLaTeXMetrics($0, fontSize: limitFont) } ?? LaTeXMetrics(size: .zero, baseline: 0)
            let topPad = sup == nil ? CGFloat(0) : (supMetrics.size.height + 2)
            let symbolResult = HandwrittenInkRenderer.render(
                text: symbol,
                origin: CGPoint(x: origin.x, y: origin.y + topPad),
                maxWidth: maxWidth,
                color: color,
                fontSize: opFont,
                strokeWidth: opStroke
            )
            var strokes = symbolResult.strokes
            var width = symbolResult.size.width
            var totalHeight = topPad + symbolResult.size.height

            if let sup {
                let supX = origin.x + max(0, (symbolResult.size.width - supMetrics.size.width) * 0.5)
                let supY = origin.y
                let supResult = renderLaTeXNode(
                    sup,
                    at: CGPoint(x: supX, y: supY),
                    maxWidth: max(70, maxWidth),
                    color: color,
                    fontSize: limitFont,
                    strokeWidth: limitStroke
                )
                strokes.append(contentsOf: supResult.strokes)
                width = max(width, max(symbolResult.size.width, supResult.size.width))
                totalHeight = max(totalHeight, topPad + symbolResult.size.height)
            }
            if let sub {
                let subX = origin.x + max(0, (symbolResult.size.width - subMetrics.size.width) * 0.5)
                let subY = origin.y + topPad + symbolResult.size.height + 2
                let subResult = renderLaTeXNode(
                    sub,
                    at: CGPoint(x: subX, y: subY),
                    maxWidth: max(70, maxWidth),
                    color: color,
                    fontSize: limitFont,
                    strokeWidth: limitStroke
                )
                strokes.append(contentsOf: subResult.strokes)
                width = max(width, max(symbolResult.size.width, subResult.size.width))
                totalHeight = max(totalHeight, (subY - origin.y) + subResult.size.height)
            }

            return LaTeXRenderResult(
                strokes: strokes,
                size: CGSize(width: max(1, width), height: max(1, totalHeight)),
                baseline: max(1, topPad + (symbolResult.size.height * 0.72))
            )
        }
    }

    private func measureLaTeXNode(_ node: LaTeXNode, fontSize: CGFloat) -> CGSize {
        measureLaTeXMetrics(node, fontSize: fontSize).size
    }

    private func measureLaTeXMetrics(_ node: LaTeXNode, fontSize: CGFloat) -> LaTeXMetrics {
        switch node {
        case .text(let raw):
            let text = normalizeLaTeXText(raw)
            guard !text.isEmpty else { return LaTeXMetrics(size: .zero, baseline: 0) }
            let size = HandwrittenInkRenderer.measure(text: text, fontSize: fontSize)
            return LaTeXMetrics(size: size, baseline: max(1, size.height * 0.78))

        case .symbol(let symbol):
            switch symbol {
            case "+":
                let height = max(18, fontSize * 0.80)
                let width = max(16, fontSize * 0.72)
                return LaTeXMetrics(size: CGSize(width: width, height: height), baseline: height * 0.76)
            case "±":
                let height = max(22, fontSize * 0.94)
                let width = max(18, fontSize * 0.76)
                return LaTeXMetrics(size: CGSize(width: width, height: height), baseline: height * 0.78)
            case "-":
                let height = max(14, fontSize * 0.5)
                let width = max(16, fontSize * 0.68)
                return LaTeXMetrics(size: CGSize(width: width, height: height), baseline: height * 0.76)
            case "=":
                let height = max(16, fontSize * 0.6)
                let width = max(18, fontSize * 0.72)
                return LaTeXMetrics(size: CGSize(width: width, height: height), baseline: height * 0.76)
            default:
                let size = HandwrittenInkRenderer.measure(text: String(symbol), fontSize: fontSize)
                return LaTeXMetrics(size: size, baseline: max(1, size.height * 0.78))
            }

        case .sequence(let children):
            var width: CGFloat = 0
            var maxAscent: CGFloat = 0
            var maxDescent: CGFloat = 0
            for child in children {
                let childMetrics = measureLaTeXMetrics(child, fontSize: fontSize)
                guard childMetrics.size.width > 0 || childMetrics.size.height > 0 else { continue }
                width += childMetrics.size.width + latexNodeSpacing(for: child, fontSize: fontSize)
                maxAscent = max(maxAscent, childMetrics.baseline)
                maxDescent = max(maxDescent, childMetrics.size.height - childMetrics.baseline)
            }
            if width > 0 {
                width -= latexNodeSpacing(for: children.last ?? .text(""), fontSize: fontSize)
            }
            return LaTeXMetrics(
                size: CGSize(width: max(0, width), height: max(0, maxAscent + maxDescent)),
                baseline: max(1, maxAscent)
            )

        case .fraction(let numerator, let denominator):
            let childFont = max(20, fontSize * 0.84)
            let numMetrics = measureLaTeXMetrics(numerator, fontSize: childFont)
            let denMetrics = measureLaTeXMetrics(denominator, fontSize: childFont)
            let barY = max(numMetrics.size.height, childFont) + 7.5
            return LaTeXMetrics(
                size: CGSize(
                    width: max(numMetrics.size.width, denMetrics.size.width) + 28,
                    height: barY + 9 + denMetrics.size.height
                ),
                baseline: max(1, barY + 2)
            )

        case .sqrt(let rootIndex, let radicand):
            let childFont = max(20, fontSize * 0.92)
            let radMetrics = measureLaTeXMetrics(radicand, fontSize: childFont)
            let rootPrefix = max(26, fontSize * 0.78)
            let indexFont = max(12, fontSize * 0.45)
            let indexMetrics = rootIndex.map { measureLaTeXMetrics($0, fontSize: indexFont) } ?? LaTeXMetrics(size: .zero, baseline: 0)
            let radTop = max(10, fontSize * 0.22)
            let height = max(radTop + radMetrics.size.height, fontSize + 18 + indexMetrics.size.height * 0.1)
            return LaTeXMetrics(
                size: CGSize(
                    width: max(rootPrefix + radMetrics.size.width + 10, rootPrefix + radMetrics.size.width + indexMetrics.size.width * 0.2),
                    height: height
                ),
                baseline: max(1, radTop + radMetrics.baseline)
            )

        case .script(let base, let sub, let sup):
            let baseMetrics = measureLaTeXMetrics(base, fontSize: fontSize)
            let scriptFont = max(15, fontSize * 0.65)
            let supMetrics = sup.map { measureLaTeXMetrics($0, fontSize: scriptFont) } ?? LaTeXMetrics(size: .zero, baseline: 0)
            let subMetrics = sub.map { measureLaTeXMetrics($0, fontSize: scriptFont) } ?? LaTeXMetrics(size: .zero, baseline: 0)
            let supLift = sup == nil ? CGFloat(0) : max(6, scriptFont * 0.72)
            let width = baseMetrics.size.width + max(supMetrics.size.width, subMetrics.size.width) + 6
            let subBottom = supLift + max(2, baseMetrics.size.height * 0.52) + subMetrics.size.height
            let height = max(supLift + baseMetrics.size.height, subBottom)
            return LaTeXMetrics(
                size: CGSize(width: max(1, width), height: max(1, height)),
                baseline: max(1, supLift + baseMetrics.baseline)
            )

        case .operatorSymbol(_, let sub, let sup):
            let opFont = max(22, fontSize * 1.25)
            let symbolSize = HandwrittenInkRenderer.measure(text: "∑", fontSize: opFont)
            let symbolBaseline = max(1, symbolSize.height * 0.72)
            let limitFont = max(14, fontSize * 0.56)
            let supMetrics = sup.map { measureLaTeXMetrics($0, fontSize: limitFont) } ?? LaTeXMetrics(size: .zero, baseline: 0)
            let subMetrics = sub.map { measureLaTeXMetrics($0, fontSize: limitFont) } ?? LaTeXMetrics(size: .zero, baseline: 0)
            let topPad = sup == nil ? CGFloat(0) : (supMetrics.size.height + 2)
            let height = topPad + symbolSize.height + (sub == nil ? 0 : 2 + subMetrics.size.height)
            let width = max(symbolSize.width, max(supMetrics.size.width, subMetrics.size.width)) + 4
            return LaTeXMetrics(
                size: CGSize(width: max(1, width), height: max(1, height)),
                baseline: max(1, topPad + symbolBaseline)
            )
        }
    }

    private func latexNodeSpacing(for node: LaTeXNode, fontSize: CGFloat) -> CGFloat {
        switch node {
        case .fraction:
            return max(12, fontSize * 0.28)
        case .operatorSymbol:
            return max(12, fontSize * 0.3)
        default:
            return max(8, fontSize * 0.2)
        }
    }

    private func normalizeLaTeXText(_ raw: String) -> String {
        var value = raw
            .replacingOccurrences(of: "\\,", with: " ")
            .replacingOccurrences(of: "\\;", with: " ")
            .replacingOccurrences(of: "\\!", with: "")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let symbolMap: [String: String] = [
            "\\times": "×", "\\cdot": "·", "\\pm": "±", "\\neq": "≠",
            "\\leq": "≤", "\\geq": "≥", "\\approx": "≈", "\\infty": "∞",
            "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ",
            "\\theta": "θ", "\\lambda": "λ", "\\mu": "μ", "\\pi": "π",
            "\\sigma": "σ", "\\phi": "φ", "\\omega": "ω", "\\sum": "Σ",
            "\\int": "∫", "\\sqrt": "√", "\\over": "/"
        ]
        for (k, v) in symbolMap {
            value = value.replacingOccurrences(of: k, with: v)
        }

        let functionMap: [String: String] = [
            "\\sin": "sin",
            "\\cos": "cos",
            "\\tan": "tan",
            "\\cot": "cot",
            "\\sec": "sec",
            "\\csc": "csc",
            "\\log": "log",
            "\\ln": "ln",
            "\\exp": "exp",
            "\\lim": "lim",
            "\\max": "max",
            "\\min": "min",
            "\\det": "det",
            "\\gcd": "gcd",
            "\\to": "→",
            "\\rightarrow": "→",
            "\\leftarrow": "←"
        ]
        for (k, v) in functionMap {
            value = value.replacingOccurrences(of: k, with: v)
        }

        value = value.replacingOccurrences(of: #"\\[a-zA-Z]+"#, with: "", options: .regularExpression)
        value = convertScriptsToUnicode(value)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func convertScriptsToUnicode(_ input: String) -> String {
        let superscriptMap: [Character: Character] = [
            "0":"⁰","1":"¹","2":"²","3":"³","4":"⁴","5":"⁵","6":"⁶","7":"⁷","8":"⁸","9":"⁹",
            "+":"⁺","-":"⁻","=":"⁼","(":"⁽",")":"⁾","n":"ⁿ","i":"ⁱ"
        ]
        let subscriptMap: [Character: Character] = [
            "0":"₀","1":"₁","2":"₂","3":"₃","4":"₄","5":"₅","6":"₆","7":"₇","8":"₈","9":"₉",
            "+":"₊","-":"₋","=":"₌","(":"₍",")":"₎"
        ]

        var output = input
        output = output.replacingOccurrences(of: #"\^\{([^}]+)\}"#, with: "^( $1 )", options: .regularExpression)
        output = output.replacingOccurrences(of: #"_\{([^}]+)\}"#, with: "_( $1 )", options: .regularExpression)

        func applyMap(_ source: String, marker: Character, map: [Character: Character]) -> String {
            var result = ""
            var i = source.startIndex
            while i < source.endIndex {
                let ch = source[i]
                if ch == marker {
                    let next = source.index(after: i)
                    if next < source.endIndex {
                        let candidate = source[next]
                        if let mapped = map[candidate] {
                            result.append(mapped)
                            i = source.index(after: next)
                            continue
                        }
                    }
                }
                result.append(ch)
                i = source.index(after: i)
            }
            return result
        }

        output = applyMap(output, marker: "^", map: superscriptMap)
        output = applyMap(output, marker: "_", map: subscriptMap)
        return output
            .replacingOccurrences(of: "( ", with: "")
            .replacingOccurrences(of: " )", with: "")
            .replacingOccurrences(of: #"\\s+"#, with: " ", options: .regularExpression)
    }

    private func renderMathSymbol(
        _ symbol: Character,
        at origin: CGPoint,
        color: UIColor,
        fontSize: CGFloat,
        strokeWidth: CGFloat
    ) -> LaTeXRenderResult {
        let size = measureLaTeXMetrics(.symbol(symbol), fontSize: fontSize).size
        let width = max(12, size.width)
        let height = max(12, size.height)
        let lineW = max(3.45, strokeWidth * 1.18)
        let fillOffset = max(0.52, lineW * 0.24)
        var strokes: [PKStroke] = []

        func addFilledLine(from start: CGPoint, to end: CGPoint) {
            let offsets: [CGFloat] = [-2, -1, 0, 1, 2]
            for step in offsets {
                let yOffset = step * fillOffset
                let widthScale: CGFloat = step == 0 ? 1.0 : (step.magnitude == 1 ? 0.82 : 0.62)
                strokes.append(
                    makeLineStroke(
                        from: CGPoint(x: start.x, y: start.y + yOffset),
                        to: CGPoint(x: end.x, y: end.y + yOffset),
                        color: color,
                        width: lineW * widthScale
                    )
                )
            }
        }

        switch symbol {
        case "+":
            let cx = origin.x + width * 0.5
            let cy = origin.y + height * 0.5
            addFilledLine(
                from: CGPoint(x: cx, y: cy - height * 0.31),
                to: CGPoint(x: cx, y: cy + height * 0.31)
            )
            addFilledLine(
                from: CGPoint(x: origin.x + width * 0.12, y: cy),
                to: CGPoint(x: origin.x + width * 0.88, y: cy)
            )
        case "±":
            let cx = origin.x + width * 0.5
            let plusY = origin.y + height * 0.4
            let minusY = origin.y + height * 0.76
            addFilledLine(
                from: CGPoint(x: cx, y: plusY - height * 0.18),
                to: CGPoint(x: cx, y: plusY + height * 0.18)
            )
            addFilledLine(
                from: CGPoint(x: origin.x + width * 0.14, y: plusY),
                to: CGPoint(x: origin.x + width * 0.86, y: plusY)
            )
            addFilledLine(
                from: CGPoint(x: origin.x + width * 0.14, y: minusY),
                to: CGPoint(x: origin.x + width * 0.86, y: minusY)
            )
        case "-":
            let cy = origin.y + height * 0.5
            addFilledLine(
                from: CGPoint(x: origin.x + width * 0.12, y: cy),
                to: CGPoint(x: origin.x + width * 0.88, y: cy)
            )
        case "=":
            let cy = origin.y + height * 0.5
            let gap = max(2.8, height * 0.28)
            addFilledLine(
                from: CGPoint(x: origin.x + width * 0.1, y: cy - gap * 0.5),
                to: CGPoint(x: origin.x + width * 0.9, y: cy - gap * 0.5)
            )
            addFilledLine(
                from: CGPoint(x: origin.x + width * 0.1, y: cy + gap * 0.5),
                to: CGPoint(x: origin.x + width * 0.9, y: cy + gap * 0.5)
            )
        default:
            let rendered = HandwrittenInkRenderer.render(
                text: String(symbol),
                origin: origin,
                maxWidth: width + 8,
                color: color,
                fontSize: fontSize,
                strokeWidth: max(2.5, strokeWidth)
            )
            let baseline = max(1, rendered.size.height * 0.78)
            return LaTeXRenderResult(strokes: rendered.strokes, size: rendered.size, baseline: baseline)
        }

        let baseline: CGFloat = {
            switch symbol {
            case "±":
                return max(1, height * 0.78)
            case "=":
                return max(1, height * 0.76)
            case "-":
                return max(1, height * 0.76)
            default:
                return max(1, height * 0.76)
            }
        }()
        return LaTeXRenderResult(strokes: strokes, size: CGSize(width: width, height: height), baseline: baseline)
    }

    private func makeLineStroke(
        from start: CGPoint,
        to end: CGPoint,
        color: UIColor,
        width: CGFloat
    ) -> PKStroke {
        let ink = PKInk(.pen, color: color)
        let p0 = PKStrokePoint(
            location: start,
            timeOffset: 0,
            size: CGSize(width: width, height: width),
            opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
        )
        let p1 = PKStrokePoint(
            location: end,
            timeOffset: 0.08,
            size: CGSize(width: width, height: width),
            opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
        )
        let path = PKStrokePath(controlPoints: [p0, p1], creationDate: Date())
        return PKStroke(ink: ink, path: path)
    }

    private func makePolylineStroke(
        points: [CGPoint],
        color: UIColor,
        width: CGFloat
    ) -> PKStroke {
        let ink = PKInk(.pen, color: color)
        let controlPoints: [PKStrokePoint] = points.enumerated().map { idx, point in
            PKStrokePoint(
                location: point,
                timeOffset: TimeInterval(idx) * 0.04,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: Date())
        return PKStroke(ink: ink, path: path)
    }

}
