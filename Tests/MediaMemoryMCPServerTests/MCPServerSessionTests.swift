import Foundation
@testable import MediaMemoryMCPServer
import XCTest

final class MCPServerSessionTests: XCTestCase {
    // MARK: - 辅助

    private func makeSession(_ backend: MCPServerBackend) -> MCPServerSession {
        MCPServerSession(backend: backend, options: MediaMemoryMCPServerDefaults.options)
    }

    /// 发送一条请求并取回响应字典；通知与被取消请求返回 nil。
    private func roundtrip(
        _ session: MCPServerSession,
        _ payload: [String: Any]
    ) async throws -> [String: Any]? {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let responseData = await session.handle(data) else { return nil }
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
    }

    private func legacyInitialize(
        _ session: MCPServerSession,
        version: String = "2025-06-18"
    ) async throws -> [String: Any] {
        let response = try await roundtrip(
            session,
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": version,
                    "capabilities": [String: Any](),
                    "clientInfo": ["name": "test", "version": "0"]
                ]
            ]
        )
        return try XCTUnwrap(response?["result"] as? [String: Any])
    }

    // MARK: - legacy 握手

    func testLegacyInitializeNegotiatesKnownVersion() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        let result = try await legacyInitialize(session, version: "2025-03-26")
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "media-memory")
        XCTAssertNotNil(result["instructions"])
    }

    func testLegacyInitializeFallsBackToLatestLegacyVersion() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        let result = try await legacyInitialize(session, version: "1999-01-01")
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
    }

    // MARK: - modern 无状态请求

    func testDiscoverListsSupportedVersions() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        let response = try await roundtrip(
            session,
            [
                "jsonrpc": "2.0",
                "id": "d1",
                "method": "server/discover",
                "params": [
                    "_meta": [
                        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                        "io.modelcontextprotocol/clientCapabilities": [String: Any]()
                    ]
                ]
            ]
        )
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        let versions = try XCTUnwrap(result["supportedVersions"] as? [String])
        XCTAssertEqual(versions.first, "2026-07-28")
        XCTAssertTrue(versions.contains("2025-06-18"))
    }

    func testModernRequestWithoutRequiredMetaIsInvalidParams() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        _ = try await legacyInitialize(session)
        let response = try await roundtrip(
            session,
            [
                "jsonrpc": "2.0",
                "id": 9,
                "method": "tools/list",
                "params": [
                    "_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]
                ]
            ]
        )
        let error = try XCTUnwrap(response?["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    func testUnsupportedModernVersionReportsSupportedList() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        let response = try await roundtrip(
            session,
            [
                "jsonrpc": "2.0",
                "id": 10,
                "method": "tools/list",
                "params": [
                    "_meta": [
                        "io.modelcontextprotocol/protocolVersion": "1900-01-01",
                        "io.modelcontextprotocol/clientCapabilities": [String: Any]()
                    ]
                ]
            ]
        )
        let error = try XCTUnwrap(response?["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32022)
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        let supported = try XCTUnwrap(data["supported"] as? [String])
        XCTAssertTrue(supported.contains("2026-07-28"))
    }

    // MARK: - 工具面

    func testToolsListExposesThreeSearchTools() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        _ = try await legacyInitialize(session)
        let response = try await roundtrip(
            session,
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [String: Any]()]
        )
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names), Set(["search_media", "get_video_detail", "library_stats"]))
        for tool in tools {
            XCTAssertNotNil(tool["description"])
            XCTAssertNotNil(tool["inputSchema"])
        }
    }

    func testSearchMediaReturnsAggregatedEvidence() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        _ = try await legacyInitialize(session)
        let response = try await roundtrip(
            session,
            [
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": [
                    "name": "search_media",
                    "arguments": ["query": "京都车站"]
                ]
            ]
        )
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("clip.mp4"), "结果应包含视频文件名：\(text)")
        XCTAssertTrue(text.contains("台词"), "证据行应标注台词来源：\(text)")
        XCTAssertTrue(text.contains("字幕"), "证据行应标注字幕来源：\(text)")

        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["count"] as? Int, 1)
        let results = try XCTUnwrap(structured["results"] as? [[String: Any]])
        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first["path"] as? String, "clip.mp4")
        XCTAssertEqual(first["matchedSegmentCount"] as? Int, 1)
        let evidence = try XCTUnwrap(first["evidence"] as? [[String: Any]])
        XCTAssertEqual(evidence.count, 2)
    }

    func testSearchMediaWithoutMatchExplainsEmptyResult() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        _ = try await legacyInitialize(session)
        let response = try await roundtrip(
            session,
            [
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/call",
                "params": [
                    "name": "search_media",
                    "arguments": ["query": "完全不存在的主题"]
                ]
            ]
        )
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertNil(result["isError"])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("没有命中"))
    }

    func testVideoDetailResolvesSegments() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        _ = try await legacyInitialize(session)
        let response = try await roundtrip(
            session,
            [
                "jsonrpc": "2.0",
                "id": 5,
                "method": "tools/call",
                "params": [
                    "name": "get_video_detail",
                    "arguments": ["path": "clip.mp4", "includeTranscripts": true]
                ]
            ]
        )
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("clip.mp4"))
        XCTAssertTrue(text.contains("台词"), "includeTranscripts 应带出台词原文")

        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["segmentCount"] as? Int, 2)
        XCTAssertEqual(structured["indexedSegmentCount"] as? Int, 1)
    }

    func testVideoDetailUnknownPathIsToolError() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        _ = try await legacyInitialize(session)
        let response = try await roundtrip(
            session,
            [
                "jsonrpc": "2.0",
                "id": 6,
                "method": "tools/call",
                "params": [
                    "name": "get_video_detail",
                    "arguments": ["path": "missing.mp4"]
                ]
            ]
        )
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true, "未知路径属于工具执行错误而非协议错误")
    }

    func testLibraryStatsCountsIndexedData() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        _ = try await legacyInitialize(session)
        let response = try await roundtrip(
            session,
            [
                "jsonrpc": "2.0",
                "id": 7,
                "method": "tools/call",
                "params": ["name": "library_stats", "arguments": [String: Any]()]
            ]
        )
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["assetCount"] as? Int, 1)
        // 40 秒视频按 V1 兼容口径产生两个回退段；fixture 只提交了其中一个。
        XCTAssertEqual(structured["segmentCount"] as? Int, 2)
        XCTAssertEqual(structured["embeddingCount"] as? Int, 1)

        // 队列概览：还有一段未建库，库应显示为排队中而不是已完成。
        let queue = try XCTUnwrap(structured["queue"] as? [[String: Any]])
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue[0]["pendingJobs"] as? Int, 1)
        XCTAssertEqual(queue[0]["isProcessed"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("处理队列"))
        XCTAssertTrue(text.contains("排队中"))
    }

    func testUnknownToolIsInvalidParams() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        _ = try await legacyInitialize(session)
        let response = try await roundtrip(
            session,
            [
                "jsonrpc": "2.0",
                "id": 8,
                "method": "tools/call",
                "params": ["name": "delete_everything", "arguments": [String: Any]()]
            ]
        )
        let error = try XCTUnwrap(response?["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    // MARK: - 协议边界

    func testUnknownMethodIsMethodNotFound() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        _ = try await legacyInitialize(session)
        let response = try await roundtrip(
            session,
            ["jsonrpc": "2.0", "id": 11, "method": "resources/list", "params": [String: Any]()]
        )
        let error = try XCTUnwrap(response?["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testBatchPayloadGetsParseError() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        let responseData = await session.handle(
            Data("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]".utf8)
        )
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(responseData)) as? [String: Any]
        )
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32700)
    }

    func testNotificationProducesNoResponse() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        let response = await session.handle(
            Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8)
        )
        XCTAssertNil(response)
    }

    func testCancellationOfUnknownRequestIsSilent() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        let response = await session.handle(
            Data(
                "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":42}}".utf8
            )
        )
        XCTAssertNil(response)
    }

    func testPingAnswersEmptyResult() async throws {
        let fixture = try await MCPSearchFixture()
        let session = makeSession(try await fixture.makeBackend())
        _ = try await legacyInitialize(session)
        let response = try await roundtrip(
            session,
            ["jsonrpc": "2.0", "id": 12, "method": "ping"]
        )
        XCTAssertNotNil(response?["result"])
    }
}
