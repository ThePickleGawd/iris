import Foundation
import Network
import UIKit

/// Lightweight HTTP server that exposes a REST API for AI agents
/// to place, query, and remove HTML widget objects on the canvas.
///
/// Starts listening on a configurable TCP port. Placement coordinates
/// are relative to the user's current viewport center (0,0 = where they're looking).
///
/// Advertises itself via Bonjour (`_iris-canvas._tcp`) so that Mac and
/// other devices on the same network discover it automatically.
class AgentHTTPServer {
    static let shared = AgentHTTPServer()

    static let defaultPort: UInt16 = 8935
    static let bonjourType = "_iris-canvas._tcp"

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "iris.agent-http", qos: .userInitiated)
    private weak var objectManager: CanvasObjectManager?

    /// Devices that have linked with this iPad via POST /api/v1/link
    private(set) var linkedDevices: [String: LinkedDevice] = [:]

    /// Returns the URL of the first linked device's agent server (port 8000), if available
    func agentServerURL() -> URL? {
        guard let device = linkedDevices.values.first, let ip = device.ip, !ip.isEmpty else {
            return nil
        }
        return URL(string: "http://\(ip):8000")
    }

    /// Returns the URL of the first linked device's backend server (port 8000), if available.
    func backendServerURL() -> URL? {
        guard let device = linkedDevices.values.first, let ip = device.ip, !ip.isEmpty else {
            return nil
        }
        let backendPort = UserDefaults.standard.integer(forKey: "iris_backend_port")
        let port = backendPort > 0 ? backendPort : 8000
        return URL(string: "http://\(ip):\(port)")
    }

    let port: UInt16
    let deviceID: String

    init(port: UInt16 = AgentHTTPServer.defaultPort) {
        self.port = port

        // Stable device ID persisted across launches
        let key = "iris_device_id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            self.deviceID = existing
        } else {
            let created = UUID().uuidString
            UserDefaults.standard.set(created, forKey: key)
            self.deviceID = created
        }
    }

    deinit { stop() }

    // MARK: - Lifecycle

    func start(objectManager: CanvasObjectManager) {
        self.objectManager = objectManager
        if listener != nil {
            print("[iris] Agent API already running — switched active canvas manager")
            return
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        do {
            listener = try NWListener(using: .tcp, on: nwPort)
        } catch {
            print("[iris] HTTP server failed: \(error)")
            return
        }

        // Advertise via Bonjour so Mac/agents discover us automatically
        let deviceName = UIDevice.current.name
        listener?.service = NWListener.Service(name: "Iris (\(deviceName))", type: Self.bonjourType)

        listener?.stateUpdateHandler = { [port] state in
            switch state {
            case .ready:
                print("[iris] Agent API ready → http://localhost:\(port)/api/v1/health")
                print("[iris] Bonjour: advertising \(Self.bonjourType)")
            case .failed(let error):
                print("[iris] Agent API failed: \(error)")
            case .cancelled:
                print("[iris] Agent API stopped")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffered: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffered: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                conn.cancel()
                return
            }

            if error != nil {
                conn.cancel()
                return
            }

            var combined = buffered
            if let data, !data.isEmpty {
                combined.append(data)
            }

            if let req = HTTPRequest.parse(combined) {
                self.route(req, conn)
                return
            }

            if combined.count > 1_048_576 {
                self.respondJSON(conn, status: 413, body: ["error": "Request too large"])
                return
            }

            if isComplete {
                self.respondJSON(conn, status: 400, body: ["error": "Malformed HTTP request"])
                return
            }

            self.receiveRequest(conn, buffered: combined)
        }
    }

    // MARK: - Router

    private func route(_ req: HTTPRequest, _ conn: NWConnection) {
        let rawPath = req.path.split(separator: "?").first.map(String.init) ?? req.path
        let segs = rawPath.split(separator: "/").map(String.init)

        // CORS preflight
        if req.method == "OPTIONS" {
            respondJSON(conn, status: 204, body: nil)
            return
        }

        // api/v1 prefix check
        guard segs.count >= 3, segs[0] == "api", segs[1] == "v1" else {
            respondJSON(conn, status: 404, body: ["error": "Not found", "path": req.path])
            return
        }

        let resource = segs[2]
        let resourceID: String? = segs.count >= 4 ? segs[3] : nil
        let resourceAction: String? = segs.count >= 5 ? segs[4] : nil

        switch (req.method, resource, resourceID, resourceAction) {

        case ("GET", "health", nil, nil):
            respondJSON(conn, status: 200, body: [
                "status": "ok",
                "service": "iris-canvas",
                "version": "1.0"
            ])

        case ("GET", "canvas", nil, nil):
            handleCanvasInfo(conn)

        case ("GET", "design-system.css", nil, nil):
            handleDesignSystemCSS(conn)

        case ("POST", "objects", nil, nil):
            handlePlaceObject(req, conn)

        case ("GET", "objects", nil, nil):
            handleListObjects(conn)

        case ("GET", "objects", .some(let id), nil):
            handleGetObject(id, conn)

        case ("DELETE", "objects", .some(let id), nil):
            handleDeleteObject(id, conn)

        case ("DELETE", "objects", nil, nil):
            handleDeleteAllObjects(conn)

        case ("POST", "suggestions", nil, nil):
            handleCreateSuggestion(req, conn)

        case ("GET", "suggestions", nil, nil):
            handleListSuggestions(conn)

        case ("POST", "suggestions", .some(let id), .some("approve")):
            handleApproveSuggestion(id, conn)

        case ("POST", "suggestions", .some(let id), .some("reject")):
            handleRejectSuggestion(id, conn)

        case ("GET", "device", nil, nil):
            handleDeviceInfo(conn)

        case ("POST", "draw", nil, nil):
            handleDraw(req, conn)

        case ("POST", "cursor", nil, nil):
            handleCursorCommand(req, conn)

        case ("POST", "link", nil, nil):
            handleLink(req, conn)

        case ("GET", "link", nil, nil):
            handleListLinked(conn)

        case ("DELETE", "link", .some(let id), nil):
            handleUnlink(id, conn)

        default:
            respondJSON(conn, status: 404, body: ["error": "Not found", "path": req.path])
        }
    }

    // MARK: - Handlers

    private func handleCanvasInfo(_ conn: NWConnection) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let center = CanvasState.canvasCenter
            let mgr = self.objectManager
            let viewport = mgr?.viewportCenter ?? center
            let snapshot = mgr?.makeCoordinateSnapshot(documentID: nil)
            let topLeft: [String: Any] = [
                "x": snapshot?.viewportTopLeftAxis.x ?? 0,
                "y": snapshot?.viewportTopLeftAxis.y ?? 0
            ]
            let topRight: [String: Any] = [
                "x": snapshot?.viewportTopRightAxis.x ?? 0,
                "y": snapshot?.viewportTopRightAxis.y ?? 0
            ]
            let bottomLeft: [String: Any] = [
                "x": snapshot?.viewportBottomLeftAxis.x ?? 0,
                "y": snapshot?.viewportBottomLeftAxis.y ?? 0
            ]
            let bottomRight: [String: Any] = [
                "x": snapshot?.viewportBottomRightAxis.x ?? 0,
                "y": snapshot?.viewportBottomRightAxis.y ?? 0
            ]

            let coordinateInfo: [String: Any] = [
                "default_post_space": "viewport_offset",
                "recommended_post_space": "viewport_local",
                "supported_spaces": [
                    "viewport_offset",
                    "viewport_center_offset",
                    "viewport_local",
                    "viewport_top_left",
                    "canvas_absolute",
                    "document_axis"
                ],
                "document_axis_origin_canvas": ["x": center.x, "y": center.y],
                "document_axis_description": "document_axis x/y where (0,0) is canvas center. Positive x=right, positive y=down.",
                "viewport_offset_description": "viewport_offset (alias viewport_center_offset): x/y offsets from the current viewport center.",
                "viewport_local_description": "viewport_local (alias viewport_top_left): x/y offsets from the current viewport top-left.",
                "viewport_bounds_document_axis": [
                    "top_left": topLeft,
                    "top_right": topRight,
                    "bottom_left": bottomLeft,
                    "bottom_right": bottomRight
                ]
            ]

            let body: [String: Any] = [
                "canvas_size": CanvasState.canvasSize,
                "canvas_center": ["x": center.x, "y": center.y],
                "viewport_center": ["x": viewport.x, "y": viewport.y],
                "coordinate_info": coordinateInfo
            ]
            self.respondJSON(conn, status: 200, body: body)
        }
    }

    private func handleDesignSystemCSS(_ conn: NWConnection) {
        var css = "/* iris-design-system.css not found in bundle */"
        if let url = Bundle.main.url(forResource: "iris-design-system", withExtension: "css"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            css = content
        }
        respondRaw(conn, status: 200, contentType: "text/css; charset=utf-8", body: css)
    }

    private func handlePlaceObject(_ req: HTTPRequest, _ conn: NWConnection) {
        guard let json = req.jsonBody, let html = json["html"] as? String else {
            respondJSON(conn, status: 400, body: ["error": "Missing required field: 'html' (string)"])
            return
        }

        let x     = numericValue(json["x"]) ?? 0
        let y     = numericValue(json["y"]) ?? 0
        let w     = numericValue(json["width"]) ?? 320
        let h     = numericValue(json["height"]) ?? 220
        let anim  = (json["animate"] as? Bool) ?? true
        let renderMode = (json["render_mode"] as? String ?? "handwritten").lowercased()
        let coordinateSpace = (json["coordinate_space"] as? String ?? "viewport_offset").lowercased()

        guard let mgr = objectManager else {
            respondJSON(conn, status: 503, body: ["error": "Canvas not ready — open a document first"])
            return
        }

        Task { @MainActor [weak self] in
            let canonicalSpace = self?.canonicalCoordinateSpace(coordinateSpace) ?? "viewport_center_offset"
            let canvasPos = self?.resolveCanvasPoint(
                x: x,
                y: y,
                coordinateSpace: canonicalSpace,
                manager: mgr
            ) ?? mgr.viewportCenter
            let viewport = mgr.viewportCenter
            let size = CGSize(width: w, height: h)
            let axis = mgr.axisPoint(forCanvasPoint: canvasPos)
            let text = self?.extractPlainText(fromHTML: html) ?? ""
            let wantsHandwritten = renderMode != "widget"

            if wantsHandwritten, !text.isEmpty {
                let inkSize = await mgr.drawHandwrittenText(
                    text,
                    at: canvasPos,
                    maxWidth: size.width
                )
                self?.respondJSON(conn, status: 201, body: [
                    "id": UUID().uuidString,
                    "x": x, "y": y,
                    "coordinate_space_used": canonicalSpace,
                    "rendered_as": "handwritten_ink",
                    "width": max(inkSize.width, size.width),
                    "height": max(inkSize.height, 44),
                    "viewport_center": ["x": viewport.x, "y": viewport.y],
                    "canvas_position": ["x": canvasPos.x, "y": canvasPos.y],
                    "document_axis_position": ["x": axis.x, "y": axis.y]
                ])
                return
            }

            let obj = await mgr.place(html: html, at: canvasPos, size: size, animated: anim)
            self?.respondJSON(conn, status: 201, body: [
                "id": obj.id.uuidString,
                "x": x, "y": y,
                "coordinate_space_used": canonicalSpace,
                "rendered_as": "widget",
                "width": w, "height": h,
                "viewport_center": ["x": viewport.x, "y": viewport.y],
                "canvas_position": ["x": canvasPos.x, "y": canvasPos.y],
                "document_axis_position": ["x": axis.x, "y": axis.y]
            ])
        }
    }

    private func extractPlainText(fromHTML html: String) -> String {
        let withBreaks = html.replacingOccurrences(
            of: "(?i)<br\\s*/?>",
            with: "\n",
            options: .regularExpression
        )
        guard let data = withBreaks.data(using: .utf8) else { return "" }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attributed = try? NSAttributedString(
            data: data,
            options: options,
            documentAttributes: nil
        ) else {
            return ""
        }

        return attributed.string
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func handleListObjects(_ conn: NWConnection) {
        Task { @MainActor [weak self] in
            guard let self, let mgr = self.objectManager else {
                self?.respondJSON(conn, status: 503, body: ["error": "Canvas not ready"])
                return
            }

            let center = CanvasState.canvasCenter
            let list: [[String: Any]] = mgr.objects.values.map { obj in
                let axis = mgr.axisPoint(forCanvasPoint: obj.position)
                return [
                    "id": obj.id.uuidString,
                    "x": obj.position.x - center.x,
                    "y": obj.position.y - center.y,
                    "document_axis_x": axis.x,
                    "document_axis_y": axis.y,
                    "canvas_x": obj.position.x,
                    "canvas_y": obj.position.y,
                    "width": obj.size.width,
                    "height": obj.size.height
                ]
            }

            self.respondJSON(conn, status: 200, body: ["objects": list, "count": list.count])
        }
    }

    private func handleGetObject(_ idString: String, _ conn: NWConnection) {
        guard let uuid = UUID(uuidString: idString) else {
            respondJSON(conn, status: 400, body: ["error": "Invalid UUID format"])
            return
        }

        Task { @MainActor [weak self] in
            guard let self, let mgr = self.objectManager else {
                self?.respondJSON(conn, status: 503, body: ["error": "Canvas not ready"])
                return
            }
            guard let obj = mgr.objects[uuid] else {
                self.respondJSON(conn, status: 404, body: ["error": "Object not found"])
                return
            }

            let center = CanvasState.canvasCenter
            let axis = mgr.axisPoint(forCanvasPoint: obj.position)
            self.respondJSON(conn, status: 200, body: [
                "id": obj.id.uuidString,
                "x": obj.position.x - center.x,
                "y": obj.position.y - center.y,
                "document_axis_x": axis.x,
                "document_axis_y": axis.y,
                "canvas_x": obj.position.x,
                "canvas_y": obj.position.y,
                "width": obj.size.width,
                "height": obj.size.height,
                "html": obj.htmlContent
            ])
        }
    }

    private func handleDeleteObject(_ idString: String, _ conn: NWConnection) {
        guard let uuid = UUID(uuidString: idString) else {
            respondJSON(conn, status: 400, body: ["error": "Invalid UUID format"])
            return
        }

        Task { @MainActor [weak self] in
            guard let self, let mgr = self.objectManager else {
                self?.respondJSON(conn, status: 503, body: ["error": "Canvas not ready"])
                return
            }
            guard mgr.objects[uuid] != nil else {
                self.respondJSON(conn, status: 404, body: ["error": "Object not found"])
                return
            }

            mgr.remove(id: uuid)
            self.respondJSON(conn, status: 200, body: ["deleted": uuid.uuidString])
        }
    }

    private func handleDeleteAllObjects(_ conn: NWConnection) {
        Task { @MainActor [weak self] in
            guard let self, let mgr = self.objectManager else {
                self?.respondJSON(conn, status: 503, body: ["error": "Canvas not ready"])
                return
            }

            let ids = Array(mgr.objects.keys)
            for id in ids { mgr.remove(id: id) }

            self.respondJSON(conn, status: 200, body: ["deleted_count": ids.count])
        }
    }

    // MARK: - Suggestion Handlers

    private func handleCreateSuggestion(_ req: HTTPRequest, _ conn: NWConnection) {
        guard let json = req.jsonBody else {
            respondJSON(conn, status: 400, body: ["error": "Missing JSON body"])
            return
        }
        guard let html = json["html"] as? String else {
            respondJSON(conn, status: 400, body: ["error": "Missing required field: 'html' (string)"])
            return
        }

        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (json["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let x = numericValue(json["x"]) ?? 0
        let y = numericValue(json["y"]) ?? 0
        let w = numericValue(json["width"]) ?? 360
        let h = numericValue(json["height"]) ?? 220
        let animateOnPlace = (json["animate"] as? Bool) ?? true
        let coordinateSpace = (json["coordinate_space"] as? String ?? "viewport_offset").lowercased()

        guard let mgr = objectManager else {
            respondJSON(conn, status: 503, body: ["error": "Canvas not ready — open a document first"])
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let canonicalSpace = self.canonicalCoordinateSpace(coordinateSpace)
            let canvasPos = self.resolveCanvasPoint(
                x: x,
                y: y,
                coordinateSpace: canonicalSpace,
                manager: mgr
            )
            let viewport = mgr.viewportCenter
            let finalTitle = ((title?.isEmpty == false) ? title : nil) ?? "Suggested Widget"
            let finalSummary = ((summary?.isEmpty == false) ? summary : nil) ?? "Agent suggests adding this widget here."
            let suggestion = mgr.addSuggestion(
                title: finalTitle,
                summary: finalSummary,
                html: html,
                at: canvasPos,
                size: CGSize(width: w, height: h),
                animateOnPlace: animateOnPlace
            )

            self.respondJSON(conn, status: 201, body: [
                "id": suggestion.id.uuidString,
                "title": suggestion.title,
                "summary": suggestion.summary,
                "x": x,
                "y": y,
                "coordinate_space_used": canonicalSpace,
                "width": w,
                "height": h,
                "viewport_center": ["x": viewport.x, "y": viewport.y],
                "canvas_position": ["x": canvasPos.x, "y": canvasPos.y],
                "status": "pending"
            ])
        }
    }

    private func handleListSuggestions(_ conn: NWConnection) {
        Task { @MainActor [weak self] in
            guard let self, let mgr = self.objectManager else {
                self?.respondJSON(conn, status: 503, body: ["error": "Canvas not ready"])
                return
            }

            let center = CanvasState.canvasCenter
            let list: [[String: Any]] = mgr.suggestions.values.sorted(by: { $0.createdAt < $1.createdAt }).map { suggestion in
                [
                    "id": suggestion.id.uuidString,
                    "title": suggestion.title,
                    "summary": suggestion.summary,
                    "x": suggestion.position.x - center.x,
                    "y": suggestion.position.y - center.y,
                    "width": suggestion.size.width,
                    "height": suggestion.size.height,
                    "status": "pending",
                    "created_at": ISO8601DateFormatter().string(from: suggestion.createdAt)
                ]
            }

            self.respondJSON(conn, status: 200, body: ["suggestions": list, "count": list.count])
        }
    }

    private func handleApproveSuggestion(_ idString: String, _ conn: NWConnection) {
        guard let uuid = UUID(uuidString: idString) else {
            respondJSON(conn, status: 400, body: ["error": "Invalid UUID format"])
            return
        }

        guard let mgr = objectManager else {
            respondJSON(conn, status: 503, body: ["error": "Canvas not ready — open a document first"])
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let placed = await mgr.approveSuggestion(id: uuid) else {
                self.respondJSON(conn, status: 404, body: ["error": "Suggestion not found"])
                return
            }
            self.respondJSON(conn, status: 200, body: [
                "approved": uuid.uuidString,
                "placed_object_id": placed.id.uuidString
            ])
        }
    }

    private func handleRejectSuggestion(_ idString: String, _ conn: NWConnection) {
        guard let uuid = UUID(uuidString: idString) else {
            respondJSON(conn, status: 400, body: ["error": "Invalid UUID format"])
            return
        }

        guard let mgr = objectManager else {
            respondJSON(conn, status: 503, body: ["error": "Canvas not ready — open a document first"])
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard mgr.rejectSuggestion(id: uuid) else {
                self.respondJSON(conn, status: 404, body: ["error": "Suggestion not found"])
                return
            }
            self.respondJSON(conn, status: 200, body: ["rejected": uuid.uuidString])
        }
    }

    // MARK: - Draw Handler

    private func handleDraw(_ req: HTTPRequest, _ conn: NWConnection) {
        guard let json = req.jsonBody, let svg = json["svg"] as? String, !svg.isEmpty else {
            respondJSON(conn, status: 400, body: ["error": "Missing required field: 'svg' (string)"])
            return
        }

        let x = numericValue(json["x"]) ?? 0
        let y = numericValue(json["y"]) ?? 0
        let coordinateSpace = (json["coordinate_space"] as? String ?? "viewport_offset").lowercased()
        let scale = numericValue(json["scale"]) ?? 1.0
        let speed = numericValue(json["speed"]) ?? 1.0
        let strokeWidth = numericValue(json["stroke_width"]) ?? 3
        let colorHex = json["color"] as? String

        guard let mgr = objectManager else {
            respondJSON(conn, status: 503, body: ["error": "Canvas not ready — open a document first"])
            return
        }

        // Parse stroke count upfront for the response
        let parser = SVGPathParser()
        let parsed = parser.parse(svgString: svg)
        let strokeCount = parsed.strokes.count

        guard strokeCount > 0 else {
            respondJSON(conn, status: 400, body: ["error": "SVG contains no drawable strokes"])
            return
        }

        // Estimate duration: ~30 points/sec per stroke, with pauses
        let totalPoints = parsed.strokes.reduce(0) { $0 + $1.points.count }
        let drawTime = Double(totalPoints) / (30.0 * max(speed, 0.1))
        let pauseTime = Double(strokeCount) * 0.15
        let estimatedDuration = (drawTime + pauseTime).rounded(toPlaces: 1)

        // Respond immediately (202), then animate asynchronously
        respondJSON(conn, status: 202, body: [
            "status": "drawing",
            "stroke_count": strokeCount,
            "estimated_duration_seconds": estimatedDuration
        ])

        Task { @MainActor in
            let canonicalSpace = self.canonicalCoordinateSpace(coordinateSpace)
            let canvasPos = self.resolveCanvasPoint(
                x: x,
                y: y,
                coordinateSpace: canonicalSpace,
                manager: mgr
            )

            let svgStrokeHexColor: String? = parsed.strokes.compactMap { stroke in
                guard let raw = stroke.color?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else {
                    return nil
                }
                let normalized = raw.replacingOccurrences(of: "#", with: "")
                let isHex = normalized.range(
                    of: #"^[0-9a-fA-F]{3,8}$"#,
                    options: .regularExpression
                ) != nil
                guard isHex, [3, 4, 6, 8].contains(normalized.count) else {
                    return nil
                }
                return "#\(normalized)"
            }.first

            let requestedColor = colorHex?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedColorHex = (requestedColor?.isEmpty == false) ? requestedColor : svgStrokeHexColor

            let color: UIColor
            if let hex = resolvedColorHex {
                color = UIColor(hex: hex)
            } else {
                color = UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1)
            }

            await mgr.drawSVG(
                svg: svg,
                at: canvasPos,
                scale: CGFloat(scale),
                color: color,
                strokeWidth: CGFloat(strokeWidth),
                speed: speed
            )
        }
    }

    // MARK: - Cursor Handler

    private func handleCursorCommand(_ req: HTTPRequest, _ conn: NWConnection) {
        guard let json = req.jsonBody, let action = json["action"] as? String else {
            respondJSON(conn, status: 400, body: ["error": "Missing required field: 'action' (string: appear|move|click|disappear)"])
            return
        }

        let x = numericValue(json["x"]) ?? 0
        let y = numericValue(json["y"]) ?? 0
        let coordinateSpace = (json["coordinate_space"] as? String ?? "viewport_offset").lowercased()

        guard let mgr = objectManager else {
            respondJSON(conn, status: 503, body: ["error": "Canvas not ready — open a document first"])
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let canonicalSpace = self.canonicalCoordinateSpace(coordinateSpace)
            let canvasPoint = self.resolveCanvasPoint(
                x: x,
                y: y,
                coordinateSpace: canonicalSpace,
                manager: mgr
            )

            switch action {
            case "appear":
                mgr.cursorAppear(at: canvasPoint)
            case "move":
                mgr.cursorMove(to: canvasPoint)
            case "click":
                mgr.cursorClick()
            case "disappear":
                mgr.cursorDisappear()
            default:
                self.respondJSON(conn, status: 400, body: ["error": "Unknown action: \(action). Use: appear, move, click, disappear"])
                return
            }

            self.respondJSON(conn, status: 200, body: [
                "action": action,
                "x": x,
                "y": y,
                "coordinate_space_used": canonicalSpace
            ])
        }
    }

    // MARK: - Device & Link Handlers

    private func handleDeviceInfo(_ conn: NWConnection) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let device = UIDevice.current
            self.respondJSON(conn, status: 200, body: [
                "id": self.deviceID,
                "name": device.name,
                "model": device.model,
                "system": "\(device.systemName) \(device.systemVersion)",
                "service": "iris-canvas",
                "port": Int(self.port)
            ])
        }
    }

    private func handleLink(_ req: HTTPRequest, _ conn: NWConnection) {
        guard let json = req.jsonBody,
              let remoteID = json["id"] as? String,
              let remoteName = json["name"] as? String else {
            respondJSON(conn, status: 400, body: ["error": "Missing required fields: 'id' (string), 'name' (string)"])
            return
        }

        let platform = json["platform"] as? String ?? "unknown"
        let ip = json["ip"] as? String
        let remotePort = (json["port"] as? Int) ?? 0

        let linked = LinkedDevice(
            id: remoteID,
            name: remoteName,
            platform: platform,
            ip: ip,
            port: remotePort,
            linkedAt: Date()
        )
        linkedDevices[remoteID] = linked

        // Persist the agent server URL so HomeView can sync sessions
        if let ip, !ip.isEmpty {
            UserDefaults.standard.set("http://\(ip):8000", forKey: "iris_agent_server_url")
        }

        print("[iris] Device linked: \(remoteName) (\(platform)) id=\(remoteID)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            let device = UIDevice.current
            self.respondJSON(conn, status: 200, body: [
                "linked": true,
                "device": [
                    "id": self.deviceID,
                    "name": device.name,
                    "model": device.model,
                    "system": "\(device.systemName) \(device.systemVersion)",
                    "port": Int(self.port)
                ]
            ])
        }
    }

    private func handleListLinked(_ conn: NWConnection) {
        let list: [[String: Any]] = linkedDevices.values.map { d in
            [
                "id": d.id,
                "name": d.name,
                "platform": d.platform,
                "ip": d.ip ?? "",
                "port": d.port,
                "linked_at": ISO8601DateFormatter().string(from: d.linkedAt)
            ]
        }
        respondJSON(conn, status: 200, body: ["devices": list, "count": list.count])
    }

    private func handleUnlink(_ id: String, _ conn: NWConnection) {
        if linkedDevices.removeValue(forKey: id) != nil {
            print("[iris] Device unlinked: \(id)")
            respondJSON(conn, status: 200, body: ["unlinked": id])
        } else {
            respondJSON(conn, status: 404, body: ["error": "Device not found"])
        }
    }

    // MARK: - Response helpers

    private func respondJSON(_ conn: NWConnection, status: Int, body: [String: Any]?) {
        var jsonData = Data()
        if let body {
            jsonData = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        }

        let header = [
            "HTTP/1.1 \(status) \(Self.statusText(status))",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(jsonData.count)",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type",
            "Connection: close",
            "", ""
        ].joined(separator: "\r\n")

        var data = Data(header.utf8)
        data.append(jsonData)

        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func respondRaw(_ conn: NWConnection, status: Int, contentType: String, body: String) {
        let bodyData = Data(body.utf8)

        let header = [
            "HTTP/1.1 \(status) \(Self.statusText(status))",
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Access-Control-Allow-Origin: *",
            "Connection: close",
            "", ""
        ].joined(separator: "\r\n")

        var data = Data(header.utf8)
        data.append(bodyData)

        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Utilities

    private func numericValue(_ val: Any?) -> Double? {
        if let n = val as? NSNumber { return n.doubleValue }
        if let n = val as? Double { return n }
        if let n = val as? Int { return Double(n) }
        if let s = val as? String, let n = Double(s) { return n }
        return nil
    }

    private func canonicalCoordinateSpace(_ raw: String) -> String {
        switch raw.lowercased() {
        case "canvas_absolute":
            return "canvas_absolute"
        case "document_axis":
            return "document_axis"
        case "viewport_local", "viewport_top_left", "viewport_topleft":
            return "viewport_local"
        case "viewport_offset", "viewport_center_offset", "viewport_center":
            return "viewport_center_offset"
        default:
            return "viewport_center_offset"
        }
    }

    @MainActor
    private func resolveCanvasPoint(
        x: Double,
        y: Double,
        coordinateSpace: String,
        manager: CanvasObjectManager
    ) -> CGPoint {
        switch coordinateSpace {
        case "canvas_absolute":
            return CGPoint(x: x, y: y)
        case "document_axis":
            return manager.canvasPoint(forAxisPoint: CGPoint(x: x, y: y))
        case "viewport_local":
            let viewportRect = manager.viewportCanvasRect()
            return CGPoint(x: viewportRect.minX + x, y: viewportRect.minY + y)
        default:
            let center = manager.viewportCenter
            return CGPoint(x: center.x + x, y: center.y + y)
        }
    }

    private static func statusText(_ code: Int) -> String {
        switch code {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 413: "Payload Too Large"
        case 404: "Not Found"
        case 503: "Service Unavailable"
        default:  "Unknown"
        }
    }
}

// MARK: - Linked Device

struct LinkedDevice {
    let id: String
    let name: String
    let platform: String
    let ip: String?
    let port: Int
    let linkedAt: Date
}

// MARK: - HTTP Request Parser

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?

    var jsonBody: [String: Any]? {
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    static func parse(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return nil }

        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        guard let headerSection = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let tokens = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard tokens.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        guard contentLength >= 0 else { return nil }
        let bodyStart = headerRange.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }

        let bodyData: Data?
        if contentLength > 0 {
            bodyData = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        } else {
            bodyData = nil
        }

        return HTTPRequest(method: tokens[0], path: tokens[1], headers: headers, body: bodyData)
    }
}

// MARK: - Helpers

private extension UIColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        let r, g, b, a: CGFloat
        switch cleaned.count {
        case 6:
            r = CGFloat((rgb >> 16) & 0xFF) / 255
            g = CGFloat((rgb >> 8) & 0xFF) / 255
            b = CGFloat(rgb & 0xFF) / 255
            a = 1
        case 8:
            r = CGFloat((rgb >> 24) & 0xFF) / 255
            g = CGFloat((rgb >> 16) & 0xFF) / 255
            b = CGFloat((rgb >> 8) & 0xFF) / 255
            a = CGFloat(rgb & 0xFF) / 255
        default:
            r = 0.10; g = 0.12; b = 0.16; a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
