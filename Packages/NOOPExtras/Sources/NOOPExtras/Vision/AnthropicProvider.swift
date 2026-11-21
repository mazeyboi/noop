import Foundation

/// Claude Messages API with image input and structured output (`output_config.format`).
public struct AnthropicProvider: FoodVisionProvider {
    public let kind = ProviderKind.anthropic
    public let model: String
    let apiKey: String
    let transport: HTTPTransport
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(apiKey: String, model: String, transport: HTTPTransport) {
        self.apiKey = apiKey; self.model = model; self.transport = transport
    }

    public func estimate(_ r: EstimateRequest) async throws -> FoodEstimate {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": EstimatePrompt.system,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg", "data": r.image.base64EncodedString()]],
                    ["type": "text", "text": EstimatePrompt.userText(r)],
                ] as [[String: Any]],
            ] as [String: Any]],
            "output_config": ["format": ["type": "json_schema", "schema": EstimatePrompt.jsonSchema]],
        ]
        let req = try URLRequest.json(Self.endpoint, body: body, timeout: 30,
                                      headers: ["x-api-key": apiKey, "anthropic-version": "2026-10-21"])
        let obj = try jsonObject(try await sendProviderRequest(req, transport: transport))
        if obj["stop_reason"] as? String == "refusal" {
            let why = (obj["stop_details"] as? [String: Any])?["explanation"] as? String
            throw ProviderError.refused(why ?? "The model declined this photo.")
        }
        let blocks = obj["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            if obj["stop_reason"] as? String == "max_tokens" { throw ProviderError.malformed("reply was cut off") }
            throw ProviderError.malformed("no text in the reply")
        }
        return try FoodEstimate.parse(text)
    }
}
