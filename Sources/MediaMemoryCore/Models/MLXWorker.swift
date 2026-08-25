import Foundation
import Darwin

public struct AlignedToken: Codable, Equatable, Sendable {
    public let text: String
    public let startMS: Int64
    public let endMS: Int64

    enum CodingKeys: String, CodingKey {
        case text
        case startMS = "start_ms"
        case endMS = "end_ms"
    }
}

public struct EmbeddingVector: Equatable, Sendable {
    public let values: [Float]
    public let norm: Double

    public var dimension: Int { values.count }
}

public enum MLXWorkerError: Error, LocalizedError, Sendable {
    case missingExecutable(String)
    case missingModel(String)
    case terminated
    case busy
    case timedOut
    case invalidResponse
    case invalidResponseDetails(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .missingExecutable(path):
            "找不到 oMLX Worker 运行入口：\(path)"
        case let .missingModel(path):
            "找不到已部署模型：\(path)"
        case .terminated:
            "MLX Worker 已意外退出。"
        case .busy:
            "MLX Worker 正在处理另一个请求。"
        case .timedOut:
            "MLX Worker 处理超时，已自动终止；可以直接重试。"
        case .invalidResponse:
            "MLX Worker 返回了无效数据。"
        case let .invalidResponseDetails(message):
            "MLX Worker 返回数据无法解析：\(message)"
        case let .operationFailed(message):
            "MLX Worker 处理失败：\(message)"
        }
    }
}

enum MLXWorkerCancellationBehavior: Equatable, Sendable {
    case terminateProcess
    case preserveProcess
}

public actor MLXWorker {
    private let configuration: ModelConfiguration.Worker
    private let workRoot: URL
    private let modelRoot: URL
    private let executableURL: URL
    private let scriptURL: URL
    private let operationTimeout: Duration

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = Data()
    private var nextOutputSequence = 0
    private var bufferedOutputChunks: [Int: Data] = [:]
    private var processGeneration = UUID()
    private var pendingResponse: PendingResponse?

    private struct PendingResponse {
        let id: UUID
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTask: Task<Void, Never>
    }

    public init(
        configuration: ModelConfiguration.Worker,
        workRoot: URL,
        operationTimeout: Duration = .seconds(300)
    ) throws {
        self.configuration = configuration
        self.workRoot = workRoot.standardizedFileURL
        self.operationTimeout = operationTimeout
        executableURL = URL(
            fileURLWithPath: NSString(string: configuration.pythonLauncherPath).expandingTildeInPath
        )
        modelRoot = URL(
            fileURLWithPath: NSString(string: configuration.modelRootPath).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
        scriptURL = try ModelConfiguration.workerScriptURL()

        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw MLXWorkerError.missingExecutable(executableURL.path)
        }
    }

    deinit {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
        if let process { ChildProcessTerminator.terminate(process) }
    }

    public func ping() async throws {
        let result: StatusResult = try await send(StatusRequest(operation: "ping"))
        guard result.status == "ready" else {
            throw MLXWorkerError.invalidResponse
        }
    }

    public func align(
        audioURL: URL,
        text: String,
        language: String
    ) async throws -> [AlignedToken] {
        let model = try modelURL(for: configuration.forcedAlignerModelID)
        let result: AlignResult = try await send(
            AlignRequest(
                operation: "align",
                modelPath: model.path,
                audioPath: audioURL.standardizedFileURL.path,
                text: text,
                language: language
            )
        )
        return result.items
    }

    public func embed(
        text: String,
        imageURLs: [URL],
        instruction: String
    ) async throws -> EmbeddingVector {
        try await embed(
            text: text,
            imageURLs: imageURLs,
            instruction: instruction,
            cancellationBehavior: .terminateProcess
        )
    }

    func embed(
        text: String,
        imageURLs: [URL],
        instruction: String,
        cancellationBehavior: MLXWorkerCancellationBehavior
    ) async throws -> EmbeddingVector {
        let model = try modelURL(for: configuration.embeddingModelID)
        let result: EmbedResult = try await send(
            EmbedRequest(
                operation: "embed",
                modelPath: model.path,
                imagePaths: imageURLs.map { $0.standardizedFileURL.path },
                text: text,
                instruction: instruction
            ),
            cancellationBehavior: cancellationBehavior
        )
        guard result.dimension == result.vector.count else {
            throw MLXWorkerError.invalidResponse
        }
        return EmbeddingVector(values: result.vector, norm: result.norm)
    }

    public func stop() {
        failPending(with: CancellationError(), terminateProcess: true)
        shutdownProcess(terminate: true)
    }

    private func modelURL(for modelID: String) throws -> URL {
        let url = modelRoot.appending(path: modelID, directoryHint: .isDirectory)
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MLXWorkerError.missingModel(url.path)
        }
        return url
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true {
            return
        }
        shutdownProcess(terminate: false)
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let generation = UUID()
        let outputSequencer = PipeReadSequencer()

        process.executableURL = executableURL
        process.arguments = [scriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["MEDIA_MEMORY_MODEL_ROOT"] = modelRoot.path
        environment["MEDIA_MEMORY_WORK_ROOT"] = workRoot.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = outputSequencer.read(from: handle)
            Task {
                await self?.receiveOutput(
                    chunk.data,
                    sequence: chunk.sequence,
                    generation: generation
                )
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.processDidTerminate(generation: generation) }
        }

        try process.run()
        self.process = process
        processGeneration = generation
        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading
        errorHandle = errorPipe.fileHandleForReading
        outputBuffer.removeAll(keepingCapacity: true)
        nextOutputSequence = 0
        bufferedOutputChunks.removeAll(keepingCapacity: true)
    }

    private func send<Request: Encodable, Result: Decodable>(
        _ request: Request,
        cancellationBehavior: MLXWorkerCancellationBehavior = .terminateProcess
    ) async throws -> Result {
        try Task.checkCancellation()
        try startIfNeeded()
        guard inputHandle != nil, outputHandle != nil else {
            throw MLXWorkerError.terminated
        }
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        let responseData = try await exchange(
            payload,
            cancellationBehavior: cancellationBehavior
        )
        try Task.checkCancellation()
        let response: WorkerEnvelope<Result>
        do {
            response = try JSONDecoder().decode(WorkerEnvelope<Result>.self, from: responseData)
        } catch {
            throw MLXWorkerError.invalidResponseDetails(error.localizedDescription)
        }
        guard response.ok else {
            throw MLXWorkerError.operationFailed(response.error ?? "未知错误")
        }
        guard let result = response.result else {
            throw MLXWorkerError.invalidResponse
        }
        return result
    }

    private func exchange(
        _ payload: Data,
        cancellationBehavior: MLXWorkerCancellationBehavior
    ) async throws -> Data {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pendingResponse == nil, let inputHandle else {
                    continuation.resume(throwing: MLXWorkerError.busy)
                    return
                }
                let timeout = operationTimeout
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.timeout(requestID: requestID)
                }
                pendingResponse = PendingResponse(
                    id: requestID,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                do {
                    try inputHandle.write(contentsOf: payload)
                } catch {
                    failPending(with: error, terminateProcess: true)
                }
            }
        } onCancel: {
            guard cancellationBehavior == .terminateProcess else { return }
            Task { await self.cancel(requestID: requestID) }
        }
    }

    private func receiveOutput(_ data: Data, sequence: Int, generation: UUID) {
        guard generation == processGeneration else { return }
        bufferedOutputChunks[sequence] = data
        while let next = bufferedOutputChunks.removeValue(forKey: nextOutputSequence) {
            nextOutputSequence += 1
            receiveOrderedOutput(next)
            if generation != processGeneration { return }
        }
    }

    private func receiveOrderedOutput(_ data: Data) {
        guard !data.isEmpty else {
            failPending(with: MLXWorkerError.terminated, terminateProcess: false)
            shutdownProcess(terminate: false)
            return
        }
        outputBuffer.append(data)
        guard let newline = outputBuffer.firstIndex(of: 0x0A) else { return }
        let line = Data(outputBuffer[..<newline])
        outputBuffer.removeSubrange(...newline)
        guard let pending = pendingResponse else { return }
        pendingResponse = nil
        pending.timeoutTask.cancel()
        pending.continuation.resume(returning: line)
    }

    private func processDidTerminate(generation: UUID) {
        guard generation == processGeneration else { return }
        failPending(with: MLXWorkerError.terminated, terminateProcess: false)
        shutdownProcess(terminate: false)
    }

    private func cancel(requestID: UUID) {
        guard pendingResponse?.id == requestID else { return }
        failPending(with: CancellationError(), terminateProcess: true)
    }

    private func timeout(requestID: UUID) {
        guard pendingResponse?.id == requestID else { return }
        failPending(with: MLXWorkerError.timedOut, terminateProcess: true)
    }

    private func failPending(with error: Error, terminateProcess: Bool) {
        guard let pending = pendingResponse else {
            if terminateProcess { shutdownProcess(terminate: true) }
            return
        }
        pendingResponse = nil
        pending.timeoutTask.cancel()
        if terminateProcess { shutdownProcess(terminate: true) }
        pending.continuation.resume(throwing: error)
    }

    private func shutdownProcess(terminate: Bool) {
        let oldProcess = process
        process = nil
        oldProcess?.terminationHandler = nil
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        outputBuffer.removeAll(keepingCapacity: false)
        nextOutputSequence = 0
        bufferedOutputChunks.removeAll(keepingCapacity: false)
        processGeneration = UUID()
        if terminate, oldProcess?.isRunning == true {
            if let oldProcess { ChildProcessTerminator.terminate(oldProcess) }
        }
    }
}

private final class PipeReadSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequence = 0

    func read(from handle: FileHandle) -> (sequence: Int, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let sequence = nextSequence
        nextSequence += 1
        return (sequence, handle.availableData)
    }
}

private final class SendableProcessReference: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private enum ChildProcessTerminator {
    static func terminate(_ process: Process) {
        process.terminate()
        let reference = SendableProcessReference(process)
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1))
            guard reference.process.isRunning else { return }
            Darwin.kill(reference.process.processIdentifier, SIGKILL)
        }
    }
}

private struct WorkerEnvelope<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let error: String?
}

private struct StatusRequest: Encodable { let operation: String }
private struct StatusResult: Decodable { let status: String }

private struct AlignRequest: Encodable {
    let operation: String
    let modelPath: String
    let audioPath: String
    let text: String
    let language: String

    enum CodingKeys: String, CodingKey {
        case operation
        case modelPath = "model_path"
        case audioPath = "audio_path"
        case text
        case language
    }
}

private struct AlignResult: Decodable { let items: [AlignedToken] }

private struct EmbedRequest: Encodable {
    let operation: String
    let modelPath: String
    let imagePaths: [String]
    let text: String
    let instruction: String

    enum CodingKeys: String, CodingKey {
        case operation
        case modelPath = "model_path"
        case imagePaths = "image_paths"
        case text
        case instruction
    }
}

private struct EmbedResult: Decodable {
    let dimension: Int
    let norm: Double
    let vector: [Float]
}
