import Foundation
@testable import MediaMemoryMCPServer
import XCTest

final class JSONRPCTests: XCTestCase {
    func testRequestRoundtrip() throws {
        let original = JSONRPCMessage.request(
            id: .int(7),
            method: "tools/call",
            params: .object([
                "name": .string("search_media"),
                "arguments": .object(["query": .string("京都"), "limit": .int(3)])
            ])
        )
        let data = try JSONRPCCodec.encode(original)
        let decoded = try JSONRPCCodec.decode(data)
        XCTAssertEqual(decoded, original)
    }

    func testResponseRoundtrip() throws {
        let original = JSONRPCMessage.response(
            id: .string("abc"),
            result: .object(["tools": .array([])])
        )
        let data = try JSONRPCCodec.encode(original)
        let decoded = try JSONRPCCodec.decode(data)
        XCTAssertEqual(decoded, original)
    }

    func testErrorOmitsNullData() throws {
        let data = try JSONRPCCodec.encode(
            JSONRPCMessage.error(id: .int(1), code: -32601, message: "未知方法")
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertNil(error["data"])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testBatchPayloadIsRejected() throws {
        let data = Data("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]".utf8)
        XCTAssertThrowsError(try JSONRPCCodec.decode(data)) { error in
            XCTAssertEqual(error as? JSONRPCCodec.CodecError, .batchUnsupported)
        }
    }

    func testWrongProtocolVersionIsRejected() throws {
        let data = Data("{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"ping\"}".utf8)
        XCTAssertThrowsError(try JSONRPCCodec.decode(data))
    }

    func testMessageWithoutKindIsRejected() throws {
        let data = Data("{\"jsonrpc\":\"2.0\",\"id\":1}".utf8)
        XCTAssertThrowsError(try JSONRPCCodec.decode(data))
    }

    func testJSONValueNumberParsing() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data("{\"i\":3,\"d\":3.5}".utf8))
        )
        let data = try JSONSerialization.data(withJSONObject: object)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value["i"], .int(3))
        XCTAssertEqual(value["d"], .double(3.5))
    }
}
