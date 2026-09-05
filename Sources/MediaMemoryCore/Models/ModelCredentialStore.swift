import Foundation
import Security

public struct ModelCredentials: Equatable, Sendable {
    public var asr: String
    public var aligner: String
    public var embedding: String
    public var description: String

    public init(
        asr: String = "",
        aligner: String = "",
        embedding: String = "",
        description: String = ""
    ) {
        self.asr = asr
        self.aligner = aligner
        self.embedding = embedding
        self.description = description
    }

    public subscript(role: ModelRole) -> String {
        get {
            switch role {
            case .asr: asr
            case .aligner: aligner
            case .embedding: embedding
            case .description: description
            }
        }
        set {
            switch role {
            case .asr: asr = newValue
            case .aligner: aligner = newValue
            case .embedding: embedding = newValue
            case .description: description = newValue
            }
        }
    }

    var roleKeyedDictionary: [String: String] {
        Dictionary(
            uniqueKeysWithValues: ModelRole.allCases.map { ($0.rawValue, self[$0]) }
        )
    }
}

/// 模型 API key 的唯一存储：应用数据目录下的 `model-credentials.json`，
/// 权限 0600（仅当前用户可读写）。
///
/// 不再使用 login keychain：keychain 的访问授权绑定创建它的那个二进制
/// 签名，本项目使用长期自签名身份（无 Team ID），每个新版本的签名都无法
/// 匹配旧条目 ACL，必然为每个条目各弹一次系统授权框。文件存储跨版本稳定，
/// 与 models.json 同目录同生命周期。
///
/// 首次读取时若凭据文件尚不存在，会一次性迁移旧版写入 login keychain 的
/// 条目（服务 `MediaMemory.ModelService` 及遗留的 `MediaMemory.oMLX`）。
/// 迁移成功后立即删除旧条目，此后不再触碰 Security API。
public enum ModelCredentialStore {
    private static let fileSchema = 1
    private static let keychainService = "MediaMemory.ModelService"
    private static let legacyKeychainService = "MediaMemory.oMLX"
    private static let legacyKeychainAccount = "default"

    public static func loadModelCredentials() throws -> ModelCredentials {
        try loadModelCredentials(for: Set(ModelRole.allCases))
    }

    public static func loadModelCredentials(
        for roles: Set<ModelRole>
    ) throws -> ModelCredentials {
        try loadModelCredentials(
            fileURL: ApplicationPaths.modelCredentialsURL(),
            for: roles
        )
    }

    public static func loadModelCredentialsAsync() async throws -> ModelCredentials {
        try await loadModelCredentialsAsync(for: Set(ModelRole.allCases))
    }

    public static func loadModelCredentialsAsync(
        for roles: Set<ModelRole>
    ) async throws -> ModelCredentials {
        try await Task.detached(priority: .utility) {
            try loadModelCredentials(for: roles)
        }.value
    }

    /// Empty keys are valid for authentication-free local services and clear
    /// previously stored secrets for that capability.
    public static func saveModelCredentials(_ credentials: ModelCredentials) throws {
        try saveModelCredentials(credentials, for: Set(ModelRole.allCases))
    }

    public static func saveModelCredentials(
        _ credentials: ModelCredentials,
        for roles: Set<ModelRole>
    ) throws {
        try saveModelCredentials(
            credentials,
            fileURL: ApplicationPaths.modelCredentialsURL(),
            for: roles
        )
    }

    public static func saveModelCredentialsAsync(_ credentials: ModelCredentials) async throws {
        try await saveModelCredentialsAsync(credentials, for: Set(ModelRole.allCases))
    }

    public static func saveModelCredentialsAsync(
        _ credentials: ModelCredentials,
        for roles: Set<ModelRole>
    ) async throws {
        try await Task.detached(priority: .utility) {
            try saveModelCredentials(credentials, for: roles)
        }.value
    }

    // MARK: - 文件实现

    static func loadModelCredentials(
        fileURL: URL,
        for roles: Set<ModelRole>,
        keychainReader: (Set<ModelRole>) throws -> ModelCredentials = readFromKeychain,
        keychainCleaner: () throws -> Void = cleanUpKeychain
    ) throws -> ModelCredentials {
        guard !roles.isEmpty else { return ModelCredentials() }
        if isCredentialStoreDisabled { return ModelCredentials() }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try project(readCredentials(at: fileURL), for: roles)
        }

        // 凭据文件缺失时执行一次性 keychain 迁移。即使旧条目全为空也写入
        // 文件：文件存在本身就是"迁移已完成"的标记，避免每次启动重读
        // keychain。迁移读取失败则不落盘，下次启动可重试。
        let migrated = try keychainReader(Set(ModelRole.allCases))
        try writeCredentials(migrated, to: fileURL)
        try? keychainCleaner()
        return try project(migrated, for: roles)
    }

    static func saveModelCredentials(
        _ credentials: ModelCredentials,
        fileURL: URL,
        for roles: Set<ModelRole>
    ) throws {
        guard !roles.isEmpty else { return }
        if isCredentialStoreDisabled { return }

        var merged = FileManager.default.fileExists(atPath: fileURL.path)
            ? (try? readCredentials(at: fileURL)) ?? ModelCredentials()
            : ModelCredentials()
        for role in ModelRole.allCases where roles.contains(role) {
            merged[role] = credentials[role]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try writeCredentials(merged, to: fileURL)
    }

    private static func project(
        _ credentials: ModelCredentials,
        for roles: Set<ModelRole>
    ) throws -> ModelCredentials {
        var projected = ModelCredentials()
        for role in ModelRole.allCases where roles.contains(role) {
            projected[role] = credentials[role]
        }
        return projected
    }

    private static func readCredentials(at fileURL: URL) throws -> ModelCredentials {
        let data = try Data(contentsOf: fileURL)
        do {
            let file = try JSONDecoder().decode(CredentialFile.self, from: data)
            guard file.schema == fileSchema else {
                throw CredentialStoreError.corruptCredentialFile(path: fileURL.path)
            }
            var credentials = ModelCredentials()
            for role in ModelRole.allCases {
                credentials[role] = file.credentials[role.rawValue] ?? ""
            }
            return credentials
        } catch let error as CredentialStoreError {
            throw error
        } catch {
            throw CredentialStoreError.corruptCredentialFile(path: fileURL.path)
        }
    }

    private static func writeCredentials(
        _ credentials: ModelCredentials,
        to fileURL: URL
    ) throws {
        let file = CredentialFile(schema: fileSchema, credentials: credentials.roleKeyedDictionary)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let temporaryURL = directory.appending(
            path: ".model-credentials-\(UUID().uuidString).tmp"
        )
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CredentialStoreError.credentialFileWriteFailed(path: temporaryURL.path)
        }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        // 已存在的文件可能带着旧版更宽的权限，统一收紧到仅当前用户。
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static var isCredentialStoreDisabled: Bool {
        ProcessInfo.processInfo.environment["MEDIA_MEMORY_DISABLE_CREDENTIAL_STORE"] == "1"
    }

    private struct CredentialFile: Codable {
        var schema: Int
        var credentials: [String: String]
    }

    // MARK: - 旧版 keychain 迁移

    /// 迁移读取始终取全部角色：文件一旦写入就是唯一事实来源，后续任何
    /// 懒加载都不应再触发 keychain 访问。
    private static func readFromKeychain(
        for roles: Set<ModelRole>
    ) throws -> ModelCredentials {
        var credentials = ModelCredentials()
        for role in ModelRole.allCases {
            credentials[role] = try readKeychainItem(
                service: keychainService,
                account: role.rawValue
            ) ?? ""
        }

        // Schema 1 把 oMLX 单键同时用作 asr 与 description 的 key。
        if credentials.asr.isEmpty || credentials.description.isEmpty,
           let legacy = try readKeychainItem(
            service: legacyKeychainService,
            account: legacyKeychainAccount
           ) {
            if credentials.asr.isEmpty { credentials.asr = legacy }
            if credentials.description.isEmpty { credentials.description = legacy }
        }
        return credentials
    }

    private static func cleanUpKeychain() {
        for role in ModelRole.allCases {
            try? deleteKeychainItem(service: keychainService, account: role.rawValue)
        }
        try? deleteKeychainItem(service: legacyKeychainService, account: legacyKeychainAccount)
    }

    private static func readKeychainItem(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.keychainReadFailed(status)
        }
        return value
    }

    private static func deleteKeychainItem(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainReadFailed(status)
        }
    }
}

public enum CredentialStoreError: Error, LocalizedError, Sendable {
    case keychainReadFailed(OSStatus)
    case corruptCredentialFile(path: String)
    case credentialFileWriteFailed(path: String)

    public var errorDescription: String? {
        switch self {
        case let .keychainReadFailed(status):
            "无法读取旧版钥匙串凭据（macOS 错误 \(status)）。可在系统弹窗中允许访问完成一次性迁移；若仍失败，请在模型设置中重新输入 API key。"
        case let .corruptCredentialFile(path):
            "本机凭据文件无法解析：\(path)。请在模型设置中重新保存 API key 以重建该文件。"
        case let .credentialFileWriteFailed(path):
            "无法写入凭据文件：\(path)。"
        }
    }
}
