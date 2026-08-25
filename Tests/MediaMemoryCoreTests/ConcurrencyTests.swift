import Foundation
@testable import MediaMemoryCore
import XCTest

final class ConcurrencyTests: XCTestCase {
    func testAsyncTimeoutReturnsAndCancelsSlowOperation() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await AsyncTimeout.run(for: .milliseconds(80), operationName: "测试操作") {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
            XCTFail("Slow operation unexpectedly completed")
        } catch let error as AsyncTimeoutError {
            XCTAssertEqual(error.operationName, "测试操作")
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testAsyncTimeoutDoesNotWaitForNonCooperativeOperation() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await AsyncTimeout.run(for: .milliseconds(50), operationName: "非协作操作") {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
                        continuation.resume(returning: 1)
                    }
                }
            }
            XCTFail("Non-cooperative operation unexpectedly completed")
        } catch let error as AsyncTimeoutError {
            XCTAssertEqual(error.operationName, "非协作操作")
        }
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(300))
    }

    func testCancelledGateWaiterReturnsWithoutWaitingForCurrentOwner() async throws {
        let gate = AsyncOperationGate()
        try await gate.acquire()

        let waiter = Task {
            try await gate.acquire()
            await gate.release()
        }
        try await Task.sleep(for: .milliseconds(30))
        let started = ContinuousClock.now
        waiter.cancel()

        do {
            try await waiter.value
            XCTFail("Cancelled waiter unexpectedly acquired the gate")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))

        await gate.release()
        try await gate.acquire()
        await gate.release()
    }

    func testForegroundGateWaiterRunsBeforeQueuedBackgroundWaiter() async throws {
        let gate = AsyncOperationGate()
        let events = GateEventRecorder()
        try await gate.acquire()

        let background = Task {
            try await gate.acquire(priority: .background)
            await events.append("background")
            await gate.release()
        }
        try await Task.sleep(for: .milliseconds(30))
        let foreground = Task {
            try await gate.acquire(priority: .foreground)
            await events.append("foreground")
            await gate.release()
        }
        try await Task.sleep(for: .milliseconds(30))

        await gate.release()
        try await foreground.value
        try await background.value
        let values = await events.values
        XCTAssertEqual(values, ["foreground", "background"])
    }

    func testCancelledForegroundWaiterDoesNotBlockBackgroundWaiter() async throws {
        let gate = AsyncOperationGate()
        try await gate.acquire()

        let background = Task {
            try await gate.acquire(priority: .background)
            await gate.release()
        }
        try await Task.sleep(for: .milliseconds(30))
        let foreground = Task {
            try await gate.acquire(priority: .foreground)
            await gate.release()
        }
        try await Task.sleep(for: .milliseconds(30))
        foreground.cancel()
        do {
            try await foreground.value
            XCTFail("Cancelled foreground waiter unexpectedly acquired the gate")
        } catch is CancellationError {
            // Expected.
        }

        await gate.release()
        try await background.value
    }

    func testWorkerTimesOutAndTerminatesAStuckProcess() async throws {
        let fixture = try HangingWorkerFixture()
        let worker = try MLXWorker(
            configuration: fixture.configuration,
            workRoot: fixture.root,
            operationTimeout: .milliseconds(120)
        )
        let started = ContinuousClock.now

        do {
            try await worker.ping()
            XCTFail("Hanging worker unexpectedly replied")
        } catch let error as MLXWorkerError {
            guard case .timedOut = error else {
                return XCTFail("Expected timedOut, got \(error)")
            }
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    func testCancellingWorkerRequestReturnsPromptly() async throws {
        let fixture = try HangingWorkerFixture()
        let worker = try MLXWorker(
            configuration: fixture.configuration,
            workRoot: fixture.root,
            operationTimeout: .seconds(30)
        )
        let request = Task { try await worker.ping() }
        try await Task.sleep(for: .milliseconds(80))
        let started = ContinuousClock.now
        request.cancel()

        do {
            try await request.value
            XCTFail("Cancelled worker unexpectedly replied")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testWorkerReassemblesLargeSplitResponseInOrder() async throws {
        let fixture = try ChunkedWorkerFixture()
        let worker = try MLXWorker(
            configuration: fixture.configuration,
            workRoot: fixture.root,
            operationTimeout: .seconds(5)
        )

        try await worker.ping()
        await worker.stop()
    }

    func testCancellingQueryRequestPreservesWorkerUntilExplicitStop() async throws {
        let fixture = try ReusableEmbeddingWorkerFixture()
        let worker = try MLXWorker(
            configuration: fixture.configuration,
            workRoot: fixture.root,
            operationTimeout: .seconds(5)
        )
        let request = Task {
            try await worker.embed(
                text: "cancel me",
                imageURLs: [],
                instruction: "query",
                cancellationBehavior: .preserveProcess
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Cancelled query unexpectedly returned a vector")
        } catch is CancellationError {
            // The atomic request drained, then the cancelled result was discarded.
        }

        let reused = try await worker.embed(
            text: "background",
            imageURLs: [],
            instruction: "index"
        )
        XCTAssertEqual(reused.values, [1, 0])
        XCTAssertEqual(try fixture.processStartCount(), 1)

        await worker.stop()
        _ = try await worker.embed(text: "restart", imageURLs: [], instruction: "index")
        XCTAssertEqual(try fixture.processStartCount(), 2)
        await worker.stop()
    }
}

private actor GateEventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private final class HangingWorkerFixture: @unchecked Sendable {
    let root: URL
    let configuration: ModelConfiguration.Worker

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "media-memory-hanging-worker-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let models = root.appending(path: "models", directoryHint: .isDirectory)
        let executable = root.appending(path: "hang.sh")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        configuration = ModelConfiguration.Worker(
            forcedAlignerModelID: "unused-aligner",
            embeddingModelID: "unused-embedding",
            pythonLauncherPath: executable.path,
            modelRootPath: models.path
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ChunkedWorkerFixture: @unchecked Sendable {
    let root: URL
    let configuration: ModelConfiguration.Worker

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "media-memory-chunked-worker-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let models = root.appending(path: "models", directoryHint: .isDirectory)
        let executable = root.appending(path: "chunked.py")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let script = """
        #!/usr/bin/python3
        import json
        import sys

        for _ in sys.stdin:
            payload = json.dumps({"ok": True, "result": {"status": "ready", "padding": "x" * 200000}})
            for index in range(0, len(payload), 137):
                sys.stdout.write(payload[index:index + 137])
                sys.stdout.flush()
            sys.stdout.write("\\n")
            sys.stdout.flush()
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        configuration = ModelConfiguration.Worker(
            forcedAlignerModelID: "unused-aligner",
            embeddingModelID: "unused-embedding",
            pythonLauncherPath: executable.path,
            modelRootPath: models.path
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ReusableEmbeddingWorkerFixture: @unchecked Sendable {
    let root: URL
    let configuration: ModelConfiguration.Worker
    private let startsURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "media-memory-reusable-worker-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let models = root.appending(path: "models", directoryHint: .isDirectory)
        let aligner = models.appending(path: "unused-aligner", directoryHint: .isDirectory)
        let embedding = models.appending(path: "unused-embedding", directoryHint: .isDirectory)
        let executable = root.appending(path: "reusable.py")
        startsURL = root.appending(path: "process-starts.txt")
        try FileManager.default.createDirectory(at: aligner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: embedding, withIntermediateDirectories: true)
        let script = """
        #!/usr/bin/python3
        import json
        import os
        import sys
        import time

        starts = os.path.join(os.environ["MEDIA_MEMORY_WORK_ROOT"], "process-starts.txt")
        with open(starts, "a", encoding="utf-8") as handle:
            handle.write("start\\n")
        for line in sys.stdin:
            request = json.loads(line)
            if request.get("operation") == "embed":
                time.sleep(0.15)
                result = {"dimension": 2, "vector": [1.0, 0.0], "norm": 1.0}
            else:
                result = {"status": "ready"}
            sys.stdout.write(json.dumps({"ok": True, "result": result}) + "\\n")
            sys.stdout.flush()
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        configuration = ModelConfiguration.Worker(
            forcedAlignerModelID: "unused-aligner",
            embeddingModelID: "unused-embedding",
            pythonLauncherPath: executable.path,
            modelRootPath: models.path
        )
    }

    func processStartCount() throws -> Int {
        let text = try String(contentsOf: startsURL, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).count
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
