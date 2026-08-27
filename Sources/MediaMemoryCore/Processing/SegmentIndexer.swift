import CryptoKit
import Foundation

public struct IndexingEvent: Equatable, Sendable {
    public let assetID: String
    public let assetName: String
    public let segmentOrdinal: Int
    public let stage: String
    public let progress: IndexingProgress
}

public struct IndexRunSummary: Equatable, Sendable {
    public let succeeded: Int
    public let failed: Int
}

public enum SegmentIndexerError: Error, LocalizedError, Sendable {
    case sourceChanged
    case noFrames

    public var errorDescription: String? {
        switch self {
        case .sourceChanged:
            "源视频在处理期间发生变化。"
        case .noFrames:
            "没有从片段中取得可用画面。"
        }
    }
}

public actor SegmentIndexer {
    public typealias EventHandler = @Sendable (IndexingEvent) async -> Void

    public static let runtimeVersion = "media-memory-worker-v1"
    public static let frameSelectionVersion = "sample-1fps-phash4-representative8-v1"

    private let database: MediaDatabase
    private let configuration: ModelConfiguration
    private let runtime: LocalModelRuntime
    private let sourceCache: LocalSourceCache
    private let workRoot: URL
    private let inputVersion: String

    public init(
        database: MediaDatabase,
        configuration: ModelConfiguration,
        runtime: LocalModelRuntime,
        sourceCache: LocalSourceCache,
        workRoot: URL
    ) {
        self.database = database
        self.configuration = configuration
        self.runtime = runtime
        self.sourceCache = sourceCache
        self.workRoot = workRoot.standardizedFileURL
        inputVersion = Self.inputVersion(for: configuration)
    }

    public static func inputVersion(for configuration: ModelConfiguration) -> String {
        let source = [
            "segment-v1",
            frameSelectionVersion,
            "vision-ocr-v1",
            configuration.asr.derivationID,
            configuration.aligner.derivationID,
            configuration.embedding.derivationID
        ].joined(separator: "|")
        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Schema-1 persisted the three bare model IDs in the evidence fingerprint.
    /// This is used only by the one-time database migration; normal runtime
    /// identity checks always use `inputVersion(for:)` above.
    public static func legacyInputVersion(for configuration: ModelConfiguration) -> String {
        let source = [
            "segment-v1",
            frameSelectionVersion,
            "vision-ocr-v1",
            configuration.asr.modelID,
            configuration.aligner.modelID,
            configuration.embedding.modelID
        ].joined(separator: "|")
        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func prepareQueue() async throws -> IndexingProgress {
        let activated = try await database.activateAllReadySegmentations()
        if activated { await cleanupPrunedFrames() }
        try await database.reconcileIndexJobs(
            embeddingModelID: configuration.embedding.derivationID,
            inputVersion: inputVersion
        )
        return try await database.indexingProgress()
    }

    public func retryFailed() async throws -> IndexingProgress {
        try await database.retryFailedJobs(kind: .indexSegment)
        return try await database.indexingProgress()
    }

    /// 仅供应用级后台协调器在启动时调用；在线补队不会回收 running。
    public func recoverInterrupted() async throws -> IndexingProgress {
        try await database.recoverInterruptedJobs(kind: .indexSegment)
        return try await prepareQueue()
    }

    public func progress() async throws -> IndexingProgress {
        try await database.indexingProgress()
    }

    public func runUntilIdle(
        onEvent: EventHandler? = nil,
        onSourceUnavailable: SourceUnavailableHandler? = nil
    ) async throws -> IndexRunSummary {
        do {
            _ = try await prepareQueue()
            var succeeded = 0
            var failed = 0

            laneLoop: while !Task.isCancelled {
                let target: SegmentIndexTarget
                let cachedAssetID = await sourceCache.cachedAssetID()
                switch try await database.claimNextIndexJob(
                    restrictToAssetID: cachedAssetID
                ) {
                case .target(let value):
                    target = value
                case .idle:
                    break laneLoop
                }
                let inputs: PreparedInputs
                do {
                    inputs = try await consumeInputs(for: target, onEvent: onEvent)
                } catch is CancellationError {
                    try await returnToQueue(target.job.claimToken)
                    throw CancellationError()
                } catch let unavailable as SourceUnavailableError {
                    // 通知必须 await：断路状态要先于车道收尾落地，否则收尾的
                    // 重启逻辑会在断路生效前把车道再拉起一次。
                    switch await resolveSourceDisposition(onSourceUnavailable, unavailable) {
                    case .park:
                        try await returnToQueue(
                            target.job.claimToken,
                            stage: "source_unavailable"
                        )
                        break laneLoop
                    case .failJob:
                        if try await fail(
                            target.job.claimToken,
                            message: unavailable.localizedDescription
                        ) {
                            failed += 1
                            await publish(target: target, stage: "failed", onEvent: onEvent)
                        }
                        continue laneLoop
                    }
                } catch MediaDatabaseDerivationError.staleClaim {
                    continue
                } catch {
                    let targetIsAvailable = try await database.isIndexTargetAvailable(
                        assetID: target.asset.id,
                        sourceFingerprint: target.asset.fingerprint
                    )
                    if !targetIsAvailable {
                        try await returnToQueue(
                            target.job.claimToken,
                            stage: "target_unavailable"
                        )
                    } else if try await fail(
                        target.job.claimToken,
                        message: error.localizedDescription
                    ) {
                        failed += 1
                        await publish(target: target, stage: "failed", onEvent: onEvent)
                    }
                    continue
                }
                // 当前片段进入模型阶段时，只预读同一视频的下一个片段，
                // 让本地提取与模型计算重叠，但不让后续视频抢跑。
                await startPrefetch()
                do {
                    try await sourceCache.withLocalURL(for: target.asset) { [self] _ in
                        try await process(target, inputs: inputs, onEvent: onEvent)
                        // Keep the asset lease through downstream enqueue so a
                        // temporarily empty job queue cannot release the source.
                        try await database.reconcileDescribeJobs()
                        await publish(target: target, stage: "complete", onEvent: onEvent)
                    }
                    succeeded += 1
                } catch is CancellationError {
                    try await returnToQueue(target.job.claimToken)
                    throw CancellationError()
                } catch let unavailable as SourceUnavailableError {
                    switch await resolveSourceDisposition(onSourceUnavailable, unavailable) {
                    case .park:
                        try await returnToQueue(
                            target.job.claimToken,
                            stage: "source_unavailable"
                        )
                        break laneLoop
                    case .failJob:
                        if try await fail(
                            target.job.claimToken,
                            message: unavailable.localizedDescription
                        ) {
                            failed += 1
                            await publish(target: target, stage: "failed", onEvent: onEvent)
                        }
                        continue laneLoop
                    }
                } catch MediaDatabaseDerivationError.missingTarget {
                    // A scan may temporarily mark an asset unavailable while this
                    // atomic commit is waiting. Keep the job pending; claim queries
                    // exclude unavailable assets until a trusted scan restores it.
                    try await returnToQueue(
                        target.job.claimToken,
                        stage: "target_unavailable"
                    )
                } catch MediaDatabaseDerivationError.staleClaim {
                    continue
                } catch {
                    if try await fail(
                        target.job.claimToken,
                        message: error.localizedDescription
                    ) {
                        failed += 1
                        await publish(target: target, stage: "failed", onEvent: onEvent)
                    }
                }
            }
            try Task.checkCancellation()
            await discardPrefetch()
            return IndexRunSummary(succeeded: succeeded, failed: failed)
        } catch {
            await discardPrefetch()
            throw error
        }
    }

    private func returnToQueue(
        _ claim: JobClaimToken,
        stage: String = "paused"
    ) async throws {
        do {
            try await database.returnIndexJobToQueue(claim: claim, stage: stage)
        } catch MediaDatabaseDerivationError.staleClaim {
            // Recovery or deletion already invalidated this execution.
        }
    }

    private func fail(_ claim: JobClaimToken, message: String) async throws -> Bool {
        do {
            try await database.failIndexJob(claim: claim, message: message)
            return true
        } catch MediaDatabaseDerivationError.staleClaim {
            // A newer attempt owns the job; the old execution cannot fail it.
            return false
        }
    }

    private struct PreparedInputs {
        let runDirectory: URL
        let sourceURL: URL
        let audioURL: URL?
        let frames: [FrameSample]
    }

    private struct PrefetchEntry {
        let jobID: String
        let assetFingerprint: String
        let directory: URL
        let task: Task<PreparedInputs, Error>
    }

    private var prefetch: PrefetchEntry?

    /// 使用预读结果（任务与指纹都匹配时），否则现场准备输入。
    private func consumeInputs(
        for target: SegmentIndexTarget,
        onEvent: EventHandler?
    ) async throws -> PreparedInputs {
        if let entry = prefetch {
            prefetch = nil
            if entry.jobID == target.job.id, entry.assetFingerprint == target.asset.fingerprint {
                do {
                    return try await entry.task.value
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: entry.directory)
                    throw CancellationError()
                } catch {
                    // 预读失败不影响正确性，退回现场提取。
                    try? FileManager.default.removeItem(at: entry.directory)
                }
            } else {
                await discardEntry(entry)
            }
        }
        return try await prepareInputs(target: target, onEvent: onEvent)
    }

    private func prepareInputs(
        target: SegmentIndexTarget,
        onEvent: EventHandler?
    ) async throws -> PreparedInputs {
        try Task.checkCancellation()
        let sourceURL = try await sourceCache.localURL(for: target.asset)
        try await sourceCache.validateLocalURL(sourceURL, for: target.asset)
        try await stage("audio", target: target, onEvent: onEvent)

        let runDirectory = workRoot
            .appending(path: "Runs", directoryHint: .isDirectory)
            .appending(path: target.job.id, directoryHint: .isDirectory)
            .appending(path: String(target.job.attemptCount), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        var audioURL: URL?
        if target.asset.audioTrackCount > 0 {
            let destination = runDirectory.appending(path: "audio.wav")
            _ = try await extractAudio(target: target, destination: destination)
            audioURL = destination
        }

        let frames = try await extractFrames(
            target: target,
            destination: runDirectory.appending(path: "frames", directoryHint: .isDirectory)
        )
        return PreparedInputs(
            runDirectory: runDirectory,
            sourceURL: sourceURL,
            audioURL: audioURL,
            frames: frames
        )
    }

    private func startPrefetch() async {
        guard prefetch == nil else { return }
        let cachedAssetID = await sourceCache.cachedAssetID()
        guard let next = try? await database.peekNextIndexJob(
            restrictToAssetID: cachedAssetID
        ) else { return }
        let directory = workRoot
            .appending(path: "Prefetch", directoryHint: .isDirectory)
            .appending(path: next.job.id, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: directory)
        prefetch = PrefetchEntry(
            jobID: next.job.id,
            assetFingerprint: next.asset.fingerprint,
            directory: directory,
            task: Task(priority: .utility) { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.prepareInputsForPrefetch(target: next, directory: directory)
            }
        )
    }

    /// 预读与现场准备共用提取逻辑，但产物放在专用目录，且不写任务阶段事件。
    private func prepareInputsForPrefetch(
        target: SegmentIndexTarget,
        directory: URL
    ) async throws -> PreparedInputs {
        try Task.checkCancellation()
        let sourceURL = try await sourceCache.localURL(for: target.asset)
        try await sourceCache.validateLocalURL(sourceURL, for: target.asset)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var audioURL: URL?
        if target.asset.audioTrackCount > 0 {
            let destination = directory.appending(path: "audio.wav")
            _ = try await extractAudio(target: target, destination: destination)
            audioURL = destination
        }
        let frames = try await extractFrames(
            target: target,
            destination: directory.appending(path: "frames", directoryHint: .isDirectory)
        )
        return PreparedInputs(
            runDirectory: directory,
            sourceURL: sourceURL,
            audioURL: audioURL,
            frames: frames
        )
    }

    private func extractAudio(
        target: SegmentIndexTarget,
        destination: URL
    ) async throws -> URL {
        try await AsyncTimeout.run(for: .seconds(120), operationName: "提取片段音频") {
            try await self.sourceCache.withLocalURL(for: target.asset) { sourceURL in
                try await AudioSegmentExtractor.extractWAV(
                    assetURL: sourceURL,
                    startMS: target.segment.startMS,
                    endMS: target.segment.endMS,
                    destinationURL: destination
                )
            }
        }
    }

    private func extractFrames(
        target: SegmentIndexTarget,
        destination: URL
    ) async throws -> [FrameSample] {
        try await AsyncTimeout.run(for: .seconds(120), operationName: "提取片段画面") {
            try await self.sourceCache.withLocalURL(for: target.asset) { sourceURL in
                try await FrameExtractor.extract(
                    assetURL: sourceURL,
                    startMS: target.segment.startMS,
                    endMS: target.segment.endMS,
                    destinationDirectory: destination
                )
            }
        }
    }

    private func discardPrefetch() async {
        if let entry = prefetch {
            prefetch = nil
            await discardEntry(entry)
        }
    }

    private func discardEntry(_ entry: PrefetchEntry) async {
        entry.task.cancel()
        _ = try? await entry.task.value
        try? FileManager.default.removeItem(at: entry.directory)
    }

    private func process(
        _ target: SegmentIndexTarget,
        inputs: PreparedInputs,
        onEvent: EventHandler?
    ) async throws {
        try Task.checkCancellation()
        defer { try? FileManager.default.removeItem(at: inputs.runDirectory) }
        let sourceURL = inputs.sourceURL

        var transcripts: [TranscriptSentenceDraft] = []
        if let audioURL = inputs.audioURL {
            try Task.checkCancellation()
            try await stage("asr", target: target, onEvent: onEvent)
            let transcription = try await runtime.transcribe(audioURL: audioURL)
            let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if let language = SentenceTiming.alignerLanguage(for: transcription.language) {
                    try Task.checkCancellation()
                    try await stage("alignment", target: target, onEvent: onEvent)
                    let tokens = try await runtime.align(
                        audioURL: audioURL,
                        text: text,
                        language: language
                    )
                    transcripts = SentenceTiming.aggregate(
                        transcript: text,
                        language: transcription.language,
                        tokens: tokens,
                        blockStartMS: target.segment.startMS,
                        blockEndMS: target.segment.endMS
                    )
                } else {
                    transcripts = SentenceTiming.aggregate(
                        transcript: text,
                        language: transcription.language,
                        tokens: [],
                        blockStartMS: target.segment.startMS,
                        blockEndMS: target.segment.endMS
                    )
                }
            }
        }

        try Task.checkCancellation()
        try await stage("frames", target: target, onEvent: onEvent)
        guard !inputs.frames.isEmpty else { throw SegmentIndexerError.noFrames }
        let representatives = FrameExtractor.representatives(from: inputs.frames)

        try Task.checkCancellation()
        try await stage("ocr", target: target, onEvent: onEvent)
        // OCR 是同步 CPU 工作：脱离本 actor 在低优先级线程执行，
        // 避免长时间占用车道执行器，也避免与界面争抢核心。
        let ocrTask = Task.detached(priority: .utility) {
            try VisionTextRecognizer.recognize(frames: inputs.frames)
        }
        let rawOCR = try await withTaskCancellationHandler {
            try await ocrTask.value
        } onCancel: {
            ocrTask.cancel()
        }
        let ocr = rawOCR.compactMap { observation -> OCRObservationDraft? in
            let start = max(target.segment.startMS, observation.startMS)
            let end = min(target.segment.endMS, observation.endMS)
            guard end > start else { return nil }
            return OCRObservationDraft(
                text: observation.text,
                confidence: observation.confidence,
                boxX: observation.boxX,
                boxY: observation.boxY,
                boxWidth: observation.boxWidth,
                boxHeight: observation.boxHeight,
                startMS: start,
                endMS: end
            )
        }

        try Task.checkCancellation()
        try await stage("embedding", target: target, onEvent: onEvent)
        let evidenceText = embeddingText(transcripts: transcripts, ocr: ocr)
        let embedding = try await runtime.embed(
            text: evidenceText,
            imageURLs: representatives.map(\.imageURL),
            instruction: "Represent this ordered video segment for semantic retrieval."
        )

        try Task.checkCancellation()
        try await sourceCache.validateLocalURL(sourceURL, for: target.asset)
        try await stage("commit", target: target, onEvent: onEvent)
        let previousFrames = try await database.segmentFrames(segmentID: target.segment.id)
        let storedFrames = try persist(
            representatives: representatives,
            target: target
        )
        let output = SegmentIndexOutput(
            sourceFingerprint: target.asset.fingerprint,
            transcripts: transcripts,
            ocr: ocr,
            frames: storedFrames,
            embedding: embedding,
            asrModelID: configuration.asr.derivationID,
            alignerModelID: configuration.aligner.derivationID,
            embeddingModelID: configuration.embedding.derivationID,
            runtimeVersion: Self.runtimeVersion
        )
        do {
            try await database.commitIndexOutput(
                claim: target.job.claimToken,
                segmentID: target.segment.id,
                output: output,
                inputVersion: inputVersion
            )
        } catch {
            removePersistedFrames(storedFrames)
            throw error
        }
        // A content-aware generation remains hidden while it is being indexed.
        // Activation is a follow-up control-plane action: an activation error
        // must never roll back or delete an already committed evidence set.
        if (try? await database.activateReadySegmentation(assetID: target.asset.id)) == true {
            await cleanupPrunedFrames()
        }
        removeObsoleteFrames(previousFrames, keeping: storedFrames)
    }

    /// Database generation activation prunes old frame rows transactionally.
    /// Reclaim their physical files in the same process instead of waiting for
    /// the next application launch. Cleanup failure never invalidates an
    /// already committed evidence generation.
    private func cleanupPrunedFrames() async {
        guard let referenced = try? await database.referencedFrameRelativePaths() else { return }
        try? ApplicationPaths.cleanupUnreferencedFrames(
            in: workRoot,
            referencedRelativePaths: referenced
        )
    }

    private func stage(
        _ value: String,
        target: SegmentIndexTarget,
        onEvent: EventHandler?
    ) async throws {
        try Task.checkCancellation()
        try await database.updateIndexJob(claim: target.job.claimToken, stage: value)
        await publish(target: target, stage: value, onEvent: onEvent)
    }

    private func publish(
        target: SegmentIndexTarget,
        stage: String,
        onEvent: EventHandler?
    ) async {
        guard let onEvent, let progress = try? await database.indexingProgress() else { return }
        await onEvent(
            IndexingEvent(
                assetID: target.asset.id,
                assetName: target.asset.filename,
                segmentOrdinal: target.segment.ordinal,
                stage: stage,
                progress: progress
            )
        )
    }

    private func embeddingText(
        transcripts: [TranscriptSentenceDraft],
        ocr: [OCRObservationDraft]
    ) -> String {
        let speech = transcripts.map(\.text).joined(separator: " ")
        let visible = ocr.map(\.text).joined(separator: " | ")
        return "Spoken content: \(speech)\nVisible text: \(visible)"
    }

    private func persist(
        representatives: [FrameSample],
        target: SegmentIndexTarget
    ) throws -> [SegmentFrameDraft] {
        let relativeDirectory = "Frames/\(target.job.id)/\(target.job.attemptCount)"
        let destinationDirectory = workRoot
            .appending(path: relativeDirectory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        do {
            return try representatives.enumerated().map { index, frame in
                let filename = String(format: "%02d-%012lld.jpg", index, frame.timeMS)
                let destination = destinationDirectory.appending(path: filename)
                try FrameExtractor.writePersistentThumbnail(
                    from: frame.imageURL,
                    to: destination
                )
                return SegmentFrameDraft(
                    timeMS: frame.timeMS,
                    relativePath: "\(relativeDirectory)/\(filename)",
                    perceptualHash: frame.perceptualHash
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationDirectory)
            throw error
        }
    }

    private func removePersistedFrames(_ frames: [SegmentFrameDraft]) {
        guard let first = frames.first else { return }
        let firstURL = workRoot.appending(path: first.relativePath)
        let directory = firstURL.deletingLastPathComponent().standardizedFileURL
        let framesRoot = workRoot.appending(path: "Frames", directoryHint: .isDirectory)
            .standardizedFileURL
        guard directory.path.hasPrefix(framesRoot.path + "/") else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func removeObsoleteFrames(
        _ previous: [SegmentFrameRecord],
        keeping current: [SegmentFrameDraft]
    ) {
        let retainedDirectories = Set(
            current.map { URL(fileURLWithPath: $0.relativePath).deletingLastPathComponent().path }
        )
        let obsoleteDirectories = Set(
            previous.map { URL(fileURLWithPath: $0.relativePath).deletingLastPathComponent().path }
        ).subtracting(retainedDirectories)
        let framesRoot = workRoot.appending(path: "Frames", directoryHint: .isDirectory)
            .standardizedFileURL
        for relativeDirectory in obsoleteDirectories {
            let directory = workRoot.appending(path: relativeDirectory).standardizedFileURL
            guard directory.path.hasPrefix(framesRoot.path + "/") else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
