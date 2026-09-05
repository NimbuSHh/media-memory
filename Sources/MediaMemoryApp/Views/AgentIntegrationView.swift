import SwiftUI

/// 「Agent 接入」面板：把 media-memory MCP 检索服务一键注册进本机 agent
/// 客户端，并提供给其他客户端手工粘贴的配置片段。
struct AgentIntegrationView: View {
    @StateObject private var controller = AgentIntegrationController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                BrandIconView(size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent 接入")
                        .font(.headline)
                    Text("把本机媒体库的语义检索登记给 AI agent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)
            Form {
                Section {
                    Text(
                        "通过 MCP 让 Claude Code、ZCode 等 agent 直接检索本机媒体库："
                            + "按画面内容、台词、画面文字语义搜索并返回时间戳证据。"
                            + "接入只登记只读检索服务，不会授权任何写入或删除操作。"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Section("检索服务") {
                    if let url = controller.serverBinaryURL {
                        LabeledContent("服务器程序") {
                            Text(url.path)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Button("拷贝程序路径") {
                            controller.copyToClipboard(url.path)
                        }
                    } else {
                        Label(
                            "未找到 media-memory-mcp。请先运行 swift build（开发）或 Scripts/build-app.sh（打包），把服务器程序放到应用可执行文件同目录。",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                Section("客户端") {
                    ForEach(controller.clients) { client in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(client.name)
                                Text(client.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if client.registered {
                                Button("移除接入", role: .destructive) {
                                    Task { await controller.uninstall(client.id) }
                                }
                                .disabled(controller.isWorking)
                            } else {
                                Button("接入") {
                                    Task { await controller.install(client.id) }
                                }
                                .disabled(
                                    controller.isWorking
                                        || controller.serverBinaryURL == nil
                                        || (client.id == .claudeCode && !client.detected)
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section("手动接入（其他客户端）") {
                    ScrollView {
                        Text(controller.manualSnippet)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 110)
                    Button("拷贝配置片段") {
                        controller.copyToClipboard(controller.manualSnippet)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if controller.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 660, height: 640)
        .task {
            await controller.refresh()
        }
        .alert(
            "Media Memory",
            isPresented: Binding(
                get: { controller.errorMessage != nil },
                set: { if !$0 { controller.errorMessage = nil } }
            ),
            actions: {
                Button("好", role: .cancel) {
                    controller.errorMessage = nil
                }
            },
            message: {
                Text(controller.errorMessage ?? "")
            }
        )
    }
}
