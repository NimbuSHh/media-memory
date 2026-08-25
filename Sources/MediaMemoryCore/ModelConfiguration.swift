import Foundation

public struct ModelConfiguration: Codable, Equatable, Sendable {
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

    public let schemaVersion: Int
    public let omlx: OMLX
    public let worker: Worker

    public init(schemaVersion: Int, omlx: OMLX, worker: Worker) {
        self.schemaVersion = schemaVersion
        self.omlx = omlx
        self.worker = worker
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
        return try JSONDecoder().decode(ModelConfiguration.self, from: data)
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

    /// SwiftPM's generated accessor looks beside the executable, while a
    /// correctly signed macOS app must seal resources under Contents/Resources.
    /// Prefer the packaged location and retain Bundle.module for tests/builds.
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
}

extension ModelConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingBundledConfiguration:
            "应用内缺少默认模型配置。"
        case .missingWorkerScript:
            "应用内缺少 MLX Worker。"
        }
    }
}
