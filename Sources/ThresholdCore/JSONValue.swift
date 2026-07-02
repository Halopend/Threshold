// JSONValue.swift — a lossless JSON tree. Persistence uses it for two things:
// (1) preserving unknown keys through load→save round trips (plan §7.1:
// "Unknown params on load are preserved and warned, not dropped"), and
// (2) the migration table's working representation (plan §7.3: migrations are
// data + pure functions over the raw tree, applied BEFORE typed decoding).

import Foundation

public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

extension JSONValue {
    /// Interpret this value as a float component array: a numeric array
    /// (`[1, 2, 3]`) or a bare number (`8` → `[8]`). Returns nil for any
    /// other shape — such values stay in the foreign sidecar untouched.
    public var asFloatComponents: [Float]? {
        switch self {
        case .number(let n):
            return [Float(n)]
        case .array(let items):
            var out = [Float]()
            out.reserveCapacity(items.count)
            for item in items {
                guard case .number(let n) = item else { return nil }
                out.append(Float(n))
            }
            return out
        default:
            return nil
        }
    }
}
