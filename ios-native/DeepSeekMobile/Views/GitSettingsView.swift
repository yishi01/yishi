import SwiftUI

struct GitSettingsView: View {
    @EnvironmentObject var client: BridgeClient
    @Binding var activeTab: MainTab
    @State private var apiKeyInput: String = ""
    @State private var workspacesText: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Git Diff Card
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Git 变更审查")
                                    .font(.system(size: 16, weight: .semibold))
                                Text(client.isGitRepo ? "分支: \(client.gitBranch)" : "当前目录尚未初始化 Git")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("刷新") {
                                Task { await client.refreshGitDiff() }
                            }
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .cleanWhiteCard(cornerRadius: 999)

                            Button("AI 审查") {
                                Task {
                                    activeTab = .chat
                                    await client.sendPrompt("请调用 git_status_diff 检查当前工作区改动，总结内容并指出潜在风险。")
                                }
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.dsPrimary))
                        }

                        ScrollView(.horizontal) {
                            Text(client.gitDiff.isEmpty ? "(无未提交的文本变更)" : client.gitDiff)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                        .frame(maxHeight: 240)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.dsSurface)
                        )
                    }
                    .padding(16)
                    .cleanWhiteCard(cornerRadius: 18)

                    // Settings Card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("DeepSeek 与工作区设置")
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Button("退出登录") {
                                client.logout()
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("DeepSeek API Key (\(client.hasAPIKey ? "已配置" : "未配置"))")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                            SecureField("sk-... (留空保持不变)", text: $apiKeyInput)
                                .padding(10)
                                .cleanWhiteCard(cornerRadius: 10)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("默认模型")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                            TextField("deepseek-chat / deepseek-reasoner", text: $client.selectedModel)
                                .textInputAutocapitalization(.never)
                                .padding(10)
                                .cleanWhiteCard(cornerRadius: 10)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("工具审批策略")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                            Picker("审批策略", selection: $client.approvalMode) {
                                Text("仅命令审批").tag("ask_commands")
                                Text("写入与命令均审批").tag("ask_writes")
                                Text("全自动执行").tag("auto")
                            }
                            .pickerStyle(.segmented)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("允许的工作区目录 (每行一个路径)")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                            TextEditor(text: $workspacesText)
                                .font(.system(size: 13, design: .monospaced))
                                .frame(height: 76)
                                .padding(6)
                                .cleanWhiteCard(cornerRadius: 10)
                        }

                        Button {
                            client.workspaces = workspacesText
                                .split(separator: "\n")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            Task {
                                try? await client.saveSettings(apiKey: apiKeyInput)
                                apiKeyInput = ""
                            }
                        } label: {
                            Text("保存设置")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Capsule().fill(Color.dsPrimary))
                        }
                    }
                    .padding(16)
                    .cleanWhiteCard(cornerRadius: 18)
                }
                .padding(14)
            }
            .background(Color.dsSurface)
            .navigationTitle("变更 · 设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                workspacesText = client.workspaces.joined(separator: "\n")
                Task { await client.refreshGitDiff() }
            }
        }
    }
}
