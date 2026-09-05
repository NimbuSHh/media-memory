import Foundation

public struct MCPServerIdentity: Sendable, Equatable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct MCPServerOptions: Sendable {
    public let identity: MCPServerIdentity
    /// legacy（≤2025-11-25）initialize 握手可协商的版本，最新优先。
    public let legacyProtocolVersions: [String]
    /// modern（2026-07-28 起）按请求 `_meta` 声明的版本，最新优先。
    public let modernProtocolVersions: [String]
    /// 给 LLM 的使用说明，随 initialize / server/discover 一起返回。
    public let instructions: String

    public init(
        identity: MCPServerIdentity,
        legacyProtocolVersions: [String],
        modernProtocolVersions: [String],
        instructions: String
    ) {
        self.identity = identity
        self.legacyProtocolVersions = legacyProtocolVersions
        self.modernProtocolVersions = modernProtocolVersions
        self.instructions = instructions
    }

    public var supportedVersions: [String] {
        modernProtocolVersions + legacyProtocolVersions
    }
}

public struct MCPToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// 工具执行结果。执行失败（如路径不存在）走 `isError`，属于工具语义；
/// 协议层错误（未知工具、参数非法）由后端抛 `MCPServerError`。
public struct MCPToolOutcome: Sendable, Equatable {
    public var text: String
    public var structuredContent: JSONValue?
    public var isError: Bool

    public init(text: String, structuredContent: JSONValue? = nil, isError: Bool = false) {
        self.text = text
        self.structuredContent = structuredContent
        self.isError = isError
    }
}

public protocol MCPServerBackend: Sendable {
    func tools() async -> [MCPToolDefinition]
    func call(name: String, arguments: JSONValue) async throws -> MCPToolOutcome
}

public enum MCPServerError: Error, Sendable {
    case unknownTool(String)
    case invalidParams(String)

    public var message: String {
        switch self {
        case .unknownTool(let name):
            "未知工具：\(name)"
        case .invalidParams(let detail):
            detail
        }
    }
}

/// 2026-07-28 规范的每请求协议字段。必需字段缺失按 -32602 拒绝。
private struct ModernRequestMeta {
    let protocolVersion: String
    let clientCapabilitiesPresent: Bool

    init?(params: JSONValue?) {
        guard let meta = params?["_meta"]?.objectValue else { return nil }
        guard let version = meta["io.modelcontextprotocol/protocolVersion"]?.stringValue else {
            return nil
        }
        protocolVersion = version
        clientCapabilitiesPresent = meta["io.modelcontextprotocol/clientCapabilities"] != nil
    }
}

/// MCP stdio 会话。请求面在 legacy 与 modern 两个 era 完全一致，差异只在
/// 会话管理：legacy 走一次 initialize 协商；modern 每个请求自带版本，
/// 服务器保持无状态。actor 重入保证取消通知能在长检索挂起期间被处理。
public actor MCPServerSession {
    private let backend: MCPServerBackend
    private let options: MCPServerOptions
    private var legacyProtocolVersion: String?
    private var inFlight: [String: Task<MCPToolOutcome, Error>] = [:]

    public init(backend: MCPServerBackend, options: MCPServerOptions) {
        self.backend = backend
        self.options = options
    }

    /// 处理一行输入，返回要写回 stdout 的响应数据。通知与被取消的请求返回 nil。
    public func handle(_ data: Data) async -> Data? {
        let message: JSONRPCMessage
        do {
            message = try JSONRPCCodec.decode(data)
        } catch {
            let detail: String
            if error is JSONRPCCodec.CodecError {
                detail = "批量消息已废弃，请逐条发送"
            } else {
                detail = "无法解析 JSON-RPC 消息"
            }
            return Self.encode(
                JSONRPCMessage.error(
                    id: .null,
                    code: JSONRPCStandardError.parseError,
                    message: detail
                )
            )
        }

        guard let method = message.method else {
            // 服务器从不发起请求；收到响应属于对端协议噪声。
            return Self.encode(
                JSONRPCMessage.error(
                    id: message.id ?? .null,
                    code: JSONRPCStandardError.invalidRequest,
                    message: "服务器不接受 JSON-RPC 响应"
                )
            )
        }

        if message.id == nil {
            await handleNotification(method: method, params: message.params)
            return nil
        }
        return await handleRequest(id: message.id ?? .null, method: method, params: message.params)
    }

    // MARK: - Notifications

    private func handleNotification(method: String, params: JSONValue?) async {
        switch method {
        case "notifications/initialized":
            // legacy 握手完成标记；无状态实现无需进一步动作。
            break
        case "notifications/cancelled":
            let key = params?["requestId"].map(Self.inFlightKey) ?? ""
            if let task = inFlight.removeValue(forKey: key) {
                task.cancel()
            }
        default:
            break
        }
    }

    // MARK: - Requests

    private func handleRequest(id: JSONValue, method: String, params: JSONValue?) async -> Data? {
        let modernMeta = ModernRequestMeta(params: params)
        switch method {
        case "initialize":
            return handleInitialize(id: id, params: params, modernMeta: modernMeta)
        case "server/discover":
            // modern 必备方法；legacy 客户端不会调用，缺 _meta 按未知方法
            // 回应，正好是 stdio 探测流程期待的回退信号。
            guard let modernMeta else {
                return errorResponse(id, JSONRPCStandardError.methodNotFound, "未知方法：\(method)")
            }
            if let rejection = rejectModernVersion(id: id, meta: modernMeta) { return rejection }
            return handleDiscover(id: id)
        case "tools/list", "tools/call", "ping":
            if let rejection = rejectModernVersion(id: id, meta: modernMeta) { return rejection }
            switch method {
            case "tools/list":
                return await handleToolsList(id: id, modernMeta: modernMeta)
            case "tools/call":
                return await handleToolsCall(id: id, params: params, modernMeta: modernMeta)
            default:
                return Self.encode(JSONRPCMessage.response(id: id, result: .object([:])))
            }
        default:
            return errorResponse(id, JSONRPCStandardError.methodNotFound, "未知方法：\(method)")
        }
    }

    /// modern 请求的版本与必备字段校验。nil 表示放行。
    private func rejectModernVersion(id: JSONValue, meta: ModernRequestMeta?) -> Data? {
        guard let meta else { return nil }
        guard meta.clientCapabilitiesPresent else {
            return errorResponse(
                id,
                JSONRPCStandardError.invalidParams,
                "缺少必填 _meta 字段：io.modelcontextprotocol/clientCapabilities"
            )
        }
        guard options.supportedVersions.contains(meta.protocolVersion) else {
            return Self.encode(
                JSONRPCMessage.error(
                    id: id,
                    code: JSONRPCStandardError.unsupportedProtocolVersion,
                    message: "不支持的协议版本",
                    data: .object(["supported": .array(options.supportedVersions.map { .string($0) })])
                )
            )
        }
        return nil
    }

    private func handleInitialize(id: JSONValue, params: JSONValue?, modernMeta: ModernRequestMeta?) -> Data? {
        if let modernMeta, let rejection = rejectModernVersion(id: id, meta: modernMeta) { return rejection }
        let requested = params?["protocolVersion"]?.stringValue
        let negotiated: String
        if let requested, options.legacyProtocolVersions.contains(requested) {
            negotiated = requested
        } else {
            // 客户端版本不受支持时回应我们最新的 legacy 版本，由客户端决定去留。
            negotiated = options.legacyProtocolVersions.first ?? "2024-11-05"
        }
        legacyProtocolVersion = negotiated
        let result: JSONValue = .object([
            "protocolVersion": .string(negotiated),
            "capabilities": .object([
                "tools": .object(["listChanged": .bool(false)])
            ]),
            "serverInfo": serverInfoValue,
            "instructions": .string(options.instructions)
        ])
        return Self.encode(JSONRPCMessage.response(id: id, result: result))
    }

    private func handleDiscover(id: JSONValue) -> Data? {
        let result: JSONValue = .object([
            "supportedVersions": .array(options.supportedVersions.map { .string($0) }),
            "capabilities": .object([
                "tools": .object([:])
            ]),
            "instructions": .string(options.instructions),
            "_meta": .object([
                "io.modelcontextprotocol/serverInfo": serverInfoValue
            ])
        ])
        return Self.encode(JSONRPCMessage.response(id: id, result: result))
    }

    private func handleToolsList(id: JSONValue, modernMeta: ModernRequestMeta?) async -> Data? {
        let definitions = await backend.tools()
        var result: [String: JSONValue] = [
            "tools": .array(definitions.map(Self.toolValue))
        ]
        if modernMeta != nil {
            result["_meta"] = .object(["io.modelcontextprotocol/serverInfo": serverInfoValue])
        }
        return Self.encode(JSONRPCMessage.response(id: id, result: .object(result)))
    }

    private func handleToolsCall(id: JSONValue, params: JSONValue?, modernMeta: ModernRequestMeta?) async -> Data? {
        guard let name = params?["name"]?.stringValue else {
            return errorResponse(id, JSONRPCStandardError.invalidParams, "tools/call 缺少工具名")
        }
        let arguments = params?["arguments"] ?? .object([:])

        let key = Self.inFlightKey(id)
        let task = Task { [backend] in
            try await backend.call(name: name, arguments: arguments)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        do {
            let outcome = try await task.value
            var result: [String: JSONValue] = [
                "content": .array([
                    .object(["type": .string("text"), "text": .string(outcome.text)])
                ])
            ]
            if let structured = outcome.structuredContent {
                result["structuredContent"] = structured
            }
            if outcome.isError {
                result["isError"] = .bool(true)
            }
            if modernMeta != nil {
                result["_meta"] = .object(["io.modelcontextprotocol/serverInfo": serverInfoValue])
            }
            return Self.encode(JSONRPCMessage.response(id: id, result: .object(result)))
        } catch is CancellationError {
            // 规范：被取消的请求不回响应，客户端按 requestId 自行忽略。
            return nil
        } catch let error as MCPServerError {
            return errorResponse(id, JSONRPCStandardError.invalidParams, error.message)
        } catch {
            return errorResponse(id, JSONRPCStandardError.internalError, error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private var serverInfoValue: JSONValue {
        .object([
            "name": .string(options.identity.name),
            "version": .string(options.identity.version)
        ])
    }

    private static func toolValue(_ tool: MCPToolDefinition) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema
        ])
    }

    private static func inFlightKey(_ id: JSONValue) -> String {
        switch id {
        case .null:
            "null"
        case .bool(let value):
            "b:\(value)"
        case .int(let value):
            "i:\(value)"
        case .double(let value):
            "d:\(value)"
        case .string(let value):
            "s:\(value)"
        case .array(let value):
            "a:\(value.map(inFlightKey).joined(separator: ","))"
        case .object(let value):
            "o:" + value.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(inFlightKey($0.value))" }
                .joined(separator: ",")
        }
    }

    private func errorResponse(_ id: JSONValue, _ code: Int, _ message: String, data: JSONValue? = nil) -> Data? {
        Self.encode(JSONRPCMessage.error(id: id, code: code, message: message, data: data))
    }

    private static func encode(_ message: JSONRPCMessage) -> Data {
        do {
            return try JSONRPCCodec.encode(message)
        } catch {
            // 协议值类型受我们控制，编码失败只可能是编程错误。
            preconditionFailure("JSON-RPC 编码失败：\(error)")
        }
    }
}
