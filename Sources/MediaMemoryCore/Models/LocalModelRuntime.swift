import Foundation

/// Provider-neutral model execution. Each capability is serialized in the same
/// lanes as before, while its adapter can be either HTTP or the bundled local
/// Worker. Localhost and remote HTTP services are intentionally indistinguishable.
public actor ModelRuntime {
    private let configuration: ModelConfiguration
    private let credentials: ModelCredentials
    private let client: HTTPModelClient
    private let worker: MLXWorker?

    private let lightGate = AsyncOperationGate()
    private let heavyGate = AsyncOperationGate()

    public init(
        configuration: ModelConfiguration,
        credentials: ModelCredentials,
        workRoot: URL
    ) throws {
        try configuration.validate()
        self.configuration = configuration
        self.credentials = credentials
        client = HTTPModelClient()
        if configuration.usesLocalWorker {
            guard let paths = configuration.localWorker else {
                throw ModelConfigurationError.missingLocalWorker
            }
            worker = try MLXWorker(
                configuration: .init(
                    forcedAlignerModelID: configuration.aligner.modelID,
                    embeddingModelID: configuration.embedding.modelID,
                    pythonLauncherPath: paths.pythonLauncherPath,
                    modelRootPath: paths.modelRootPath
                ),
                workRoot: workRoot
            )
        } else {
            worker = nil
        }
    }

    public init(
        configuration: ModelConfiguration,
        apiKey: String,
        workRoot: URL
    ) throws {
        try self.init(
            configuration: configuration,
            credentials: ModelCredentials(asr: apiKey, description: apiKey),
            workRoot: workRoot
        )
    }

    public func transcribe(audioURL: URL) async throws -> ModelTranscription {
        try await lightGate.acquire(priority: .background)
        do {
            guard configuration.asr.transport == .openAITranscription,
                  let endpointURL = configuration.asr.endpointURL else {
                throw ModelConfigurationError.invalidEndpoint(.asr)
            }
            let value = try await client.transcribe(
                endpointURL: endpointURL,
                apiKey: credentials.asr,
                audioURL: audioURL,
                modelID: configuration.asr.modelID
            )
            await lightGate.release()
            return value
        } catch {
            await lightGate.release()
            throw error
        }
    }

    public func align(audioURL: URL, text: String, language: String) async throws -> [AlignedToken] {
        try await lightGate.acquire(priority: .background)
        do {
            let value: [AlignedToken]
            switch configuration.aligner.transport {
            case .localWorker:
                guard let worker else { throw ModelConfigurationError.missingLocalWorker }
                value = try await worker.align(audioURL: audioURL, text: text, language: language)
            case .mediaMemoryAlignment:
                guard let endpointURL = configuration.aligner.endpointURL else {
                    throw ModelConfigurationError.invalidEndpoint(.aligner)
                }
                value = try await client.align(
                    endpointURL: endpointURL,
                    apiKey: credentials.aligner,
                    audioURL: audioURL,
                    text: text,
                    language: language,
                    modelID: configuration.aligner.modelID
                )
            default:
                throw ModelConfigurationError.unsupportedTransport(
                    .aligner,
                    configuration.aligner.transport
                )
            }
            await lightGate.release()
            return value
        } catch {
            await lightGate.release()
            throw error
        }
    }

    public func embed(
        text: String,
        imageURLs: [URL] = [],
        instruction: String
    ) async throws -> EmbeddingVector {
        try await embed(
            text: text,
            imageURLs: imageURLs,
            instruction: instruction,
            priority: .background,
            cancellationBehavior: .terminateProcess
        )
    }

    public func embedQuery(
        text: String,
        instruction: String
    ) async throws -> EmbeddingVector {
        try await embed(
            text: text,
            imageURLs: [],
            instruction: instruction,
            priority: .foreground,
            cancellationBehavior: .preserveProcess
        )
    }

    private func embed(
        text: String,
        imageURLs: [URL],
        instruction: String,
        priority: AsyncOperationPriority,
        cancellationBehavior: MLXWorkerCancellationBehavior
    ) async throws -> EmbeddingVector {
        try await lightGate.acquire(priority: priority)
        do {
            let value: EmbeddingVector
            switch configuration.embedding.transport {
            case .localWorker:
                guard let worker else { throw ModelConfigurationError.missingLocalWorker }
                value = try await worker.embed(
                    text: text,
                    imageURLs: imageURLs,
                    instruction: instruction,
                    cancellationBehavior: cancellationBehavior
                )
            case .mediaMemoryEmbedding:
                guard let endpointURL = configuration.embedding.endpointURL else {
                    throw ModelConfigurationError.invalidEndpoint(.embedding)
                }
                value = try await client.embed(
                    endpointURL: endpointURL,
                    apiKey: credentials.embedding,
                    text: text,
                    imageURLs: imageURLs,
                    instruction: instruction,
                    modelID: configuration.embedding.modelID
                )
            default:
                throw ModelConfigurationError.unsupportedTransport(
                    .embedding,
                    configuration.embedding.transport
                )
            }
            await lightGate.release()
            return value
        } catch {
            await lightGate.release()
            throw error
        }
    }

    public func describe(
        kind: MediaKind = .video,
        images: [TimedImageInput],
        evidenceText: String
    ) async throws -> SegmentDescription {
        try await heavyGate.acquire(priority: .background)
        do {
            guard configuration.description.transport == .openAIChatCompletion,
                  let endpointURL = configuration.description.endpointURL else {
                throw ModelConfigurationError.invalidEndpoint(.description)
            }
            let value = try await client.describeSegment(
                endpointURL: endpointURL,
                apiKey: credentials.description,
                kind: kind,
                images: images,
                evidenceText: evidenceText,
                modelID: configuration.description.modelID
            )
            await heavyGate.release()
            return value
        } catch {
            await heavyGate.release()
            throw error
        }
    }

    public func stopDirectModels() async {
        do {
            try await lightGate.acquire(priority: .background)
        } catch {
            return
        }
        if let worker { await worker.stop() }
        await lightGate.release()
    }
}

/// Source compatibility for extensions and tests written against V0.
public typealias LocalModelRuntime = ModelRuntime
