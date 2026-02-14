import UIKit
import WebKit

final class CanvasObjectWebView: UIView {
    let objectID: UUID
    private let webView: WKWebView

    var onDragEnded: ((UUID, CGPoint) -> Void)?
    var onResizeEnded: ((UUID, CGRect) -> Void)?
    var onCloseRequested: ((UUID) -> Void)?

    private let minSize = CGSize(width: 220, height: 150)
    private let topBar = UIView()
    private let closeButton = UIButton(type: .system)
    private let resizeHandle = UIView()
    private let topLeftLabel = UILabel()
    private let topRightLabel = UILabel()
    private let bottomLeftLabel = UILabel()
    private let bottomRightLabel = UILabel()
    private var startFrame: CGRect = .zero
    private var zoomScale: CGFloat = 1.0

    init(id: UUID, size: CGSize, htmlContent: String) {
        self.objectID = id
        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: CGRect(origin: .zero, size: size))

        layer.cornerRadius = 14
        layer.masksToBounds = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowOffset = CGSize(width: 0, height: 4)
        layer.shadowRadius = 14

        backgroundColor = .clear

        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = true
        webView.layer.cornerRadius = 14
        webView.layer.masksToBounds = true
        addSubview(webView)

        topBar.backgroundColor = UIColor(white: 1.0, alpha: 0.01)
        addSubview(topBar)

        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = UIColor(white: 0.35, alpha: 0.95)
        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.92)
        closeButton.layer.cornerRadius = 11
        closeButton.layer.masksToBounds = true
        closeButton.addTarget(self, action: #selector(handleCloseTapped), for: .touchUpInside)
        addSubview(closeButton)

        resizeHandle.backgroundColor = UIColor(white: 0.95, alpha: 0.95)
        resizeHandle.layer.cornerRadius = 8
        resizeHandle.layer.borderWidth = 1
        resizeHandle.layer.borderColor = UIColor(white: 0.72, alpha: 1).cgColor
        addSubview(resizeHandle)

        for label in [topLeftLabel, topRightLabel, bottomLeftLabel, bottomRightLabel] {
            styleCornerLabel(label)
            addSubview(label)
        }

        let dragPan = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        topBar.addGestureRecognizer(dragPan)

        let resizePan = UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
        resizeHandle.addGestureRecognizer(resizePan)

        loadHTML(htmlContent)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
        topBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(34, bounds.height))
        closeButton.frame = CGRect(x: max(6, bounds.width - 28), y: 6, width: 22, height: 22)
        resizeHandle.frame = CGRect(x: max(0, bounds.width - 22), y: max(0, bounds.height - 22), width: 18, height: 18)
        layoutCornerLabels()
        updateCornerLabelText()
    }

    @objc private func handleCloseTapped() {
        onCloseRequested?(objectID)
    }

    private func loadHTML(_ content: String) {
        let css = """
        * { box-sizing: border-box; }
        html, body { margin:0; padding:0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
            color: #0f172a;
            background: #ffffff;
            padding: 14px;
            line-height: 1.4;
        }
        h1,h2,h3 { margin: 0 0 8px 0; line-height: 1.2; }
        p { margin: 0 0 8px 0; }
        .card { border: 1px solid #e2e8f0; border-radius: 12px; padding: 12px; }
        table { width:100%; border-collapse: collapse; }
        th, td { border-bottom: 1px solid #e2e8f0; text-align: left; padding: 6px; font-size: 13px; }
        """

        let html = """
        <!doctype html>
        <html>
        <head>
            <meta name=\"viewport\" content=\"width=device-width,initial-scale=1.0\">
            <style>\(css)</style>
        </head>
        <body>\(content)</body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    @objc private func handleDrag(_ g: UIPanGestureRecognizer) {
        guard let host = superview else { return }
        let t = g.translation(in: host)
        let inv = 1.0 / max(zoomScale, 0.0001)

        switch g.state {
        case .began:
            UIView.animate(withDuration: 0.12) { self.layer.shadowOpacity = 0.2 }
        case .changed:
            center = CGPoint(x: center.x + t.x * inv, y: center.y + t.y * inv)
            g.setTranslation(.zero, in: host)
        case .ended, .cancelled:
            UIView.animate(withDuration: 0.12) { self.layer.shadowOpacity = 0.12 }
            onDragEnded?(objectID, frame.origin)
        default:
            break
        }
    }

    @objc private func handleResize(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: superview)
        let inv = 1.0 / max(zoomScale, 0.0001)

        switch g.state {
        case .began:
            startFrame = frame
        case .changed:
            var f = startFrame
            f.size.width = max(minSize.width, startFrame.size.width + t.x * inv)
            f.size.height = max(minSize.height, startFrame.size.height + t.y * inv)
            frame = f
        case .ended, .cancelled:
            onResizeEnded?(objectID, frame)
        default:
            break
        }
    }

    func updateForZoomScale(_ scale: CGFloat) {
        zoomScale = scale
    }

    private func styleCornerLabel(_ label: UILabel) {
        label.isUserInteractionEnabled = false
        label.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        label.textColor = UIColor(white: 0.15, alpha: 0.95)
        label.backgroundColor = UIColor.white.withAlphaComponent(0.92)
        label.layer.cornerRadius = 6
        label.layer.masksToBounds = true
        label.textAlignment = .center
    }

    private func layoutCornerLabels() {
        let labelSize = CGSize(width: 88, height: 18)
        topLeftLabel.frame = CGRect(x: 6, y: 6, width: labelSize.width, height: labelSize.height)
        topRightLabel.frame = CGRect(x: max(6, bounds.width - labelSize.width - 32), y: 6, width: labelSize.width, height: labelSize.height)
        bottomLeftLabel.frame = CGRect(x: 6, y: max(6, bounds.height - labelSize.height - 6), width: labelSize.width, height: labelSize.height)
        bottomRightLabel.frame = CGRect(x: max(6, bounds.width - labelSize.width - 6), y: max(6, bounds.height - labelSize.height - 6), width: labelSize.width, height: labelSize.height)
        bringSubviewToFront(closeButton)
        bringSubviewToFront(resizeHandle)
    }

    private func updateCornerLabelText() {
        let center = CanvasState.canvasCenter
        let tl = CGPoint(x: frame.minX - center.x, y: frame.minY - center.y)
        let tr = CGPoint(x: frame.maxX - center.x, y: frame.minY - center.y)
        let bl = CGPoint(x: frame.minX - center.x, y: frame.maxY - center.y)
        let br = CGPoint(x: frame.maxX - center.x, y: frame.maxY - center.y)

        topLeftLabel.text = "TL \(Int(tl.x)),\(Int(tl.y))"
        topRightLabel.text = "TR \(Int(tr.x)),\(Int(tr.y))"
        bottomLeftLabel.text = "BL \(Int(bl.x)),\(Int(bl.y))"
        bottomRightLabel.text = "BR \(Int(br.x)),\(Int(br.y))"
    }
}
