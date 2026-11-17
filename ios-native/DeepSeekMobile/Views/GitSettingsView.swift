import SwiftUI

struct GitSettingsView: View {
    @EnvironmentObject var client: BridgeClient
    @Binding var activeTab: MainTab
    @State private var apiKeyInput: String = ""
    @State private var newWorkspaceInput: String = ""
    @State private var cfTokenInput: String = ""
    @State private var isRestartingTunnel: Bool = false
    @State private var copiedTunnelURL: Bool = false
    @State private var savedToast: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Dedicated AI Workspace & Isolation Permission Card
                aiWorkspaceAndIsolationCard

                // 2. Cloudflare Tunnel Card (External Access Without Tailscale)
                cloudflareTunnelCard

                // 3. Git Diff Card
                gitReviewCard

                // 4. DeepSeek Model & Approval Policy Card
                deepseekSettingsCard
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 88)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.dsAccent)
                    Text("AI 工作区隔离 · 变更与设置")
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
            Task {
                await client.refreshGitDiff()
                await client.refreshTunnelStatus()
            }
        }
    }

    // MARK: - 1. AI Workspace & Isolation Permission Card

    private var aiWorkspaceAndIsolationCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.dsAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 工作区与文件隔离设置")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.dsPrimary)
                    Text("你在「文件」页可管理电脑全盘，AI 默认仅限授权工作区")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            // AI Access Mode Picker
            VStack(alignment: .leading, spacing: 6) {
                Text("AI 磁盘访问权限范围")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)

                Picker("AI 权限范围", selection: $client.aiAccessMode) {
                    Text("🔒 工作区隔离").tag("workspace_only")
                    Text("👁️ 全盘只读").tag("workspace_read_all")
                    Text("🔓 完全权限").tag("full_access")
                }
                .pickerStyle(.segmented)
                .onChange(of: client.aiAccessMode) { _ in
                    Task { try? await client.saveSettings(apiKey: "") }
                }

                Text(aiModeDescription)
                    .font(.system(size: 11.5))
                    .foregroundStyle(client.aiAccessMode == "full_access" ? Color.orange : .secondary)
                    .padding(.top, 2)
            }

            Divider().opacity(0.4)

            // Authorized Workspaces List
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("已授权的 AI 工作区目录 (\(client.workspaces.count))")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.80)) {
                            activeTab = .files
                        }
                    } label: {
                        Text("去文件页点选目录 >")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.dsAccent)
                    }
                }

                ForEach(client.workspaces, id: \.self) { ws in
                    let isActive = (ws == client.activeWorkspace)
                    HStack(spacing: 10) {
                        Image(systemName: isActive ? "checkmark.circle.fill" : "folder.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(isActive ? Color.green : Color.dsAccent)

                        VStack(alignment: .leading, spacing: 2) {
                            Text((ws as NSString).lastPathComponent.isEmpty ? ws : (ws as NSString).lastPathComponent)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(Color.dsPrimary)
                            Text(ws)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if !isActive {
                            Button {
                                Haptics.light()
                                Task { await client.authorizeWorkspace(path: ws, setActive: true) }
                            } label: {
                                Text("设为当前")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Color.dsAccent)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.white.opacity(0.75)))
                            }
                        } else {
                            Text("当前工作区")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.green.opacity(0.14)))
                        }

                        if client.workspaces.count > 1 {
                            Button {
                                Haptics.warning()
                                Task { await client.removeWorkspace(ws) }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.red.opacity(0.8))
                            }
                        }
                    }
                    .padding(10)
                    .cleanWhiteCard(cornerRadius: 14)
                }

                // Add New Workspace Path Row
                HStack(spacing: 8) {
                    TextField("输入电脑目录路径 (如 D:\\Projects)", text: $newWorkspaceInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced))
                        .padding(10)
                        .cleanWhiteCard(cornerRadius: 12)

                    Button {
                        let path = newWorkspaceInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !path.isEmpty else { return }
                        newWorkspaceInput = ""
                        Task {
                            await client.authorizeWorkspace(path: path, setActive: true)
                        }
                    } label: {
                        Text("添加并激活")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.dsPrimary))
                    }
                    .glassPressable(scale: 0.95)
                }
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 22, prominent: true)
    }

    private var aiModeDescription: String {
        switch client.aiAccessMode {
        case "full_access":
            return "⚠️ 完全权限模式：AI 被允许读写电脑 C/D/E 全盘任意文件（危险操作仍受工具审批策略控制）。"
        case "workspace_read_all":
            return "👁️ 全盘只读模式：AI 可以跨盘读取任意文件作为上下文参考，但只能在下方授权工作区内修改或新建文件。"
        default:
            return "🔒 严格隔离模式（默认）：你在手机端可自由管理电脑全盘，但 AI 仅能读写下方授权的工作区目录。"
        }
    }

    // MARK: - 2. Cloudflare External Tunnel Card

    private var cloudflareTunnelCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.dsAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("外网公网穿透 (Cloudflare Tunnel)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.dsPrimary)
                    Text("无需开启 Tailscale，不冲突小火箭；出门 5G/任意 Wi-Fi 直连")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("当前外网 HTTPS 地址 (\(client.tunnelStatus.isEmpty ? "就绪" : client.tunnelStatus))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(client.savedPublicURL.isEmpty ? "尚未获取 (连上电脑 Wi-Fi 后自动同步)" : client.savedPublicURL)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.dsPrimary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cleanWhiteCard(cornerRadius: 12)
            }

            HStack(spacing: 8) {
                Button {
                    Haptics.light()
                    if !client.savedPublicURL.isEmpty {
                        UIPasteboard.general.string = client.savedPublicURL
                        copiedTunnelURL = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copiedTunnelURL = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedTunnelURL ? "checkmark" : "doc.on.doc")
                        Text(copiedTunnelURL ? "已复制地址" : "复制外网地址")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .cleanWhiteCard(cornerRadius: 999)
                }
                .glassPressable(scale: 0.96)

                Button {
                    Haptics.medium()
                    Task {
                        isRestartingTunnel = true
                        await client.restartTunnel(cloudflaredToken: cfTokenInput)
                        cfTokenInput = ""
                        isRestartingTunnel = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text(isRestartingTunnel ? "重启中..." : "刷新 / 重建隧道")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.dsPrimary))
                }
                .glassPressable(scale: 0.96)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("可选：固定域名 Tunnel Token (\(client.hasCloudflaredToken ? "已绑定" : "默认零配置临时域名"))")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                SecureField("eyJhIjo... (留空即自动免登录穿透)", text: $cfTokenInput)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(10)
                    .cleanWhiteCard(cornerRadius: 12)
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 22, prominent: false)
    }

    // MARK: - 3. Git Diff Card

    private var gitReviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.dsAccent)
                        Text("当前工作区 Git 变更审查")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.dsPrimary)
                    }
                    Text(client.isGitRepo ? "分支: \(client.gitBranch) (\(client.activeWorkspace))" : "当前工作区尚未初始化 Git")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
            .frame(maxHeight: 200)
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
    }

    // MARK: - 3. DeepSeek & Approval Settings Card

    private var deepseekSettingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Image("DSHLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                    Text("DeepSeek 模型与工具审批")
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
                Text("AI 工具执行审批策略")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("审批策略", selection: $client.approvalMode) {
                    Text("仅命令审批").tag("ask_commands")
                    Text("写入与命令审批").tag("ask_writes")
                    Text("全自动执行").tag("auto")
                }
                .pickerStyle(.segmented)
            }

            Button {
                Haptics.medium()
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
}
