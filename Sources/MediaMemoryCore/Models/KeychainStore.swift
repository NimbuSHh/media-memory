import Foundation
import Security

public enum KeychainStore {
    private static let service = "MediaMemory.oMLX"
    private static let account = "default"

    public static func loadOMLXKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: status)
        }
        return key
    }

    public static func loadOMLXKeyAsync() async throws -> String? {
        try await Task.detached(priority: .utility) {
            try loadOMLXKey()
        }.value
    }

    public static func saveOMLXKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeychainError.emptyValue
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insertion = base
            attributes.forEach { insertion[$0.key] = $0.value }
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError(status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError(status: updateStatus)
        }
    }

    public static func saveOMLXKeyAsync(_ key: String) async throws {
        try await Task.detached(priority: .utility) {
            try saveOMLXKey(key)
        }.value
    }
}

public enum KeychainError: Error, LocalizedError, Sendable {
    case emptyValue
    case status(OSStatus)

    init(status: OSStatus) {
        self = .status(status)
    }

    public var errorDescription: String? {
        switch self {
        case .emptyValue:
            "API key 不能为空。"
        case let .status(status):
            "无法访问钥匙串（错误 \(status)）。"
        }
    }
}
