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
}

public enum KeychainStore {
    private static let service = "MediaMemory.ModelService"
    private static let legacyService = "MediaMemory.oMLX"
    private static let legacyAccount = "default"

    public static func loadModelCredentials() throws -> ModelCredentials {
        if isDisabledForIsolatedRun { return ModelCredentials() }
        var credentials = ModelCredentials()
        for role in ModelRole.allCases {
            credentials[role] = try load(service: service, account: role.rawValue) ?? ""
        }

        // Schema 1 used one oMLX key for both HTTP capabilities. Read it as a
        // fallback without rewriting Keychain during app startup.
        if credentials.asr.isEmpty || credentials.description.isEmpty,
           let legacy = try load(service: legacyService, account: legacyAccount) {
            if credentials.asr.isEmpty { credentials.asr = legacy }
            if credentials.description.isEmpty { credentials.description = legacy }
        }
        return credentials
    }

    public static func loadModelCredentialsAsync() async throws -> ModelCredentials {
        try await Task.detached(priority: .utility) {
            try loadModelCredentials()
        }.value
    }

    /// Empty keys are valid for authentication-free local services and remove
    /// any previously stored secret for that capability.
    public static func saveModelCredentials(_ credentials: ModelCredentials) throws {
        if isDisabledForIsolatedRun { return }
        let previous = try loadNewCredentials()
        do {
            for role in ModelRole.allCases {
                try set(credentials[role], service: service, account: role.rawValue)
            }
        } catch {
            for role in ModelRole.allCases {
                try? set(previous[role], service: service, account: role.rawValue)
            }
            throw error
        }
    }

    public static func saveModelCredentialsAsync(_ credentials: ModelCredentials) async throws {
        try await Task.detached(priority: .utility) {
            try saveModelCredentials(credentials)
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

    private static func loadNewCredentials() throws -> ModelCredentials {
        var credentials = ModelCredentials()
        for role in ModelRole.allCases {
            credentials[role] = try load(service: service, account: role.rawValue) ?? ""
        }
        return credentials
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
}

public enum KeychainError: Error, LocalizedError, Sendable {
    case emptyValue
    case status(OSStatus)

    init(status: OSStatus) { self = .status(status) }

    public var errorDescription: String? {
        switch self {
        case .emptyValue:
            "API key 不能为空。"
        case let .status(status):
            "无法访问钥匙串（错误 \(status)）。"
        }
    }
}
