// media-memory-mcp：MCP stdio 服务器入口。由 agent 客户端作为子进程拉起，
// 协议通道独占 stdout，一切诊断走 stderr；数据库只读打开，进程无常驻状态。
import Foundation
import MediaMemoryCore
import MediaMemoryMCPServer

let standardErrorHandle = FileHandle.standardError

func logDiagnostic(_ message: String) {
    standardErrorHandle.write(Data(("[media-memory-mcp] \(message)\n").utf8))
}

let session: MCPServerSession
do {
    let (backend, degradationNote) = try await MediaMemoryMCPServices.makeSearchBackend()
    if let degradationNote {
        logDiagnostic(degradationNote)
    }
    session = MCPServerSession(backend: backend, options: MediaMemoryMCPServerDefaults.options)
} catch {
    logDiagnostic("启动失败：\(error)")
    exit(1)
}

/// 响应按完成顺序返回，stdout 写入必须互斥。
final class OutputWriter: @unchecked Sendable {
    private let handle = FileHandle.standardOutput
    private let queue = DispatchQueue(label: "io.github.nimbushh.media-memory.mcp.stdout")

    func write(_ data: Data) {
        queue.sync {
            handle.write(data)
            handle.write(Data([0x0A]))
        }
    }
}

let output = OutputWriter()

await withTaskGroup(of: Void.self) { group in
    do {
        for try await line in FileHandle.standardInput.bytes.lines {
            let payload = Data(line.utf8)
            group.addTask {
                guard !payload.isEmpty else { return }
                if let response = await session.handle(payload) {
                    output.write(response)
                }
            }
        }
    } catch {
        logDiagnostic("输入流读取失败：\(error.localizedDescription)")
    }
}
