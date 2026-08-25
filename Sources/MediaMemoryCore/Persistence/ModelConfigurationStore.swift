import Foundation

public enum ModelConfigurationStore {
    public static func load() throws -> ModelConfiguration {
        let url = try ApplicationPaths.modelConfigurationURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return try ModelConfiguration.loadDefault()
        }
        return try ModelConfiguration.load(from: url)
    }

    public static func save(_ configuration: ModelConfiguration) throws {
        let url = try ApplicationPaths.modelConfigurationURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: url, options: .atomic)
    }

    public static func saveAsync(_ configuration: ModelConfiguration) async throws {
        try await Task.detached(priority: .utility) {
            try save(configuration)
        }.value
    }
}
