import Foundation

/// 模型执行分两条车道：轻车道串行调度 ASR、强制对齐与 Embedding（小模型），
/// 重车道独立调度 Qwen3.8 描述（27B），两条车道可以同时各持有一个推理。
/// 每条车道内部仍然一次只跑一个操作。查询只在资源闸门上获得更高
/// 排队优先级；它不会取消或改变已经运行/排队的后台任务。
public actor LocalModelRuntime {
    private let configuration: ModelConfiguration
    private let client: OMLXClient
    private let worker: MLXWorker

    private let lightGate = AsyncOperationGate()
    private let heavyGate = AsyncOperationGate()

    public init(
        configuration: ModelConfiguration,
        apiKey: String,
        workRoot: URL
    ) throws {
        self.configuration = configuration
        client = OMLXClient(baseURL: configuration.omlx.baseURL, apiKey: apiKey)
        worker = try MLXWorker(configuration: configuration.worker, workRoot: workRoot)
    }

    public func transcribe(audioURL: URL) async throws -> OMLXTranscription {
        try await lightGate.acquire(priority: .background)
        do {
            let value = try await client.transcribe(
                audioURL: audioURL,
                modelID: configuration.omlx.asrModelID
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
            let value = try await worker.align(audioURL: audioURL, text: text, language: language)
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

    /// Foreground query embedding. It moves ahead of queued background model
    /// calls, but never preempts the operation that currently owns the Worker.
    /// Cancelling the query discards its result after the atomic Worker request
    /// finishes instead of terminating the shared Worker process.
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
            let value = try await worker.embed(
                text: text,
                imageURLs: imageURLs,
                instruction: instruction,
                cancellationBehavior: cancellationBehavior
            )
            await lightGate.release()
            return value
        } catch {
            await lightGate.release()
            throw error
        }
    }

    public func describe(
        images: [TimedImageInput],
        evidenceText: String
    ) async throws -> SegmentDescription {
        try await heavyGate.acquire(priority: .background)
        do {
            let value = try await client.describeSegment(
                images: images,
                evidenceText: evidenceText,
                modelID: configuration.omlx.descriptionModelID
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
        await worker.stop()
        await lightGate.release()
    }
}
