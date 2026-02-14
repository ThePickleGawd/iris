import UIKit

@MainActor
final class CanvasObjectManager: ObservableObject {
    @Published private(set) var objects: [UUID: CanvasObject] = [:]
    @Published private(set) var suggestions: [UUID: WidgetSuggestion] = [:]
    @Published private(set) var viewportRevision: Int = 0

    private(set) var objectViews: [UUID: CanvasObjectWebView] = [:]
    private(set) var suggestionViews: [UUID: SuggestionChipView] = [:]

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

    func notifyViewportChanged() {
        viewportRevision &+= 1
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

    func screenPoint(forCanvasPoint point: CGPoint) -> CGPoint {
        guard let canvasView else { return point }
        return canvasView.screenPoint(forCanvasPoint: point)
    }

    /// Captures the current visible canvas viewport as PNG data.
    /// Uses drawHierarchy on the full canvas view, so this includes:
    /// - drawing strokes
    /// - widgets (overlay subviews)
    /// - suggestion chips (same overlay)
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

    // MARK: - Suggestions

    @discardableResult
    func addSuggestion(
        title: String,
        summary: String,
        html: String,
        at position: CGPoint,
        size: CGSize = CGSize(width: 360, height: 220),
        animateOnPlace: Bool = true
    ) -> WidgetSuggestion {
        let suggestion = WidgetSuggestion(
            title: title,
            summary: summary,
            htmlContent: html,
            position: position,
            size: size,
            animateOnPlace: animateOnPlace
        )
        suggestions[suggestion.id] = suggestion
        attachSuggestionView(for: suggestion)
        return suggestion
    }

    @discardableResult
    func rejectSuggestion(id: UUID) -> Bool {
        suggestionViews[id]?.removeFromSuperview()
        suggestionViews.removeValue(forKey: id)
        return suggestions.removeValue(forKey: id) != nil
    }

    @discardableResult
    func approveSuggestion(id: UUID) async -> CanvasObject? {
        guard let suggestion = suggestions.removeValue(forKey: id) else { return nil }
        suggestionViews[id]?.removeFromSuperview()
        suggestionViews.removeValue(forKey: id)

        return await place(
            html: suggestion.htmlContent,
            at: suggestion.position,
            size: suggestion.size,
            animated: suggestion.animateOnPlace
        )
    }

    private func attachSuggestionView(for suggestion: WidgetSuggestion) {
        guard let canvasView else { return }

        suggestionViews[suggestion.id]?.removeFromSuperview()

        let chip = SuggestionChipView(
            id: suggestion.id,
            title: suggestion.title,
            summary: suggestion.summary
        )

        chip.frame = CGRect(origin: suggestion.position, size: CGSize(width: 270, height: 92))
        chip.onApprove = { [weak self] id in
            guard let self else { return }
            Task { _ = await self.approveSuggestion(id: id) }
        }
        chip.onReject = { [weak self] id in
            _ = self?.rejectSuggestion(id: id)
        }

        canvasView.widgetContainerView().addSubview(chip)
        suggestionViews[suggestion.id] = chip
    }
}

final class SuggestionChipView: UIView {
    let suggestionID: UUID
    var onApprove: ((UUID) -> Void)?
    var onReject: ((UUID) -> Void)?

    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()
    private let addButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    init(id: UUID, title: String, summary: String) {
        self.suggestionID = id
        super.init(frame: .zero)

        backgroundColor = UIColor(white: 1.0, alpha: 0.95)
        layer.cornerRadius = 12
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 0.86, alpha: 1).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.08
        layer.shadowOffset = CGSize(width: 0, height: 4)
        layer.shadowRadius = 10

        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = UIColor(white: 0.12, alpha: 1)
        addSubview(titleLabel)

        summaryLabel.text = summary
        summaryLabel.font = UIFont.systemFont(ofSize: 11, weight: .regular)
        summaryLabel.textColor = UIColor(white: 0.36, alpha: 1)
        summaryLabel.numberOfLines = 2
        addSubview(summaryLabel)

        addButton.setTitle("Add", for: .normal)
        addButton.setTitleColor(.white, for: .normal)
        addButton.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        addButton.backgroundColor = UIColor.systemBlue
        addButton.layer.cornerRadius = 11
        addButton.addTarget(self, action: #selector(handleAdd), for: .touchUpInside)
        addSubview(addButton)

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = UIColor(white: 0.4, alpha: 1)
        closeButton.backgroundColor = UIColor(white: 0.95, alpha: 1)
        closeButton.layer.cornerRadius = 11
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.frame = CGRect(x: 10, y: 10, width: bounds.width - 92, height: 16)
        summaryLabel.frame = CGRect(x: 10, y: 30, width: bounds.width - 20, height: 34)
        addButton.frame = CGRect(x: bounds.width - 64, y: bounds.height - 30, width: 52, height: 22)
        closeButton.frame = CGRect(x: bounds.width - 28, y: 8, width: 20, height: 20)
    }

    @objc private func handleAdd() { onApprove?(suggestionID) }
    @objc private func handleClose() { onReject?(suggestionID) }
}
