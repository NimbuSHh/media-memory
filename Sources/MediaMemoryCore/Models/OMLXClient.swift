import Foundation

public struct ModelTranscription: Decodable, Equatable, Sendable {
    public let text: String
    public let language: String?
    public let duration: Double?
}

public typealias OMLXTranscription = ModelTranscription

public struct TimedImageInput: Equatable, Sendable {
    public let timeMS: Int64
    public let url: URL

    public init(timeMS: Int64, url: URL) {
        self.timeMS = timeMS
        self.url = url
    }
}

public enum ModelServiceError: Error, LocalizedError, Sendable {
    case invalidEndpoint
    case invalidResponse
    case invalidModelOutput(String)
    case httpStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "模型服务请求地址无效。"
        case .invalidResponse:
            "模型服务返回了无效响应。"
        case let .invalidModelOutput(message):
            "模型返回内容不符合接口契约：\(message)"
        case let .httpStatus(status, message):
            "模型服务请求失败（HTTP \(status)）：\(message)"
        }
    }
}

/// HTTP adapters are capability-specific and provider-neutral. Endpoint URLs
/// are complete request URLs, so a local and a remote implementation are
/// interchangeable when they implement the same request/response contract.
public actor HTTPModelClient {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 300
            configuration.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: configuration)
        }
    }

    public func transcribe(
        endpointURL: URL,
        apiKey: String,
        audioURL: URL,
        modelID: String,
        language: String? = nil
    ) async throws -> ModelTranscription {
        let boundary = "MediaMemory-\(UUID().uuidString)"
        var body = Data()
        appendField(name: "model", value: modelID, boundary: boundary, to: &body)
        if let language, !language.isEmpty {
            appendField(name: "language", value: language, boundary: boundary, to: &body)
        }
        let audio = try await Self.readFile(at: audioURL)
        appendFile(
            name: "file",
            filename: audioURL.lastPathComponent,
            mimeType: audioURL.pathExtension.lowercased() == "m4a" ? "audio/mp4" : "audio/wav",
            data: audio,
            boundary: boundary,
            to: &body
        )
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = try request(url: endpointURL, apiKey: apiKey)
        request.timeoutInterval = 300
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data = try await responseData(for: request)
        return try JSONDecoder().decode(ModelTranscription.self, from: data)
    }

    /// Media Memory alignment HTTP contract: multipart fields `model`, `text`,
    /// `language`, and `file`; response `{ "items": [{text,start_ms,end_ms}] }`.
    public func align(
        endpointURL: URL,
        apiKey: String,
        audioURL: URL,
        text: String,
        language: String,
        modelID: String
    ) async throws -> [AlignedToken] {
        let boundary = "MediaMemory-\(UUID().uuidString)"
        var body = Data()
        appendField(name: "model", value: modelID, boundary: boundary, to: &body)
        appendField(name: "text", value: text, boundary: boundary, to: &body)
        appendField(name: "language", value: language, boundary: boundary, to: &body)
        appendFile(
            name: "file",
            filename: audioURL.lastPathComponent,
            mimeType: audioURL.pathExtension.lowercased() == "m4a" ? "audio/mp4" : "audio/wav",
            data: try await Self.readFile(at: audioURL),
            boundary: boundary,
            to: &body
        )
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = try request(url: endpointURL, apiKey: apiKey)
        request.timeoutInterval = 300
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data = try await responseData(for: request)
        return try JSONDecoder().decode(AlignmentResponse.self, from: data).items
    }

    /// Media Memory multimodal embedding HTTP contract. Images are ordered data
    /// URLs; the service returns one vector plus optional dimension and norm.
    public func embed(
        endpointURL: URL,
        apiKey: String,
        text: String,
        imageURLs: [URL],
        instruction: String,
        modelID: String
    ) async throws -> EmbeddingVector {
        var images: [String] = []
        for imageURL in imageURLs {
            try Task.checkCancellation()
            let data = try await Self.readFile(at: imageURL)
            let mimeType = imageURL.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            images.append("data:\(mimeType);base64,\(data.base64EncodedString())")
        }
        let payload = EmbeddingRequest(
            model: modelID,
            input: .init(text: text, images: images, instruction: instruction)
        )
        var request = try request(url: endpointURL, apiKey: apiKey)
        request.timeoutInterval = 300
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let data = try await responseData(for: request)
        let result = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        let dimension = result.dimension ?? result.vector.count
        guard !result.vector.isEmpty,
              dimension == result.vector.count,
              result.vector.allSatisfy(\.isFinite) else {
            throw ModelServiceError.invalidModelOutput("向量为空、维度不匹配或包含非有限值")
        }
        let norm = result.norm ?? sqrt(result.vector.reduce(0) { $0 + Double($1 * $1) })
        guard norm.isFinite, norm > 0 else {
            throw ModelServiceError.invalidModelOutput("向量范数无效")
        }
        return EmbeddingVector(values: result.vector, norm: norm)
    }

    public func describeSegment(
        endpointURL: URL,
        apiKey: String,
        images: [TimedImageInput],
        evidenceText: String,
        modelID: String
    ) async throws -> SegmentDescription {
        var content: [[String: Any]] = [[
            "type": "text",
            "text": """
            以下图片按源视频时间顺序排列，是你唯一的视觉输入。
            你没有音频输入：禁止描述、推测或虚构任何声音、语音或音乐内容。
            ASR/OCR 证据如下（语音与画面文字以证据为准，描述中不要罗列文字清单）：
            \(evidenceText)
            只输出符合约定 schema 的 JSON。summary 组织片段整体叙述；
            visible_details 逐条描述可观察事实；无法确认的内容写入 uncertainty。
            """
        ]]
        for image in images {
            try Task.checkCancellation()
            let data = try await Self.readFile(at: image.url)
            let mimeType = image.url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            content.append([
                "type": "text",
                "text": String(format: "源视频时间 %.3f 秒：", Double(image.timeMS) / 1_000)
            ])
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:\(mimeType);base64,\(data.base64EncodedString())"]
            ])
        }

        let stringArray: [String: Any] = ["type": "array", "items": ["type": "string"]]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "visible_details": stringArray,
                "uncertainty": stringArray
            ],
            "required": ["summary", "visible_details", "uncertainty"],
            "additionalProperties": false
        ]
        let payload: [String: Any] = [
            "model": modelID,
            "messages": [
                [
                    "role": "system",
                    "content": """
                    你是视频片段的视觉描述器，只能依据给定关键帧与 ASR/OCR 证据
                    描述可观察事实。不要猜测身份、关系、地点、意图、情绪或声音。
                    """
                ],
                ["role": "user", "content": content]
            ],
            "temperature": 0,
            "max_tokens": 800,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "segment_evidence_description",
                    "strict": true,
                    "schema": schema
                ]
            ]
        ]
        var request = try request(url: endpointURL, apiKey: apiKey)
        request.timeoutInterval = 600
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data = try await responseData(for: request)

        let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let contentText = completion.choices.first?.message.content else {
            throw ModelServiceError.invalidModelOutput("响应中没有文本内容")
        }
        return try decodeDescription(from: contentText)
    }

    private func request(url: URL, apiKey: String) throws -> URLRequest {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw ModelServiceError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data.prefix(1_000), encoding: .utf8) ?? "无响应正文"
            throw ModelServiceError.httpStatus(http.statusCode, message)
        }
        return data
    }

    private func decodeDescription(from content: String) throws -> SegmentDescription {
        let candidates = [content, Self.extractJSONObject(from: content)].compactMap { $0 }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let value = try? decoder.decode(SegmentDescription.self, from: data) {
                return value
            }
        }
        throw ModelServiceError.invalidModelOutput("无法解析结构化描述 JSON")
    }

    private nonisolated static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else {
            return nil
        }
        return String(text[start...end])
    }

    private nonisolated static func readFile(at url: URL) async throws -> Data {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func appendField(
        name: String,
        value: String,
        boundary: String,
        to data: inout Data
    ) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        data.append(Data("\(value)\r\n".utf8))
    }

    private func appendFile(
        name: String,
        filename: String,
        mimeType: String,
        data fileData: Data,
        boundary: String,
        to data: inout Data
    ) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        data.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        data.append(fileData)
        data.append(Data("\r\n".utf8))
    }
}

private struct AlignmentResponse: Decodable { let items: [AlignedToken] }

private struct EmbeddingRequest: Encodable {
    struct Input: Encodable {
        let text: String
        let images: [String]
        let instruction: String
    }
    let model: String
    let input: Input
}

private struct EmbeddingResponse: Decodable {
    let dimension: Int?
    let vector: [Float]
    let norm: Double?
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}

/// V0 source-compatibility wrapper. Product code uses full capability URLs via
/// `HTTPModelClient`; this type no longer implies that oMLX is required.
public actor OMLXClient {
    private let baseURL: URL
    private let apiKey: String
    private let client: HTTPModelClient

    public init(baseURL: URL, apiKey: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        client = HTTPModelClient(session: session)
    }

    public func transcribe(
        audioURL: URL,
        modelID: String,
        language: String? = nil
    ) async throws -> ModelTranscription {
        try await client.transcribe(
            endpointURL: baseURL.appending(path: "audio/transcriptions"),
            apiKey: apiKey,
            audioURL: audioURL,
            modelID: modelID,
            language: language
        )
    }

    public func describeSegment(
        images: [TimedImageInput],
        evidenceText: String,
        modelID: String
    ) async throws -> SegmentDescription {
        try await client.describeSegment(
            endpointURL: baseURL.appending(path: "chat/completions"),
            apiKey: apiKey,
            images: images,
            evidenceText: evidenceText,
            modelID: modelID
        )
    }
}
