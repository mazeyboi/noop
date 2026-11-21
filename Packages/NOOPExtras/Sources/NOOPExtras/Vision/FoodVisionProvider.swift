import Foundation

/// One meal photo to estimate.
public struct EstimateRequest: Sendable {
    public var image: Data          // JPEG, already downscaled
    public var hint: String?
    public var meal: MealType
    public var at: Date
    public var timeZone: TimeZone

    public init(image: Data, hint: String?, meal: MealType, at: Date, timeZone: TimeZone = .current) {
        self.image = image; self.hint = hint; self.meal = meal; self.at = at; self.timeZone = timeZone
    }
}

/// An AI service that turns a meal photo into a `FoodEstimate`. Adapters only translate formats;
/// prompt, schema and parsing are shared (`EstimatePrompt`, `FoodEstimate.parse`).
public protocol FoodVisionProvider: Sendable {
    var kind: ProviderKind { get }
    var model: String { get }
    func estimate(_ request: EstimateRequest) async throws -> FoodEstimate
}

public enum ProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case anthropic, openai, gemini, openaiCompatible
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .openaiCompatible: return "OpenAI-compatible"
        }
    }

    /// Shown as suggestions only; the model field is free text.
    public var suggestedModels: [String] {
        switch self {
        case .anthropic: return ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        case .openai: return ["gpt-5.1", "gpt-5-mini"]
        case .gemini: return ["gemini-2.5-flash", "gemini-2.5-pro"]
        case .openaiCompatible: return []
        }
    }

    public var needsBaseURL: Bool { self == .openaiCompatible }
    /// A local OpenAI-compatible server (Ollama, LM Studio) may not use a key.
    public var needsKey: Bool { self != .openaiCompatible }

    public var privacyNote: String? {
        switch self {
        case .gemini: return "Gemini's free tier may use your photos to train Google's models. A paid key doesn't."
        default: return nil
        }
    }
}

public enum ProviderError: Error, Equatable, Sendable {
    case notConfigured
    case offline
    case timeout
    case rateLimited
    case server(Int)
    case auth(Int)
    case badRequest(String)
    case refused(String)
    case malformed(String)

    /// Retryable errors keep the photo pending and are tried again later on their own.
    public var isRetryable: Bool {
        switch self {
        case .offline, .timeout, .rateLimited, .server, .malformed: return true
        case .notConfigured, .auth, .badRequest, .refused: return false
        }
    }

    public var message: String {
        switch self {
        case .notConfigured: return "Set up an AI provider in Food settings"
        case .offline: return "Offline. It will be estimated when you're back online."
        case .timeout: return "The AI took too long. It will retry."
        case .rateLimited: return "The provider is rate limiting. It will retry."
        case .server(let c): return "The provider had an error (\(c)). It will retry."
        case .auth: return "The API key was rejected. Check it in Food settings."
        case .badRequest(let m): return "The provider rejected the request: \(m)"
        case .refused(let m): return "Couldn't estimate: \(m) Tap to retry or enter it manually."
        case .malformed: return "The AI's answer couldn't be read. It will retry."
        }
    }

    static func from(urlError e: Error) -> ProviderError? {
        guard let u = e as? URLError else { return nil }
        switch u.code {
        case .timedOut: return .timeout
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed:
            return .offline
        default: return .offline
        }
    }

    static func from(status: Int, body: Data) -> ProviderError? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .auth(status)
        case 408: return .timeout
        case 429: return .rateLimited
        case 500...: return .server(status)
        default: return .badRequest(errorMessage(body) ?? "HTTP \(status)")
        }
    }

    /// `{"error":{"message":…}}` (Anthropic, OpenAI, Gemini all use this shape) or `{"error":"…"}`.
    static func errorMessage(_ body: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let m = obj["error"] as? String { return m }
        return nil
    }
}

/// The provider Oliver picked (stored in the extras kv table; the key lives in the Keychain).
public struct ProviderSettings: Codable, Equatable, Sendable {
    public var kind: ProviderKind
    public var model: String
    public var baseURL: String?

    public init(kind: ProviderKind, model: String, baseURL: String?) {
        self.kind = kind; self.model = model; self.baseURL = baseURL
    }

    public static let kvKey = "provider.settings"

    /// nil when nothing is configured: there is deliberately no default provider.
    public static func load(from json: String?) -> ProviderSettings? {
        guard let json, let s = try? JSONDecoder().decode(ProviderSettings.self, from: Data(json.utf8)) else { return nil }
        return s
    }

    public var json: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
}

public enum ProviderFactory {
    public static func keyName(_ kind: ProviderKind) -> String { "provider.\(kind.rawValue).key" }

    public static func make(settings: ProviderSettings?, secrets: SecretStore,
                            transport: HTTPTransport) -> FoodVisionProvider? {
        guard let s = settings else { return nil }
        let model = s.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        let key = secrets.get(keyName(s.kind))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if s.kind.needsKey && key.isEmpty { return nil }
        switch s.kind {
        case .anthropic: return AnthropicProvider(apiKey: key, model: model, transport: transport)
        case .openai: return OpenAIProvider(apiKey: key, model: model, baseURL: nil, transport: transport)
        case .gemini: return GeminiProvider(apiKey: key, model: model, transport: transport)
        case .openaiCompatible:
            guard let raw = s.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                  let url = URL(string: raw), url.scheme == "http" || url.scheme == "https" else { return nil }
            return OpenAIProvider(apiKey: key, model: model, baseURL: url, transport: transport, compatible: true)
        }
    }
}

/// Shared send + status/URLError mapping for the adapters.
func sendProviderRequest(_ req: URLRequest, transport: HTTPTransport) async throws -> Data {
    let data: Data, resp: HTTPURLResponse
    do {
        (data, resp) = try await transport.send(req)
    } catch {
        throw ProviderError.from(urlError: error) ?? .offline
    }
    if let e = ProviderError.from(status: resp.statusCode, body: data) { throw e }
    return data
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProviderError.malformed("response is not JSON")
    }
    return o
}
