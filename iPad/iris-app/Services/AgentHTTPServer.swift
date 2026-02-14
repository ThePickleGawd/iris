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

    static let defaultPort: UInt16 = 8935
    static let bonjourType = "_iris-canvas._tcp"

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "iris.agent-http", qos: .userInitiated)
    private weak var objectManager: CanvasObjectManager?

    /// Devices that have linked with this iPad via POST /api/v1/link
    private var linkedDevices: [String: LinkedDevice] = [:]

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

        conn.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                conn.cancel()
                return
            }

            guard let req = HTTPRequest.parse(data) else {
                self.respondJSON(conn, status: 400, body: ["error": "Malformed HTTP request"])
                return
            }

            self.route(req, conn)
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

        switch (req.method, resource, resourceID) {

        case ("GET", "health", nil):
            respondJSON(conn, status: 200, body: [
                "status": "ok",
                "service": "iris-canvas",
                "version": "1.0"
            ])

        case ("GET", "canvas", nil):
            handleCanvasInfo(conn)

        case ("GET", "design-system.css", nil):
            handleDesignSystemCSS(conn)

        case ("POST", "objects", nil):
            handlePlaceObject(req, conn)

        case ("GET", "objects", nil):
            handleListObjects(conn)

        case ("GET", "objects", .some(let id)):
            handleGetObject(id, conn)

        case ("DELETE", "objects", .some(let id)):
            handleDeleteObject(id, conn)

        case ("DELETE", "objects", nil):
            handleDeleteAllObjects(conn)

        case ("GET", "device", nil):
            handleDeviceInfo(conn)

        case ("POST", "link", nil):
            handleLink(req, conn)

        case ("GET", "link", nil):
            handleListLinked(conn)

        case ("DELETE", "link", .some(let id)):
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
            let viewport = self.objectManager?.viewportCenter ?? center
            self.respondJSON(conn, status: 200, body: [
                "canvas_size": CanvasState.canvasSize,
                "canvas_center": ["x": center.x, "y": center.y],
                "viewport_center": ["x": viewport.x, "y": viewport.y],
                "coordinate_info": "POST x/y are offsets from the user's current viewport center. GET x/y are offsets from canvas center."
            ])
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

        guard let mgr = objectManager else {
            respondJSON(conn, status: 503, body: ["error": "Canvas not ready — open a document first"])
            return
        }

        Task { @MainActor [weak self] in
            // Place relative to where the user is currently looking
            let viewport = mgr.viewportCenter
            let canvasPos = CGPoint(x: viewport.x + x, y: viewport.y + y)
            let size = CGSize(width: w, height: h)

            let obj = await mgr.place(html: html, at: canvasPos, size: size, animated: anim)

            let center = CanvasState.canvasCenter
            self?.respondJSON(conn, status: 201, body: [
                "id": obj.id.uuidString,
                "x": x, "y": y,
                "width": w, "height": h,
                "viewport_center": ["x": viewport.x, "y": viewport.y],
                "canvas_position": ["x": canvasPos.x, "y": canvasPos.y]
            ])
        }
    }

    private func handleListObjects(_ conn: NWConnection) {
        Task { @MainActor [weak self] in
            guard let self, let mgr = self.objectManager else {
                self?.respondJSON(conn, status: 503, body: ["error": "Canvas not ready"])
                return
            }

            let center = CanvasState.canvasCenter
            let list: [[String: Any]] = mgr.objects.values.map { obj in
                [
                    "id": obj.id.uuidString,
                    "x": obj.position.x - center.x,
                    "y": obj.position.y - center.y,
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
            self.respondJSON(conn, status: 200, body: [
                "id": obj.id.uuidString,
                "x": obj.position.x - center.x,
                "y": obj.position.y - center.y,
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
        return nil
    }

    private static func statusText(_ code: Int) -> String {
        switch code {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
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
        guard let str = String(data: data, encoding: .utf8) else { return nil }

        let parts = str.components(separatedBy: "\r\n\r\n")
        let headerSection = parts[0]
        let bodyString = parts.count > 1 ? parts.dropFirst().joined(separator: "\r\n\r\n") : nil

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

        let bodyData = bodyString.flatMap { $0.isEmpty ? nil : $0.data(using: .utf8) }

        return HTTPRequest(method: tokens[0], path: tokens[1], headers: headers, body: bodyData)
    }
}
