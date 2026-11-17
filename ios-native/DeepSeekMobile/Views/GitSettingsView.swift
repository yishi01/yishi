import SwiftUI
import UIKit

struct GitSettingsView: View {
    @EnvironmentObject var client: BridgeClient
    @ObservedObject private var theme = ThemePreferences.shared
    @ObservedObject private var logger = AppLogger.shared
    @Binding var activeTab: MainTab

    enum SettingsSection: String, CaseIterable {
        case appearance = "美化定制"
        case modelsSearch = "模型与搜索"
        case diagnostics = "版本与日志"
        case workspaceGit = "工作区·Git"
    }

    @State private var section: SettingsSection = .modelsSearch

    // Workspace / Tunnel / Legacy DeepSeek Inputs
    @State private var apiKeyInput: String = ""
    @State private var newWorkspaceInput: String = ""
    @State private var cfTokenInput: String = ""
    @State private var isRestartingTunnel: Bool = false
    @State private var copiedTunnelURL: Bool = false
    @State private var savedToast: Bool = false

    // Model Profile Editor Sheet
    @State private var editingProfile: ModelProfileItem?
    @State private var isNewProfile: Bool = false
    @State private var profKeyOverride: String = ""
    @State private var profTestResult: String?
    @State private var isTestingProf: Bool = false

    // Search Config State
    @State private var searchKeyInput: String = ""
    @State private var searchQueryInput: String = "DeepSeek AI"
    @State private var searchTestResp: SearchTestResponse?
    @State private var isTestingSearch: Bool = false

    // Logs State
    @State private var logSource: String = "mobile" // mobile | pc
    @State private var logLevelFilter: String = "ALL"
    @State private var logSearchQuery: String = ""
    @State private var isRunningSelfCheck: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SettingsSection.allCases, id: \.self) { sec in
                            let selected = (section == sec)
                            Button {
                                Haptics.light()
                                section = sec
                            } label: {
                                Text(sec.rawValue)
                                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                                    .foregroundStyle(selected ? .white : Color.dsPrimary)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 8)
                                    .background {
                                        if selected {
                                            Capsule().fill(theme.accentColor)
                                        } else {
                                            Capsule().fill(Color.white.opacity(0.65))
                                        }
                                    }
                            }
                            .buttonStyle(SingleTapRowButtonStyle())
                        }
                    }
                }

                switch section {
                case .appearance:
                    appearanceCard
                case .modelsSearch:
                    multiModelProfilesCard
                    searchProviderCard
                case .diagnostics:
                    versionHealthCard
                    logsViewerCard
                case .workspaceGit:
                    aiWorkspaceAndIsolationCard
                    cloudflareTunnelCard
                    gitReviewCard
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 92)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                    Text("设置扩展 · 版本与诊断")
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
                await client.loadPCDiagnostics()
                await client.loadPCLogs(level: logLevelFilter, query: logSearchQuery)
            }
        }
        .sheet(item: $editingProfile) { prof in
            modelProfileEditorSheet(initial: prof)
        }
    }

    // MARK: - 1. Appearance & Interaction Customization

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "paintbrush.fill")
                    .foregroundStyle(theme.accentColor)
                Text("外观美化与手机交互定制")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
                Spacer()
                Button("恢复默认") {
                    Haptics.light()
                    theme.resetDefaults()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.accentColor)
            }

            // Accent Theme Swatches
            VStack(alignment: .leading, spacing: 8) {
                Text("主题光晕色调")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                    ForEach(AccentThemeOption.allCases) { opt in
                        let picked = (theme.accentId == opt.rawValue)
                        Button {
                            Haptics.light()
                            theme.accentId = opt.rawValue
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(opt.color)
                                    .frame(width: 14, height: 14)
                                Text(opt.label)
                                    .font(.system(size: 12, weight: picked ? .semibold : .medium))
                                    .foregroundStyle(Color.dsPrimary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .cleanWhiteCard(cornerRadius: 12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(picked ? opt.color : .clear, lineWidth: 1.8)
                            )
                        }
                        .buttonStyle(SingleTapRowButtonStyle())
                    }
                }
            }

            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("液态玻璃通透度")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Text("\(Int(theme.glassIntensity * 100))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $theme.glassIntensity, in: 0.40...1.20, step: 0.05)
                    .tint(theme.accentColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("对话正文字体缩放")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Text(String(format: "%.2fx", theme.fontScale))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $theme.fontScale, in: 0.85...1.22, step: 0.03)
                    .tint(theme.accentColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("消息气泡圆角")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Text("\(Int(theme.bubbleRadius))pt")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $theme.bubbleRadius, in: 12...28, step: 1)
                    .tint(theme.accentColor)
            }

            Divider().opacity(0.35)

            Toggle("无操作时自动隐藏底部输入与模型栏", isOn: $theme.autoHideComposer)
                .font(.system(size: 13.5))
            if theme.autoHideComposer {
                HStack {
                    Text("无操作隐藏延迟: \(Int(theme.autoHideDelaySec))秒")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Slider(value: $theme.autoHideDelaySec, in: 2...10, step: 1)
                        .tint(theme.accentColor)
                }
            }
            Toggle("紧凑聊天间距模式", isOn: $theme.compactMode)
                .font(.system(size: 13.5))
            Toggle("启用灵动岛实时状态与确认弹窗", isOn: $theme.enableDynamicIsland)
                .font(.system(size: 13.5))
            Toggle("启用触感振动反馈 (Haptics)", isOn: $theme.enableHaptics)
                .font(.system(size: 13.5))
        }
        .padding(14)
        .liquidGlass(cornerRadius: 20, prominent: true)
    }

    // MARK: - 2. Multi-Model & Multi-Provider Configuration

    private var multiModelProfilesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "cpu.fill")
                    .foregroundStyle(theme.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("多模型与提供商配置 (支持除 DS 外的模型)")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(Color.dsPrimary)
                    Text("支持 DeepSeek、OpenAI、Claude (/v1/messages)、OpenRouter、硅基流动、Kimi 及自定义")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isNewProfile = true
                    profKeyOverride = ""
                    profTestResult = nil
                    editingProfile = ModelProfileItem(
                        id: "custom-\(Int(Date().timeIntervalSince1970 % 10000))",
                        name: "自定义模型",
                        provider: "openai_compatible",
                        baseURL: "https://api.openai.com/v1",
                        model: "gpt-4o-mini",
                        temperature: 0.7,
                        maxTokens: 8192,
                        supportsTools: true,
                        supportsReasoning: false,
                        hasAPIKey: false,
                        apiKeyMasked: "",
                        inheritsGlobalKey: false
                    )
                } label: {
                    Label("新增", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.accentColor.opacity(0.14)))
                }
            }

            ForEach(client.modelProfiles) { prof in
                let isActive = (prof.id == client.activeProfileId)
                HStack(spacing: 10) {
                    Button {
                        Task { await client.switchModelProfile(prof) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 17))
                                .foregroundStyle(isActive ? theme.accentColor : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(prof.name)
                                        .font(.system(size: 13.5, weight: isActive ? .semibold : .medium))
                                        .foregroundStyle(Color.dsPrimary)
                                    Text(providerBadge(prof.provider))
                                        .font(.system(size: 9.5, weight: .bold))
                                        .padding(.horizontal, 5.5)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                                        .foregroundStyle(theme.accentColor)
                                }
                                Text("\(prof.model) · \(prof.hasAPIKey ? "Key已配置 \(prof.apiKeyMasked)" : "未填Key")")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SingleTapRowButtonStyle())

                    Button("编辑") {
                        isNewProfile = false
                        profKeyOverride = ""
                        profTestResult = nil
                        editingProfile = prof
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                }
                .padding(10)
                .cleanWhiteCard(cornerRadius: 14)
            }

            // Global DeepSeek Key & Approval Mode Quick Row
            VStack(alignment: .leading, spacing: 6) {
                Text("全局 DeepSeek API Key (所有 DeepSeek 预设共享)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    SecureField(client.hasAPIKey ? "已配置 Key（留空保持不变）" : "输入 DeepSeek API Key...", text: $apiKeyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8.5)
                        .cleanWhiteCard(cornerRadius: 12)

                    Button("保存") {
                        Task {
                            try? await client.saveSettings(apiKey: apiKeyInput)
                            apiKeyInput = ""
                            client.showToastMessage("设置已保存")
                        }
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.dsPrimary))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("工具与插件执行审批策略")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("审批模式", selection: $client.approvalMode) {
                    Text("运行命令询问").tag("ask_commands")
                    Text("写文件与命令询问").tag("ask_writes")
                    Text("全部自动执行").tag("auto")
                }
                .pickerStyle(.segmented)
                .onChange(of: client.approvalMode) { _ in
                    Task { try? await client.saveSettings(apiKey: "") }
                }
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 20, prominent: true)
    }

    // MARK: - 3. Search Provider Configuration

    private var searchProviderCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: "magnifyingglass.circle.fill")
                    .foregroundStyle(theme.accentColor)
                Text("网页搜索商配置 (Agent 联网工具)")
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
                Spacer()
                Toggle("", isOn: $client.searchConfig.enabled)
                    .labelsHidden()
            }

            Picker("搜索提供商", selection: $client.searchConfig.provider) {
                Text("DuckDuckGo (免 Key 默认)").tag("duckduckgo")
                Text("Tavily Search").tag("tavily")
                Text("Brave Search").tag("brave")
                Text("Google Serper").tag("serper")
                Text("Bocha 博查 AI 搜索").tag("bocha")
                Text("自定义 HTTP API").tag("custom")
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .cleanWhiteCard(cornerRadius: 12)

            if client.searchConfig.provider != "duckduckgo" {
                SecureField(
                    client.searchConfig.hasAPIKey ? "已保存 Key (\(client.searchConfig.apiKeyMasked))，留空保留" : "输入搜索服务 API Key...",
                    text: $searchKeyInput
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .cleanWhiteCard(cornerRadius: 12)
            }

            if client.searchConfig.provider == "custom" {
                TextField("自定义接口 URL (如 https://example.com/search?q={query})", text: $client.searchConfig.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .cleanWhiteCard(cornerRadius: 12)
            }

            HStack {
                Text("最大返回条数: \(client.searchConfig.maxResults)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Stepper("", value: $client.searchConfig.maxResults, in: 1...12)
                    .labelsHidden()
            }

            HStack(spacing: 8) {
                Button {
                    Task {
                        try? await client.saveSearchConfig(client.searchConfig, apiKeyOverride: searchKeyInput)
                        searchKeyInput = ""
                        client.showToastMessage("搜索商配置已保存")
                    }
                } label: {
                    Text("保存搜索配置")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.dsPrimary))
                }

                Button {
                    isTestingSearch = true
                    Task {
                        searchTestResp = await client.testSearch(
                            query: searchQueryInput,
                            configOverride: client.searchConfig,
                            apiKeyOverride: searchKeyInput
                        )
                        isTestingSearch = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isTestingSearch { ProgressView().controlSize(.small) }
                        Text("测试搜索")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(theme.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .cleanWhiteCard(cornerRadius: 999)
                }
            }

            if let sr = searchTestResp {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sr.ok ? "搜索连通 (\(sr.provider), \(Int(sr.latencyMs))ms) -> 返回 \(sr.results.count) 条" : "搜索测试失败: \(sr.error)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(sr.ok ? .green : .red)
                    ForEach(sr.results.prefix(3)) { r in
                        Text("• \(r.title)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(9)
                .cleanWhiteCard(cornerRadius: 12)
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 20, prominent: false)
    }

    // MARK: - 4. Version Info, Connection Health & Self-Check

    private var versionHealthCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(theme.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("版本信息与双端运行状态")
                        .font(.system(size: 15.5, weight: .semibold))
                    Text("iOS Client v0.8.0 (Build 11) · PC Bridge v\(client.pcDiagnostics?.version ?? client.serverVersion)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                diagMetricBox("手机网络", value: client.networkInterfaceLabel)
                diagMetricBox("当前路由延迟", value: client.lastRouteLatencyMs.map { "\(Int($0)) ms" } ?? "-")
                diagMetricBox("WS 重连次数", value: "手机 \(client.wsReconnectCount) / PC \(client.pcDiagnostics?.wsReconnects ?? 0)")
                diagMetricBox("PC 内存 / 磁盘", value: "\(client.pcDiagnostics?.memoryMB.map { "\(Int($0))MB" } ?? "-") / \(client.pcDiagnostics?.diskFreeGB.map { "\(Int($0))GB" } ?? "-")")
            }

            Text("当前服务地址: \(client.normalizedBaseURL)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    isRunningSelfCheck = true
                    Task {
                        await client.loadPCDiagnostics()
                        await client.runPCSelfCheck()
                        isRunningSelfCheck = false
                    }
                } label: {
                    HStack {
                        if isRunningSelfCheck { ProgressView().controlSize(.small).tint(.white) }
                        else { Image(systemName: "stethoscope") }
                        Text("一键双端健康自检")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9.5)
                    .background(Capsule().fill(Color.dsPrimary))
                }

                Button {
                    Task {
                        await client.recoverRouteAndSocket(reason: "manual_reprobe")
                        await client.loadPCDiagnostics()
                        client.showToastMessage("已重新探测并切换最优线路")
                    }
                } label: {
                    Label("线路择优重连", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9.5)
                        .cleanWhiteCard(cornerRadius: 999)
                }
            }

            if let sc = client.selfCheckReport {
                VStack(alignment: .leading, spacing: 6) {
                    Text("自检结论: \(sc.overallStatus.uppercased()) (\(sc.checks.count) 项)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(sc.overallStatus == "ok" ? .green : (sc.overallStatus == "warn" ? .orange : .red))
                    ForEach(sc.checks) { c in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: c.status == "ok" ? "checkmark.circle.fill" : (c.status == "warn" ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"))
                                .font(.system(size: 12))
                                .foregroundStyle(c.status == "ok" ? .green : (c.status == "warn" ? .orange : .red))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(c.name) (\(Int(c.latencyMs))ms)")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(c.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(10)
                .cleanWhiteCard(cornerRadius: 12)
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 20, prominent: true)
    }

    private func diagMetricBox(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.dsPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .cleanWhiteCard(cornerRadius: 12)
    }

    private var logsViewerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(theme.accentColor)
                Text("双端运行日志监控")
                    .font(.system(size: 15.5, weight: .semibold))
                Spacer()
                Button("刷新") {
                    Task { await client.loadPCLogs(level: logLevelFilter, query: logSearchQuery) }
                }
                .font(.system(size: 12, weight: .medium))
            }

            Picker("日志来源", selection: $logSource) {
                Text("手机端本地 (\(logger.entries.count))").tag("mobile")
                Text("电脑服务端 (\(client.pcLogs.count))").tag("pc")
            }
            .pickerStyle(.segmented)
            .onChange(of: logSource) { src in
                if src == "pc" {
                    Task { await client.loadPCLogs(level: logLevelFilter, query: logSearchQuery) }
                }
            }

            HStack(spacing: 8) {
                Picker("级别", selection: $logLevelFilter) {
                    Text("全部").tag("ALL")
                    Text("INFO").tag("INFO")
                    Text("WARN").tag("WARNING")
                    Text("ERROR").tag("ERROR")
                }
                .pickerStyle(.menu)
                .onChange(of: logLevelFilter) { _ in
                    if logSource == "pc" {
                        Task { await client.loadPCLogs(level: logLevelFilter, query: logSearchQuery) }
                    }
                }

                TextField("关键字过滤...", text: $logSearchQuery)
                    .font(.system(size: 12))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .cleanWhiteCard(cornerRadius: 10)

                Button {
                    let dump: String
                    if logSource == "mobile" {
                        dump = logger.exportText()
                    } else {
                        dump = client.pcLogs.map { "[\($0.ts)] [\($0.level)] \($0.message)" }.joined(separator: "\n")
                    }
                    UIPasteboard.general.string = dump
                    client.showToastMessage("已复制全部日志到剪贴板")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13))
                        .padding(7)
                        .cleanWhiteCard(cornerRadius: 10)
                }

                Button {
                    if logSource == "mobile" {
                        logger.clear()
                    } else {
                        Task { await client.clearPCLogs() }
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .padding(7)
                        .cleanWhiteCard(cornerRadius: 10)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if logSource == "mobile" {
                        let filtered = logger.entries.reversed().filter { e in
                            (logLevelFilter == "ALL" || e.level.contains(logLevelFilter.prefix(4))) &&
                            (logSearchQuery.isEmpty || e.message.localizedCaseInsensitiveContains(logSearchQuery) || e.category.localizedCaseInsensitiveContains(logSearchQuery))
                        }
                        ForEach(Array(filtered.prefix(80))) { item in
                            Text("[\(item.formattedTime)] [\(item.level)] [\(item.category)] \(item.message)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(item.level == "ERROR" ? .red : (item.level == "WARN" ? .orange : Color.dsPrimary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        ForEach(client.pcLogs.prefix(80)) { item in
                            Text("[\(String(item.ts.suffix(12)))] [\(item.level)] \(item.message)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(item.level == "ERROR" ? .red : (item.level == "WARNING" ? .orange : Color.dsPrimary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(8)
            }
            .frame(height: 220)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.68)))
        }
        .padding(14)
        .liquidGlass(cornerRadius: 20, prominent: false)
    }

    // MARK: - 5. Workspace Isolation, Cloudflare Tunnel & Git Diff

    private var aiWorkspaceAndIsolationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 工作区与文件隔离设置")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.dsPrimary)
                    Text("你在「文件」页可管理电脑全盘，AI 默认仅限授权工作区")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            Picker("AI 权限范围", selection: $client.aiAccessMode) {
                Text("🔒 工作区隔离").tag("workspace_only")
                Text("👁️ 全盘只读").tag("workspace_read_all")
                Text("🔓 完全权限").tag("full_access")
            }
            .pickerStyle(.segmented)
            .onChange(of: client.aiAccessMode) { _ in
                Task { try? await client.saveSettings(apiKey: "") }
            }

            Text("已授权 AI 工作区列表")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(client.workspaces, id: \.self) { ws in
                let isAct = (ws == client.activeWorkspace)
                HStack(spacing: 8) {
                    Button {
                        Task { await client.authorizeWorkspace(path: ws, setActive: true) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isAct ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isAct ? theme.accentColor : .secondary)
                            Text(ws)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.dsPrimary)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(SingleTapRowButtonStyle())

                    if client.workspaces.count > 1 {
                        Button {
                            Task { await client.removeWorkspace(ws) }
                        } label: {
                            Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(.red)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .cleanWhiteCard(cornerRadius: 12)
            }

            HStack(spacing: 8) {
                TextField("添加电脑路径 (如 D:\\MyProject)", text: $newWorkspaceInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8.5)
                    .cleanWhiteCard(cornerRadius: 12)

                Button("授权") {
                    let clean = newWorkspaceInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return }
                    newWorkspaceInput = ""
                    Task { await client.authorizeWorkspace(path: clean, setActive: true) }
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 8.5)
                .background(Capsule().fill(Color.dsPrimary))
            }

            TextField("Bark 推送 URL（可选，用于审批提醒）", text: $client.barkURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 12.5))
                .padding(.horizontal, 11)
                .padding(.vertical, 8.5)
                .cleanWhiteCard(cornerRadius: 12)
        }
        .padding(14)
        .liquidGlass(cornerRadius: 20, prominent: true)
    }

    private var cloudflareTunnelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "globe.asia.australia.fill")
                    .foregroundStyle(theme.accentColor)
                Text("Cloudflare 公网穿透隧道")
                    .font(.system(size: 15.5, weight: .semibold))
                Spacer()
                let isTunnelOnline = (client.tunnelStatus == "connected" || client.tunnelStatus == "running")
                Text(isTunnelOnline ? "在线" : (client.tunnelStatus.isEmpty ? "检查中" : client.tunnelStatus))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isTunnelOnline ? .green : .orange)
            }

            if !client.savedPublicURL.isEmpty {
                HStack {
                    Text(client.savedPublicURL)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color.dsPrimary)
                        .lineLimit(1)
                    Spacer()
                    Button(copiedTunnelURL ? "已复制" : "复制") {
                        UIPasteboard.general.string = client.savedPublicURL
                        copiedTunnelURL = true
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                }
                .padding(9)
                .cleanWhiteCard(cornerRadius: 12)
            }

            HStack(spacing: 8) {
                SecureField(client.hasCloudflaredToken ? "已配置固定 Tunnel Token（留空使用免费临时域名）" : "可选：绑定 Cloudflare 固定隧道 Token", text: $cfTokenInput)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .cleanWhiteCard(cornerRadius: 12)

                Button {
                    isRestartingTunnel = true
                    Task {
                        await client.restartTunnel(cloudflaredToken: cfTokenInput)
                        cfTokenInput = ""
                        isRestartingTunnel = false
                    }
                } label: {
                    Text(isRestartingTunnel ? "重连中" : "重启隧道")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8.5)
                        .background(Capsule().fill(Color.dsPrimary))
                }
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 20, prominent: false)
    }

    private var gitReviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(theme.accentColor)
                Text("Git 变更审查 (\(client.gitBranch.isEmpty ? "非 Git" : client.gitBranch))")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("刷新") {
                    Task { await client.refreshGitDiff() }
                }
                .font(.system(size: 12))

                Button("退出登录", role: .destructive) {
                    client.logout()
                }
                .font(.system(size: 12))
                .foregroundStyle(.red)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(client.gitDiff.isEmpty ? "当前工作区无未提交变更" : client.gitDiff)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.dsPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .cleanWhiteCard(cornerRadius: 12)
        }
        .padding(14)
        .liquidGlass(cornerRadius: 20, prominent: false)
    }

    // MARK: - Profile Editor Sheet

    private func modelProfileEditorSheet(initial: ModelProfileItem) -> some View {
        ModelProfileEditorView(
            profile: initial,
            isNew: isNewProfile,
            onSave: { updated, newKey in
                var list = client.modelProfiles
                if let idx = list.firstIndex(where: { $0.id == updated.id }) {
                    list[idx] = updated
                } else {
                    list.append(updated)
                }
                try await client.saveModelProfiles(
                    list,
                    activeId: isNewProfile ? updated.id : nil,
                    apiKeyOverrides: newKey.isEmpty ? [:] : [updated.id: newKey]
                )
            },
            onDelete: { id in
                var list = client.modelProfiles.filter { $0.id != id }
                guard !list.isEmpty else { return }
                let nextActive = (client.activeProfileId == id) ? list[0].id : client.activeProfileId
                try await client.saveModelProfiles(list, activeId: nextActive)
            }
        )
        .environmentObject(client)
    }

    private func providerBadge(_ p: String) -> String {
        switch p {
        case "anthropic": return "Anthropic"
        case "gemini_openai": return "Gemini"
        default: return "OpenAI兼容"
        }
    }
}

private struct ModelProfileEditorView: View {
    @EnvironmentObject var client: BridgeClient
    @Environment(\.dismiss) private var dismiss

    @State var profile: ModelProfileItem
    let isNew: Bool
    var onSave: (ModelProfileItem, String) async throws -> Void
    var onDelete: (String) async throws -> Void

    @State private var apiKeyInput: String = ""
    @State private var testStatus: String?
    @State private var isTesting: Bool = false
    @State private var errText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("基础信息") {
                    TextField("显示名称", text: $profile.name)
                    Picker("协议类型", selection: $profile.provider) {
                        Text("OpenAI 兼容 (/chat/completions)").tag("openai_compatible")
                        Text("Anthropic Claude (/v1/messages)").tag("anthropic")
                        Text("Gemini OpenAI 兼容").tag("gemini_openai")
                    }
                    TextField("模型 Model ID (如 deepseek-chat / claude-sonnet-4-5)", text: $profile.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("API Base URL", text: $profile.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section("鉴权密钥 (安全保存于电脑端)") {
                    SecureField(
                        profile.hasAPIKey ? "已保存密钥 \(profile.apiKeyMasked)（留空保留）" : "输入该提供商 API Key...",
                        text: $apiKeyInput
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }

                Section("推理与能力参数") {
                    HStack {
                        Text("采样温度 Temperature")
                        Spacer()
                        Text(String(format: "%.2f", profile.temperature))
                            .font(.system(.body, design: .monospaced))
                    }
                    Slider(value: $profile.temperature, in: 0.0...1.5, step: 0.05)
                    Stepper("最大输出 Tokens: \(profile.maxTokens)", value: $profile.maxTokens, in: 1024...32768, step: 1024)
                    Toggle("启用工具调用 (Tools)", isOn: $profile.supportsTools)
                    Toggle("思考模型 (Reasoning)", isOn: $profile.supportsReasoning)
                }

                Section {
                    Button {
                        isTesting = true
                        testStatus = nil
                        Task {
                            let res = await client.testModelProfile(profile, apiKeyOverride: apiKeyInput)
                            testStatus = "\(res.ok ? "✅" : "❌") \(res.detail) (\(Int(res.latencyMs))ms)"
                            isTesting = false
                        }
                    } label: {
                        HStack {
                            if isTesting { ProgressView().controlSize(.small) }
                            Text("测试接口连通性")
                        }
                    }
                    if let testStatus = testStatus {
                        Text(testStatus).font(.system(size: 12))
                    }
                }

                if !isNew && client.modelProfiles.count > 1 {
                    Section {
                        Button("删除该模型配置", role: .destructive) {
                            Task {
                                try? await onDelete(profile.id)
                                dismiss()
                            }
                        }
                    }
                }

                if let errText = errText {
                    Section {
                        Text(errText).foregroundStyle(.red).font(.system(size: 12))
                    }
                }
            }
            .navigationTitle(isNew ? "新增模型配置" : "编辑模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            do {
                                try await onSave(profile, apiKeyInput)
                                dismiss()
                            } catch {
                                errText = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
    }
}
