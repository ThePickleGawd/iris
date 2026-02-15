import Foundation
import PencilKit
import UIKit

@MainActor
final class SVGStrokeAnimator {

    private let canvasView: NoteCanvasView
    private let cursor: AgentCursorController
    private let objectManager: CanvasObjectManager

    init(canvasView: NoteCanvasView, cursor: AgentCursorController, objectManager: CanvasObjectManager) {
        self.canvasView = canvasView
        self.cursor = cursor
        self.objectManager = objectManager
    }

    func animate(
        strokes: [SVGStroke],
        textRuns: [SVGTextRun] = [],
        origin: CGPoint,
        scale: CGFloat,
        color: UIColor,
        strokeWidth: CGFloat,
        speed: Double
    ) async {
        let baseDrawing = canvasView.drawing
        var completedStrokes: [PKStroke] = []
        let traceWidthMultiplier: CGFloat = 1.24
        let fps: Double = 60
        let frameNanos = UInt64(1_000_000_000.0 / fps)
        let effectiveSpeed = max(0.65, speed)
        let desiredPointsPerSecond = 260.0 * effectiveSpeed
        let computedPointsPerFrame = max(1, Int(ceil(desiredPointsPerSecond / fps)))
        let pointsPerFrame = min(2, computedPointsPerFrame)
        let vectorStrokes = strokes.filter { $0.source != .text }
        let textStrokes = strokes.filter { $0.source == .text }

        // Separate outline strokes (animated) from fill strokes (batched)
        let outlineStrokes = vectorStrokes.filter { !$0.isFill }
        let fillStrokes = vectorStrokes.filter { $0.isFill }
        let animatedStrokes = outlineStrokes.isEmpty ? Array(fillStrokes.prefix(1)) : outlineStrokes
        let nonAnimatedFillStrokes: [SVGStroke] = {
            if outlineStrokes.isEmpty {
                return Array(fillStrokes.dropFirst(animatedStrokes.count))
            }
            return fillStrokes
        }()

        typealias StrokeTrace = (densePoints: [CGPoint], pkPoints: [PKStrokePoint])
        var strokeTraces: [StrokeTrace] = []
        strokeTraces.reserveCapacity(animatedStrokes.count)
        for svgStroke in animatedStrokes {
            let densePoints = densifyPoints(
                svgStroke.points,
                maxStep: max(2.8, 7.0 / max(scale, 0.1))
            )
            guard densePoints.count >= 2 else { continue }
            let w = ((svgStroke.strokeWidth ?? strokeWidth) * scale * traceWidthMultiplier)
            let pkPoints = densePoints.enumerated().map { idx, pt -> PKStrokePoint in
                PKStrokePoint(
                    location: canvasPt(pt, origin: origin, scale: scale),
                    timeOffset: TimeInterval(idx) / fps,
                    size: CGSize(width: w, height: w),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
                )
            }
            strokeTraces.append((densePoints: densePoints, pkPoints: pkPoints))
        }

        cursor.disappear()

        if !strokeTraces.isEmpty {
            // (1) Move to first start before any SVG path pixels appear.
            let firstStartScreen = screenPt(strokeTraces[0].densePoints[0], origin: origin, scale: scale)
            cursor.appear(at: firstStartScreen)
            try? await Task.sleep(nanoseconds: 70_000_000)

            // (2) Draw/trace path strokes with Iris pointer cursor.
            for (strokeIndex, trace) in strokeTraces.enumerated() {
                let densePoints = trace.densePoints
                let pkPoints = trace.pkPoints
                let strokeStartScreen = screenPt(densePoints[0], origin: origin, scale: scale)

                if strokeIndex > 0 {
                    await moveCursorLinearly(to: strokeStartScreen, fps: fps)
                    try? await Task.sleep(nanoseconds: 24_000_000)
                } else {
                    cursor.position = strokeStartScreen
                }

                // Draw progressively
                var idx = 1
                while idx < pkPoints.count {
                    cursor.position = screenPt(densePoints[idx], origin: origin, scale: scale)
                    let path = PKStrokePath(controlPoints: Array(pkPoints[0...idx]), creationDate: Date())
                    var drawing = baseDrawing
                    for s in completedStrokes { drawing.strokes.append(s) }
                    drawing.strokes.append(PKStroke(
                        ink: inkForStroke(animatedStrokes[strokeIndex], fallback: color),
                        path: path
                    ))
                    canvasView.drawing = drawing

                    if idx >= pkPoints.count - 1 { break }
                    try? await Task.sleep(nanoseconds: frameNanos)
                    idx = min(idx + pointsPerFrame, pkPoints.count - 1)
                }

                let fullPath = PKStrokePath(controlPoints: pkPoints, creationDate: Date())
                completedStrokes.append(PKStroke(
                    ink: inkForStroke(animatedStrokes[strokeIndex], fallback: color),
                    path: fullPath
                ))
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }

        // Add path fill strokes at once (no animation — they appear instantly)
        for svgStroke in nonAnimatedFillStrokes {
            guard svgStroke.points.count >= 2 else { continue }
            let fillWidth = (svgStroke.strokeWidth ?? 1) * scale * traceWidthMultiplier
            let pkPoints = svgStroke.points.enumerated().map { idx, pt -> PKStrokePoint in
                PKStrokePoint(
                    location: canvasPt(pt, origin: origin, scale: scale),
                    timeOffset: TimeInterval(idx) / fps,
                    size: CGSize(width: fillWidth, height: fillWidth),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
                )
            }
            let path = PKStrokePath(controlPoints: pkPoints, creationDate: Date())
            completedStrokes.append(PKStroke(
                ink: inkForStroke(svgStroke, fallback: color),
                path: path
            ))
        }

        // Text runs use a fast typed effect with a blinking caret (no Iris pointer).
        if !textRuns.isEmpty {
            cursor.disappear()
            await animateTypedTextRuns(textRuns, origin: origin, scale: scale, speed: speed)
        }

        // Commit text geometry (so typed text persists in drawing file).
        for svgStroke in textStrokes {
            guard svgStroke.points.count >= 2 else { continue }
            let width = (svgStroke.strokeWidth ?? strokeWidth) * scale * traceWidthMultiplier
            let pkPoints = svgStroke.points.enumerated().map { idx, pt -> PKStrokePoint in
                PKStrokePoint(
                    location: canvasPt(pt, origin: origin, scale: scale),
                    timeOffset: TimeInterval(idx) / fps,
                    size: CGSize(width: width, height: width),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
                )
            }
            let path = PKStrokePath(controlPoints: pkPoints, creationDate: Date())
            completedStrokes.append(PKStroke(
                ink: inkForStroke(svgStroke, fallback: color),
                path: path
            ))
        }

        // Commit final drawing with outlines + fills
        var finalDrawing = baseDrawing
        for s in completedStrokes { finalDrawing.strokes.append(s) }
        canvasView.drawing = finalDrawing
        try? await Task.sleep(nanoseconds: 24_000_000)
        cursor.disappear()
    }

    // MARK: - Coordinates

    private func canvasPt(_ svgPoint: CGPoint, origin: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + svgPoint.x * scale, y: origin.y + svgPoint.y * scale)
    }

    private func screenPt(_ svgPoint: CGPoint, origin: CGPoint, scale: CGFloat) -> CGPoint {
        canvasView.screenPoint(forCanvasPoint: canvasPt(svgPoint, origin: origin, scale: scale))
    }

    private func densifyPoints(_ points: [CGPoint], maxStep: CGFloat) -> [CGPoint] {
        guard points.count >= 2, maxStep > 0 else { return points }
        var result: [CGPoint] = [points[0]]

        for i in 1..<points.count {
            let start = points[i - 1]
            let end = points[i]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let distance = hypot(dx, dy)
            if distance <= maxStep {
                result.append(end)
                continue
            }

            let segments = max(1, Int(ceil(distance / maxStep)))
            for step in 1...segments {
                let t = CGFloat(step) / CGFloat(segments)
                result.append(
                    CGPoint(
                        x: start.x + dx * t,
                        y: start.y + dy * t
                    )
                )
            }
        }

        return result
    }

    private func moveCursorLinearly(to target: CGPoint, fps: Double) async {
        let start = cursor.position
        let dx = target.x - start.x
        let dy = target.y - start.y
        let distance = hypot(dx, dy)
        if distance <= 1 {
            cursor.position = target
            return
        }

        let pixelsPerSecond: CGFloat = 1800
        let duration = min(0.18, max(0.04, Double(distance / pixelsPerSecond)))
        let steps = max(1, Int(ceil(duration * fps)))
        let stepNanos = UInt64((duration / Double(steps)) * 1_000_000_000.0)

        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            cursor.position = CGPoint(
                x: start.x + dx * t,
                y: start.y + dy * t
            )
            try? await Task.sleep(nanoseconds: stepNanos)
        }

        cursor.position = target
    }

    private func uiColor(from raw: String?, fallback: UIColor) -> UIColor {
        guard let raw else { return fallback }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return fallback }
        var hex = normalized
        if !hex.hasPrefix("#") { hex = "#\(hex)" }
        let candidate = hex.dropFirst()
        let isHex = candidate.range(of: #"^[0-9a-fA-F]{3,8}$"#, options: .regularExpression) != nil
        guard isHex else { return fallback }

        let cleaned = String(candidate)
        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else { return fallback }

        let r, g, b, a: CGFloat
        switch cleaned.count {
        case 3:
            r = CGFloat((value >> 8) & 0xF) / 15.0
            g = CGFloat((value >> 4) & 0xF) / 15.0
            b = CGFloat(value & 0xF) / 15.0
            a = 1
        case 4:
            r = CGFloat((value >> 12) & 0xF) / 15.0
            g = CGFloat((value >> 8) & 0xF) / 15.0
            b = CGFloat((value >> 4) & 0xF) / 15.0
            a = CGFloat(value & 0xF) / 15.0
        case 6:
            r = CGFloat((value >> 16) & 0xFF) / 255.0
            g = CGFloat((value >> 8) & 0xFF) / 255.0
            b = CGFloat(value & 0xFF) / 255.0
            a = 1
        case 8:
            r = CGFloat((value >> 24) & 0xFF) / 255.0
            g = CGFloat((value >> 16) & 0xFF) / 255.0
            b = CGFloat((value >> 8) & 0xFF) / 255.0
            a = CGFloat(value & 0xFF) / 255.0
        default:
            return fallback
        }
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }

    private func inkForStroke(_ stroke: SVGStroke, fallback: UIColor) -> PKInk {
        let resolved = uiColor(from: stroke.color, fallback: fallback)
        let type: PKInk.InkType = (stroke.source == .text) ? .monoline : .pen
        return PKInk(type, color: resolved)
    }

    private func animateTypedTextRuns(
        _ runs: [SVGTextRun],
        origin: CGPoint,
        scale: CGFloat,
        speed: Double
    ) async {
        let overlay: UIView = canvasView
        let charsPerSecond = max(24.0, 62.0 * max(0.4, speed))
        let perCharNanos = UInt64(1_000_000_000.0 / charsPerSecond)

        for run in runs {
            let anchorCanvas = canvasPt(run.anchor, origin: origin, scale: scale)
            let anchorScreen = canvasView.screenPoint(forCanvasPoint: anchorCanvas)
            let size = max(10, run.fontSize * scale)
            let font = UIFont(name: run.fontFamily, size: size)
                ?? UIFont.systemFont(ofSize: size, weight: .regular)
            let color = uiColor(from: run.color, fallback: .label)

            let label = UILabel()
            label.backgroundColor = .clear
            label.font = font
            label.textColor = color
            label.text = ""
            label.numberOfLines = 1
            label.sizeToFit()
            label.frame.origin = CGPoint(
                x: anchorScreen.x,
                y: anchorScreen.y - font.ascender
            )

            let caret = UIView(frame: CGRect(x: label.frame.maxX + 2, y: label.frame.minY, width: 3, height: font.lineHeight))
            caret.backgroundColor = color.withAlphaComponent(0.95)
            caret.layer.cornerRadius = 1.5
            caret.layer.masksToBounds = true
            caret.layer.zPosition = 3000
            caret.layer.shadowColor = color.cgColor
            caret.layer.shadowOpacity = 0.35
            caret.layer.shadowRadius = 2
            caret.layer.shadowOffset = .zero
            label.layer.zPosition = 2999
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1.0
            blink.toValue = 0.0
            blink.duration = 0.45
            blink.autoreverses = true
            blink.repeatCount = .infinity
            caret.layer.add(blink, forKey: "blink")

            overlay.addSubview(label)
            overlay.addSubview(caret)
            try? await Task.sleep(nanoseconds: 170_000_000)

            var current = ""
            for ch in run.text {
                current.append(ch)
                label.text = current
                label.sizeToFit()
                label.frame.origin = CGPoint(
                    x: anchorScreen.x,
                    y: anchorScreen.y - font.ascender
                )
                caret.frame = CGRect(
                    x: label.frame.maxX + 2,
                    y: label.frame.minY,
                    width: 3,
                    height: font.lineHeight
                )
                try? await Task.sleep(nanoseconds: perCharNanos)
            }

            try? await Task.sleep(nanoseconds: 220_000_000)
            caret.layer.removeAnimation(forKey: "blink")
            caret.removeFromSuperview()
            label.removeFromSuperview()
        }
    }
}
