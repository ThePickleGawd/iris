import Foundation
import CoreGraphics

struct SVGStroke {
    let points: [CGPoint]
    let color: String?
    let strokeWidth: CGFloat?
    let isFill: Bool

    init(points: [CGPoint], color: String?, strokeWidth: CGFloat?, isFill: Bool = false) {
        self.points = points
        self.color = color
        self.strokeWidth = strokeWidth
        self.isFill = isFill
    }
}

struct SVGParseResult {
    let strokes: [SVGStroke]
    let viewBox: CGRect
}

/// Parses SVG XML into ordered lists of point sequences suitable for PencilKit rendering.
/// Uses Foundation XMLParser — no third-party dependencies.
final class SVGPathParser: NSObject, XMLParserDelegate {

    private var strokes: [SVGStroke] = []
    private var viewBox: CGRect = .zero
    private var svgWidth: CGFloat = 0
    private var svgHeight: CGFloat = 0

    // Track nested style/transform inheritance.
    private var groupStyleStack: [(stroke: String?, strokeWidth: String?)] = []
    private var transformStack: [CGAffineTransform] = []

    func parse(svgString: String) -> SVGParseResult {
        strokes = []
        viewBox = .zero
        svgWidth = 0
        svgHeight = 0
        groupStyleStack = []
        transformStack = []

        guard let data = svgString.data(using: .utf8) else {
            return SVGParseResult(strokes: [], viewBox: .zero)
        }

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        // If no viewBox was set, use width/height
        if viewBox == .zero && svgWidth > 0 && svgHeight > 0 {
            viewBox = CGRect(x: 0, y: 0, width: svgWidth, height: svgHeight)
        }

        normalizeToViewBoxOrigin()

        return SVGParseResult(strokes: strokes, viewBox: viewBox)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attrs: [String: String]) {

        switch element.lowercased() {
        case "svg":
            parseSVGRoot(attrs)
            let parent = transformStack.last ?? .identity
            transformStack.append(parent.concatenating(parseTransform(attrs["transform"])))
        case "g":
            let stroke = attrs["stroke"] ?? styleValue("stroke", from: attrs["style"])
            let sw = attrs["stroke-width"] ?? styleValue("stroke-width", from: attrs["style"])
            groupStyleStack.append((stroke: stroke, strokeWidth: sw))
            let parent = transformStack.last ?? .identity
            transformStack.append(parent.concatenating(parseTransform(attrs["transform"])))
        case "path":
            parsePath(attrs)
        case "rect":
            parseRect(attrs)
        case "line":
            parseLine(attrs)
        case "polyline":
            parsePolyline(attrs, closed: false)
        case "polygon":
            parsePolyline(attrs, closed: true)
        case "circle":
            parseCircle(attrs)
        case "ellipse":
            parseEllipse(attrs)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        let lower = element.lowercased()
        if lower == "g" {
            _ = groupStyleStack.popLast()
        }
        if lower == "g" || lower == "svg" {
            _ = transformStack.popLast()
        }
    }

    // MARK: - SVG Root

    private func parseSVGRoot(_ attrs: [String: String]) {
        if let vb = attrs["viewBox"] ?? attrs["viewbox"] {
            let parts = vb.split(whereSeparator: { " ,".contains($0) }).compactMap { Double($0) }
            if parts.count == 4 {
                viewBox = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            }
        }
        if let w = parseDimension(attrs["width"]) { svgWidth = w }
        if let h = parseDimension(attrs["height"]) { svgHeight = h }
    }

    private func parseDimension(_ value: String?) -> CGFloat? {
        guard let value else { return nil }
        // Strip units like "px", "pt", etc.
        let numeric = value.trimmingCharacters(in: .letters)
        return Double(numeric).map { CGFloat($0) }
    }

    // MARK: - Element Parsers

    private func parsePath(_ attrs: [String: String]) {
        guard let d = attrs["d"], !d.isEmpty else { return }
        let (color, width) = resolveStyle(attrs)
        guard hasVisibleStroke(color: color, width: width) else { return }
        let strokeWidth = resolvedStrokeWidth(width)
        let transform = elementTransform(attrs)
        let paths = SVGPathCommandParser.parse(d)
        for points in paths where points.count >= 2 {
            strokes.append(SVGStroke(
                points: applyTransform(points, transform: transform),
                color: color,
                strokeWidth: strokeWidth
            ))
        }
    }

    private func parseRect(_ attrs: [String: String]) {
        let x = cgFloat(attrs["x"]) ?? 0
        let y = cgFloat(attrs["y"]) ?? 0
        let w = cgFloat(attrs["width"]) ?? 0
        let h = cgFloat(attrs["height"]) ?? 0
        var rx = cgFloat(attrs["rx"]) ?? 0
        var ry = cgFloat(attrs["ry"]) ?? 0
        guard w > 0, h > 0 else { return }

        // If only one radius given, match the other
        if rx > 0 && ry == 0 { ry = rx }
        if ry > 0 && rx == 0 { rx = ry }
        rx = min(rx, w / 2)
        ry = min(ry, h / 2)

        let (color, width) = resolveStyle(attrs)
        guard hasVisibleStroke(color: color, width: width) else { return }
        let strokeWidth = resolvedStrokeWidth(width)
        let transform = elementTransform(attrs)

        var points: [CGPoint] = []
        if rx > 0 && ry > 0 {
            // Rounded rect: sample corners
            let samplesPerCorner = 6
            // Top-right corner
            points.append(CGPoint(x: x + rx, y: y))
            points.append(CGPoint(x: x + w - rx, y: y))
            sampleArc(center: CGPoint(x: x + w - rx, y: y + ry),
                       rx: rx, ry: ry,
                       startAngle: -.pi / 2, endAngle: 0,
                       samples: samplesPerCorner, into: &points)
            // Bottom-right corner
            points.append(CGPoint(x: x + w, y: y + h - ry))
            sampleArc(center: CGPoint(x: x + w - rx, y: y + h - ry),
                       rx: rx, ry: ry,
                       startAngle: 0, endAngle: .pi / 2,
                       samples: samplesPerCorner, into: &points)
            // Bottom-left corner
            points.append(CGPoint(x: x + rx, y: y + h))
            sampleArc(center: CGPoint(x: x + rx, y: y + h - ry),
                       rx: rx, ry: ry,
                       startAngle: .pi / 2, endAngle: .pi,
                       samples: samplesPerCorner, into: &points)
            // Top-left corner
            points.append(CGPoint(x: x, y: y + ry))
            sampleArc(center: CGPoint(x: x + rx, y: y + ry),
                       rx: rx, ry: ry,
                       startAngle: .pi, endAngle: 3 * .pi / 2,
                       samples: samplesPerCorner, into: &points)
            points.append(points[0]) // close
        } else {
            points = [
                CGPoint(x: x, y: y),
                CGPoint(x: x + w, y: y),
                CGPoint(x: x + w, y: y + h),
                CGPoint(x: x, y: y + h),
                CGPoint(x: x, y: y)
            ]
        }

        strokes.append(SVGStroke(
            points: applyTransform(points, transform: transform),
            color: color,
            strokeWidth: strokeWidth
        ))
    }

    private func parseLine(_ attrs: [String: String]) {
        let x1 = cgFloat(attrs["x1"]) ?? 0
        let y1 = cgFloat(attrs["y1"]) ?? 0
        let x2 = cgFloat(attrs["x2"]) ?? 0
        let y2 = cgFloat(attrs["y2"]) ?? 0
        let (color, width) = resolveStyle(attrs)
        guard hasVisibleStroke(color: color, width: width) else { return }
        let strokeWidth = resolvedStrokeWidth(width)
        let transform = elementTransform(attrs)
        strokes.append(SVGStroke(
            points: applyTransform([CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2)], transform: transform),
            color: color, strokeWidth: strokeWidth
        ))
    }

    private func parsePolyline(_ attrs: [String: String], closed: Bool) {
        guard let pointsStr = attrs["points"] else { return }
        var points = parsePointsList(pointsStr)
        guard points.count >= 2 else { return }
        if closed, let first = points.first, points.last != first {
            points.append(first)
        }

        let (color, width) = resolveStyle(attrs)
        let fill = attrs["fill"] ?? styleValue("fill", from: attrs["style"])
        let hasFill = isVisibleFill(fill)
        let hasVisibleOutline = hasVisibleStroke(color: color, width: width)
        let transform = elementTransform(attrs)

        // If filled (and closed), generate scanline fill strokes
        if closed && hasFill {
            let fillStrokes = scanlineFill(polygon: points, color: fill)
            if transform.isIdentity {
                strokes.append(contentsOf: fillStrokes)
            } else {
                let transformed = fillStrokes.map { stroke in
                    SVGStroke(
                        points: applyTransform(stroke.points, transform: transform),
                        color: stroke.color,
                        strokeWidth: stroke.strokeWidth,
                        isFill: stroke.isFill
                    )
                }
                strokes.append(contentsOf: transformed)
            }
        }

        // Draw outline only when an actual visible stroke exists.
        if hasVisibleOutline {
            let outlineWidth = resolvedStrokeWidth(width)
            strokes.append(SVGStroke(
                points: applyTransform(points, transform: transform),
                color: color,
                strokeWidth: outlineWidth
            ))
        }
    }

    private func parseCircle(_ attrs: [String: String]) {
        let cx = cgFloat(attrs["cx"]) ?? 0
        let cy = cgFloat(attrs["cy"]) ?? 0
        let r = cgFloat(attrs["r"]) ?? 0
        guard r > 0 else { return }
        let (color, width) = resolveStyle(attrs)
        guard hasVisibleStroke(color: color, width: width) else { return }
        let strokeWidth = resolvedStrokeWidth(width)
        let transform = elementTransform(attrs)
        let points = sampleEllipse(cx: cx, cy: cy, rx: r, ry: r, samples: 24)
        strokes.append(SVGStroke(
            points: applyTransform(points, transform: transform),
            color: color,
            strokeWidth: strokeWidth
        ))
    }

    private func parseEllipse(_ attrs: [String: String]) {
        let cx = cgFloat(attrs["cx"]) ?? 0
        let cy = cgFloat(attrs["cy"]) ?? 0
        let rx = cgFloat(attrs["rx"]) ?? 0
        let ry = cgFloat(attrs["ry"]) ?? 0
        guard rx > 0, ry > 0 else { return }
        let (color, width) = resolveStyle(attrs)
        guard hasVisibleStroke(color: color, width: width) else { return }
        let strokeWidth = resolvedStrokeWidth(width)
        let transform = elementTransform(attrs)
        let points = sampleEllipse(cx: cx, cy: cy, rx: rx, ry: ry, samples: 24)
        strokes.append(SVGStroke(
            points: applyTransform(points, transform: transform),
            color: color,
            strokeWidth: strokeWidth
        ))
    }

    // MARK: - Style Resolution

    private func resolveStyle(_ attrs: [String: String]) -> (color: String?, width: CGFloat?) {
        var color = attrs["stroke"] ?? styleValue("stroke", from: attrs["style"])
        var width = cgFloat(attrs["stroke-width"] ?? styleValue("stroke-width", from: attrs["style"]))

        // Inherit from parent <g> elements
        for group in groupStyleStack.reversed() {
            if color == nil { color = group.stroke }
            if width == nil, let sw = group.strokeWidth { width = cgFloat(sw) }
        }

        if color == nil || color?.lowercased() == "none" || color?.lowercased() == "transparent" {
            let fill = attrs["fill"] ?? styleValue("fill", from: attrs["style"])
            if let fill, fill.lowercased() != "none", fill.lowercased() != "transparent" {
                color = fill
            }
        }

        return (color, width)
    }

    private func styleValue(_ key: String, from style: String?) -> String? {
        guard let style else { return nil }
        for part in style.split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == key {
                return kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func resolvedStrokeWidth(_ width: CGFloat?) -> CGFloat {
        let w = width ?? 1
        return max(0, w)
    }

    private func hasVisibleStroke(color: String?, width: CGFloat?) -> Bool {
        guard let raw = color?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        let normalized = raw.lowercased()
        if normalized == "none" || normalized == "transparent" {
            return false
        }
        return resolvedStrokeWidth(width) > 0.001
    }

    private func isVisibleFill(_ fill: String?) -> Bool {
        guard let raw = fill?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        let normalized = raw.lowercased()
        return normalized != "none" && normalized != "transparent"
    }

    private func elementTransform(_ attrs: [String: String]) -> CGAffineTransform {
        let inherited = transformStack.last ?? .identity
        let local = parseTransform(attrs["transform"])
        return inherited.concatenating(local)
    }

    private func applyTransform(_ points: [CGPoint], transform: CGAffineTransform) -> [CGPoint] {
        guard !transform.isIdentity else { return points }
        return points.map { $0.applying(transform) }
    }

    // MARK: - Polygon Scanline Fill

    /// Generate horizontal line strokes that fill a polygon interior.
    /// Each scanline becomes a 2-point stroke marked as isFill.
    private func scanlineFill(polygon: [CGPoint], color: String?) -> [SVGStroke] {
        // Remove closing duplicate if present
        var verts = polygon
        if let first = verts.first, let last = verts.last, first == last {
            verts.removeLast()
        }
        guard verts.count >= 3 else { return [] }

        let minY = verts.map(\.y).min()!
        let maxY = verts.map(\.y).max()!
        let height = maxY - minY
        guard height > 0 else { return [] }

        // Dense scanlines with heavy overlap for solid PencilKit fill.
        // PK's .pen ink has antialiased rounded edges, so we need
        // massive overlap to achieve fully opaque coverage.
        let step: CGFloat = 0.2
        let lineWidth: CGFloat = step * 8  // 1.6 SVG-unit wide strokes every 0.2
        var fills: [SVGStroke] = []

        var y = minY + step / 2
        while y < maxY {
            // Find intersections of horizontal line y with polygon edges
            var intersections: [CGFloat] = []
            for i in 0..<verts.count {
                let j = (i + 1) % verts.count
                let p1 = verts[i], p2 = verts[j]
                let yMin = min(p1.y, p2.y)
                let yMax = max(p1.y, p2.y)
                if y >= yMin && y < yMax && yMax != yMin {
                    let x = p1.x + (y - p1.y) * (p2.x - p1.x) / (p2.y - p1.y)
                    intersections.append(x)
                }
            }
            intersections.sort()

            // Pair up intersections for fill spans
            var i = 0
            while i + 1 < intersections.count {
                let x1 = intersections[i]
                let x2 = intersections[i + 1]
                if x2 - x1 > 0.1 {
                    fills.append(SVGStroke(
                        points: [CGPoint(x: x1, y: y), CGPoint(x: x2, y: y)],
                        color: color,
                        strokeWidth: lineWidth,
                        isFill: true
                    ))
                }
                i += 2
            }
            y += step
        }

        return fills
    }

    // MARK: - Geometry Helpers

    private func sampleEllipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, samples: Int) -> [CGPoint] {
        var points: [CGPoint] = []
        for i in 0...samples {
            let angle = 2 * CGFloat.pi * CGFloat(i) / CGFloat(samples)
            points.append(CGPoint(x: cx + rx * cos(angle), y: cy + ry * sin(angle)))
        }
        return points
    }

    private func sampleArc(center: CGPoint, rx: CGFloat, ry: CGFloat,
                            startAngle: CGFloat, endAngle: CGFloat,
                            samples: Int, into points: inout [CGPoint]) {
        for i in 1...samples {
            let t = CGFloat(i) / CGFloat(samples)
            let angle = startAngle + (endAngle - startAngle) * t
            points.append(CGPoint(
                x: center.x + rx * cos(angle),
                y: center.y + ry * sin(angle)
            ))
        }
    }

    private func cgFloat(_ str: String?) -> CGFloat? {
        guard let str else { return nil }
        return Double(str).map { CGFloat($0) }
    }

    private func parsePointsList(_ str: String) -> [CGPoint] {
        let numbers = str.split(whereSeparator: { " ,\t\n\r".contains($0) })
            .compactMap { Double($0) }
        var points: [CGPoint] = []
        var i = 0
        while i + 1 < numbers.count {
            points.append(CGPoint(x: numbers[i], y: numbers[i + 1]))
            i += 2
        }
        return points
    }

    private func normalizeToViewBoxOrigin() {
        guard viewBox != .zero else { return }
        guard abs(viewBox.minX) > 0.0001 || abs(viewBox.minY) > 0.0001 else { return }

        let shift = CGAffineTransform(translationX: -viewBox.minX, y: -viewBox.minY)
        strokes = strokes.map { stroke in
            SVGStroke(
                points: applyTransform(stroke.points, transform: shift),
                color: stroke.color,
                strokeWidth: stroke.strokeWidth,
                isFill: stroke.isFill
            )
        }
        viewBox = CGRect(x: 0, y: 0, width: viewBox.width, height: viewBox.height)
    }

    private func parseTransform(_ value: String?) -> CGAffineTransform {
        guard let value else { return .identity }
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .identity }

        guard let regex = try? NSRegularExpression(pattern: #"([a-zA-Z]+)\s*\(([^)]*)\)"#) else {
            return .identity
        }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return .identity }

        var transform = CGAffineTransform.identity
        for match in matches where match.numberOfRanges >= 3 {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let params = parseTransformNumbers(ns.substring(with: match.range(at: 2)))

            let op: CGAffineTransform
            switch name {
            case "translate":
                let tx = params.count > 0 ? params[0] : 0
                let ty = params.count > 1 ? params[1] : 0
                op = CGAffineTransform(translationX: tx, y: ty)
            case "scale":
                guard let sx = params.first else { continue }
                let sy = params.count > 1 ? params[1] : sx
                op = CGAffineTransform(scaleX: sx, y: sy)
            case "rotate":
                guard let degrees = params.first else { continue }
                let radians = degrees * .pi / 180
                if params.count >= 3 {
                    let cx = params[1]
                    let cy = params[2]
                    op = CGAffineTransform(translationX: cx, y: cy)
                        .concatenating(CGAffineTransform(rotationAngle: radians))
                        .concatenating(CGAffineTransform(translationX: -cx, y: -cy))
                } else {
                    op = CGAffineTransform(rotationAngle: radians)
                }
            case "matrix":
                guard params.count >= 6 else { continue }
                op = CGAffineTransform(a: params[0], b: params[1], c: params[2], d: params[3], tx: params[4], ty: params[5])
            case "skewx":
                guard let degrees = params.first else { continue }
                let tanValue = tan(degrees * .pi / 180)
                op = CGAffineTransform(a: 1, b: 0, c: tanValue, d: 1, tx: 0, ty: 0)
            case "skewy":
                guard let degrees = params.first else { continue }
                let tanValue = tan(degrees * .pi / 180)
                op = CGAffineTransform(a: 1, b: tanValue, c: 0, d: 1, tx: 0, ty: 0)
            default:
                continue
            }

            transform = transform.concatenating(op)
        }
        return transform
    }

    private func parseTransformNumbers(_ input: String) -> [CGFloat] {
        guard let regex = try? NSRegularExpression(
            pattern: #"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?"#
        ) else {
            return []
        }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match -> CGFloat? in
            let token = ns.substring(with: match.range)
            guard let value = Double(token), value.isFinite else { return nil }
            return CGFloat(value)
        }
    }
}

// MARK: - SVG Path Command Parser

/// Parses SVG `d` attribute path data into arrays of CGPoints.
/// Handles: M/m, L/l, H/h, V/v, C/c, S/s, Q/q, T/t, A/a, Z/z
enum SVGPathCommandParser {

    static func parse(_ d: String) -> [[CGPoint]] {
        let tokens = tokenize(d)
        var paths: [[CGPoint]] = []
        var currentPath: [CGPoint] = []
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint? = nil
        var lastCommand: Character? = nil
        var i = 0

        func nextNumber() -> CGFloat? {
            guard i < tokens.count, case .number(let n) = tokens[i] else { return nil }
            i += 1
            return n
        }

        func nextPoint(relative: Bool) -> CGPoint? {
            guard let x = nextNumber(), let y = nextNumber() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while i < tokens.count {
            let token = tokens[i]

            guard case .command(let cmd) = token else {
                // Implicit repeated command
                if let lastCmd = lastCommand {
                    // Implicit lineto after moveto
                    let effectiveCmd: Character
                    if lastCmd == "M" { effectiveCmd = "L" }
                    else if lastCmd == "m" { effectiveCmd = "l" }
                    else { effectiveCmd = lastCmd }

                    processCommand(effectiveCmd, tokens: tokens, index: &i,
                                   current: &current, subpathStart: &subpathStart,
                                   lastControl: &lastControl, lastCommand: &lastCommand,
                                   currentPath: &currentPath, paths: &paths)
                    continue
                }
                i += 1
                continue
            }

            i += 1 // consume command token
            processCommand(cmd, tokens: tokens, index: &i,
                           current: &current, subpathStart: &subpathStart,
                           lastControl: &lastControl, lastCommand: &lastCommand,
                           currentPath: &currentPath, paths: &paths)
        }

        if currentPath.count >= 2 {
            paths.append(currentPath)
        }

        return paths
    }

    private static func processCommand(
        _ cmd: Character,
        tokens: [PathToken], index i: inout Int,
        current: inout CGPoint, subpathStart: inout CGPoint,
        lastControl: inout CGPoint?, lastCommand: inout Character?,
        currentPath: inout [CGPoint], paths: inout [[CGPoint]]
    ) {
        let rel = cmd.isLowercase

        func nextNumber() -> CGFloat? {
            guard i < tokens.count, case .number(let n) = tokens[i] else { return nil }
            i += 1
            return n
        }

        func nextPoint() -> CGPoint? {
            guard let x = nextNumber(), let y = nextNumber() else { return nil }
            return rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        switch cmd.uppercased().first! {
        case "M":
            // Start a new subpath
            if currentPath.count >= 2 {
                paths.append(currentPath)
            }
            currentPath = []
            guard let pt = nextPoint() else { return }
            current = pt
            subpathStart = pt
            currentPath.append(pt)
            lastControl = nil
            lastCommand = cmd

            // Implicit lineto for additional coordinate pairs
            while i < tokens.count, case .number = tokens[i] {
                guard let pt = nextPoint() else { break }
                current = pt
                currentPath.append(pt)
            }

        case "L":
            while i < tokens.count, case .number = tokens[i] {
                guard let pt = nextPoint() else { break }
                current = pt
                currentPath.append(pt)
            }
            lastControl = nil
            lastCommand = cmd

        case "H":
            while let dx = nextNumber() {
                let x = rel ? current.x + dx : dx
                current = CGPoint(x: x, y: current.y)
                currentPath.append(current)
            }
            lastControl = nil
            lastCommand = cmd

        case "V":
            while let dy = nextNumber() {
                let y = rel ? current.y + dy : dy
                current = CGPoint(x: current.x, y: y)
                currentPath.append(current)
            }
            lastControl = nil
            lastCommand = cmd

        case "C":
            while i < tokens.count, case .number = tokens[i] {
                guard let c1 = nextPoint(), let c2 = nextPoint(), let end = nextPoint() else { break }
                sampleCubicBezier(from: current, c1: c1, c2: c2, to: end, into: &currentPath)
                lastControl = c2
                current = end
            }
            lastCommand = cmd

        case "S":
            while i < tokens.count, case .number = tokens[i] {
                let c1: CGPoint
                if let lc = lastControl, lastCommand?.uppercased() == "C" || lastCommand?.uppercased() == "S" {
                    c1 = CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
                } else {
                    c1 = current
                }
                guard let c2 = nextPoint(), let end = nextPoint() else { break }
                sampleCubicBezier(from: current, c1: c1, c2: c2, to: end, into: &currentPath)
                lastControl = c2
                current = end
            }
            lastCommand = cmd

        case "Q":
            while i < tokens.count, case .number = tokens[i] {
                guard let ctrl = nextPoint(), let end = nextPoint() else { break }
                sampleQuadBezier(from: current, control: ctrl, to: end, into: &currentPath)
                lastControl = ctrl
                current = end
            }
            lastCommand = cmd

        case "T":
            while i < tokens.count, case .number = tokens[i] {
                let ctrl: CGPoint
                if let lc = lastControl, lastCommand?.uppercased() == "Q" || lastCommand?.uppercased() == "T" {
                    ctrl = CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
                } else {
                    ctrl = current
                }
                guard let end = nextPoint() else { break }
                sampleQuadBezier(from: current, control: ctrl, to: end, into: &currentPath)
                lastControl = ctrl
                current = end
            }
            lastCommand = cmd

        case "A":
            while i < tokens.count, case .number = tokens[i] {
                guard let rx = nextNumber(), let ry = nextNumber(),
                      let rotation = nextNumber(),
                      let largeArcRaw = nextNumber(), let sweepRaw = nextNumber(),
                      let end = nextPoint() else { break }
                let largeArc = largeArcRaw != 0
                let sweep = sweepRaw != 0
                sampleArc(from: current, rx: rx, ry: ry,
                          rotation: rotation, largeArc: largeArc, sweep: sweep,
                          to: end, into: &currentPath)
                current = end
            }
            lastControl = nil
            lastCommand = cmd

        case "Z":
            current = subpathStart
            currentPath.append(current)
            if currentPath.count >= 2 {
                paths.append(currentPath)
            }
            currentPath = []
            lastControl = nil
            lastCommand = cmd

        default:
            break
        }
    }

    // MARK: - Bezier Sampling

    private static let samplesPerSegment = 8

    private static func sampleCubicBezier(from p0: CGPoint, c1: CGPoint, c2: CGPoint, to p3: CGPoint,
                                           into points: inout [CGPoint]) {
        for i in 1...samplesPerSegment {
            let t = CGFloat(i) / CGFloat(samplesPerSegment)
            let mt = 1 - t
            let x = mt*mt*mt*p0.x + 3*mt*mt*t*c1.x + 3*mt*t*t*c2.x + t*t*t*p3.x
            let y = mt*mt*mt*p0.y + 3*mt*mt*t*c1.y + 3*mt*t*t*c2.y + t*t*t*p3.y
            points.append(CGPoint(x: x, y: y))
        }
    }

    private static func sampleQuadBezier(from p0: CGPoint, control: CGPoint, to p2: CGPoint,
                                          into points: inout [CGPoint]) {
        for i in 1...samplesPerSegment {
            let t = CGFloat(i) / CGFloat(samplesPerSegment)
            let mt = 1 - t
            let x = mt*mt*p0.x + 2*mt*t*control.x + t*t*p2.x
            let y = mt*mt*p0.y + 2*mt*t*control.y + t*t*p2.y
            points.append(CGPoint(x: x, y: y))
        }
    }

    /// Approximate SVG arc with line segments using the endpoint-to-center parameterization.
    private static func sampleArc(from p0: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                                   rotation: CGFloat, largeArc: Bool, sweep: Bool,
                                   to p1: CGPoint, into points: inout [CGPoint]) {
        // Degenerate cases
        if p0 == p1 { return }
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if rx == 0 || ry == 0 {
            points.append(p1)
            return
        }

        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        // Step 1: compute (x1', y1')
        let dx = (p0.x - p1.x) / 2
        let dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        // Step 2: ensure radii are large enough
        let x1p2 = x1p * x1p
        let y1p2 = y1p * y1p
        let lambda = x1p2 / (rx * rx) + y1p2 / (ry * ry)
        if lambda > 1 {
            let sqrtLambda = sqrt(lambda)
            rx *= sqrtLambda
            ry *= sqrtLambda
        }

        let rx2 = rx * rx
        let ry2 = ry * ry

        // Step 3: compute center
        var sq = (rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2) / (rx2 * y1p2 + ry2 * x1p2)
        if sq < 0 { sq = 0 }
        var root = sqrt(sq)
        if largeArc == sweep { root = -root }

        let cxp = root * rx * y1p / ry
        let cyp = -root * ry * x1p / rx

        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        // Step 4: compute angles
        func angle(ux: CGFloat, uy: CGFloat, vx: CGFloat, vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let theta1 = angle(ux: 1, uy: 0, vx: (x1p - cxp) / rx, vy: (y1p - cyp) / ry)
        var dTheta = angle(ux: (x1p - cxp) / rx, uy: (y1p - cyp) / ry,
                           vx: (-x1p - cxp) / rx, vy: (-y1p - cyp) / ry)

        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }

        let steps = max(8, Int(abs(dTheta) / (CGFloat.pi / 12)))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let a = theta1 + dTheta * t
            let xr = rx * cos(a)
            let yr = ry * sin(a)
            let x = cosPhi * xr - sinPhi * yr + cx
            let y = sinPhi * xr + cosPhi * yr + cy
            points.append(CGPoint(x: x, y: y))
        }
    }

    // MARK: - Tokenizer

    enum PathToken {
        case command(Character)
        case number(CGFloat)
    }

    static func tokenize(_ d: String) -> [PathToken] {
        var tokens: [PathToken] = []
        var numBuf = ""
        let commandChars = Set("MmLlHhVvCcSsQqTtAaZz")

        func flushNumber() {
            if !numBuf.isEmpty {
                if let val = Double(numBuf) {
                    tokens.append(.number(CGFloat(val)))
                }
                numBuf = ""
            }
        }

        var prev: Character?
        for ch in d {
            if commandChars.contains(ch) {
                flushNumber()
                tokens.append(.command(ch))
            } else if ch == "," || ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                flushNumber()
            } else if ch == "-" {
                // Negative sign: starts a new number unless the buffer is empty
                // or the previous character was 'e'/'E' (scientific notation)
                if !numBuf.isEmpty && prev != "e" && prev != "E" {
                    flushNumber()
                }
                numBuf.append(ch)
            } else if ch == "." {
                // Second decimal point starts a new number
                if numBuf.contains(".") {
                    flushNumber()
                }
                numBuf.append(ch)
            } else {
                numBuf.append(ch)
            }
            prev = ch
        }
        flushNumber()
        return tokens
    }
}
