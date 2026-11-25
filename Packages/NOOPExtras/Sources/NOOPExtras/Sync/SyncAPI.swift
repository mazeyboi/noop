import Foundation

public struct SyncConfig: Sendable {
    public static let defaultBaseURL = URL(string: "https://health.home.dowling.dk/api/v1")!
    public static let urlKey = "server.url"          // kv
    public static let tokenKey = "server.token"      // SecretStore

    public var baseURL: URL
    public var token: String?

    public init(baseURL: URL = SyncConfig.defaultBaseURL, token: String?) {
        self.baseURL = baseURL; self.token = token
    }

    public static func load(store: ExtrasStore, secrets: SecretStore) -> SyncConfig {
        let url = (try? store.kv(urlKey)).flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" || $0.scheme == "http" ? $0 : nil }
        return SyncConfig(baseURL: url ?? defaultBaseURL, token: secrets.get(tokenKey))
    }
}

public enum SyncError: Error, Equatable, Sendable {
    case notConfigured
    /// Not on the home network (DNS, timeout, connection refused). Normal away from home.
    case unreachable
    case unauthorized
    case rejected(String)
    case http(Int)
    case localChanges
    case invalidResponse
    case local(String)

    public var message: String {
        switch self {
        case .notConfigured: return "Add the server's device token in Food settings."
        case .unreachable: return "Server not reachable (only works on the home network)."
        case .unauthorized: return "The server rejected the device token."
        case .rejected(let m): return "The server rejected a record: \(m)"
        case .http(let c): return "Server error (HTTP \(c))."
        case .localChanges: return "This phone has food log changes that haven't synced yet."
        case .invalidResponse: return "The server sent something unexpected."
        case .local(let m): return "Couldn't read data on this phone: \(m)"
        }
    }
}

/// The health server's API (server/health in the health-dashboard repo).
public struct SyncAPI: Sendable {
    public let config: SyncConfig
    let transport: HTTPTransport

    public init(config: SyncConfig, transport: HTTPTransport) {
        self.config = config; self.transport = transport
    }

    private func url(_ path: String) -> URL { config.baseURL.appendingPathComponent(path) }

    private func request(_ path: String, method: String, body: Data? = nil, contentType: String? = nil,
                         timeout: TimeInterval = 20) throws -> URLRequest {
        guard let token = config.token, !token.isEmpty else { throw SyncError.notConfigured }
        var r = URLRequest(url: url(path), timeoutInterval: timeout)
        r.httpMethod = method
        r.httpBody = body
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return r
    }

    private func send(_ r: URLRequest, ok: Set<Int> = Set(200..<300)) async throws -> (Data, Int) {
        let data: Data, resp: HTTPURLResponse
        do { (data, resp) = try await transport.send(r) } catch { throw SyncError.unreachable }
        let code = resp.statusCode
        if ok.contains(code) { return (data, code) }
        switch code {
        case 401, 403: throw SyncError.unauthorized
        case 422: throw SyncError.rejected(Self.detail(data) ?? "invalid record")
        default: throw SyncError.http(code)
        }
    }

    static func detail(_ data: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let d = o["detail"] as? String { return d }
        if let d = o["detail"] as? [[String: Any]] {   // FastAPI validation errors
            return d.compactMap { $0["msg"] as? String }.joined(separator: "; ")
        }
        return nil
    }

    private struct Batch: Encodable { var records: [SyncRecord] }

    /// Returns how many the server applied (an older version than the server's is not applied).
    @discardableResult
    public func ingest(kind: SyncKind, records: [SyncRecord]) async throws -> Int {
        let body = try ExtrasCodec.wireEncoder.encode(Batch(records: records))
        let (data, _) = try await send(request("ingest/\(kind.rawValue)", method: "POST", body: body,
                                               contentType: "application/json", timeout: 60))
        let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (o?["applied"] as? NSNumber)?.intValue ?? 0
    }

    public func photoExists(id: String) async throws -> Bool {
        let (_, code) = try await send(request("photos/\(id)", method: "HEAD"), ok: [200, 404])
        return code == 200
    }

    public func putPhoto(id: String, jpeg: Data) async throws {
        _ = try await send(request("photos/\(id)", method: "PUT", body: jpeg, contentType: "image/jpeg", timeout: 60))
    }

    /// nil when the server has no such photo.
    public func getPhoto(id: String) async throws -> Data? {
        let (data, code) = try await send(request("photos/\(id)", method: "GET", timeout: 60), ok: [200, 404])
        return code == 200 ? data : nil
    }

    public func restore() async throws -> RestoreSnapshot {
        let (data, _) = try await send(request("restore/extras", method: "GET", timeout: 60))
        do { return try ExtrasCodec.wireDecoder.decode(RestoreSnapshot.self, from: data) }
        catch { throw SyncError.invalidResponse }
    }

    /// The device name the token belongs to ("Test connection" in settings).
    public func whoami() async throws -> String {
        let (data, _) = try await send(request("whoami", method: "GET"))
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let d = o["device"] as? String
        else { throw SyncError.invalidResponse }
        return d
    }
}
