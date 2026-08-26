import Foundation
@testable import MediaMemoryCore
import XCTest

final class HTTPModelClientTests: XCTestCase {
    func testCapabilityContractsDecodeProviderNeutralResponses() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-http-model-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let audio = temporary.appending(path: "test.wav")
        let image = temporary.appending(path: "test.png")
        try Data([0, 1, 2, 3]).write(to: audio)
        try Data([4, 5, 6, 7]).write(to: image)

        let client = HTTPModelClient(session: makeSession())
        let transcription = try await client.transcribe(
            endpointURL: URL(string: "https://models.example/audio")!,
            apiKey: "",
            audioURL: audio,
            modelID: "asr"
        )
        XCTAssertEqual(transcription.text, "ok")

        let alignment = try await client.align(
            endpointURL: URL(string: "https://models.example/align")!,
            apiKey: "test-key",
            audioURL: audio,
            text: "ok",
            language: "English",
            modelID: "aligner"
        )
        XCTAssertEqual(alignment.first?.startMS, 10)

        let embedding = try await client.embed(
            endpointURL: URL(string: "https://models.example/embed")!,
            apiKey: "test-key",
            text: "query",
            imageURLs: [image],
            instruction: "retrieve",
            modelID: "embedding"
        )
        XCTAssertEqual(embedding.dimension, 3)

        let description = try await client.describeSegment(
            endpointURL: URL(string: "https://models.example/chat")!,
            apiKey: "test-key",
            images: [TimedImageInput(timeMS: 0, url: image)],
            evidenceText: "fixture",
            modelID: "vision"
        )
        XCTAssertEqual(description.summary, "blue test image")
    }

    func testHTTPErrorPreservesStatusAndUsefulBody() async throws {
        let client = HTTPModelClient(session: makeSession())
        let audio = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-http-error-\(UUID().uuidString).wav")
        try Data([0]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        do {
            _ = try await client.transcribe(
                endpointURL: URL(string: "https://models.example/unauthorized")!,
                apiKey: "wrong",
                audioURL: audio,
                modelID: "asr"
            )
            XCTFail("Expected HTTP failure")
        } catch let error as ModelServiceError {
            guard case let .httpStatus(status, message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 401)
            XCTAssertTrue(message.contains("invalid key"))
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ModelURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let status: Int
        let body: String
        switch path {
        case "/audio":
            status = request.value(forHTTPHeaderField: "Authorization") == nil ? 200 : 400
            body = #"{"text":"ok","language":"en","duration":0.5}"#
        case "/align":
            status = request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key" ? 200 : 401
            body = #"{"items":[{"text":"ok","start_ms":10,"end_ms":120}]}"#
        case "/embed":
            status = 200
            body = #"{"dimension":3,"vector":[1,0,0],"norm":1}"#
        case "/chat":
            status = 200
            body = #"{"choices":[{"message":{"content":"```json\n{\"summary\":\"blue test image\",\"visible_details\":[\"blue\"],\"uncertainty\":[]}\n```"}}]}"#
        default:
            status = 401
            body = #"{"error":"invalid key"}"#
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
