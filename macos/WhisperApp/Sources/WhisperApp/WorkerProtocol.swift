import Foundation

struct WorkerCommand: Encodable, Sendable {
    let protocolName = "whisper.worker"
    let version = 1
    let type = "command"
    let requestID: String
    let command: String
    let payload: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case version, type
        case requestID = "request_id"
        case command, payload
    }
}

struct WorkerEvent: Decodable, Sendable, Equatable {
    let protocolName: String
    let version: Int
    let type: String
    let requestID: String
    let event: String
    let payload: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case version, type
        case requestID = "request_id"
        case event, payload
    }
}

enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}
