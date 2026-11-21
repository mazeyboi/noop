import Foundation
import XCTest
@testable import NOOPExtras

func fixture(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
        ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    return try! Data(contentsOf: url)
}

/// Scripted HTTP: records every request and answers from a queue (or a handler).
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    enum Reply { case http(Int, Data), error(Error) }
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var replies: [Reply] = []
    var handler: ((URLRequest) -> Reply)?

    init(_ replies: [Reply] = []) { self.replies = replies }

    func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply = lock.withLock {
            requests.append(req)
            if let handler { return handler(req) }
            return replies.isEmpty ? .http(500, Data()) : replies.removeFirst()
        }
        switch reply {
        case .error(let e): throw e
        case .http(let code, let data):
            return (data, HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }

    func body(_ i: Int) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: requests[i].httpBody ?? Data())) as? [String: Any] ?? [:]
    }
}

extension Dictionary where Key == String, Value == Any {
    func path(_ keys: Any...) -> Any? {
        var cur: Any? = self
        for k in keys {
            if let s = k as? String { cur = (cur as? [String: Any])?[s] }
            else if let i = k as? Int { let a = cur as? [Any]; cur = (a != nil && i < a!.count) ? a![i] : nil }
        }
        return cur
    }
}

let sampleJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0xFF, 0xD9])

func sampleRequest() -> EstimateRequest {
    EstimateRequest(image: sampleJPEG, hint: "about 200 g rice", meal: .lunch,
                    at: Date(timeIntervalSince1970: 1_795_000_000),
                    timeZone: TimeZone(identifier: "Europe/Copenhagen")!)
}

func assertThrows<T>(_ expected: ProviderError, file: StaticString = #filePath, line: UInt = #line,
                     _ body: () async throws -> T) async {
    do {
        _ = try await body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let e as ProviderError {
        XCTAssertEqual(e, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error \(error)", file: file, line: line)
    }
}
