import Foundation

public enum JSONRPCStandardError {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    /// MCP 2026-07-28：请求声明的协议版本不受支持。
    public static let unsupportedProtocolVersion = -32022
}

public struct JSONRPCErrorDetail: Sendable, Equatable, Codable {
    public let code: Int
    public let message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case code, message, data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(data, forKey: .data)
    }
}

/// 单条 JSON-RPC 2.0 消息。请求、通知与响应共用一个值类型，由工厂方法
/// 保证合法组合；编码时按 kind 选择输出字段。
public struct JSONRPCMessage: Sendable, Equatable {
    public let id: JSONValue?
    public let method: String?
    public let params: JSONValue?
    public let result: JSONValue?
    public let error: JSONRPCErrorDetail?

    public static func request(id: JSONValue, method: String, params: JSONValue?) -> JSONRPCMessage {
        JSONRPCMessage(id: id, method: method, params: params, result: nil, error: nil)
    }

    public static func notification(method: String, params: JSONValue?) -> JSONRPCMessage {
        JSONRPCMessage(id: nil, method: method, params: params, result: nil, error: nil)
    }

    public static func response(id: JSONValue, result: JSONValue) -> JSONRPCMessage {
        JSONRPCMessage(id: id, method: nil, params: nil, result: result, error: nil)
    }

    public static func error(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) -> JSONRPCMessage {
        JSONRPCMessage(
            id: id,
            method: nil,
            params: nil,
            result: nil,
            error: JSONRPCErrorDetail(code: code, message: message, data: data)
        )
    }

    private init(
        id: JSONValue?,
        method: String?,
        params: JSONValue?,
        result: JSONValue?,
        error: JSONRPCErrorDetail?
    ) {
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }
}

extension JSONRPCMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params, result, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        guard jsonrpc == "2.0" else {
            throw DecodingError.dataCorruptedError(
                forKey: .jsonrpc,
                in: container,
                debugDescription: "仅支持 JSON-RPC 2.0"
            )
        }
        let id = try container.decodeIfPresent(JSONValue.self, forKey: .id)
        let method = try container.decodeIfPresent(String.self, forKey: .method)
        let params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
        let result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        let error = try container.decodeIfPresent(JSONRPCErrorDetail.self, forKey: .error)

        if let method {
            self.init(id: id, method: method, params: params, result: nil, error: nil)
        } else if let error {
            guard result == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .result,
                    in: container,
                    debugDescription: "响应不能同时携带 result 与 error"
                )
            }
            self.init(id: id, method: nil, params: nil, result: nil, error: error)
        } else if let result {
            self.init(id: id, method: nil, params: nil, result: result, error: nil)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "消息既不是请求也不是响应"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        if let method {
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encodeIfPresent(params, forKey: .params)
        } else if let error {
            try container.encode(id ?? .null, forKey: .id)
            try container.encode(error, forKey: .error)
        } else {
            try container.encode(id ?? .null, forKey: .id)
            try container.encode(result ?? .null, forKey: .result)
        }
    }
}

/// stdio 传输是逐行 JSON 文本；本模块只负责单条消息与 Data 的互转。
public enum JSONRPCCodec {
    public enum CodecError: Error, Equatable, Sendable {
        case batchUnsupported
    }

    public static func decode(_ data: Data) throws -> JSONRPCMessage {
        // 批量语义已废弃：顶层是数组时直接按废弃拒绝。
        if (try? JSONDecoder().decode([JSONValue].self, from: data)) != nil {
            throw CodecError.batchUnsupported
        }
        return try JSONDecoder().decode(JSONRPCMessage.self, from: data)
    }

    public static func encode(_ message: JSONRPCMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(message)
    }
}
