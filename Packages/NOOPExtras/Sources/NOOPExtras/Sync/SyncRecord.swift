import Foundation

/// The server's ingest kinds (`POST /api/v1/ingest/{kind}`).
public enum SyncKind: String, CaseIterable, Codable, Sendable {
    // owned by extras (also restored from the server)
    case foods, meals, targets, food_entries
    // read from NOOP's own database
    case sleep_sessions, daily_metrics, hr_minute, workouts, noop_intake

    public static let extras: [SyncKind] = [.foods, .meals, .targets, .food_entries]
    public static let noop: [SyncKind] = [.sleep_sessions, .daily_metrics, .workouts, .noop_intake, .hr_minute]
}

/// Any JSON value. The `data` payload of a server record.
public enum JSONValue: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
}

/// One record as the server stores it: `{id, updated_at, deleted, data}`.
public struct SyncRecord: Codable, Equatable, Sendable {
    public var id: String
    public var updatedAt: Date
    public var deleted: Bool
    public var data: [String: JSONValue]

    public init(id: String, updatedAt: Date, deleted: Bool, data: [String: JSONValue]) {
        self.id = id; self.updatedAt = updatedAt; self.deleted = deleted; self.data = data
    }

    enum CodingKeys: String, CodingKey { case id, updatedAt = "updated_at", deleted, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        data = try c.decodeIfPresent([String: JSONValue].self, forKey: .data) ?? [:]
    }
}

public extension ISO8601DateFormatter {
    /// `2026-11-21T12:00:00.123Z`: what the server's `fromisoformat` reads, with a UTC offset.
    static let extras: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static let extrasNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// JSON encoders shared by the store (exact dates) and the wire (ISO 8601).
public enum ExtrasCodec {
    public static func wireDate(_ d: Date) -> String { ISO8601DateFormatter.extras.string(from: d) }

    public static func parseWireDate(_ s: String) -> Date? {
        ISO8601DateFormatter.extras.date(from: s) ?? ISO8601DateFormatter.extrasNoFraction.date(from: s)
    }

    public static let wireEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer(); try c.encode(wireDate(date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let wireDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n) }
            let s = try c.decode(String.self)
            guard let date = parseWireDate(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date: \(s)")
            }
            return date
        }
        return d
    }()

    /// Store blobs keep full-precision dates (seconds since 1970 as a Double).
    public static let dbEncoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let dbDecoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()

    /// A value as a server `data` object.
    public static func data<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        let json = try wireEncoder.encode(value)
        return try JSONDecoder().decode([String: JSONValue].self, from: json)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: [String: JSONValue]) throws -> T {
        try wireDecoder.decode(T.self, from: try JSONEncoder().encode(data))
    }
}
