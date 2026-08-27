import CryptoKit
import Foundation

public enum ModelRole: String, CaseIterable, Codable, Hashable, Sendable {
    case asr
    case aligner
    case embedding
    case description

    public var displayName: String {
        switch self {
        case .asr: "语音识别"
        case .aligner: "句子时间定位"
        case .embedding: "多模态向量"
        case .description: "画面描述"
        }
    }
}

/// The app depends on capability contracts, not vendor identities. A localhost
/// service and a remote service use the same transport when their HTTP contract
/// is the same.
public enum ModelTransport: String, CaseIterable, Codable, Sendable {
    case openAITranscription = "openai_audio_transcriptions"
    case mediaMemoryAlignment = "media_memory_alignment"
    case mediaMemoryEmbedding = "media_memory_multimodal_embedding"
    case openAIChatCompletion = "openai_chat_completions"
    case localWorker = "local_worker"

    public var requiresEndpoint: Bool { self != .localWorker }
}

public enum ModelAuthentication: String, Codable, Sendable {
    case none
    case bearer
}

public struct ModelEndpoint: Codable, Equatable, Sendable {
    public let transport: ModelTransport
    public let endpointURL: URL?
    public let modelID: String
    public let authentication: ModelAuthentication

    public init(
        transport: ModelTransport,
        endpointURL: URL?,
        modelID: String,
        authentication: ModelAuthentication = .none
    ) {
        self.transport = transport
        self.endpointURL = endpointURL
        self.modelID = modelID
        self.authentication = transport == .localWorker ? .none : authentication
    }

    /// Persisted derivations must change when the same model name is served by
    /// a different endpoint or adapter. API keys intentionally do not participate.
    public var derivationID: String {
        let source = [
            transport.rawValue,
            endpointURL?.absoluteString ?? "local-worker",
            modelID
        ].joined(separator: "\n")
        let suffix = SHA256.hash(data: Data(source.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(modelID)@\(suffix)"
    }

    private enum CodingKeys: String, CodingKey {
        case transport
        case endpointURL
        case modelID
        case authentication
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transport = try container.decode(ModelTransport.self, forKey: .transport)
        endpointURL = try container.decodeIfPresent(URL.self, forKey: .endpointURL)
        modelID = try container.decode(String.self, forKey: .modelID)
        if transport == .localWorker {
            authentication = .none
        } else if let saved = try container.decodeIfPresent(
            ModelAuthentication.self,
            forKey: .authentication
        ) {
            authentication = saved
        } else {
            // Schema 1/2 had no explicit authentication mode. Preserve likely
            // remote Bearer setups while ensuring local no-auth services never
            // cause a Keychain read merely because the app launched.
            authentication = endpointURL?.isLoopbackHost == true ? .none : .bearer
        }
    }
}

public struct ModelConfiguration: Codable, Equatable, Sendable {
    /// Schema-1 compatibility view. New code should use capability endpoints.
    public struct OMLX: Codable, Equatable, Sendable {
        public let baseURL: URL
        public let asrModelID: String
        public let descriptionModelID: String

        public init(baseURL: URL, asrModelID: String, descriptionModelID: String) {
            self.baseURL = baseURL
            self.asrModelID = asrModelID
            self.descriptionModelID = descriptionModelID
        }
    }

    public struct Worker: Codable, Equatable, Sendable {
        public let forcedAlignerModelID: String
        public let embeddingModelID: String
        public let pythonLauncherPath: String
        public let modelRootPath: String

        public init(
            forcedAlignerModelID: String,
            embeddingModelID: String,
            pythonLauncherPath: String,
            modelRootPath: String
        ) {
            self.forcedAlignerModelID = forcedAlignerModelID
            self.embeddingModelID = embeddingModelID
            self.pythonLauncherPath = pythonLauncherPath
            self.modelRootPath = modelRootPath
        }
    }

    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let asr: ModelEndpoint
    public let aligner: ModelEndpoint
    public let embedding: ModelEndpoint
    public let description: ModelEndpoint
    public let localWorker: Worker?

    public init(
        asr: ModelEndpoint,
        aligner: ModelEndpoint,
        embedding: ModelEndpoint,
        description: ModelEndpoint,
        localWorker: Worker?
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.asr = asr
        self.aligner = aligner
        self.embedding = embedding
        self.description = description
        self.localWorker = localWorker
    }

    public var usesLocalWorker: Bool {
        aligner.transport == .localWorker || embedding.transport == .localWorker
    }

    public var credentialRoles: Set<ModelRole> {
        Set(ModelRole.allCases.filter { endpoint(for: $0).authentication == .bearer })
    }

    public var omlx: OMLX {
        var baseURL = asr.endpointURL ?? URL(string: "http://127.0.0.1/")!
        if baseURL.lastPathComponent == "transcriptions" {
            baseURL.deleteLastPathComponent()
            if baseURL.lastPathComponent == "audio" { baseURL.deleteLastPathComponent() }
        }
        return OMLX(
            baseURL: baseURL,
            asrModelID: asr.modelID,
            descriptionModelID: description.modelID
        )
    }

    public var worker: Worker {
        let paths = localWorker ?? Worker(
            forcedAlignerModelID: aligner.modelID,
            embeddingModelID: embedding.modelID,
            pythonLauncherPath: "",
            modelRootPath: ""
        )
        return Worker(
            forcedAlignerModelID: aligner.modelID,
            embeddingModelID: embedding.modelID,
            pythonLauncherPath: paths.pythonLauncherPath,
            modelRootPath: paths.modelRootPath
        )
    }

    /// Source compatibility for schema-1 callers. Encoding always writes the
    /// current schema.
    public init(schemaVersion _: Int, omlx: OMLX, worker: Worker) {
        let authentication: ModelAuthentication = omlx.baseURL.isLoopbackHost ? .none : .bearer
        self.init(
            asr: ModelEndpoint(
                transport: .openAITranscription,
                endpointURL: omlx.baseURL.appending(path: "audio/transcriptions"),
                modelID: omlx.asrModelID,
                authentication: authentication
            ),
            aligner: ModelEndpoint(
                transport: .localWorker,
                endpointURL: nil,
                modelID: worker.forcedAlignerModelID
            ),
            embedding: ModelEndpoint(
                transport: .localWorker,
                endpointURL: nil,
                modelID: worker.embeddingModelID
            ),
            description: ModelEndpoint(
                transport: .openAIChatCompletion,
                endpointURL: omlx.baseURL.appending(path: "chat/completions"),
                modelID: omlx.descriptionModelID,
                authentication: authentication
            ),
            localWorker: worker
        )
    }

    public func endpoint(for role: ModelRole) -> ModelEndpoint {
        switch role {
        case .asr: asr
        case .aligner: aligner
        case .embedding: embedding
        case .description: description
        }
    }

    public func validate() throws {
        for role in ModelRole.allCases {
            try validate(role: role)
        }
    }

    public func validate(role: ModelRole) throws {
        let endpoint = endpoint(for: role)
        guard !endpoint.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelConfigurationError.missingModelID(role)
        }
        guard Self.allowedTransports(for: role).contains(endpoint.transport) else {
            throw ModelConfigurationError.unsupportedTransport(role, endpoint.transport)
        }
        if endpoint.transport.requiresEndpoint {
            guard let url = endpoint.endpointURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else {
                throw ModelConfigurationError.invalidEndpoint(role)
            }
        }
        if endpoint.transport == .localWorker {
            guard let localWorker,
                  !localWorker.pythonLauncherPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !localWorker.modelRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ModelConfigurationError.missingLocalWorker
            }
        }
    }

    public static func allowedTransports(for role: ModelRole) -> Set<ModelTransport> {
        switch role {
        case .asr: [.openAITranscription]
        case .aligner: [.mediaMemoryAlignment, .localWorker]
        case .embedding: [.mediaMemoryEmbedding, .localWorker]
        case .description: [.openAIChatCompletion]
        }
    }

    public static func loadDefault() throws -> ModelConfiguration {
        guard let url = resourceBundle().url(
            forResource: "default-models",
            withExtension: "json"
        ) else {
            throw ModelConfigurationError.missingBundledConfiguration
        }
        return try load(from: url)
    }

    public static func load(from url: URL) throws -> ModelConfiguration {
        let data = try Data(contentsOf: url)
        let configuration = try JSONDecoder().decode(ModelConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }

    public static func workerScriptURL() throws -> URL {
        guard let url = resourceBundle().url(
            forResource: "media_worker",
            withExtension: "py"
        ) else {
            throw ModelConfigurationError.missingWorkerScript
        }
        return url
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case asr
        case aligner
        case embedding
        case description
        case localWorker
        case omlx
        case worker
    }

    private struct LegacyOMLX: Decodable {
        let baseURL: URL
        let asrModelID: String
        let descriptionModelID: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= Self.currentSchemaVersion else {
            throw ModelConfigurationError.unsupportedSchemaVersion(version)
        }

        if version >= 2 {
            schemaVersion = Self.currentSchemaVersion
            asr = try container.decode(ModelEndpoint.self, forKey: .asr)
            aligner = try container.decode(ModelEndpoint.self, forKey: .aligner)
            embedding = try container.decode(ModelEndpoint.self, forKey: .embedding)
            description = try container.decode(ModelEndpoint.self, forKey: .description)
            localWorker = try container.decodeIfPresent(Worker.self, forKey: .localWorker)
            return
        }

        // Schema 1 was tied to one oMLX HTTP connection plus a direct MLX
        // worker. Decode it in place so existing users keep working, then emit
        // the current schema the next time Settings is saved.
        let legacyHTTP = try container.decode(LegacyOMLX.self, forKey: .omlx)
        let legacyWorker = try container.decode(Worker.self, forKey: .worker)
        let legacyHTTPAuthentication: ModelAuthentication =
            legacyHTTP.baseURL.isLoopbackHost ? .none : .bearer
        schemaVersion = Self.currentSchemaVersion
        asr = ModelEndpoint(
            transport: .openAITranscription,
            endpointURL: legacyHTTP.baseURL.appending(path: "audio/transcriptions"),
            modelID: legacyHTTP.asrModelID,
            authentication: legacyHTTPAuthentication
        )
        aligner = ModelEndpoint(
            transport: .localWorker,
            endpointURL: nil,
            modelID: legacyWorker.forcedAlignerModelID
        )
        embedding = ModelEndpoint(
            transport: .localWorker,
            endpointURL: nil,
            modelID: legacyWorker.embeddingModelID
        )
        description = ModelEndpoint(
            transport: .openAIChatCompletion,
            endpointURL: legacyHTTP.baseURL.appending(path: "chat/completions"),
            modelID: legacyHTTP.descriptionModelID,
            authentication: legacyHTTPAuthentication
        )
        localWorker = legacyWorker
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(asr, forKey: .asr)
        try container.encode(aligner, forKey: .aligner)
        try container.encode(embedding, forKey: .embedding)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(localWorker, forKey: .localWorker)
    }

    /// SwiftPM's generated accessor looks beside the executable, while a
    /// packaged macOS app seals resources under Contents/Resources.
    private static func resourceBundle() -> Bundle {
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(
               url: resources.appending(
                   path: "MediaMemory_MediaMemoryCore.bundle",
                   directoryHint: .isDirectory
               )
           ) {
            return bundle
        }
        return Bundle.module
    }
}

public enum ModelConfigurationError: Error, Equatable {
    case missingBundledConfiguration
    case missingWorkerScript
    case unsupportedSchemaVersion(Int)
    case missingModelID(ModelRole)
    case invalidEndpoint(ModelRole)
    case unsupportedTransport(ModelRole, ModelTransport)
    case missingLocalWorker
}

extension ModelConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingBundledConfiguration:
            "应用内缺少默认模型配置。"
        case .missingWorkerScript:
            "应用内缺少本地模型 Worker。"
        case let .unsupportedSchemaVersion(version):
            "模型配置版本 \(version) 高于当前应用支持的版本。"
        case let .missingModelID(role):
            "\(role.displayName)的模型名称不能为空。"
        case let .invalidEndpoint(role):
            "\(role.displayName)的请求地址必须是有效的 HTTP(S) URL。"
        case let .unsupportedTransport(role, _):
            "\(role.displayName)选择了不支持的接口类型。"
        case .missingLocalWorker:
            "本地 Worker 的启动器或模型目录没有配置完整。"
        }
    }
}

private extension URL {
    var isLoopbackHost: Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
