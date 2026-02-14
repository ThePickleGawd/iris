import UIKit
import WebKit

class CanvasObjectWebView: UIView {
    let webView: WKWebView
    let objectID: UUID
    private var currentZoomScale: CGFloat = 1.0

    /// Called when the user finishes dragging. New origin in canvas content coordinates.
    var onDragEnded: ((UUID, CGPoint) -> Void)?

    init(id: UUID, size: CGSize, htmlContent: String) {
        self.objectID = id

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        self.webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)

        super.init(frame: CGRect(origin: .zero, size: size))

        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isUserInteractionEnabled = false // touches go to pan gesture
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(webView)

        // Visual styling
        layer.cornerRadius = 12
        layer.masksToBounds = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowOffset = CGSize(width: 0, height: 4)
        layer.shadowRadius = 12

        webView.layer.cornerRadius = 12
        webView.layer.masksToBounds = true

        setupDragGesture()
        loadHTML(htmlContent)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Drag gesture

    private func setupDragGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        let translation = gesture.translation(in: parent)

        switch gesture.state {
        case .began:
            // Lift effect
            UIView.animate(withDuration: 0.2) {
                self.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
                self.layer.shadowOpacity = 0.25
                self.layer.shadowRadius = 20
            }

        case .changed:
            center = CGPoint(
                x: center.x + translation.x,
                y: center.y + translation.y
            )
            gesture.setTranslation(.zero, in: parent)

        case .ended, .cancelled:
            // Drop effect
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5) {
                self.transform = .identity
                self.layer.shadowOpacity = 0.15
                self.layer.shadowRadius = 12
            }
            onDragEnded?(objectID, frame.origin)

        default:
            break
        }
    }

    // MARK: - HTML

    private func loadHTML(_ content: String) {
        let css = loadDesignSystemCSS()
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>\(css)</style>
        </head>
        <body>\(content)</body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func loadDesignSystemCSS() -> String {
        if let url = Bundle.main.url(forResource: "iris-design-system", withExtension: "css"),
           let css = try? String(contentsOf: url) {
            return css
        }
        return """
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, sans-serif;
            font-size: 15px;
            line-height: 1.5;
            color: #1E2738;
            background: #FFFFFF;
            padding: 16px;
            -webkit-text-size-adjust: 100%;
        }
        h1 { font-size: 24px; font-weight: 600; margin-bottom: 8px; }
        h2 { font-size: 20px; font-weight: 600; margin-bottom: 8px; }
        p { margin-bottom: 8px; }
        code { font-family: ui-monospace, monospace; font-size: 13px; background: #F9FAFB; padding: 2px 6px; border-radius: 6px; }
        """
    }

    func updateForZoomScale(_ scale: CGFloat) {
        guard scale > 0 else { return }
        currentZoomScale = scale
        let inverseScale = 1.0 / scale
        webView.transform = CGAffineTransform(scaleX: inverseScale, y: inverseScale)
        webView.frame = bounds
    }
}
