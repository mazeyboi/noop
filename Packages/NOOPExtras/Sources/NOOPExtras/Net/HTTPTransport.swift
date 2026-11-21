import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Every network call goes through this, so tests can answer from recorded JSON.
public protocol HTTPTransport: Sendable {
    func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    /// An ephemeral session: no cookies, no cache, no shared credentials.
    public static func ephemeral() -> URLSessionTransport {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.urlCache = nil
        return URLSessionTransport(session: URLSession(configuration: c))
    }

    public func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

extension URLRequest {
    static func json(_ url: URL, method: String = "POST", body: Any? = nil, timeout: TimeInterval = 30,
                     headers: [String: String] = [:]) throws -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        if let body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }
}
