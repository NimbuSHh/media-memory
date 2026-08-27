import Foundation
import LocalAuthentication
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
}

public enum KeychainStore {
    private static let service = "MediaMemory.ModelService"
    private static let legacyService = "MediaMemory.oMLX"
    private static let legacyAccount = "default"

    public static func loadModelCredentials() throws -> ModelCredentials {
        try loadModelCredentials(for: Set(ModelRole.allCases))
    }

    public static func loadModelCredentials(
        for roles: Set<ModelRole>
    ) throws -> ModelCredentials {
        if isDisabledForIsolatedRun { return ModelCredentials() }
        var credentials = ModelCredentials()
        for role in ModelRole.allCases where roles.contains(role) {
            credentials[role] = try load(service: service, account: role.rawValue) ?? ""
        }

        // Schema 1 used one oMLX key for both HTTP capabilities. Read it as a
        // fallback without rewriting Keychain during app startup.
        if (roles.contains(.asr) && credentials.asr.isEmpty)
            || (roles.contains(.description) && credentials.description.isEmpty),
           let legacy = try load(service: legacyService, account: legacyAccount) {
            if roles.contains(.asr), credentials.asr.isEmpty { credentials.asr = legacy }
            if roles.contains(.description), credentials.description.isEmpty {
                credentials.description = legacy
            }
        }
        return credentials
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

    /// Empty keys are valid for authentication-free local services and remove
    /// any previously stored secret for that capability.
    public static func saveModelCredentials(_ credentials: ModelCredentials) throws {
        try saveModelCredentials(credentials, for: Set(ModelRole.allCases))
    }

    public static func saveModelCredentials(
        _ credentials: ModelCredentials,
        for roles: Set<ModelRole>
    ) throws {
        if isDisabledForIsolatedRun { return }
        guard !roles.isEmpty else { return }
        let previous = try loadNewCredentials(for: roles)
        do {
            for role in ModelRole.allCases where roles.contains(role) {
                try set(credentials[role], service: service, account: role.rawValue)
            }
        } catch {
            for role in ModelRole.allCases where roles.contains(role) {
                try? set(previous[role], service: service, account: role.rawValue)
            }
            throw error
        }
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

    /// Explicit recovery for credentials created by the old ad-hoc signed App.
    /// This is never called at startup. macOS may show one authorization prompt
    /// while deleting an item whose old code-signing ACL no longer matches.
    public static func replaceInaccessibleModelCredentialsAsync(
        _ credentials: ModelCredentials,
        for roles: Set<ModelRole>
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try replaceInaccessibleModelCredentials(credentials, for: roles)
        }.value
    }

    public static func deleteLegacyOMLXKeyAsync() async {
        guard !isDisabledForIsolatedRun else { return }
        await Task.detached(priority: .utility) {
            try? set("", service: legacyService, account: legacyAccount)
        }.value
    }

    // Kept for schema-1 integration helpers. New product code uses the
    // capability-scoped API above.
    public static func loadOMLXKey() throws -> String? {
        if isDisabledForIsolatedRun { return nil }
        return try load(service: legacyService, account: legacyAccount)
    }

    public static func loadOMLXKeyAsync() async throws -> String? {
        try await Task.detached(priority: .utility) { try loadOMLXKey() }.value
    }

    public static func saveOMLXKey(_ key: String) throws {
        if isDisabledForIsolatedRun { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeychainError.emptyValue }
        try set(trimmed, service: legacyService, account: legacyAccount)
    }

    public static func saveOMLXKeyAsync(_ key: String) async throws {
        try await Task.detached(priority: .utility) { try saveOMLXKey(key) }.value
    }

    private static func loadNewCredentials(for roles: Set<ModelRole>) throws -> ModelCredentials {
        var credentials = ModelCredentials()
        for role in ModelRole.allCases where roles.contains(role) {
            credentials[role] = try load(service: service, account: role.rawValue) ?? ""
        }
        return credentials
    }

    private static func replaceInaccessibleModelCredentials(
        _ credentials: ModelCredentials,
        for roles: Set<ModelRole>
    ) throws {
        if isDisabledForIsolatedRun { return }
        guard !roles.isEmpty else { return }
        try replaceCredentialsForMigration(credentials, roles: roles) { role, value in
            try replaceForMigration(
                value,
                service: service,
                account: role.rawValue,
                prompt: "Media Memory 需要迁移旧版本保存的模型凭据。"
            )
        }
    }

    static func replaceCredentialsForMigration(
        _ credentials: ModelCredentials,
        roles: Set<ModelRole>,
        replaceRole: (ModelRole, String) throws -> Void
    ) throws {
        var completedAccounts: [String] = []
        for role in ModelRole.allCases where roles.contains(role) {
            do {
                try replaceRole(role, credentials[role])
                completedAccounts.append(role.rawValue)
            } catch {
                throw KeychainError.migrationPartiallyCompleted(
                    completedAccounts: completedAccounts,
                    failedAccount: role.rawValue,
                    detail: error.localizedDescription
                )
            }
        }
    }

    private static var isDisabledForIsolatedRun: Bool {
        ProcessInfo.processInfo.environment["MEDIA_MEMORY_DISABLE_KEYCHAIN"] == "1"
    }

    private static func load(service: String, account: String) throws -> String? {
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
            throw KeychainError(status: status)
        }
        return value
    }

    private static func set(_ value: String, service: String, account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if trimmed.isEmpty {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insertion = base
            attributes.forEach { insertion[$0.key] = $0.value }
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError(status: updateStatus)
        }
    }

    private static func replaceForMigration(
        _ value: String,
        service: String,
        account: String,
        prompt: String
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let context = LAContext()
        context.localizedReason = prompt
        var authorizedDeletion = base
        authorizedDeletion[kSecUseAuthenticationContext as String] = context
        let deleteStatus = SecItemDelete(authorizedDeletion as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError.migrationRequiresManualRemoval(
                account: account,
                status: deleteStatus
            )
        }
        guard !trimmed.isEmpty else { return }

        var insertion = base
        insertion[kSecValueData as String] = Data(trimmed.utf8)
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }
}

public enum KeychainError: Error, LocalizedError, Sendable {
    case emptyValue
    case status(OSStatus)
    case migrationRequiresManualRemoval(account: String, status: OSStatus)
    case migrationPartiallyCompleted(
        completedAccounts: [String],
        failedAccount: String,
        detail: String
    )

    init(status: OSStatus) { self = .status(status) }

    public var isAccessDenied: Bool {
        switch self {
        case let .status(status):
            status == errSecAuthFailed || status == errSecInteractionNotAllowed
        case .emptyValue, .migrationRequiresManualRemoval, .migrationPartiallyCompleted:
            false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .emptyValue:
            "API key 不能为空。"
        case let .status(status):
            "无法访问钥匙串（错误 \(status)）。"
        case let .migrationRequiresManualRemoval(account, status):
            "无法迁移旧签名保存的钥匙串项目 \(account)（错误 \(status)）。可再次保存并批准系统请求；若仍失败，请打开“钥匙串访问”，删除服务 MediaMemory.ModelService 下同名项目，再返回模型设置重新保存。"
        case let .migrationPartiallyCompleted(completedAccounts, failedAccount, detail):
            if completedAccounts.isEmpty {
                "钥匙串迁移在项目 \(failedAccount) 失败：\(detail) 可再次保存重试。"
            } else {
                "已迁移钥匙串项目 \(completedAccounts.joined(separator: ", "))，但项目 \(failedAccount) 失败：\(detail) 可再次保存；已完成项目会安全重建。"
            }
        }
    }
}
