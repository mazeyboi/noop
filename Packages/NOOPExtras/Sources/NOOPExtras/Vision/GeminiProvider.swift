import Foundation

/// Google Gemini `generateContent` with inline image data and `responseSchema`.
public struct GeminiProvider: FoodVisionProvider {
    public let kind = ProviderKind.gemini
    public let model: String
    let apiKey: String
    let transport: HTTPTransport

    public init(apiKey: String, model: String, transport: HTTPTransport) {
        self.apiKey = apiKey; self.model = model; self.transport = transport
    }

    var endpoint: URL {
        let m = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))) ?? model
        return URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(m):generateContent")!
    }

    static let blockedFinishReasons: Set<String> = ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "IMAGE_SAFETY", "RECITATION"]

    public func estimate(_ r: EstimateRequest) async throws -> FoodEstimate {
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": EstimatePrompt.system]]],
            "contents": [[
                "role": "user",
                "parts": [
                    ["inline_data": ["mime_type": "image/jpeg", "data": r.image.base64EncodedString()]],
                    ["text": EstimatePrompt.userText(r)],
                ] as [[String: Any]],
            ] as [String: Any]],
            "generationConfig": ["responseMimeType": "application/json",
                                 "responseSchema": EstimatePrompt.geminiSchema] as [String: Any],
        ]
        // The key goes in a header, never in the URL (URLs end up in logs).
        let req = try URLRequest.json(endpoint, body: body, timeout: 30, headers: ["x-goog-api-key": apiKey])
        let obj = try jsonObject(try await sendProviderRequest(req, transport: transport))
        if let block = (obj["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
            throw ProviderError.refused("Blocked by the provider (\(block))")
        }
        let cand = (obj["candidates"] as? [[String: Any]])?.first
        if let reason = cand?["finishReason"] as? String, Self.blockedFinishReasons.contains(reason) {
            throw ProviderError.refused("Blocked by the provider (\(reason))")
        }
        let parts = (cand?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw ProviderError.malformed("no text in the reply") }
        return try FoodEstimate.parse(text)
    }
}
