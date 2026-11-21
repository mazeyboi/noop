import Foundation

/// OpenAI Chat Completions with image input and strict `json_schema` output. With `compatible: true`
/// it talks to any OpenAI-compatible server (OpenRouter, Groq, a local Ollama or LM Studio), and falls
/// back once to plain `json_object` mode if the server rejects `json_schema`.
public struct OpenAIProvider: FoodVisionProvider {
    public var kind: ProviderKind { compatible ? .openaiCompatible : .openai }
    public let model: String
    let apiKey: String
    let baseURL: URL
    let transport: HTTPTransport
    let compatible: Bool

    public init(apiKey: String, model: String, baseURL: URL?, transport: HTTPTransport, compatible: Bool = false) {
        self.apiKey = apiKey; self.model = model; self.transport = transport; self.compatible = compatible
        self.baseURL = baseURL ?? URL(string: "https://api.openai.com/v1")!
    }

    var endpoint: URL {
        var s = baseURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + "/chat/completions")!
    }

    func body(_ r: EstimateRequest, schemaMode: Bool) -> [String: Any] {
        var system = EstimatePrompt.system
        let format: [String: Any]
        if schemaMode {
            format = ["type": "json_schema",
                      "json_schema": ["name": "food_estimate", "strict": true, "schema": EstimatePrompt.jsonSchema] as [String: Any]]
        } else {
            format = ["type": "json_object"]
            let schema = (try? JSONSerialization.data(withJSONObject: EstimatePrompt.jsonSchema, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            system += "\n\nThe JSON object must match this JSON Schema:\n\(schema)"
        }
        return [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": [
                    ["type": "text", "text": EstimatePrompt.userText(r)],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(r.image.base64EncodedString())"]],
                ] as [[String: Any]]] as [String: Any],
            ],
            "response_format": format,
        ]
    }

    public func estimate(_ r: EstimateRequest) async throws -> FoodEstimate {
        do {
            return try await send(r, schemaMode: true)
        } catch ProviderError.badRequest(let m) where compatible {
            _ = m // server doesn't do json_schema (older Ollama, some routers): try plain JSON mode once
            return try await send(r, schemaMode: false)
        }
    }

    private func send(_ r: EstimateRequest, schemaMode: Bool) async throws -> FoodEstimate {
        var headers: [String: String] = [:]
        if !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        let req = try URLRequest.json(endpoint, body: body(r, schemaMode: schemaMode), timeout: 30, headers: headers)
        let obj = try jsonObject(try await sendProviderRequest(req, transport: transport))
        let choice = (obj["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any]
        if let refusal = message?["refusal"] as? String, !refusal.isEmpty { throw ProviderError.refused(refusal) }
        if choice?["finish_reason"] as? String == "content_filter" {
            throw ProviderError.refused("Blocked by the provider's content filter.")
        }
        guard let text = message?["content"] as? String else { throw ProviderError.malformed("no content in the reply") }
        return try FoodEstimate.parse(text)
    }
}
