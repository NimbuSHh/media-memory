import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ModelCapabilityTestReport: Equatable, Sendable {
    public let role: ModelRole
    public let detail: String

    public init(role: ModelRole, detail: String) {
        self.role = role
        self.detail = detail
    }
}

/// Executes a minimal real inference against one draft configuration. Fixtures
/// are generated locally and contain no media-library data.
public enum ModelCapabilityTester {
    public static func test(
        role: ModelRole,
        configuration: ModelConfiguration,
        credentials: ModelCredentials,
        workRoot: URL
    ) async throws -> ModelCapabilityTestReport {
        try configuration.validate(role: role)
        let directory = workRoot
            .standardizedFileURL
            .appending(path: "ModelTests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        return try await AsyncTimeout.run(
            for: .seconds(360),
            operationName: "\(role.displayName)测试"
        ) {
            switch role {
            case .asr:
                return try await testASR(
                    configuration: configuration,
                    credentials: credentials,
                    directory: directory
                )
            case .aligner:
                return try await testAligner(
                    configuration: configuration,
                    credentials: credentials,
                    workRoot: workRoot,
                    directory: directory
                )
            case .embedding:
                return try await testEmbedding(
                    configuration: configuration,
                    credentials: credentials,
                    workRoot: workRoot,
                    directory: directory
                )
            case .description:
                return try await testDescription(
                    configuration: configuration,
                    credentials: credentials,
                    directory: directory
                )
            }
        }
    }

    private static func testASR(
        configuration: ModelConfiguration,
        credentials: ModelCredentials,
        directory: URL
    ) async throws -> ModelCapabilityTestReport {
        let audioURL = directory.appending(path: "test.wav")
        try writeTestWAV(to: audioURL)
        guard let endpointURL = configuration.asr.endpointURL else {
            throw ModelConfigurationError.invalidEndpoint(.asr)
        }
        let result = try await HTTPModelClient().transcribe(
            endpointURL: endpointURL,
            apiKey: credentials.asr,
            audioURL: audioURL,
            modelID: configuration.asr.modelID
        )
        return ModelCapabilityTestReport(
            role: .asr,
            detail: "请求成功，返回 \(result.text.count) 个字符"
        )
    }

    private static func testAligner(
        configuration: ModelConfiguration,
        credentials: ModelCredentials,
        workRoot: URL,
        directory: URL
    ) async throws -> ModelCapabilityTestReport {
        let audioURL = directory.appending(path: "test.wav")
        try writeTestWAV(to: audioURL)
        let items: [AlignedToken]
        switch configuration.aligner.transport {
        case .localWorker:
            let worker = try makeWorker(configuration: configuration, workRoot: workRoot)
            do {
                try await worker.ping()
                items = try await worker.align(
                    audioURL: audioURL,
                    text: "Media Memory test",
                    language: "English"
                )
                await worker.stop()
            } catch {
                await worker.stop()
                throw error
            }
        case .mediaMemoryAlignment:
            guard let endpointURL = configuration.aligner.endpointURL else {
                throw ModelConfigurationError.invalidEndpoint(.aligner)
            }
            items = try await HTTPModelClient().align(
                endpointURL: endpointURL,
                apiKey: credentials.aligner,
                audioURL: audioURL,
                text: "Media Memory test",
                language: "English",
                modelID: configuration.aligner.modelID
            )
        default:
            throw ModelConfigurationError.unsupportedTransport(
                .aligner,
                configuration.aligner.transport
            )
        }
        guard items.allSatisfy({ $0.startMS >= 0 && $0.endMS >= $0.startMS }) else {
            throw ModelServiceError.invalidModelOutput("时间戳顺序无效")
        }
        return ModelCapabilityTestReport(role: .aligner, detail: "请求成功，返回 \(items.count) 个时间项")
    }

    private static func testEmbedding(
        configuration: ModelConfiguration,
        credentials: ModelCredentials,
        workRoot: URL,
        directory: URL
    ) async throws -> ModelCapabilityTestReport {
        let imageURL = directory.appending(path: "test.png")
        try writeTestPNG(to: imageURL)
        let vector: EmbeddingVector
        switch configuration.embedding.transport {
        case .localWorker:
            let worker = try makeWorker(configuration: configuration, workRoot: workRoot)
            do {
                try await worker.ping()
                vector = try await worker.embed(
                    text: "a blue square",
                    imageURLs: [imageURL],
                    instruction: "Represent this test image and text for retrieval."
                )
                await worker.stop()
            } catch {
                await worker.stop()
                throw error
            }
        case .mediaMemoryEmbedding:
            guard let endpointURL = configuration.embedding.endpointURL else {
                throw ModelConfigurationError.invalidEndpoint(.embedding)
            }
            vector = try await HTTPModelClient().embed(
                endpointURL: endpointURL,
                apiKey: credentials.embedding,
                text: "a blue square",
                imageURLs: [imageURL],
                instruction: "Represent this test image and text for retrieval.",
                modelID: configuration.embedding.modelID
            )
        default:
            throw ModelConfigurationError.unsupportedTransport(
                .embedding,
                configuration.embedding.transport
            )
        }
        guard vector.dimension > 0 else {
            throw ModelServiceError.invalidModelOutput("向量为空")
        }
        return ModelCapabilityTestReport(role: .embedding, detail: "请求成功，向量维度 \(vector.dimension)")
    }

    private static func testDescription(
        configuration: ModelConfiguration,
        credentials: ModelCredentials,
        directory: URL
    ) async throws -> ModelCapabilityTestReport {
        let imageURL = directory.appending(path: "test.png")
        try writeTestPNG(to: imageURL)
        guard let endpointURL = configuration.description.endpointURL else {
            throw ModelConfigurationError.invalidEndpoint(.description)
        }
        let result = try await HTTPModelClient().describeSegment(
            endpointURL: endpointURL,
            apiKey: credentials.description,
            images: [TimedImageInput(timeMS: 0, url: imageURL)],
            evidenceText: "没有用户数据；这是应用生成的连通性测试图片。",
            modelID: configuration.description.modelID
        )
        guard !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelServiceError.invalidModelOutput("summary 为空")
        }
        return ModelCapabilityTestReport(role: .description, detail: "请求成功，结构化描述有效")
    }

    private static func makeWorker(
        configuration: ModelConfiguration,
        workRoot: URL
    ) throws -> MLXWorker {
        guard let paths = configuration.localWorker else {
            throw ModelConfigurationError.missingLocalWorker
        }
        return try MLXWorker(
            configuration: .init(
                forcedAlignerModelID: configuration.aligner.modelID,
                embeddingModelID: configuration.embedding.modelID,
                pythonLauncherPath: paths.pythonLauncherPath,
                modelRootPath: paths.modelRootPath
            ),
            workRoot: workRoot
        )
    }

    private static func writeTestWAV(to url: URL) throws {
        let sampleRate: UInt32 = 16_000
        let sampleCount = Int(sampleRate / 2)
        var pcm = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let envelope = 1 - Double(index) / Double(sampleCount)
            let sample = sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate))
            var value = Int16(sample * envelope * 8_000).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }

        var wav = Data("RIFF".utf8)
        append(UInt32(36 + pcm.count), to: &wav)
        wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &wav)
        append(UInt16(1), to: &wav)
        append(UInt16(1), to: &wav)
        append(sampleRate, to: &wav)
        append(sampleRate * 2, to: &wav)
        append(UInt16(2), to: &wav)
        append(UInt16(16), to: &wav)
        wav.append(Data("data".utf8))
        append(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        try wav.write(to: url, options: .atomic)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func writeTestPNG(to url: URL) throws {
        let width = 96
        let height = 96
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ModelServiceError.invalidModelOutput("无法生成测试图片")
        }
        context.setFillColor(CGColor(red: 0.08, green: 0.35, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 28, y: 28, width: 40, height: 40))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else {
            throw ModelServiceError.invalidModelOutput("无法生成测试图片")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ModelServiceError.invalidModelOutput("无法写入测试图片")
        }
    }
}
