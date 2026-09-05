import AppKit
import Foundation

/// 「Agent 接入」面板的状态与动作：定位 MCP 服务器二进制，探测各 agent
/// 客户端的安装与注册状态，执行接入/移除。全部是本机配置文件与子进程
/// 操作，不联网；对每个客户端只写入/移除名为 media-memory 的服务器条目，
/// 其余键原样保留。
@MainActor
final class AgentIntegrationController: ObservableObject {
    struct ClientStatus: Identifiable {
        let id: IntegrationTarget
        let name: String
        var detected: Bool
        var registered: Bool
        var detail: String
    }

    enum IntegrationTarget: String, CaseIterable {
        case codex
        case claudeCode
        case zcode
        case opencode
    }

    nonisolated static let serverName = "media-memory"

    @Published private(set) var serverBinaryURL: URL?
    @Published private(set) var clients: [ClientStatus] = []
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    // MARK: - 生命周期

    func refresh() async {
        serverBinaryURL = Self.resolveServerBinary()
        let results = await Task.detached(priority: .userInitiated) { [serverBinaryURL] () -> [ClientStatus] in
            await Self.inspectClients(serverBinaryURL: serverBinaryURL)
        }.value
        clients = results
    }

    func install(_ target: IntegrationTarget) async {
        guard let serverBinaryURL else {
            errorMessage = "未找到 media-memory-mcp 服务器程序，无法接入。"
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.install(target, serverBinaryPath: serverBinaryURL.path)
            }.value
        } catch {
            errorMessage = "接入失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func uninstall(_ target: IntegrationTarget) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.uninstall(target)
            }.value
        } catch {
            errorMessage = "移除失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    var manualSnippet: String {
        let path = serverBinaryURL?.path ?? "/path/to/media-memory-mcp"
        return """
        {
          "mcpServers": {
            "media-memory": {
              "command": "\(path)"
            }
          }
        }
        """
    }

    func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    // MARK: - 二进制定位

    /// 已安装 app 中与 MediaMemory 同在 Contents/MacOS；swift run/dev 场景
    /// 与之同在 .build/<config> 目录，同一规则天然覆盖两种布局。
    nonisolated static func resolveServerBinary() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let candidate = executable.deletingLastPathComponent()
            .appending(component: "media-memory-mcp")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    // MARK: - 客户端探测

    nonisolated private static func inspectClients(
        serverBinaryURL: URL?
    ) async -> [ClientStatus] {
        let claudeBinary = locateClaudeBinary()
        let claudeRegistered = claudeBinary != nil && registeredInClaudeJSON()
        let zcodeDetected = FileManager.default.fileExists(atPath: zcodeAppSupportPath)
            || FileManager.default.fileExists(atPath: zcodeUserConfigURL.path)
        let opencodeDetected = FileManager.default.fileExists(atPath: opencodeConfigDirectory.path)
            || locateOpenCodeBinary() != nil
        let codexDetected = FileManager.default.fileExists(atPath: codexConfigDirectory.path)
            || locateCodexBinary() != nil

        var statuses: [ClientStatus] = []
        for target in IntegrationTarget.allCases {
            let name: String
            let detected: Bool
            let registered: Bool
            var detail = ""
            switch target {
            case .claudeCode:
                name = "Claude Code"
                detected = claudeBinary != nil
                registered = claudeRegistered
                detail = detected ? "检测到 claude 命令行" : "未检测到 claude 命令行"
            case .zcode:
                name = "ZCode"
                detected = zcodeDetected
                registered = registeredInZCode()
                detail = detected ? "写入 ~/.zcode/cli/config.json" : "未检测到 ZCode；仍可手动接入"
            case .opencode:
                name = "OpenCode"
                detected = opencodeDetected
                registered = registeredInOpenCode()
                detail = detected ? "写入 ~/.config/opencode/opencode.json" : "未检测到 OpenCode；仍可手动接入"
            case .codex:
                name = "Codex"
                detected = codexDetected
                registered = registeredInCodex()
                detail = detected ? "写入 ~/.codex/config.toml" : "未检测到 Codex；仍可手动接入"
            }
            if registered {
                detail = serverBinaryURL == nil ? "已接入（服务器程序缺失，请重新打包）" : "已接入"
            }
            statuses.append(
                ClientStatus(
                    id: target,
                    name: name,
                    detected: detected,
                    registered: registered,
                    detail: detail
                )
            )
        }
        return statuses
    }

    // MARK: - 接入/移除

    nonisolated private static func install(
        _ target: IntegrationTarget,
        serverBinaryPath: String
    ) throws {
        switch target {
        case .claudeCode:
            guard let claude = locateClaudeBinary() else {
                throw IntegrationError.clientMissing("claude")
            }
            // add 对同名条目会报错；先移除旧行保证幂等。
            _ = try? runProcess(claude, ["mcp", "remove", "-s", "user", serverName])
            try runProcess(
                claude,
                ["mcp", "add", "-s", "user", serverName, "--", serverBinaryPath]
            )
        case .zcode:
            try mutateJSONObject(zcodeUserConfigURL) { root in
                var servers = nestedMCPServers(in: root)
                servers[serverName] = ["command": serverBinaryPath, "enabled": true]
                root["mcp"] = ["servers": servers]
            }
        case .opencode:
            try mutateJSONObject(opencodeConfigURL) { root in
                var servers = root["mcp"] as? [String: Any] ?? [:]
                servers[serverName] = [
                    "type": "local",
                    "command": [serverBinaryPath],
                    "enabled": true
                ]
                root["mcp"] = servers
            }
        case .codex:
            try writeCodexSection(
                """
                [mcp_servers.\(serverName)]
                command = "\(serverBinaryPath)"
                """
            )
        }
    }

    nonisolated private static func uninstall(_ target: IntegrationTarget) throws {
        switch target {
        case .claudeCode:
            guard let claude = locateClaudeBinary() else {
                throw IntegrationError.clientMissing("claude")
            }
            try runProcess(claude, ["mcp", "remove", "-s", "user", serverName])
        case .zcode:
            try mutateJSONObject(zcodeUserConfigURL) { root in
                var servers = nestedMCPServers(in: root)
                servers.removeValue(forKey: serverName)
                root["mcp"] = ["servers": servers]
            }
        case .opencode:
            try mutateJSONObject(opencodeConfigURL) { root in
                var servers = root["mcp"] as? [String: Any] ?? [:]
                servers.removeValue(forKey: serverName)
                root["mcp"] = servers
            }
        case .codex:
            try writeCodexSection(nil)
        }
    }

    // MARK: - Claude Code

    nonisolated private static func locateClaudeBinary() -> URL? {
        let candidates = [
            "~/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        return candidates.compactMap {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
        }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated private static func registeredInClaudeJSON() -> Bool {
        let url = URL(fileURLWithPath: "~/.claude.json".resolvingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else {
            return false
        }
        return servers[serverName] != nil
    }

    // MARK: - ZCode / OpenCode

    nonisolated private static var zcodeAppSupportPath: String {
        NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)
            .first.map { $0 + "/ZCode" } ?? ""
    }

    nonisolated private static var zcodeUserConfigURL: URL {
        let home = NSHomeDirectory() as NSString
        return URL(fileURLWithPath: home.appendingPathComponent(".zcode/cli/config.json"))
    }

    nonisolated private static var opencodeConfigDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: ".config/opencode", directoryHint: .isDirectory)
    }

    nonisolated private static var opencodeConfigURL: URL {
        opencodeConfigDirectory.appending(component: "opencode.json")
    }

    nonisolated private static func locateOpenCodeBinary() -> URL? {
        ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode", NSHomeDirectory() + "/.opencode/bin/opencode"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Codex（TOML 配置）

    nonisolated private static var codexConfigDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: ".codex", directoryHint: .isDirectory)
    }

    nonisolated private static var codexConfigURL: URL {
        codexConfigDirectory.appending(component: "config.toml")
    }

    nonisolated private static func locateCodexBinary() -> URL? {
        ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", NSHomeDirectory() + "/.local/bin/codex"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated private static func registeredInCodex() -> Bool {
        guard let text = try? String(contentsOf: codexConfigURL, encoding: .utf8) else {
            return false
        }
        return text.components(separatedBy: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.\(serverName)]"
        }
    }

    /// 只增删自己的 `[mcp_servers.media-memory]` 段，文件其余内容按行
    /// 原样保留；`section` 为 nil 表示移除。
    nonisolated private static func writeCodexSection(_ section: String?) throws {
        let directory = codexConfigDirectory
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let existing = (try? String(contentsOf: codexConfigURL, encoding: .utf8)) ?? ""
        var kept: [String] = []
        var inManagedSection = false
        for line in existing.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[mcp_servers.\(serverName)]" {
                inManagedSection = true
                continue
            }
            if inManagedSection {
                if trimmed.hasPrefix("[") {
                    inManagedSection = false
                    kept.append(line)
                }
            } else {
                kept.append(line)
            }
        }
        var output = kept.joined(separator: "\n")
        if let section {
            if !output.isEmpty, !output.hasSuffix("\n") {
                output += "\n"
            }
            output += section + "\n"
        }
        try Data(output.utf8).write(to: codexConfigURL, options: .atomic)
    }

    nonisolated private static func registeredInZCode() -> Bool {
        guard let root = readJSONObject(zcodeUserConfigURL),
              let servers = nestedMCPServers(in: root) as? [String: Any] else {
            return false
        }
        return servers[serverName] != nil
    }

    nonisolated private static func registeredInOpenCode() -> Bool {
        guard let root = readJSONObject(opencodeConfigURL),
              let servers = root["mcp"] as? [String: Any] else {
            return false
        }
        return servers[serverName] != nil
    }

    /// ZCode 配置用嵌套的 mcp.servers；缺失时视为空表。
    nonisolated private static func nestedMCPServers(in root: [String: Any]) -> [String: Any] {
        (root["mcp"] as? [String: Any])?["servers"] as? [String: Any] ?? [:]
    }

    // MARK: - JSON 配置读写

    nonisolated private static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    /// 读-改-写单个 JSON 配置文件：只动 media-memory 条目，其余内容原样
    /// 保留。文件不存在时创建目录与文件。
    nonisolated private static func mutateJSONObject(
        _ url: URL,
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws {
        var root = readJSONObject(url) ?? [:]
        try mutation(&root)
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: - 子进程

    @discardableResult
    nonisolated private static func runProcess(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // 挂起保护：客户端 CLI 偶发等待输入时不能卡死接入面板。被 watchdog
        // 终止的进程退出码非零，自然走错误路径。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        do {
            try process.run()
        } catch {
            throw IntegrationError.processFailed(executable.lastPathComponent, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: data, encoding: .utf8) ?? ""
            throw IntegrationError.processFailed(
                executable.lastPathComponent,
                output.isEmpty ? "退出码 \(process.terminationStatus)" : output
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum IntegrationError: LocalizedError {
    case clientMissing(String)
    case processFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .clientMissing(let name):
            "未找到 \(name) 命令行工具。"
        case .processFailed(let name, let detail):
            "\(name) 执行失败：\(detail)"
        }
    }
}

private extension String {
    var resolvingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}
