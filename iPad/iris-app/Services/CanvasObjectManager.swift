import Foundation
import CoreText
import PencilKit
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

        if animated, let cursor {
            let widgetCenterCanvas = CGPoint(
                x: position.x + (size.width * 0.5),
                y: position.y + (size.height * 0.5)
            )
            let targetScreen = canvasView.screenPoint(forCanvasPoint: widgetCenterCanvas)
            let startScreen = CGPoint(
                x: targetScreen.x - 52,
                y: targetScreen.y - 64
            )
            cursor.appear(at: startScreen)
            try? await Task.sleep(nanoseconds: 160_000_000)
            cursor.moveTo(targetScreen, duration: 0.34)
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
        guard let view = objectViews[id] else { return }
        let backendID = objects[id]?.backendWidgetID
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

    // MARK: - SVG Drawing

    /// Parses an SVG string and animates it onto the canvas with cursor tracking.
    /// Returns the number of strokes parsed.
    @discardableResult
    func drawSVG(
        svg: String,
        at position: CGPoint,
        scale: CGFloat = 1.0,
        color: UIColor = UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1),
        strokeWidth: CGFloat = 3,
        speed: Double = 1.0
    ) async -> Int {
        guard let canvasView, let cursor else { return 0 }

        let parser = SVGPathParser()
        let result = parser.parse(svgString: svg)
        guard !result.strokes.isEmpty else { return 0 }
        let normalizedStrokes = normalizeStrokesToLocalOrigin(result.strokes)

        isAnimatingDraw = true
        defer { isAnimatingDraw = false }

        let animator = SVGStrokeAnimator(
            canvasView: canvasView,
            cursor: cursor,
            objectManager: self
        )

        await animator.animate(
            strokes: normalizedStrokes,
            origin: position,
            scale: scale,
            color: color,
            strokeWidth: strokeWidth,
            speed: speed
        )

        // Trigger final save by notifying drawing changed
        if let recentStroke = canvasView.drawing.strokes.last {
            updateMostRecentStrokeBounds(recentStroke.renderBounds)
        }

        return result.strokes.count
    }

    @discardableResult
    func drawHandwrittenText(
        _ text: String,
        at position: CGPoint,
        maxWidth: CGFloat = 420,
        color: UIColor = UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1)
    ) async -> CGSize {
        guard let canvasView else { return .zero }

        let result = HandwrittenInkRenderer.render(
            text: text,
            origin: position,
            maxWidth: maxWidth,
            color: color
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

    private func normalizeStrokesToLocalOrigin(_ strokes: [SVGStroke]) -> [SVGStroke] {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude

        for stroke in strokes {
            for point in stroke.points {
                minX = min(minX, point.x)
                minY = min(minY, point.y)
            }
        }

        guard minX.isFinite, minY.isFinite else { return strokes }
        guard abs(minX) > 0.001 || abs(minY) > 0.001 else { return strokes }

        return strokes.map { stroke in
            let shifted = stroke.points.map { point in
                CGPoint(x: point.x - minX, y: point.y - minY)
            }
            return SVGStroke(
                points: shifted,
                color: stroke.color,
                strokeWidth: stroke.strokeWidth,
                isFill: stroke.isFill
            )
        }
    }
}
