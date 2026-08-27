import Foundation

public struct StartupModelConfiguration: Sendable {
    public let configuration: ModelConfiguration
    public let canAdoptLegacyModelIdentities: Bool
    public let authenticationMigrationRoles: Set<ModelRole>
}

public enum ModelConfigurationStore {
    public static func load() throws -> ModelConfiguration {
        try loadForStartup().configuration
    }

    /// Loads the configuration together with the provenance needed by the
    /// one-time database identity migration. A schema-2 file may have changed
    /// endpoint while keeping the same model name, so it is never safe to infer
    /// that bare legacy IDs came from its current endpoint.
    public static func loadForStartup() throws -> StartupModelConfiguration {
        let url = try ApplicationPaths.modelConfigurationURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            // With no saved settings, an existing database can only have used
            // the bundled legacy defaults. A new installation has no rows, so
            // allowing adoption is also a harmless no-op.
            return StartupModelConfiguration(
                configuration: try ModelConfiguration.loadDefault(),
                canAdoptLegacyModelIdentities: true,
                authenticationMigrationRoles: []
            )
        }
        return try loadForStartup(from: url)
    }

    static func loadForStartup(from url: URL) throws -> StartupModelConfiguration {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let dictionary = object as? [String: Any]
        let sourceSchemaVersion = dictionary?["schemaVersion"] as? Int ?? 1
        let configuration = try JSONDecoder().decode(ModelConfiguration.self, from: data)
        try configuration.validate()
        let authenticationMigrationRoles = sourceSchemaVersion < 3
            ? Set(ModelRole.allCases.filter {
                configuration.endpoint(for: $0).transport.requiresEndpoint
            })
            : []
        return StartupModelConfiguration(
            configuration: configuration,
            canAdoptLegacyModelIdentities: sourceSchemaVersion < 2,
            authenticationMigrationRoles: authenticationMigrationRoles
        )
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
