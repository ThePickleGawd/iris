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
        origin: CGPoint,
        scale: CGFloat,
        color: UIColor,
        strokeWidth: CGFloat,
        speed: Double
    ) async {
        let baseDrawing = canvasView.drawing
        var completedStrokes: [PKStroke] = []
        let ink = PKInk(.pen, color: color)
        let traceWidthMultiplier: CGFloat = 1.24
        // Cursor should move at 1/5 normal speed.
        let cursorSpeedScale: Double = 0.2
        let cursorDurationScale: Double = 5.0
        let fps: Double = 60
        let frameNanos = UInt64((1_000_000_000.0 / fps) * cursorDurationScale)
        let effectiveSpeed = max(0.65, speed)
        let desiredPointsPerSecond = 260.0 * effectiveSpeed * cursorSpeedScale
        let computedPointsPerFrame = max(1, Int(ceil(desiredPointsPerSecond / fps)))
        let pointsPerFrame = min(1, computedPointsPerFrame)

        // Separate outline strokes (animated) from fill strokes (batched)
        let outlineStrokes = strokes.filter { !$0.isFill }
        let fillStrokes = strokes.filter { $0.isFill }
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

        guard !strokeTraces.isEmpty else { return }

        cursor.disappear()

        // (1) Move to first start before any SVG pixels appear.
        let firstStartScreen = screenPt(strokeTraces[0].densePoints[0], origin: origin, scale: scale)
        cursor.appear(at: firstStartScreen)
        try? await Task.sleep(nanoseconds: UInt64(70_000_000 * cursorDurationScale))

        // (2) Draw/trace with cursor.
        for (strokeIndex, trace) in strokeTraces.enumerated() {
            let densePoints = trace.densePoints
            let pkPoints = trace.pkPoints
            let strokeStartScreen = screenPt(densePoints[0], origin: origin, scale: scale)

            if strokeIndex > 0 {
                await moveCursorLinearly(to: strokeStartScreen, fps: fps)
                try? await Task.sleep(nanoseconds: UInt64(24_000_000 * cursorDurationScale))
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
                drawing.strokes.append(PKStroke(ink: ink, path: path))
                canvasView.drawing = drawing

                if idx >= pkPoints.count - 1 { break }
                try? await Task.sleep(nanoseconds: frameNanos)
                idx = min(idx + pointsPerFrame, pkPoints.count - 1)
            }

            let fullPath = PKStrokePath(controlPoints: pkPoints, creationDate: Date())
            completedStrokes.append(PKStroke(ink: ink, path: fullPath))
            try? await Task.sleep(nanoseconds: UInt64(8_000_000 * cursorDurationScale))
        }

        // Add all fill strokes at once (no animation — they appear instantly)
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
            completedStrokes.append(PKStroke(ink: ink, path: path))
        }

        // Commit final drawing with outlines + fills
        var finalDrawing = baseDrawing
        for s in completedStrokes { finalDrawing.strokes.append(s) }
        canvasView.drawing = finalDrawing
        try? await Task.sleep(nanoseconds: UInt64(24_000_000 * cursorDurationScale))

        // (3) Disappear cursor.
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

        let pixelsPerSecond: CGFloat = 360
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
}
