import SwiftUI

struct GitSettingsView: View {
    @EnvironmentObject var client: BridgeClient
    @Binding var activeTab: MainTab
    @State private var apiKeyInput: String = ""
    @State private var workspacesText: String = ""
    @State private var savedToast: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Git Diff Liquid Glass Card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.dsAccent)
                                Text("Git 变更审查")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.dsPrimary)
                            }
                            Text(client.isGitRepo ? "当前分支: \(client.gitBranch)" : "当前目录尚未初始化 Git")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Haptics.light()
                            Task { await client.refreshGitDiff() }
                        } label: {
                            Text("刷新")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Color.dsPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6.5)
                                .cleanWhiteCard(cornerRadius: 999)
                        }
                        .glassPressable(scale: 0.94)

                        Button {
                            Haptics.medium()
                            Task {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.80)) {
                                    activeTab = .chat
                                }
                                await client.sendPrompt("请调用 git_status_diff 检查当前工作区改动，总结内容并指出潜在风险。")
                            }
                        } label: {
                            Text("AI 审查")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6.5)
                                .background(Capsule().fill(Color.dsPrimary))
                        }
                        .glassPressable(scale: 0.94)
                    }

                    ScrollView(.horizontal) {
                        Text(client.gitDiff.isEmpty ? "(无未提交的文本变更)" : client.gitDiff)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                    .frame(maxHeight: 220)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.45))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.75), lineWidth: 1)
                    )
                }
                .padding(16)
                .liquidGlass(cornerRadius: 22, prominent: false)

                // Settings Liquid Glass Card
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        HStack(spacing: 8) {
                            Image("DSHLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 24, height: 24)
                            Text("DeepSeek 与工作区设置")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.dsPrimary)
                        }
                        Spacer()
                        Button {
                            Haptics.warning()
                            client.logout()
                        } label: {
                            Text("退出连接")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .cleanWhiteCard(cornerRadius: 999)
                        }
                        .glassPressable(scale: 0.95)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("DeepSeek API Key (\(client.hasAPIKey ? "已配置" : "未配置"))")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        SecureField("sk-... (留空保持不变)", text: $apiKeyInput)
                            .padding(11)
                            .cleanWhiteCard(cornerRadius: 12)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("默认模型")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("deepseek-flash / deepseek-chat / deepseek-reasoner", text: $client.selectedModel)
                            .textInputAutocapitalization(.never)
                            .padding(11)
                            .cleanWhiteCard(cornerRadius: 12)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("工具审批策略")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Picker("审批策略", selection: $client.approvalMode) {
                            Text("仅命令审批").tag("ask_commands")
                            Text("写入与命令审批").tag("ask_writes")
                            Text("全自动执行").tag("auto")
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("允许的工作区目录 (每行一个路径)")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $workspacesText)
                            .font(.system(size: 12.5, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(height: 78)
                            .padding(6)
                            .cleanWhiteCard(cornerRadius: 12)
                    }

                    Button {
                        Haptics.medium()
                        client.workspaces = workspacesText
                            .split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        Task {
                            try? await client.saveSettings(apiKey: apiKeyInput)
                            apiKeyInput = ""
                            Haptics.success()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                savedToast = true
                            }
                            try? await Task.sleep(nanoseconds: 1_800_000_000)
                            withAnimation(.easeOut(duration: 0.25)) {
                                savedToast = false
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: savedToast ? "checkmark.circle.fill" : "square.and.arrow.down")
                                .font(.system(size: 14, weight: .semibold))
                            Text(savedToast ? "已同步至电脑端 DSH" : "保存设置")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            Capsule()
                                .fill(savedToast ? Color.green : Color.dsPrimary)
                                .shadow(color: Color.dsPrimary.opacity(0.20), radius: 10, x: 0, y: 4)
                        )
                    }
                    .glassPressable(scale: 0.97)
                }
                .padding(16)
                .liquidGlass(cornerRadius: 22, prominent: false)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 84) // Scrolls cleanly behind the floating Liquid Glass tab bar
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.below.square.and.square.filled")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.dsAccent)
                    Text("变更审查 · 工作区设置")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Color.dsPrimary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .liquidGlass(cornerRadius: 999, prominent: false)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .onAppear {
            workspacesText = client.workspaces.joined(separator: "\n")
            Task { await client.refreshGitDiff() }
        }
    }
}
