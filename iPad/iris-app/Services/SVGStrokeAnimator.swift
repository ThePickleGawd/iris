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
        let fps: Double = 30
        let frameNanos = UInt64(1_000_000_000.0 / (fps * max(speed, 0.1)))
        let pointsPerFrame = max(1, Int(ceil(speed)))

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

        cursor.disappear()
        // Appear at first point of first drawable stroke.
        if let first = animatedStrokes.first?.points.first {
            cursor.appear(at: screenPt(first, origin: origin, scale: scale))
            try? await Task.sleep(nanoseconds: 240_000_000)
        }

        // Animate a stroke sequence with cursor tracking.
        for svgStroke in animatedStrokes {
            guard svgStroke.points.count >= 2 else { continue }

            let w = ((svgStroke.strokeWidth ?? strokeWidth) * scale * traceWidthMultiplier)
            let pkPoints = svgStroke.points.enumerated().map { idx, pt -> PKStrokePoint in
                PKStrokePoint(
                    location: canvasPt(pt, origin: origin, scale: scale),
                    timeOffset: TimeInterval(idx) / fps,
                    size: CGSize(width: w, height: w),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
                )
            }

            // Animate cursor to stroke start
            cursor.moveTo(screenPt(svgStroke.points[0], origin: origin, scale: scale), duration: 0.15)
            try? await Task.sleep(nanoseconds: 130_000_000)

            // Draw progressively
            var idx = 0
            while idx < pkPoints.count {
                idx = min(idx + pointsPerFrame, pkPoints.count - 1)

                let path = PKStrokePath(controlPoints: Array(pkPoints[0...idx]), creationDate: Date())
                var drawing = baseDrawing
                for s in completedStrokes { drawing.strokes.append(s) }
                drawing.strokes.append(PKStroke(ink: ink, path: path))
                canvasView.drawing = drawing

                cursor.position = screenPt(svgStroke.points[idx], origin: origin, scale: scale)

                if idx >= pkPoints.count - 1 { break }
                try? await Task.sleep(nanoseconds: frameNanos)
            }

            let fullPath = PKStrokePath(controlPoints: pkPoints, creationDate: Date())
            completedStrokes.append(PKStroke(ink: ink, path: fullPath))
            try? await Task.sleep(nanoseconds: 110_000_000)
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
        try? await Task.sleep(nanoseconds: 180_000_000)
        cursor.disappear()
    }

    // MARK: - Coordinates

    private func canvasPt(_ svgPoint: CGPoint, origin: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + svgPoint.x * scale, y: origin.y + svgPoint.y * scale)
    }

    private func screenPt(_ svgPoint: CGPoint, origin: CGPoint, scale: CGFloat) -> CGPoint {
        canvasView.screenPoint(forCanvasPoint: canvasPt(svgPoint, origin: origin, scale: scale))
    }
}
