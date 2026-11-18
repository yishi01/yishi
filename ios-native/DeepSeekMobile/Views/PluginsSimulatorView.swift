import SwiftUI
import UniformTypeIdentifiers
import WebKit

private struct SandboxHTMLWebView: UIViewRepresentable {
    let html: String

    final class Coordinator {
        var lastLoadedHTML: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = .clear
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastLoadedHTML != html {
            context.coordinator.lastLoadedHTML = html
            uiView.loadHTMLString(html, baseURL: nil)
        }
    }
}

struct PluginsSimulatorView: View {
    @EnvironmentObject var client: BridgeClient
    @ObservedObject private var theme = ThemePreferences.shared

    enum SubTab: String, CaseIterable {
        case plugins = "DSH 插件 · 电脑端"
        case simulator = "模拟器 · 不可信代码自检"
    }

    @State private var subTab: SubTab = .plugins

    // Plugins UI State (No Marketplace)
    @State private var showUploadImporter: Bool = false
    @State private var showInstallSheet: Bool = false
    @State private var editingPlugin: PCPluginItem?
    @State private var editingConfigText: String = "{}"
    @State private var editingEnvText: String = "{}"
    @State private var editingPatch: DSHPatchItem?
    @State private var editingPatchJSON: String = "{}"
    @State private var dshSpecInput: String = ""
    @State private var dshInstallOutput: String = ""
    @State private var isInstallingDSH: Bool = false
    @State private var pluginRunOutput: PluginRunResult?
    @State private var pluginError: String?

    // Simulator & Security Self-Check State
    @State private var codeInput: String = """
import os, json
print("Hello from DSH Sandbox!")
print("DEEPSEEK_API_KEY:", os.environ.get("DEEPSEEK_API_KEY", "已被安全剥离"))
"""
    @State private var language: String = "python"
    @State private var allowNetwork: Bool = false
    @State private var timeoutSec: Double = 10
    @State private var isAuditing: Bool = false
    @State private var isSimulating: Bool = false
    @State private var auditReport: SandboxAuditReport?
    @State private var runResult: SandboxRunResult?
    @State private var simError: String?
    @State private var showHTMLPreviewSheet: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("模式", selection: $subTab) {
                    ForEach(SubTab.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)

                if subTab == .plugins {
                    pluginsSection
                } else {
                    simulatorSection
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 92)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: subTab == .plugins ? "puzzlepiece.extension.fill" : "shield.checkerboard")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                    Text(subTab == .plugins ? "DSH 插件系统（手机配置 · 电脑执行）" : "脚本模拟器 & 不可信代码自检")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.dsPrimary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .liquidGlass(cornerRadius: 999, prominent: false)
                Spacer()
                if subTab == .plugins {
                    Button {
                        Haptics.light()
                        Task { await client.loadPlugins() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.dsPrimary)
                            .frame(width: 36, height: 36)
                            .cleanWhiteCard(cornerRadius: 999)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .onAppear {
            Task { await client.loadPlugins() }
        }
        .fileImporter(
            isPresented: $showUploadImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    do {
                        try await client.installPluginUpload(fileURL: url)
                        client.showToastMessage("已上传安装到电脑端插件目录")
                    } catch {
                        pluginError = error.localizedDescription
                    }
                }
            }
        }
        .sheet(isPresented: $showInstallSheet) {
            PluginInstallModalSheet()
                .environmentObject(client)
        }
        .sheet(item: $editingPlugin) { plugin in
            pluginConfigSheet(plugin)
        }
        .sheet(item: $editingPatch) { patch in
            dshPatchConfigSheet(patch)
        }
        .sheet(isPresented: $showHTMLPreviewSheet) {
            NavigationStack {
                SandboxHTMLWebView(html: runResult?.previewHTML ?? codeInput)
                    .navigationTitle("HTML 沙箱实时预览")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { showHTMLPreviewSheet = false }
                        }
                    }
            }
        }
    }

    // MARK: - 1. DSH Plugins Management (Zero Marketplace)

    private var pluginsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let err = pluginError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(err).font(.system(size: 12)).foregroundStyle(.red)
                    Spacer()
                    Button("关闭") { pluginError = nil }.font(.system(size: 11.5))
                }
                .padding(11)
                .cleanWhiteCard(cornerRadius: 14)
            }

            // Actions Card (Install from Phone / Git / Local / Create)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("安装与导入插件到电脑")
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(Color.dsPrimary)
                        Text("支持从手机上传 .zip/.py/.js/SKILL.md、Git 克隆或创建脚本插件，全部在电脑运行")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        Haptics.light()
                        showUploadImporter = true
                    } label: {
                        Label("手机上传安装", systemImage: "arrow.up.doc.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9.5)
                            .background(Capsule().fill(Color.dsPrimary))
                    }
                    .glassPressable(scale: 0.96)

                    Button {
                        Haptics.light()
                        showInstallSheet = true
                    } label: {
                        Label("路径 / Git / 新建", systemImage: "plus.circle.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(theme.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9.5)
                            .cleanWhiteCard(cornerRadius: 999)
                    }
                    .glassPressable(scale: 0.96)
                }
            }
            .padding(14)
            .liquidGlass(cornerRadius: 20, prominent: true)

            // Installed Bridge PC Plugins
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("已安装的电脑端插件 (\(client.plugins.count))")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.dsPrimary)
                    Spacer()
                    Text("AI 对话自动注入")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if client.plugins.isEmpty {
                    Text("暂无独立桥接插件。可点击上方「手机上传安装」或「新建」添加 Python/Node/SKILL.md 插件。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(client.plugins) { p in
                        pluginRowCard(p)
                    }
                }
            }
            .padding(14)
            .liquidGlass(cornerRadius: 20, prominent: false)

            if let res = pluginRunOutput {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("电脑执行结果: \(res.pluginId) · \(res.tool)", systemImage: res.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(res.ok ? .green : .red)
                        Spacer()
                        Text("\(Int(res.durationMs)) ms · code \(res.exitCode)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button("关闭") { pluginRunOutput = nil }.font(.system(size: 11.5))
                    }
                    Text(res.stdout.isEmpty ? res.stderr : res.stdout + (res.stderr.isEmpty ? "" : "\n--- stderr ---\n" + res.stderr))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color.dsPrimary)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.65)))
                }
                .padding(12)
                .liquidGlass(cornerRadius: 18, prominent: true)
            }

            // Native PC DSH Desktop Profile Integration
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(theme.accentColor)
                    Text("电脑本地 DSH Profile 配置")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.dsPrimary)
                    Spacer()
                    Text(client.dshProfile.exists ? "已关联" : "未找到")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(client.dshProfile.exists ? .green : .orange)
                }

                if client.dshProfile.exists {
                    Text("目录: \(client.dshProfile.profileDir)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)

                    // Direct Spec Install into PC DSH Profile (No Marketplace)
                    HStack(spacing: 8) {
                        TextField("直接输入 DSH 插件包名 / 路径 / Git 地址...", text: $dshSpecInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .cleanWhiteCard(cornerRadius: 12)

                        Button {
                            let spec = dshSpecInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !spec.isEmpty else { return }
                            isInstallingDSH = true
                            Task {
                                do {
                                    dshInstallOutput = try await client.installDSHPackage(spec: spec)
                                    dshSpecInput = ""
                                } catch {
                                    pluginError = error.localizedDescription
                                }
                                isInstallingDSH = false
                            }
                        } label: {
                            if isInstallingDSH {
                                ProgressView().controlSize(.small).frame(width: 60)
                            } else {
                                Text("电脑安装")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(Color.dsPrimary))
                            }
                        }
                    }

                    if !dshInstallOutput.isEmpty {
                        Text(dshInstallOutput)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                    }

                    if !client.dshProfile.bundles.isEmpty {
                        Text("DSH 组合包 (Bundles)")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(client.dshProfile.bundles) { b in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.name)
                                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.dsPrimary)
                                    if !b.description.isEmpty {
                                        Text(b.description)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { b.enabled },
                                    set: { newVal in
                                        Task { try? await client.toggleDSHEntry(kind: "bundle", id: b.name, enabled: newVal) }
                                    }
                                ))
                                .labelsHidden()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .cleanWhiteCard(cornerRadius: 12)
                        }
                    }

                    if !client.dshProfile.patches.isEmpty {
                        Text("Cordis Patch 覆盖项")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(client.dshProfile.patches) { pt in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pt.id)
                                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                    Text(pt.name)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("配置") {
                                    editingPatchJSON = pt.configJSON
                                    editingPatch = pt
                                }
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(theme.accentColor)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4.5)
                                .background(Capsule().fill(theme.accentColor.opacity(0.12)))

                                Toggle("", isOn: Binding(
                                    get: { pt.enabled },
                                    set: { newVal in
                                        Task { try? await client.toggleDSHEntry(kind: "patch", id: pt.id, enabled: newVal) }
                                    }
                                ))
                                .labelsHidden()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .cleanWhiteCard(cornerRadius: 12)
                        }
                    }
                } else {
                    Text("未在本机默认路径检测到 `~/.dsh/profiles/desktop`，可在上方使用手机独立安装与管理电脑端插件。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .liquidGlass(cornerRadius: 20, prominent: false)
        }
    }

    private func pluginRowCard(_ p: PCPluginItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.dsPrimary)
                        Text("v\(p.version)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if p.isDSHBundle {
                            Text("DSH")
                                .font(.system(size: 9.5, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(theme.accentColor.opacity(0.15)))
                                .foregroundStyle(theme.accentColor)
                        }
                    }
                    Text(p.description.isEmpty ? p.source : p.description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { p.enabled },
                    set: { val in Task { try? await client.togglePlugin(id: p.id, enabled: val) } }
                ))
                .labelsHidden()
            }

            HStack(spacing: 8) {
                if !p.skills.isEmpty {
                    Label("\(p.skills.count) 技能", systemImage: "sparkles")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.accentColor)
                }
                if !p.tools.isEmpty {
                    Label("\(p.tools.count) PC脚本", systemImage: "terminal")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if p.enabled && !p.tools.isEmpty {
                    Button {
                        Haptics.medium()
                        Task {
                            do {
                                pluginRunOutput = try await client.runPluginOnPC(id: p.id)
                            } catch {
                                pluginError = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("电脑执行", systemImage: "play.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.dsPrimary))
                    }
                }

                Button("配置") {
                    editingConfigText = p.configJSON
                    editingEnvText = p.envJSON
                    editingPlugin = p
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(theme.accentColor.opacity(0.12)))

                Button {
                    Task { try? await client.deletePlugin(id: p.id) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(6)
                }
            }
        }
        .padding(11)
        .cleanWhiteCard(cornerRadius: 15)
    }

    // MARK: - 2. Sandbox Simulator & Untrusted Code Self-Check

    private var simulatorSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text("沙箱隔离策略：自动剥离宿主机 API Key 与 Auth Token")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dsPrimary)
                }

                HStack(spacing: 8) {
                    Picker("语言", selection: $language) {
                        Text("Python").tag("python")
                        Text("Node.js").tag("javascript")
                        Text("PowerShell").tag("powershell")
                        Text("HTML 预览").tag("html")
                        Text("Bash").tag("bash")
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .cleanWhiteCard(cornerRadius: 999)

                    Menu("载入示例") {
                        Button("安全沙箱环境变量检测") {
                            language = "python"
                            codeInput = "import os\nprint('USERPROFILE=', os.environ.get('USERPROFILE'))\nprint('API_KEY=', os.environ.get('DEEPSEEK_API_KEY', 'STRIPPED'))\nprint('SANDBOX=', os.environ.get('DSH_SANDBOX'))"
                        }
                        Button("高风险代码自检样本") {
                            language = "python"
                            codeInput = "import os, subprocess\nos.system('whoami')\nsubprocess.run(['dir'], shell=True)\nsecret = open(os.path.expanduser('~/.ssh/id_rsa')).read()"
                        }
                        Button("HTML/Canvas 交互小工具") {
                            language = "html"
                            codeInput = "<!DOCTYPE html><html><body style='font-family:-apple-system;padding:20px;background:#f4f7ff;'><h2>DSH 手机沙箱预览</h2><button onclick='document.getElementById(\"out\").innerText=new Date().toLocaleTimeString()' style='padding:10px 16px;border-radius:12px;background:#3b6ef8;color:#fff;border:none;'>点击测时</button><p id='out'>等待点击...</p></body></html>"
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.accentColor)

                    Spacer()
                }

                TextEditor(text: $codeInput)
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(minHeight: 160, maxHeight: 240)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.85)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.06), lineWidth: 1))

                HStack {
                    Toggle("允许外网通信", isOn: $allowNetwork)
                        .font(.system(size: 12))
                    Spacer()
                    Text("超时 \(Int(timeoutSec))s")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Stepper("", value: $timeoutSec, in: 3...30, step: 2)
                        .labelsHidden()
                }

                if let err = simError {
                    Text(err).font(.system(size: 12)).foregroundStyle(.red)
                }

                HStack(spacing: 10) {
                    Button {
                        Haptics.light()
                        simError = nil
                        isAuditing = true
                        Task {
                            do {
                                auditReport = try await client.auditUntrustedCode(code: codeInput, language: language)
                            } catch {
                                simError = error.localizedDescription
                            }
                            isAuditing = false
                        }
                    } label: {
                        HStack {
                            if isAuditing { ProgressView().controlSize(.small) }
                            else { Image(systemName: "shield.lefthalf.filled.badge.checkmark") }
                            Text("不可信代码自检")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(theme.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .cleanWhiteCard(cornerRadius: 999)
                    }

                    Button {
                        Haptics.medium()
                        simError = nil
                        isSimulating = true
                        Task {
                            do {
                                let res = try await client.runSandboxScript(
                                    code: codeInput,
                                    language: language,
                                    timeoutSec: Int(timeoutSec),
                                    allowNetwork: allowNetwork
                                )
                                runResult = res
                                auditReport = res.audit
                            } catch {
                                simError = error.localizedDescription
                            }
                            isSimulating = false
                        }
                    } label: {
                        HStack {
                            if isSimulating { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: "play.circle.fill") }
                            Text(language == "html" ? "自检并渲染" : "沙箱模拟运行")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.dsPrimary))
                    }
                }
            }
            .padding(14)
            .liquidGlass(cornerRadius: 20, prominent: true)

            if let audit = auditReport {
                auditReportCard(audit)
            }

            if let res = runResult {
                runResultCard(res)
            }
        }
    }

    private func auditReportCard(_ audit: SandboxAuditReport) -> some View {
        let color: Color = {
            switch audit.riskLevel {
            case "critical", "high": return .red
            case "medium": return .orange
            case "low": return .blue
            default: return .green
            }
        }()
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("安全自检报告 · 风险等级: \(audit.riskLevel.uppercased())", systemImage: "shield.checkered")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                Spacer()
                Text("风险分 \(audit.score)/100")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
            }

            Text(audit.summary)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.dsPrimary)

            ForEach(audit.findings) { f in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("L\(f.line) · \(f.category)")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(f.severity == "high" || f.severity == "critical" ? .red : .orange)
                        Spacer()
                        Text(f.severity.uppercased())
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(f.message)
                        .font(.system(size: 11.5))
                    if !f.snippet.isEmpty {
                        Text(f.snippet)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(9)
                .cleanWhiteCard(cornerRadius: 11)
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 20, prominent: false)
    }

    private func runResultCard(_ res: SandboxRunResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(res.ok ? "模拟执行成功" : "模拟执行异常", systemImage: res.ok ? "terminal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(res.ok ? .green : .red)
                Spacer()
                Text("耗时 \(Int(res.durationMs))ms · 退出码 \(res.exitCode)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if !res.previewHTML.isEmpty {
                Button {
                    showHTMLPreviewSheet = true
                } label: {
                    Label("打开全屏 HTML 沙箱渲染视图", systemImage: "safari.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(theme.accentColor))
                }
            }

            if !res.stdout.isEmpty {
                Text("STDOUT:\n" + res.stdout)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.dsPrimary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.75)))
            }

            if !res.stderr.isEmpty {
                Text("STDERR:\n" + res.stderr)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.08)))
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 20, prominent: true)
    }

    // MARK: - Config Modals

    private func pluginConfigSheet(_ plugin: PCPluginItem) -> some View {
        NavigationStack {
            Form {
                Section("插件信息") {
                    LabeledContent("ID", value: plugin.id)
                    LabeledContent("路径", value: plugin.path)
                    LabeledContent("来源", value: plugin.source)
                }
                Section("JSON Config (注入 DSH_PLUGIN_CONFIG)") {
                    TextEditor(text: $editingConfigText)
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(minHeight: 130)
                }
                Section("环境变量 Env JSON (仅用于电脑执行该插件)") {
                    TextEditor(text: $editingEnvText)
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(minHeight: 100)
                }
            }
            .navigationTitle("配置 \(plugin.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { editingPlugin = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            do {
                                try await client.updatePluginConfig(
                                    id: plugin.id,
                                    configJSON: editingConfigText,
                                    envJSON: editingEnvText
                                )
                                editingPlugin = nil
                            } catch {
                                pluginError = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
    }

    private func dshPatchConfigSheet(_ patch: DSHPatchItem) -> some View {
        NavigationStack {
            Form {
                Section("DSH Patch Entry") {
                    LabeledContent("ID", value: patch.id)
                    LabeledContent("模块名", value: patch.name)
                }
                Section("Config JSON (写入 cordis.patch.yml)") {
                    TextEditor(text: $editingPatchJSON)
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(minHeight: 160)
                }
            }
            .navigationTitle("配置 DSH 条目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { editingPatch = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            do {
                                try await client.updateDSHPatchConfig(entryId: patch.id, configJSON: editingPatchJSON)
                                editingPatch = nil
                            } catch {
                                pluginError = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct PluginInstallModalSheet: View {
    @EnvironmentObject var client: BridgeClient
    @Environment(\.dismiss) private var dismiss

    @State private var mode: String = "inline" // inline | git | local_path
    @State private var name: String = ""
    @State private var desc: String = ""
    @State private var skillMD: String = "---\nname: my-plugin\ndescription: Custom PC plugin\n---\n\n# Usage\nDescribe steps."
    @State private var scriptCode: String = "import os, sys\nprint('Executed on PC!', sys.argv[1:])"
    @State private var scriptLang: String = "python"
    @State private var gitURL: String = ""
    @State private var localPath: String = ""
    @State private var errText: String?
    @State private var isWorking: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("安装方式", selection: $mode) {
                    Text("新建脚本/技能").tag("inline")
                    Text("Git 克隆到电脑").tag("git")
                    Text("导入电脑本地目录").tag("local_path")
                }

                Section("基本信息") {
                    TextField("插件名称 (如 log-analyzer)", text: $name)
                        .textInputAutocapitalization(.never)
                    if mode == "inline" {
                        TextField("功能简介", text: $desc)
                    }
                }

                if mode == "inline" {
                    Section("PC 执行脚本") {
                        Picker("脚本语言", selection: $scriptLang) {
                            Text("Python (.py)").tag("python")
                            Text("Node.js (.js)").tag("javascript")
                            Text("PowerShell (.ps1)").tag("powershell")
                        }
                        TextEditor(text: $scriptCode)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 110)
                    }
                    Section("SKILL.md 说明 (供 AI 识别调用)") {
                        TextEditor(text: $skillMD)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 90)
                    }
                } else if mode == "git" {
                    Section("Git 仓库地址") {
                        TextField("https://github.com/user/plugin-repo.git", text: $gitURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } else {
                    Section("电脑本地目录/文件路径") {
                        TextField("例如 C:\\Users\\...\\my-plugin", text: $localPath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if let errText = errText {
                    Section {
                        Text(errText).foregroundStyle(.red).font(.system(size: 12))
                    }
                }
            }
            .navigationTitle("添加 PC 插件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isWorking ? "处理中..." : "安装") {
                        isWorking = true
                        errText = nil
                        Task {
                            do {
                                if mode == "git" {
                                    try await client.installPluginFromGit(url: gitURL, name: name)
                                } else if mode == "local_path" {
                                    try await client.installPluginFromLocalPath(path: localPath, name: name)
                                } else {
                                    try await client.installPluginInline(
                                        name: name,
                                        description: desc,
                                        skillMD: skillMD,
                                        scriptCode: scriptCode,
                                        language: scriptLang,
                                        configJSON: "{}"
                                    )
                                }
                                dismiss()
                            } catch {
                                errText = error.localizedDescription
                            }
                            isWorking = false
                        }
                    }
                    .disabled(isWorking)
                }
            }
        }
    }
}
