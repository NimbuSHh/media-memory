import Foundation
import MediaMemoryCore

/// MCP 服务器默认身份。版本随应用 release 一起推进。
public enum MediaMemoryMCPServerDefaults {
    public static let identity = MCPServerIdentity(name: "media-memory", version: "0.1.0")

    /// initialize 握手可协商的 legacy 版本，最新优先。
    public static let legacyProtocolVersions = [
        "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"
    ]

    public static let modernProtocolVersions = ["2026-07-28"]

    public static let instructions = """
    Media Memory 检索用户的本地视频/图片媒体库（内容为中文为主）。典型用法：
    先用 library_stats 了解库规模，再用 search_media 按画面内容、台词或画面
    文字检索（同一媒体聚合为一条结果，附带可定位的时间戳）；需要某个媒体
    的完整分段信息时用 get_video_detail。所有数据只读，均来自用户本机。
    """

    public static var options: MCPServerOptions {
        MCPServerOptions(
            identity: identity,
            legacyProtocolVersions: legacyProtocolVersions,
            modernProtocolVersions: modernProtocolVersions,
            instructions: instructions
        )
    }
}

/// 与 GUI 完全同源的服务装配：相同数据根（含 MEDIA_MEMORY_DATA_ROOT 覆盖）、
/// 相同 models.json/凭据文件配置、数据库以只读连接打开。模型运行时不可用时
/// 降级为关键词检索，服务仍然可用。
public enum MediaMemoryMCPServices {
    public static func makeSearchBackend() async throws -> (
        backend: MediaMemorySearchBackend,
        degradationNote: String?
    ) {
        let configuration: ModelConfiguration
        var degradationNote: String?
        do {
            configuration = try ModelConfigurationStore.load()
        } catch {
            configuration = try ModelConfiguration.loadDefault()
            degradationNote = "models.json 读取失败，已使用内置默认模型配置。"
        }

        let databaseURL = try ApplicationPaths.databaseURL()
        let database: MediaDatabase
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            database = try MediaDatabase(readOnlyURL: databaseURL)
            // 只读连接不迁移。库落后于当前程序时，检索查询必然失败；
            // 与其让 agent 收到 SQL 错误，不如直接拒绝启动并给出路径。
            let schema = try await database.schemaVersion()
            guard schema >= MediaDatabase.supportedSchemaVersion else {
                throw BootstrapError.librarySchemaOutdated(
                    schema: schema,
                    supported: MediaDatabase.supportedSchemaVersion
                )
            }
        } else {
            // 只读连接要求库文件已存在。app 首次启动前集成 agent 时，
            // 用临时空库维持服务，统计与检索自然为空。
            let scratchURL = FileManager.default.temporaryDirectory
                .appending(component: "media-memory-mcp-empty-\(UUID().uuidString).sqlite")
            database = try MediaDatabase(url: scratchURL)
            degradationNote = "媒体库尚未创建（应用尚未完成首次启动/扫描），检索将返回空结果。"
        }

        // 凭据来自应用数据目录的 model-credentials.json（0600，仅当前用户
        // 可读写），与 models.json 同源。读取是纯文件操作，不触碰
        // Security API，无人值守进程没有授权弹窗风险。需要显式禁用时设置
        // MEDIA_MEMORY_DISABLE_CREDENTIAL_STORE=1。
        var semanticNote: String?
        let credentials: ModelCredentials
        if configuration.embedding.transport == .mediaMemoryEmbedding {
            do {
                credentials = try ModelCredentialStore.loadModelCredentials()
            } catch {
                credentials = ModelCredentials()
                semanticNote = "凭据读取失败，语义检索将自动降级为关键词检索（\(error.localizedDescription)）。"
            }
            if credentials.embedding.isEmpty {
                semanticNote = "embedding 走 HTTP 且未配置密钥；若端点要求鉴权，语义检索将自动降级为关键词检索。"
            }
        } else {
            credentials = ModelCredentials()
        }
        var runtime: ModelRuntime?
        do {
            runtime = try ModelRuntime(
                configuration: configuration,
                credentials: credentials,
                workRoot: try ApplicationPaths.workDirectoryURL()
            )
        } catch {
            semanticNote = "语义检索不可用（\(error.localizedDescription)），将只提供关键词检索。"
        }

        let searchService = SearchService(
            database: database,
            configuration: configuration,
            runtime: runtime
        )
        let backend = MediaMemorySearchBackend(
            searchService: searchService,
            database: database,
            modelSummary: Self.modelSummary(configuration)
        )
        return (backend, degradationNote ?? semanticNote)
    }

    enum BootstrapError: LocalizedError {
        case librarySchemaOutdated(schema: Int64, supported: Int64)

        var errorDescription: String? {
            switch self {
            case let .librarySchemaOutdated(schema, supported):
                "媒体库 schema（\(schema)）由旧版本应用创建，当前程序要求 \(supported)。"
                    + "请先启动 Media Memory 应用完成库迁移，再使用 agent 检索。"
            }
        }
    }

    private static func modelSummary(_ configuration: ModelConfiguration) -> String {
        let embeddingTransport: String
        if configuration.embedding.transport == .localWorker {
            embeddingTransport = "本地 Worker"
        } else {
            embeddingTransport = "HTTP"
        }
        var summary = "embedding \(configuration.embedding.modelID)（\(embeddingTransport)）"
        if configuration.description.transport.requiresEndpoint {
            summary += "；描述 \(configuration.description.modelID)（HTTP）"
        }
        return summary
    }
}
