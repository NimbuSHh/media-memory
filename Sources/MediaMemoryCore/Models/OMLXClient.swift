import Foundation

public struct OMLXTranscription: Decodable, Equatable, Sendable {
    public let text: String
    public let language: String?
    public let duration: Double?
}

public struct TimedImageInput: Equatable, Sendable {
    public let timeMS: Int64
    public let url: URL

    public init(timeMS: Int64, url: URL) {
        self.timeMS = timeMS
        self.url = url
    }
}

public enum OMLXClientError: Error, LocalizedError, Sendable {
    case invalidEndpoint
    case invalidResponse
    case invalidModelOutput(String)
    case httpStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "oMLX 服务地址无效。"
        case .invalidResponse:
            "oMLX 返回了无效响应。"
        case let .invalidModelOutput(message):
            "模型返回的结构不符合描述契约：\(message)"
        case let .httpStatus(status, message):
            "oMLX 请求失败（HTTP \(status)）：\(message)"
        }
    }
}

public actor OMLXClient {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    public init(baseURL: URL, apiKey: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
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
        audioURL: URL,
        modelID: String,
        language: String? = nil
    ) async throws -> OMLXTranscription {
        let endpoint = baseURL.appending(path: "audio/transcriptions")
        guard endpoint.scheme != nil else {
            throw OMLXClientError.invalidEndpoint
        }
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

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 300
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(OMLXTranscription.self, from: data)
    }

    public func describeSegment(
        images: [TimedImageInput],
        evidenceText: String,
        modelID: String
    ) async throws -> SegmentDescription {
        let endpoint = baseURL.appending(path: "chat/completions")
        guard endpoint.scheme != nil else { throw OMLXClientError.invalidEndpoint }

        var content: [[String: Any]] = [[
            "type": "text",
            "text": """
            以下图片按源视频时间顺序排列，是你唯一的视觉输入。
            你没有音频输入：禁止描述、推测或虚构任何声音、语音或音乐内容。
            ASR/OCR 证据如下（语音与画面文字以证据为准，描述中不要罗列文字清单）：
            \(evidenceText)
            summary 组织这个片段的整体叙述，可以引用证据中的信息；
            visible_details 逐条描述画面中可观察的事实（包括证据未覆盖的画面文字）；
            抽帧不能证明连续动作；无法从画面与证据确认的内容写入 uncertainty。
            """
        ]]
        for image in images {
            try Task.checkCancellation()
            let data = try await Self.readFile(at: image.url)
            let mimeType = image.url.pathExtension.lowercased() == "png"
                ? "image/png" : "image/jpeg"
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
                    你是视频片段的视觉描述器，用中文输出。你只能依据给定的关键帧与
                    ASR/OCR 证据描述可观察的事实。不要猜测人物身份、关系、地点、
                    意图或情绪；不要输出任何语音或声音内容。
                    """
                ],
                ["role": "user", "content": content]
            ],
            "temperature": 0,
            "max_tokens": 800,
            "chat_template_kwargs": ["enable_thinking": false],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "segment_evidence_description",
                    "strict": true,
                    "schema": schema
                ]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 600
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let contentText = completion.choices.first?.message.content,
              let contentData = contentText.data(using: .utf8) else {
            throw OMLXClientError.invalidModelOutput("响应中没有 JSON 内容")
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(SegmentDescription.self, from: contentData)
        } catch {
            throw OMLXClientError.invalidModelOutput(error.localizedDescription)
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OMLXClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data.prefix(1_000), encoding: .utf8) ?? "无响应正文"
            throw OMLXClientError.httpStatus(http.statusCode, message)
        }
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
        data.append(
            Data(
                "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
                    .utf8
            )
        )
        data.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        data.append(fileData)
        data.append(Data("\r\n".utf8))
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }

    let choices: [Choice]
}
