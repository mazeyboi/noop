import XCTest
@testable import NOOPExtras

final class ProviderTests: XCTestCase {
    let b64 = sampleJPEG.base64EncodedString()

    // MARK: Anthropic

    func test_anthropic_builds_request() async throws {
        let t = FakeTransport([.http(200, fixture("anthropic_ok.json"))])
        let p = AnthropicProvider(apiKey: "sk-test", model: "claude-haiku-5-5", transport: t)
        _ = try await p.estimate(sampleRequest())
        let r = t.requests[0]
        XCTAssertEqual(r.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        let body = t.body(0)
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(body.path("output_config", "format", "type") as? String, "json_schema")
        XCTAssertNotNil(body.path("output_config", "format", "schema", "properties", "items"))
        XCTAssertEqual(body.path("messages", 0, "content", 0, "type") as? String, "image")
        XCTAssertEqual(body.path("messages", 0, "content", 0, "source", "media_type") as? String, "image/jpeg")
        XCTAssertEqual(body.path("messages", 0, "content", 0, "source", "data") as? String, b64)
        let text = body.path("messages", 0, "content", 1, "text") as? String ?? ""
        XCTAssertTrue(text.contains("about 200 g rice"), text)
        XCTAssertTrue(text.contains("lunch"), text)
        XCTAssertFalse(String(decoding: r.httpBody!, as: UTF8.self).contains("sk-test"))
        XCTAssertEqual(r.timeoutInterval, 30)
    }

    func test_anthropic_parses_ok() async throws {
        let t = FakeTransport([.http(200, fixture("anthropic_ok.json"))])
        let est = try await AnthropicProvider(apiKey: "k", model: "m", transport: t).estimate(sampleRequest())
        XCTAssertEqual(est.items.count, 2)
        XCTAssertEqual(est.items[1].caffeineMg, 95)
        XCTAssertEqual(est.totals.kcal, 292, accuracy: 0.001)
        XCTAssertEqual(est.confidence, .medium)
    }

    func test_anthropic_refusal() async {
        let t = FakeTransport([.http(200, fixture("anthropic_refusal.json"))])
        await assertThrows(.refused("Declined.")) {
            try await AnthropicProvider(apiKey: "k", model: "m", transport: t).estimate(sampleRequest())
        }
    }

    // MARK: OpenAI and OpenAI-compatible

    func test_openai_builds_request() async throws {
        let t = FakeTransport([.http(200, fixture("openai_ok.json"))])
        _ = try await OpenAIProvider(apiKey: "sk-o", model: "gpt-5-mini", baseURL: nil, transport: t).estimate(sampleRequest())
        let r = t.requests[0]
        XCTAssertEqual(r.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer sk-o")
        let body = t.body(0)
        XCTAssertEqual(body["model"] as? String, "gpt-5-mini")
        XCTAssertEqual(body.path("response_format", "type") as? String, "json_schema")
        XCTAssertEqual(body.path("response_format", "json_schema", "strict") as? Bool, true)
        let content = body.path("messages", 1, "content") as? [[String: Any]] ?? []
        let image = content.first { $0["type"] as? String == "image_url" }
        XCTAssertEqual(image?.path("image_url", "url") as? String, "data:image/jpeg;base64,\(b64)")
        XCTAssertEqual(body.path("messages", 0, "role") as? String, "system")
    }

    func test_openai_parses_ok() async throws {
        let t = FakeTransport([.http(200, fixture("openai_ok.json"))])
        let est = try await OpenAIProvider(apiKey: "k", model: "m", baseURL: nil, transport: t).estimate(sampleRequest())
        XCTAssertEqual(est.items.map(\.name), ["Rugbrød with leverpostej", "Coffee"])
    }

    func test_openai_refusal() async {
        let t = FakeTransport([.http(200, fixture("openai_refusal.json"))])
        await assertThrows(.refused("I can't help with that.")) {
            try await OpenAIProvider(apiKey: "k", model: "m", baseURL: nil, transport: t).estimate(sampleRequest())
        }
    }

    func test_compatible_uses_base_url_and_falls_back_to_json_object() async throws {
        let t = FakeTransport([.http(400, fixture("error_body.json")), .http(200, fixture("openai_ok.json"))])
        let p = OpenAIProvider(apiKey: "", model: "llava", baseURL: URL(string: "http://192.168.1.50:11434/v1/")!,
                               transport: t, compatible: true)
        let est = try await p.estimate(sampleRequest())
        XCTAssertEqual(est.items.count, 2)
        XCTAssertEqual(t.requests.count, 2)
        XCTAssertEqual(t.requests[0].url?.absoluteString, "http://192.168.1.50:11434/v1/chat/completions")
        XCTAssertNil(t.requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(t.body(1).path("response_format", "type") as? String, "json_object")
    }

    func test_openai_400_is_bad_request_without_fallback() async {
        let t = FakeTransport([.http(400, fixture("error_body.json"))])
        await assertThrows(.badRequest("model: not found")) {
            try await OpenAIProvider(apiKey: "k", model: "m", baseURL: nil, transport: t).estimate(sampleRequest())
        }
        XCTAssertEqual(t.requests.count, 1)
    }

    // MARK: Gemini

    func test_gemini_builds_request() async throws {
        let t = FakeTransport([.http(200, fixture("gemini_ok.json"))])
        _ = try await GeminiProvider(apiKey: "AIza-test", model: "gemini-2.5-flash", transport: t).estimate(sampleRequest())
        let r = t.requests[0]
        XCTAssertEqual(r.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-test")
        let body = t.body(0)
        XCTAssertEqual(body.path("generationConfig", "responseMimeType") as? String, "application/json")
        XCTAssertEqual(body.path("generationConfig", "responseSchema", "type") as? String, "OBJECT")
        XCTAssertEqual(body.path("contents", 0, "parts", 0, "inline_data", "data") as? String, b64)
        XCTAssertNotNil(body.path("systemInstruction", "parts", 0, "text"))
    }

    func test_gemini_parses_ok() async throws {
        let t = FakeTransport([.http(200, fixture("gemini_ok.json"))])
        let est = try await GeminiProvider(apiKey: "k", model: "m", transport: t).estimate(sampleRequest())
        XCTAssertEqual(est.items.count, 2)
    }

    func test_gemini_blocked() async {
        let t = FakeTransport([.http(200, fixture("gemini_blocked.json"))])
        await assertThrows(.refused("Blocked by the provider (SAFETY)")) {
            try await GeminiProvider(apiKey: "k", model: "m", transport: t).estimate(sampleRequest())
        }
    }

    // MARK: shared behaviour

    func test_http_status_mapping() async {
        for (code, expected) in [(401, ProviderError.auth(401)), (403, .auth(403)), (429, .rateLimited),
                                 (503, .server(503)), (404, .badRequest("model: not found"))] {
            let t = FakeTransport([.http(code, fixture("error_body.json"))])
            await assertThrows(expected) {
                try await AnthropicProvider(apiKey: "k", model: "m", transport: t).estimate(sampleRequest())
            }
        }
    }

    func test_url_error_mapping() async {
        for (err, expected) in [(URLError(.timedOut), ProviderError.timeout),
                                (URLError(.notConnectedToInternet), .offline),
                                (URLError(.cannotFindHost), .offline)] {
            let t = FakeTransport([.error(err)])
            await assertThrows(expected) {
                try await GeminiProvider(apiKey: "k", model: "m", transport: t).estimate(sampleRequest())
            }
        }
    }

    func test_retryable_classification() {
        XCTAssertTrue(ProviderError.offline.isRetryable)
        XCTAssertTrue(ProviderError.rateLimited.isRetryable)
        XCTAssertTrue(ProviderError.server(502).isRetryable)
        XCTAssertTrue(ProviderError.malformed("x").isRetryable)
        XCTAssertFalse(ProviderError.refused("x").isRetryable)
        XCTAssertFalse(ProviderError.auth(401).isRetryable)
        XCTAssertFalse(ProviderError.badRequest("x").isRetryable)
    }

    func test_parses_fenced_json_and_recomputes_totals() throws {
        let text = """
        Here you go:
        ```json
        {"items":[{"name":"Pasta","grams":250,"kcal":400,"protein_g":14,"carbs_g":null,"fat_g":"9"},
                  {"name":"Parmesan","grams":10,"kcal":40}],
         "total":{"kcal":9999},"confidence":"HIGH","note":null}
        ```
        """
        let est = try FoodEstimate.parse(text)
        XCTAssertEqual(est.totals.kcal, 440)
        XCTAssertEqual(est.items[0].carbsG, 0)
        XCTAssertEqual(est.items[0].fatG, 9)
        XCTAssertEqual(est.confidence, .high)
        XCTAssertEqual(est.note, "")
    }

    func test_parse_camel_case_and_unknown_confidence() throws {
        let est = try FoodEstimate.parse(#"{"items":[{"name":"Apple","grams":150,"kcal":78,"proteinG":0.4}],"confidence":"unsure","note":"ok"}"#)
        XCTAssertEqual(est.items[0].proteinG, 0.4)
        XCTAssertEqual(est.confidence, .low)
    }

    func test_parse_garbage_is_malformed() {
        XCTAssertThrowsError(try FoodEstimate.parse("I think it's a sandwich")) {
            XCTAssertEqual($0 as? ProviderError, .malformed("no JSON object in the reply"))
        }
    }

    func test_parse_no_items_is_refusal() {
        XCTAssertThrowsError(try FoodEstimate.parse(#"{"items":[],"confidence":"low","note":"That's a cat."}"#)) {
            XCTAssertEqual($0 as? ProviderError, .refused("No food found in the photo. That's a cat."))
        }
    }

    func test_factory_nil_without_key() {
        let secrets = MemorySecretStore()
        let s = ProviderSettings(kind: .anthropic, model: "claude-haiku-5-5", baseURL: nil)
        XCTAssertNil(ProviderFactory.make(settings: nil, secrets: secrets, transport: FakeTransport()))
        XCTAssertNil(ProviderFactory.make(settings: s, secrets: secrets, transport: FakeTransport()))
        secrets.set(ProviderFactory.keyName(.anthropic), "sk")
        XCTAssertEqual(ProviderFactory.make(settings: s, secrets: secrets, transport: FakeTransport())?.kind, .anthropic)
        // compatible needs a base URL but may have no key (local Ollama)
        let c = ProviderSettings(kind: .openaiCompatible, model: "llava", baseURL: nil)
        XCTAssertNil(ProviderFactory.make(settings: c, secrets: secrets, transport: FakeTransport()))
        let c2 = ProviderSettings(kind: .openaiCompatible, model: "llava", baseURL: "http://192.168.1.50:11434/v1")
        XCTAssertEqual(ProviderFactory.make(settings: c2, secrets: secrets, transport: FakeTransport())?.kind, .openaiCompatible)
        XCTAssertNil(ProviderFactory.make(settings: ProviderSettings(kind: .gemini, model: " ", baseURL: nil),
                                          secrets: secrets, transport: FakeTransport()))
    }

    func test_no_default_provider() {
        XCTAssertNil(ProviderSettings.load(from: nil))
    }
}
