import Foundation
import Network
import SwiftUI

@MainActor
final class BridgeClient: ObservableObject {
    static let defaultToken = "_44dVxHP8puOv1RjHTb-uWrgb5LY4k6s"
    static let initialCloudflareURL = "https://patterns-traveller-replied-parallel.trycloudflare.com"
    static let defaultPresetURLs: [(label: String, url: String)] = [
        ("Wi-Fi 局域网直连", "http://192.168.31.190:8765"),
        ("Tailscale 域名", "http://dsh-pc"),
        ("Tailscale 直连 IP", "http://100.88.121.40:8765"),
        ("Tailscale HTTPS", "https://dsh-pc.tail1e24af.ts.net"),
    ]

    @AppStorage("ds_server_url") var serverURL: String = "http://192.168.31.190:8765"
    @AppStorage("ds_public_url") var savedPublicURL: String = ""
    @AppStorage("ds_auth_token") var authToken: String = "_44dVxHP8puOv1RjHTb-uWrgb5LY4k6s"
    @AppStorage("ds_active_workspace") var activeWorkspace: String = ""
    @AppStorage("ds_active_session_id") var activeSessionId: String = ""

    @Published var isAuthenticated: Bool = false
    @Published var isConnecting: Bool = false
    @Published var isConnected: Bool = false
    @Published var authError: String?
    @Published var probeDiagnostics: [String] = []
    @Published var globalToast: String?

    // Network & Stability Telemetry
    @Published var networkInterfaceLabel: String = "检测中"
    @Published var wsReconnectCount: Int = 0
    @Published var lastRouteLatencyMs: Double?
    @Published var serverVersion: String = ""

    // Settings, Model Profiles & Search Config
    @Published var workspaces: [String] = []
    @Published var aiAccessMode: String = "workspace_only"
    @Published var selectedModel: String = "deepseek-flash"
    @Published var activeProfileId: String = "deepseek-flash"
    @Published var modelProfiles: [ModelProfileItem] = []
    @Published var approvalMode: String = "ask_commands"
    @Published var deepseekBaseURL: String = "https://api.deepseek.com"
    @Published var barkURL: String = ""
    @Published var hasAPIKey: Bool = false
    @Published var enableTunnel: Bool = true
    @Published var hasCloudflaredToken: Bool = false
    @Published var tunnelStatus: String = ""
    @Published var searchConfig: SearchConfigItem = SearchConfigItem()
    @Published var dshProfileDir: String = ""

    // Sessions, Chat Turns, Queue & Review Approvals
    @Published var sessions: [SessionSummaryItem] = []
    @Published var turns: [ChatTurnItem] = []
    @Published var pendingApprovals: [PendingApprovalItem] = []
    @Published var activeApprovalForPopup: PendingApprovalItem?
    @Published var queuedMessages: [QueuedMessageItem] = []
    @Published var sessionStatus: String = "idle"

    // Full PC File Manager State
    @Published var pcDrives: [PCDriveItem] = []
    @Published var pcShortcuts: [PCShortcutItem] = []
    @Published var currentDir: String = ""
    @Published var currentParentDir: String = ""
    @Published var currentDrive: String = "C:"
    @Published var currentDirInAIWorkspace: Bool = false
    @Published var showHiddenFiles: Bool = false
    @Published var fileEntries: [FileEntryItem] = []
    @Published var isLoadingDirectory: Bool = false
    @Published var clipboard: FileClipboardItem?
    @Published var fileError: String?

    // Plugins & Sandbox
    @Published var plugins: [PCPluginItem] = []
    @Published var dshProfile: DSHProfileStatus = DSHProfileStatus()

    // Diagnostics & Logs
    @Published var pcDiagnostics: PCDiagnosticsStatus?
    @Published var pcLogs: [PCLogEntry] = []
    @Published var selfCheckReport: SelfCheckReport?

    // Git & Cross-Tab References
    @Published var gitBranch: String = ""
    @Published var gitDiff: String = ""
    @Published var isGitRepo: Bool = false
    @Published var referencedFilePath: String?
    @Published var activeArtifactForReview: FileArtifactItem?

    private var lastSeq: Int = 0
    private var webSocketTask: URLSessionWebSocketTask?
    private var wsGeneration: UInt64 = 0
    private var wsHeartbeatTask: Task<Void, Never>?
    private var wsReconnectTask: Task<Void, Never>?
    private var lastWSActivityAt: Date = Date()
    private var consecutiveWSErrors: Int = 0
    private var wsSynced: Bool = false
    private var connectAttemptId: UUID = UUID()
    private var failoverTask: Task<String?, Never>?
    private var pcDirToken: UInt64 = 0

    private let pathMonitor = NWPathMonitor()
    private var lastNetworkSignature: String = ""

    var effectivePresetURLs: [(label: String, url: String)] {
        var list: [(label: String, url: String)] = []
        let pub = savedPublicURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pub.isEmpty {
            list.append(("Cloudflare 外网公网", pub))
        } else if !Self.initialCloudflareURL.isEmpty {
            list.append(("Cloudflare 外网公网", Self.initialCloudflareURL))
        }
        list.append(contentsOf: Self.defaultPresetURLs)
        return list
    }

    private lazy var probeSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 3.5
        cfg.timeoutIntervalForResource = 4.5
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private lazy var apiSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    var normalizedBaseURL: String {
        Self.normalizeURL(serverURL)
    }

    static func normalizeURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = "http://192.168.31.190:8765" }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    init() {
        setupNetworkMonitor()
    }

    deinit {
        pathMonitor.cancel()
    }

    private func setupNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let iface: String
            if path.status != .satisfied {
                iface = "无网络"
            } else if path.usesInterfaceType(.wifi) {
                iface = "Wi-Fi"
            } else if path.usesInterfaceType(.cellular) {
                iface = "蜂窝 5G/4G"
            } else if path.usesInterfaceType(.wiredEthernet) {
                iface = "有线网络"
            } else {
                iface = "VPN/其他"
            }
            let sig = "\(path.status)-\(iface)"
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let old = self.lastNetworkSignature
                self.lastNetworkSignature = sig
                self.networkInterfaceLabel = iface
                if !old.isEmpty && old != sig && path.status == .satisfied {
                    AppLogger.shared.info("Network", "网络切换至 \(iface)，准备刷新连接路由")
                    if self.isAuthenticated {
                        await self.recoverRouteAndSocket(reason: "network_\(iface)")
                    }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.agy.deepseek.nwmonitor"))
    }

    func showToastMessage(_ text: String) {
        globalToast = text
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if globalToast == text {
                globalToast = nil
            }
        }
    }

    func bootstrap() async {
        if authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            authToken = Self.defaultToken
        }
        await verifyAndLogin(url: serverURL, token: authToken)
    }

    func verifyAndLogin(url: String, token: String) async {
        let attemptId = UUID()
        connectAttemptId = attemptId
        isConnecting = true
        authError = nil
        probeDiagnostics = []

        let rawURL = Self.normalizeURL(url)
        let rawTok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveToken = rawTok.isEmpty ? Self.defaultToken : rawTok
        self.authToken = effectiveToken

        var candidates: [String] = [rawURL]
        for item in effectivePresetURLs {
            if !candidates.contains(item.url) {
                candidates.append(item.url)
            }
        }

        guard let body = try? JSONSerialization.data(withJSONObject: ["token": effectiveToken]) else {
            if connectAttemptId == attemptId {
                isConnecting = false
                authError = "请求参数构造失败"
            }
            return
        }

        let session = probeSession

        enum ProbeOutcome: Sendable {
            case success(url: String, data: Data, latencyMs: Double)
            case failure(url: String, reason: String)
        }

        var winningURL: String?
        var winningData: Data?
        var winningLatency: Double?
        var failures: [(String, String)] = []

        await withTaskGroup(of: ProbeOutcome.self) { group in
            for candidate in candidates {
                group.addTask {
                    guard let endpoint = URL(string: candidate + "/api/auth/verify") else {
                        return .failure(url: candidate, reason: "无效地址")
                    }
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 3.5
                    req.httpBody = body
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let t0 = Date()
                    do {
                        let (data, resp) = try await session.data(for: req)
                        let ms = Date().timeIntervalSince(t0) * 1000.0
                        if let http = resp as? HTTPURLResponse {
                            if http.statusCode == 200 {
                                return .success(url: candidate, data: data, latencyMs: ms)
                            } else if http.statusCode == 401 {
                                return .failure(url: candidate, reason: "Auth Token 错误 (401)")
                            } else {
                                return .failure(url: candidate, reason: "HTTP \(http.statusCode)")
                            }
                        }
                        return .failure(url: candidate, reason: "响应无效")
                    } catch {
                        return .failure(url: candidate, reason: error.localizedDescription)
                    }
                }
            }

            for await outcome in group {
                switch outcome {
                case .success(let okURL, let okData, let ms):
                    winningURL = okURL
                    winningData = okData
                    winningLatency = ms
                    group.cancelAll()
                case .failure(let badURL, let reason):
                    failures.append((badURL, reason))
                }
                if winningURL != nil { break }
            }
        }

        guard connectAttemptId == attemptId else { return }

        if let okURL = winningURL, let data = winningData {
            self.serverURL = okURL
            self.lastRouteLatencyMs = winningLatency
            AppLogger.shared.info("Auth", "并发路由测速成功 -> \(okURL) (\(Int(winningLatency ?? 0))ms)")
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let settings = json["settings"] as? [String: Any] {
                applySettings(settings)
            }
            isAuthenticated = true
            isConnecting = false
            Haptics.success()
            await loadSessions()
            await loadPCDrives()
            await loadPCDirectory(activeWorkspace)
            await loadPlugins()
            await refreshGitDiff()
        } else {
            isConnecting = false
            isAuthenticated = false
            probeDiagnostics = failures.map { "\($0.0) → \($0.1)" }
            AppLogger.shared.error("Auth", "全部链路连接失败: \(probeDiagnostics.joined(separator: "; "))")
            if failures.contains(where: { $0.1.contains("401") }) {
                authError = "Auth Token 不匹配，请核对电脑端控制台打印的 Token。"
            } else {
                authError = "所有链路均未连上电脑：在同一 Wi-Fi 请允许「本地网络」权限；外网可使用 Cloudflare 公网地址或 Tailscale。"
            }
        }
    }

    func logout() {
        wsGeneration &+= 1
        wsHeartbeatTask?.cancel()
        wsHeartbeatTask = nil
        wsReconnectTask?.cancel()
        wsReconnectTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isAuthenticated = false
        isConnected = false
        AppLogger.shared.warn("Auth", "已断开并退出登录")
    }

    // MARK: - Single-Flight Automatic Route Failover & Hardened HTTP Request

    func attemptRouteFailover() async -> String? {
        if let existing = failoverTask {
            return await existing.value
        }
        let task = Task<String?, Never> { [weak self] in
            guard let self = self else { return nil }
            var candidates: [String] = []
            let current = self.normalizedBaseURL
            for preset in self.effectivePresetURLs {
                let norm = Self.normalizeURL(preset.url)
                if !candidates.contains(norm) {
                    candidates.append(norm)
                }
            }
            if !candidates.contains(current) {
                candidates.insert(current, at: 0)
            }

            let session = self.probeSession
            var chosen: (url: String, latencyMs: Double)?
            await withTaskGroup(of: (String, Double)?.self) { group in
                for cand in candidates {
                    group.addTask {
                        guard let u = URL(string: cand + "/api/health") else { return nil }
                        var req = URLRequest(url: u)
                        req.timeoutInterval = 3.0
                        let t0 = Date()
                        if let (_, resp) = try? await session.data(for: req),
                           let http = resp as? HTTPURLResponse,
                           http.statusCode == 200 {
                            return (cand, Date().timeIntervalSince(t0) * 1000.0)
                        }
                        return nil
                    }
                }
                for await hit in group {
                    if let hit = hit {
                        chosen = hit
                        group.cancelAll()
                        break
                    }
                }
            }
            if let hit = chosen {
                if self.serverURL != hit.url {
                    AppLogger.shared.info("Failover", "自动切换最优链路: \(self.serverURL) -> \(hit.url) (\(Int(hit.latencyMs))ms)")
                    self.serverURL = hit.url
                }
                self.lastRouteLatencyMs = hit.latencyMs
                return hit.url
            }
            return nil
        }
        failoverTask = task
        let result = await task.value
        failoverTask = nil
        return result
    }

    func recoverRouteAndSocket(reason: String) async {
        _ = await attemptRouteFailover()
        if isAuthenticated {
            connectWebSocket(reset: false)
        }
        AppLogger.shared.info("Stability", "触发连接自愈 (\(reason))")
    }

    private func isTransientHTTPError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return true
        }
        if ns.domain == "Bridge", (ns.code == 502 || ns.code == 503 || ns.code == 524 || ns.code == 530) {
            return true
        }
        return false
    }

    private func request(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        useAuth: Bool = true,
        timeout: TimeInterval = 25,
        allowFailoverRetry: Bool = true
    ) async throws -> Data {
        do {
            return try await performSingleRequest(
                baseURL: normalizedBaseURL,
                path: path,
                method: method,
                body: body,
                useAuth: useAuth,
                timeout: timeout
            )
        } catch {
            if allowFailoverRetry && isTransientHTTPError(error) {
                AppLogger.shared.warn("HTTP", "\(method) \(path) 遇网络抖动(\(error.localizedDescription))，尝试切换最优线路重试")
                if let betterURL = await attemptRouteFailover() {
                    return try await performSingleRequest(
                        baseURL: betterURL,
                        path: path,
                        method: method,
                        body: body,
                        useAuth: useAuth,
                        timeout: timeout
                    )
                }
            }
            throw error
        }
    }

    private func performSingleRequest(
        baseURL: String,
        path: String,
        method: String,
        body: Data?,
        useAuth: Bool,
        timeout: TimeInterval
    ) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if useAuth && !authToken.isEmpty {
            req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await apiSession.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            if http.statusCode == 401 {
                logout()
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = obj["detail"] as? String {
                throw NSError(domain: "Bridge", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: detail])
            }
            throw NSError(domain: "Bridge", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        return data
    }

    // MARK: - Settings, Model Profiles & Search Config

    func fetchSettings() async throws {
        let data = try await request("/api/settings")
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            applySettings(json)
        }
    }

    private func applySettings(_ json: [String: Any]) {
        if let ver = json["version"] as? String {
            serverVersion = ver
        }
        if let ws = json["workspaces"] as? [String] {
            workspaces = ws
            if !ws.contains(activeWorkspace) {
                activeWorkspace = (json["active_workspace"] as? String) ?? ws.first ?? ""
            }
        }
        if let act = json["active_workspace"] as? String, !act.isEmpty {
            activeWorkspace = act
        }
        if let aiMode = json["ai_access_mode"] as? String {
            aiAccessMode = aiMode
        }
        if let m = json["model"] as? String, !m.isEmpty {
            selectedModel = m
        }
        if let pid = json["active_profile_id"] as? String, !pid.isEmpty {
            activeProfileId = pid
        }
        if let mode = json["default_approval_mode"] as? String {
            approvalMode = mode
        }
        if let base = json["deepseek_base_url"] as? String {
            deepseekBaseURL = base
        }
        if let bark = json["bark_url"] as? String {
            barkURL = bark
        }
        if let pub = json["public_url"] as? String, !pub.isEmpty {
            savedPublicURL = pub
        }
        if let et = json["enable_tunnel"] as? Bool {
            enableTunnel = et
        }
        if let dshDir = json["dsh_profile_dir"] as? String {
            dshProfileDir = dshDir
        }
        hasCloudflaredToken = (json["has_cloudflared_token"] as? Bool) ?? false
        hasAPIKey = (json["has_api_key"] as? Bool) ?? false

        if let rawProfiles = json["model_profiles"] as? [[String: Any]] {
            modelProfiles = rawProfiles.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return ModelProfileItem(
                    id: id,
                    name: (item["name"] as? String) ?? id,
                    provider: (item["provider"] as? String) ?? "openai_compatible",
                    baseURL: (item["base_url"] as? String) ?? "",
                    model: (item["model"] as? String) ?? id,
                    temperature: (item["temperature"] as? Double) ?? 0.7,
                    maxTokens: (item["max_tokens"] as? Int) ?? 8192,
                    supportsTools: (item["supports_tools"] as? Bool) ?? true,
                    supportsReasoning: (item["supports_reasoning"] as? Bool) ?? false,
                    hasAPIKey: (item["has_api_key"] as? Bool) ?? false,
                    apiKeyMasked: (item["api_key_masked"] as? String) ?? "",
                    inheritsGlobalKey: (item["inherits_global_key"] as? Bool) ?? false
                )
            }
        }

        if let sc = json["search_config"] as? [String: Any] {
            searchConfig = SearchConfigItem(
                enabled: (sc["enabled"] as? Bool) ?? true,
                provider: (sc["provider"] as? String) ?? "duckduckgo",
                baseURL: (sc["base_url"] as? String) ?? "",
                maxResults: (sc["max_results"] as? Int) ?? 6,
                timeoutSec: (sc["timeout_sec"] as? Int) ?? 12,
                hasAPIKey: (sc["has_api_key"] as? Bool) ?? false,
                apiKeyMasked: (sc["api_key_masked"] as? String) ?? ""
            )
        }
    }

    func refreshTunnelStatus() async {
        do {
            let data = try await request("/api/tunnel/status")
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                tunnelStatus = (json["status"] as? String) ?? ""
                if let url = json["live_url"] as? String, !url.isEmpty {
                    savedPublicURL = url
                }
            }
        } catch {}
    }

    func restartTunnel(cloudflaredToken: String = "") async {
        if !cloudflaredToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let payload: [String: Any] = [
                "cloudflared_token": cloudflaredToken.trimmingCharacters(in: .whitespacesAndNewlines),
                "enable_tunnel": true,
            ]
            if let body = try? JSONSerialization.data(withJSONObject: payload) {
                _ = try? await request("/api/settings", method: "PUT", body: body)
            }
        }
        do {
            let data = try await request("/api/tunnel/restart", method: "POST")
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                tunnelStatus = (json["status"] as? String) ?? ""
                if let url = json["live_url"] as? String, !url.isEmpty {
                    savedPublicURL = url
                }
                Haptics.success()
            }
        } catch {}
    }

    func saveSettings(apiKey: String) async throws {
        var payload: [String: Any] = [
            "workspaces": workspaces,
            "active_workspace": activeWorkspace,
            "ai_access_mode": aiAccessMode,
            "default_approval_mode": approvalMode,
            "bark_url": barkURL,
            "deepseek_base_url": deepseekBaseURL,
            "model": selectedModel,
        ]
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["deepseek_api_key"] = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request("/api/settings", method: "PUT", body: body)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            applySettings(json)
        }
        await loadPCDrives()
        Haptics.success()
    }

    func switchModelProfile(_ profile: ModelProfileItem) async {
        activeProfileId = profile.id
        selectedModel = profile.model
        let payload: [String: Any] = ["active_profile_id": profile.id]
        if let body = try? JSONSerialization.data(withJSONObject: payload),
           let data = try? await request("/api/settings", method: "PUT", body: body),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            applySettings(json)
        }
        Haptics.light()
        showToastMessage("已切换模型: \(profile.name)")
    }

    func saveModelProfiles(_ profiles: [ModelProfileItem], activeId: String? = nil, apiKeyOverrides: [String: String] = [:]) async throws {
        let serialized: [[String: Any]] = profiles.map { p in
            var dict: [String: Any] = [
                "id": p.id,
                "name": p.name,
                "provider": p.provider,
                "base_url": p.baseURL,
                "model": p.model,
                "temperature": p.temperature,
                "max_tokens": p.maxTokens,
                "supports_tools": p.supportsTools,
                "supports_reasoning": p.supportsReasoning,
            ]
            if let overrideKey = apiKeyOverrides[p.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !overrideKey.isEmpty {
                dict["api_key"] = overrideKey
            }
            return dict
        }
        var payload: [String: Any] = ["model_profiles": serialized]
        if let aid = activeId, !aid.isEmpty {
            payload["active_profile_id"] = aid
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request("/api/settings", method: "PUT", body: body)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            applySettings(json)
        }
        Haptics.success()
    }

    func testModelProfile(_ profile: ModelProfileItem, apiKeyOverride: String = "") async -> (ok: Bool, latencyMs: Double, detail: String) {
        var payload: [String: Any] = [
            "profile_id": profile.id,
            "provider": profile.provider,
            "base_url": profile.baseURL,
            "model": profile.model,
        ]
        if !apiKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["api_key"] = apiKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await request("/api/providers/test", method: "POST", body: body)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return (
                    (json["ok"] as? Bool) ?? false,
                    (json["latency_ms"] as? Double) ?? 0,
                    (json["detail"] as? String) ?? ""
                )
            }
        } catch {
            return (false, 0, error.localizedDescription)
        }
        return (false, 0, "未知错误")
    }

    func saveSearchConfig(_ config: SearchConfigItem, apiKeyOverride: String = "") async throws {
        var sc: [String: Any] = [
            "enabled": config.enabled,
            "provider": config.provider,
            "base_url": config.baseURL,
            "max_results": config.maxResults,
            "timeout_sec": config.timeoutSec,
        ]
        if !apiKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sc["api_key"] = apiKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let body = try JSONSerialization.data(withJSONObject: ["search_config": sc])
        let data = try await request("/api/settings", method: "PUT", body: body)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            applySettings(json)
        }
        Haptics.success()
    }

    func testSearch(query: String, configOverride: SearchConfigItem? = nil, apiKeyOverride: String = "") async -> SearchTestResponse {
        var payload: [String: Any] = ["query": query, "max_results": 5]
        if let sc = configOverride {
            var scDict: [String: Any] = [
                "enabled": true,
                "provider": sc.provider,
                "base_url": sc.baseURL,
                "max_results": sc.maxResults,
                "timeout_sec": sc.timeoutSec,
            ]
            if !apiKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scDict["api_key"] = apiKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            payload["search_config"] = scDict
        }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await request("/api/search/test", method: "POST", body: body)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let rawResults = (json["results"] as? [[String: Any]]) ?? []
                let entries = rawResults.map {
                    SearchResultEntry(
                        title: ($0["title"] as? String) ?? "",
                        url: ($0["url"] as? String) ?? "",
                        snippet: ($0["snippet"] as? String) ?? ""
                    )
                }
                return SearchTestResponse(
                    ok: (json["ok"] as? Bool) ?? false,
                    provider: (json["provider"] as? String) ?? "",
                    latencyMs: (json["latency_ms"] as? Double) ?? 0,
                    error: (json["error"] as? String) ?? "",
                    results: entries
                )
            }
        } catch {
            return SearchTestResponse(ok: false, provider: searchConfig.provider, latencyMs: 0, error: error.localizedDescription, results: [])
        }
        return SearchTestResponse(ok: false, provider: searchConfig.provider, latencyMs: 0, error: "解析失败", results: [])
    }

    func authorizeWorkspace(path: String, setActive: Bool = true) async {
        do {
            let payload: [String: Any] = [
                "path": path,
                "set_active": setActive,
                "session_id": activeSessionId,
            ]
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await request("/api/workspaces/authorize", method: "POST", body: body)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let settings = json["settings"] as? [String: Any] {
                applySettings(settings)
            }
            await loadPCDirectory(currentDir.isEmpty ? activeWorkspace : currentDir)
            await loadPCDrives()
            Haptics.success()
        } catch {
            fileError = error.localizedDescription
        }
    }

    func removeWorkspace(_ path: String) async {
        guard workspaces.count > 1 else { return }
        workspaces.removeAll { $0 == path }
        if activeWorkspace == path {
            activeWorkspace = workspaces.first ?? ""
        }
        try? await saveSettings(apiKey: "")
    }

    // MARK: - Sessions & WebSocket Streaming with Heartbeat + Backoff

    func loadSessions() async {
        do {
            let data = try await request("/api/sessions")
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = json["sessions"] as? [[String: Any]] {
                let parsed = raw.compactMap { item -> SessionSummaryItem? in
                    guard let sid = item["session_id"] as? String else { return nil }
                    return SessionSummaryItem(
                        sessionId: sid,
                        title: (item["title"] as? String) ?? "Session",
                        status: (item["status"] as? String) ?? "idle",
                        model: (item["model"] as? String) ?? "deepseek-flash"
                    )
                }
                self.sessions = parsed
                if activeSessionId.isEmpty || !parsed.contains(where: { $0.sessionId == activeSessionId }) {
                    if let first = parsed.first {
                        activeSessionId = first.sessionId
                    } else {
                        _ = try? await createNewSession()
                        return
                    }
                }
                connectWebSocket(reset: true)
            }
        } catch {}
    }

    func createNewSession() async throws -> SessionSummaryItem? {
        let ws = activeWorkspace.isEmpty ? (workspaces.first ?? "") : activeWorkspace
        let payload: [String: Any] = [
            "workspace": ws,
            "title": "New Session",
            "model": selectedModel,
            "profile_id": activeProfileId,
            "approval_mode": approvalMode,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request("/api/sessions", method: "POST", body: body)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sid = json["session_id"] as? String {
            let item = SessionSummaryItem(
                sessionId: sid,
                title: (json["title"] as? String) ?? "New Session",
                status: (json["status"] as? String) ?? "idle",
                model: (json["model"] as? String) ?? selectedModel
            )
            sessions.insert(item, at: 0)
            await selectSession(sid)
            return item
        }
        return nil
    }

    func selectSession(_ sessionId: String) async {
        activeSessionId = sessionId
        turns = []
        pendingApprovals = []
        queuedMessages = []
        lastSeq = 0
        connectWebSocket(reset: true)
    }

    func connectWebSocket(reset: Bool = false) {
        wsReconnectTask?.cancel()
        wsReconnectTask = nil
        wsHeartbeatTask?.cancel()
        wsHeartbeatTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        guard !activeSessionId.isEmpty, !authToken.isEmpty else { return }

        wsGeneration &+= 1
        let gen = wsGeneration

        let wsScheme = normalizedBaseURL.hasPrefix("https://") ? "wss://" : "ws://"
        let hostPart = normalizedBaseURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        let after = reset ? 0 : lastSeq
        let encodedToken = authToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? authToken
        let urlStr = "\(wsScheme)\(hostPart)/ws/sessions/\(activeSessionId)?token=\(encodedToken)&after_seq=\(after)"
        guard let url = URL(string: urlStr) else { return }

        wsSynced = false
        let task = URLSession.shared.webSocketTask(with: url)
        self.webSocketTask = task
        self.lastWSActivityAt = Date()
        task.resume()
        AppLogger.shared.info("WebSocket", "连接 \(wsScheme)\(hostPart) (after_seq=\(after))")
        startHeartbeatLoop(for: task, generation: gen)
        receiveNextMessage(from: task, generation: gen)
    }

    private func startHeartbeatLoop(for task: URLSessionWebSocketTask, generation: UInt64) {
        wsHeartbeatTask?.cancel()
        wsHeartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 11_000_000_000)
                guard !Task.isCancelled, let self = self, self.wsGeneration == generation, self.webSocketTask === task else {
                    return
                }
                if Date().timeIntervalSince(self.lastWSActivityAt) > 28.0 {
                    AppLogger.shared.warn("WebSocket", "心跳超时 (>28s 无响应)，主动重建连接")
                    self.scheduleWSReconnect(reason: "heartbeat_timeout", tryFailoverFirst: true)
                    return
                }
                task.send(.string("ping")) { [weak self] err in
                    if let err = err {
                        Task { @MainActor [weak self] in
                            guard let self = self, self.wsGeneration == generation else { return }
                            AppLogger.shared.warn("WebSocket", "发送心跳失败: \(err.localizedDescription)")
                            self.scheduleWSReconnect(reason: "ping_send_err", tryFailoverFirst: false)
                        }
                    }
                }
            }
        }
    }

    private func receiveNextMessage(from task: URLSessionWebSocketTask, generation: UInt64) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self = self, self.wsGeneration == generation, self.webSocketTask === task else { return }
                switch result {
                case .success(let message):
                    self.lastWSActivityAt = Date()
                    self.isConnected = true
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handleSocketPayload(json)
                    }
                    self.receiveNextMessage(from: task, generation: generation)
                case .failure(let err):
                    self.isConnected = false
                    self.wsReconnectCount += 1
                    self.consecutiveWSErrors += 1
                    AppLogger.shared.warn("WebSocket", "连接中断(#\(self.consecutiveWSErrors)): \(err.localizedDescription)")
                    self.scheduleWSReconnect(
                        reason: err.localizedDescription,
                        tryFailoverFirst: (self.consecutiveWSErrors % 2 == 0)
                    )
                }
            }
        }
    }

    private func scheduleWSReconnect(reason: String, tryFailoverFirst: Bool) {
        guard isAuthenticated, wsReconnectTask == nil else { return }
        isConnected = false
        let delaySec = min(10.0, pow(1.7, Double(max(0, consecutiveWSErrors - 1))))
        wsReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            guard !Task.isCancelled, let self = self, self.isAuthenticated else { return }
            self.wsReconnectTask = nil
            if tryFailoverFirst {
                _ = await self.attemptRouteFailover()
            }
            self.connectWebSocket(reset: false)
        }
    }

    private func handleSocketPayload(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        if type == "ping" || type == "pong" { return }
        if type == "sync_complete" {
            wsSynced = true
            isConnected = true
            consecutiveWSErrors = 0
            if let sess = msg["session"] as? [String: Any] {
                applySessionSummary(sess)
            }
            return
        }
        if let seq = msg["seq"] as? Int {
            if seq <= lastSeq { return }
            lastSeq = seq
        }
        let d = (msg["data"] as? [String: Any]) ?? [:]
        if let sess = d["session"] as? [String: Any] {
            applySessionSummary(sess)
        }

        switch type {
        case "user_message":
            let text = (d["text"] as? String) ?? ""
            turns.append(ChatTurnItem(id: UUID().uuidString, userText: text))
            if wsSynced {
                LiveActivityController.shared.notifyTurnStarted(sessionTitle: "DeepSeek")
            }

        case "thought_delta":
            ensureActiveTurn()
            if let full = d["full_text"] as? String {
                turns[turns.count - 1].thoughtText = full
            } else if let delta = d["text"] as? String {
                turns[turns.count - 1].thoughtText += delta
            }
            if wsSynced {
                LiveActivityController.shared.notifyPhaseChanged(
                    .thinking,
                    toolCount: turns.last?.toolCalls.count ?? 0,
                    queuedCount: queuedMessages.count
                )
            }

        case "tool_call":
            ensureActiveTurn()
            let tcId = (d["id"] as? String) ?? UUID().uuidString
            let name = (d["name"] as? String) ?? "tool"
            let argsObj = d["args"] ?? [:]
            let argsData = (try? JSONSerialization.data(withJSONObject: argsObj, options: [.prettyPrinted])) ?? Data()
            let argsStr = String(data: argsData, encoding: .utf8) ?? "{}"
            let idx = turns[turns.count - 1].toolCalls.count + 1
            turns[turns.count - 1].toolCalls.append(
                ToolCallItem(id: tcId, index: idx, name: name, argsText: argsStr)
            )
            if wsSynced {
                Haptics.light()
                LiveActivityController.shared.notifyPhaseChanged(
                    .callingTool,
                    toolCount: idx,
                    queuedCount: queuedMessages.count
                )
            }

        case "tool_result":
            ensureActiveTurn()
            let tcId = (d["id"] as? String) ?? ""
            let errStr = d["error"] as? String
            let resStr = (d["result"] as? String) ?? ""
            if let pos = turns[turns.count - 1].toolCalls.firstIndex(where: { $0.id == tcId }) {
                turns[turns.count - 1].toolCalls[pos].resultText = errStr ?? resStr
                turns[turns.count - 1].toolCalls[pos].isError = (errStr != nil)
            }

        case "file_artifact":
            ensureActiveTurn()
            let art = FileArtifactItem(
                id: (d["id"] as? String) ?? UUID().uuidString,
                name: (d["name"] as? String) ?? "file",
                path: (d["path"] as? String) ?? "",
                title: (d["title"] as? String) ?? (d["name"] as? String) ?? "文件",
                summary: (d["summary"] as? String) ?? "点击可审查内容或下载到手机本地",
                size: (d["size"] as? Int) ?? 0,
                ext: (d["ext"] as? String) ?? "",
                mode: (d["mode"] as? String) ?? "review",
                isText: (d["is_text"] as? Bool) ?? false,
                preview: (d["preview"] as? String) ?? ""
            )
            if let existingIdx = turns[turns.count - 1].artifacts.firstIndex(where: { $0.path == art.path }) {
                turns[turns.count - 1].artifacts[existingIdx] = art
            } else {
                turns[turns.count - 1].artifacts.append(art)
            }
            if wsSynced { Haptics.light() }

        case "text_delta":
            ensureActiveTurn()
            if let full = d["full_text"] as? String {
                turns[turns.count - 1].assistantText = full
            } else if let delta = d["text"] as? String {
                turns[turns.count - 1].assistantText += delta
            }
            if wsSynced {
                LiveActivityController.shared.notifyPhaseChanged(
                    .answering,
                    toolCount: turns.last?.toolCalls.count ?? 0,
                    queuedCount: queuedMessages.count
                )
            }

        case "approval_request":
            if wsSynced {
                Haptics.warning()
                let first = pendingApprovals.first
                let reqId = (d["request_id"] as? String) ?? first?.id ?? ""
                let tool = (d["tool_name"] as? String) ?? first?.toolName ?? "tool"
                let risk = (d["risk_level"] as? String) ?? first?.riskLevel ?? "medium"
                let summary = (d["review_summary"] as? String) ?? first?.reviewSummary ?? (first?.argsJSON ?? "")
                LiveActivityController.shared.notifyPhaseChanged(
                    .waitingApproval,
                    toolCount: turns.last?.toolCalls.count ?? 0,
                    approvalId: reqId,
                    toolName: tool,
                    summary: summary,
                    riskLevel: risk,
                    queuedCount: queuedMessages.count
                )
            }

        case "approval_resolved":
            if pendingApprovals.isEmpty {
                LiveActivityController.shared.clearPendingApproval()
            }

        case "queue_updated":
            if let rawQ = d["queued_messages"] as? [[String: Any]] {
                queuedMessages = Self.parseQueuedMessages(rawQ)
            }

        case "turn_done":
            sessionStatus = "idle"
            if wsSynced {
                Haptics.success()
                LiveActivityController.shared.notifyTurnFinished()
            }

        case "error":
            ensureActiveTurn()
            turns[turns.count - 1].errorText = (d["message"] as? String) ?? "连接中断，请重试"
            sessionStatus = "error"
            if wsSynced {
                LiveActivityController.shared.notifyTurnFinished()
            }

        default:
            break
        }
    }

    private func ensureActiveTurn() {
        if turns.isEmpty {
            turns.append(ChatTurnItem(id: UUID().uuidString))
        }
    }

    private static func parseQueuedMessages(_ raw: [[String: Any]]) -> [QueuedMessageItem] {
        raw.compactMap { q in
            guard let id = q["id"] as? String,
                  let prompt = q["prompt"] as? String else { return nil }
            return QueuedMessageItem(
                id: id,
                prompt: prompt,
                model: (q["model"] as? String) ?? "",
                profileId: (q["profile_id"] as? String) ?? "",
                createdAt: (q["created_at"] as? String) ?? ""
            )
        }
    }

    private func applySessionSummary(_ sess: [String: Any]) {
        if let st = sess["status"] as? String {
            sessionStatus = st
        }
        if let rawQ = sess["queued_messages"] as? [[String: Any]] {
            queuedMessages = Self.parseQueuedMessages(rawQ)
        }
        if let rawApprovals = sess["pending_approvals"] as? [[String: Any]] {
            pendingApprovals = rawApprovals.compactMap { item in
                guard let reqId = item["request_id"] as? String else { return nil }
                let tool = (item["tool_name"] as? String) ?? "tool"
                let argsObj = item["args"] ?? [:]
                let argsData = (try? JSONSerialization.data(withJSONObject: argsObj, options: [.prettyPrinted])) ?? Data()
                let argsStr = String(data: argsData, encoding: .utf8) ?? "{}"
                return PendingApprovalItem(
                    id: reqId,
                    toolName: tool,
                    argsJSON: argsStr,
                    riskLevel: (item["risk_level"] as? String) ?? "medium",
                    reviewSummary: (item["review_summary"] as? String) ?? "",
                    reviewScore: (item["review_score"] as? Int) ?? 0
                )
            }
            if let active = activeApprovalForPopup,
               !pendingApprovals.contains(where: { $0.id == active.id }) {
                activeApprovalForPopup = nil
            }
        }
    }

    // MARK: - Chat Actions, Queue & Deep Links

    func sendPrompt(_ prompt: String) async {
        let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !activeSessionId.isEmpty else { return }
        Haptics.light()
        do {
            let body = try JSONSerialization.data(withJSONObject: [
                "prompt": clean,
                "model": selectedModel,
                "profile_id": activeProfileId,
                "queue_if_busy": true,
            ])
            let data = try await request("/api/sessions/\(activeSessionId)/message", method: "POST", body: body)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let sess = json["session"] as? [String: Any] {
                    applySessionSummary(sess)
                }
                if (json["queued"] as? Bool) == true {
                    showToastMessage("已加入发送队列（第 \(queuedMessages.count) 条）")
                }
            }
        } catch {
            showToastMessage("发送失败: \(error.localizedDescription)")
        }
    }

    func promoteQueuedMessage(_ itemId: String) async {
        guard !activeSessionId.isEmpty else { return }
        if let data = try? await request("/api/sessions/\(activeSessionId)/queue/\(itemId)/send_now", method: "POST"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sess = json["session"] as? [String: Any] {
            applySessionSummary(sess)
        }
    }

    func deleteQueuedMessage(_ itemId: String) async {
        guard !activeSessionId.isEmpty else { return }
        if let data = try? await request("/api/sessions/\(activeSessionId)/queue/\(itemId)", method: "DELETE"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sess = json["session"] as? [String: Any] {
            applySessionSummary(sess)
        }
    }

    func clearQueuedMessages() async {
        guard !activeSessionId.isEmpty else { return }
        if let data = try? await request("/api/sessions/\(activeSessionId)/queue", method: "DELETE"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sess = json["session"] as? [String: Any] {
            applySessionSummary(sess)
        }
    }

    func cancelCurrentTurn() async {
        guard !activeSessionId.isEmpty else { return }
        Haptics.medium()
        _ = try? await request("/api/sessions/\(activeSessionId)/cancel", method: "POST")
        LiveActivityController.shared.notifyTurnFinished()
    }

    func resolveApproval(requestId: String, allow: Bool, setAutoMode: Bool = false) async {
        guard !activeSessionId.isEmpty else { return }
        Haptics.medium()
        var payload: [String: Any] = ["allow": allow]
        if setAutoMode {
            payload["set_approval_mode"] = "auto"
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        if let data = try? await request(
            "/api/sessions/\(activeSessionId)/approvals/\(requestId)",
            method: "POST",
            body: body
        ),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sess = json["session"] as? [String: Any] {
            applySessionSummary(sess)
            if pendingApprovals.isEmpty {
                LiveActivityController.shared.clearPendingApproval()
            }
        }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "deepseekgo" else { return }
        let action = (url.host ?? "").lowercased()
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let reqId = comps?.queryItems?.first(where: { $0.name == "id" })?.value ?? ""
        AppLogger.shared.info("DeepLink", "收到灵动岛操作: \(action) id=\(reqId)")

        Task {
            if !activeSessionId.isEmpty {
                // Ensure latest pending approvals are synced
                if let data = try? await request("/api/sessions/\(activeSessionId)/events?after_seq=\(lastSeq)"),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sess = json["session"] as? [String: Any] {
                    applySessionSummary(sess)
                }
            }
            let targetId = !reqId.isEmpty ? reqId : (pendingApprovals.first?.id ?? "")
            if action == "approve" && !targetId.isEmpty {
                await resolveApproval(requestId: targetId, allow: true)
                showToastMessage("已从灵动岛批准执行")
            } else if action == "deny" && !targetId.isEmpty {
                await resolveApproval(requestId: targetId, allow: false)
                showToastMessage("已从灵动岛拒绝操作")
            } else if let matched = pendingApprovals.first(where: { $0.id == targetId }) ?? pendingApprovals.first {
                activeApprovalForPopup = matched
            }
        }
    }

    // MARK: - Full PC File System Manager (Race-Free Single Tap)

    func loadPCDrives() async {
        do {
            let data = try await request("/api/pc/drives")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let rawDrives = json["drives"] as? [[String: Any]] {
                pcDrives = rawDrives.compactMap { d in
                    guard let letter = d["letter"] as? String,
                          let path = d["path"] as? String else { return nil }
                    return PCDriveItem(
                        letter: letter,
                        name: (d["name"] as? String) ?? letter,
                        label: (d["label"] as? String) ?? letter,
                        path: path,
                        totalBytes: (d["total_bytes"] as? NSNumber)?.int64Value ?? 0,
                        usedBytes: (d["used_bytes"] as? NSNumber)?.int64Value ?? 0,
                        freeBytes: (d["free_bytes"] as? NSNumber)?.int64Value ?? 0
                    )
                }
            }
            if let rawShortcuts = json["shortcuts"] as? [[String: Any]] {
                pcShortcuts = rawShortcuts.compactMap { s in
                    guard let name = s["name"] as? String,
                          let path = s["path"] as? String else { return nil }
                    return PCShortcutItem(name: name, path: path, icon: (s["icon"] as? String) ?? "folder")
                }
            }
        } catch {}
    }

    func loadPCDirectory(_ path: String) async {
        fileError = nil
        pcDirToken &+= 1
        let myToken = pcDirToken
        isLoadingDirectory = true
        defer {
            if pcDirToken == myToken {
                isLoadingDirectory = false
            }
        }

        let target = path.isEmpty ? activeWorkspace : path
        let pathEnc = target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let hiddenFlag = showHiddenFiles ? "true" : "false"
        do {
            let data = try await request("/api/pc/list?path=\(pathEnc)&show_hidden=\(hiddenFlag)")
            guard pcDirToken == myToken else { return }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = json["entries"] as? [[String: Any]] else { return }
            currentDir = (json["path"] as? String) ?? target
            currentParentDir = (json["parent_path"] as? String) ?? ""
            currentDrive = (json["drive"] as? String) ?? "C:"
            currentDirInAIWorkspace = (json["in_ai_workspace"] as? Bool) ?? false
            fileEntries = entries.compactMap { Self.parseFileEntry($0) }
        } catch {
            if pcDirToken == myToken {
                fileError = error.localizedDescription
            }
        }
    }

    static func parseFileEntry(_ e: [String: Any]) -> FileEntryItem? {
        guard let name = e["name"] as? String,
              let path = e["path"] as? String else { return nil }
        return FileEntryItem(
            name: name,
            path: path,
            parentPath: (e["parent_path"] as? String) ?? "",
            isDir: (e["is_dir"] as? Bool) ?? false,
            size: (e["size"] as? Int) ?? 0,
            mtime: (e["mtime"] as? Double) ?? 0,
            ctime: (e["ctime"] as? Double) ?? 0,
            atime: (e["atime"] as? Double) ?? 0,
            ext: (e["ext"] as? String) ?? "",
            mimeType: (e["mime_type"] as? String) ?? "application/octet-stream",
            isReadonly: (e["is_readonly"] as? Bool) ?? false,
            isHidden: (e["is_hidden"] as? Bool) ?? false,
            inAIWorkspace: (e["in_ai_workspace"] as? Bool) ?? false,
            aiCanRead: (e["ai_can_read"] as? Bool) ?? false,
            aiCanWrite: (e["ai_can_write"] as? Bool) ?? false
        )
    }

    func readPCFile(_ fullPath: String) async throws -> (content: String, mtime: Double) {
        let pathEnc = fullPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let data = try await request("/api/pc/read?path=\(pathEnc)")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return ((json["content"] as? String) ?? "", (json["mtime"] as? Double) ?? 0)
    }

    func writePCFile(_ fullPath: String, content: String) async throws {
        let payload: [String: Any] = ["path": fullPath, "content": content]
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await request("/api/pc/write", method: "PUT", body: body)
        await loadPCDirectory(currentDir)
        Haptics.success()
    }

    func createPCEntry(name: String, isDir: Bool, content: String = "") async throws {
        let payload: [String: Any] = [
            "parent_path": currentDir,
            "name": name,
            "is_dir": isDir,
            "content": content,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await request("/api/pc/create", method: "POST", body: body)
        await loadPCDirectory(currentDir)
        Haptics.success()
    }

    func renamePCEntry(item: FileEntryItem, newName: String) async throws {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let sep = item.path.contains("/") ? "/" : "\\"
        let destPath = item.parentPath.hasSuffix(sep) ? "\(item.parentPath)\(clean)" : "\(item.parentPath)\(sep)\(clean)"
        let payload: [String: Any] = ["src_path": item.path, "dest_path": destPath]
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await request("/api/pc/move", method: "POST", body: body)
        await loadPCDirectory(currentDir)
        Haptics.success()
    }

    func pasteClipboardIntoCurrentDir() async throws {
        guard let clip = clipboard else { return }
        let sep = currentDir.contains("/") ? "/" : "\\"
        let destPath = currentDir.hasSuffix(sep) ? "\(currentDir)\(clip.source.name)" : "\(currentDir)\(sep)\(clip.source.name)"
        let payload: [String: Any] = ["src_path": clip.source.path, "dest_path": destPath]
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await request(clip.isMove ? "/api/pc/move" : "/api/pc/copy", method: "POST", body: body)
        if clip.isMove { clipboard = nil }
        await loadPCDirectory(currentDir)
        Haptics.success()
    }

    func deletePCEntry(_ item: FileEntryItem) async throws {
        let pathEnc = item.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        _ = try await request("/api/pc/delete?path=\(pathEnc)", method: "DELETE")
        await loadPCDirectory(currentDir)
        Haptics.medium()
    }

    func uploadLocalFileToPC(fileURL: URL, targetDir: String? = nil) async throws -> (name: String, path: String) {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        let fileData = try Data(contentsOf: fileURL)
        let b64 = fileData.base64EncodedString()
        let dest = (targetDir?.isEmpty == false) ? targetDir! : (currentDir.isEmpty ? activeWorkspace : currentDir)
        let payload: [String: Any] = ["dir_path": dest, "filename": fileURL.lastPathComponent, "content_base64": b64]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let respData = try await request("/api/pc/upload_base64", method: "POST", body: body, timeout: 60)
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let savedPath = json["path"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        await loadPCDirectory(currentDir)
        Haptics.success()
        return (fileURL.lastPathComponent, savedPath)
    }

    func downloadPCFileToLocalTemp(pcPath: String, filename: String) async throws -> URL {
        let pathEnc = pcPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let data = try await request("/api/pc/download?path=\(pathEnc)", timeout: 60)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: tempURL, options: .atomic)
        return tempURL
    }

    // MARK: - Git Status & Diff

    func refreshGitDiff() async {
        let wsEnc = activeWorkspace.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        do {
            let data = try await request("/api/git/status?workspace=\(wsEnc)")
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                isGitRepo = (json["is_git_repo"] as? Bool) ?? false
                gitBranch = (json["branch"] as? String) ?? ""
                let diffStr = (json["diff"] as? String) ?? ""
                let reasonStr = (json["reason"] as? String) ?? ""
                gitDiff = diffStr.isEmpty ? reasonStr : diffStr
            }
        } catch {}
    }

    // MARK: - DSH Plugins System (Configured on Mobile, Executed on PC)

    func loadPlugins() async {
        do {
            let data = try await request("/api/plugins")
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                applyPluginsPayload(json)
            }
        } catch {}
    }

    private func applyPluginsPayload(_ json: [String: Any]) {
        if let rawList = json["plugins"] as? [[String: Any]] {
            plugins = rawList.compactMap { Self.parsePlugin($0) }
        }
        if let rawDsh = json["dsh_profile"] as? [String: Any] {
            let bundles = ((rawDsh["bundles"] as? [[String: Any]]) ?? []).compactMap { b -> DSHBundleItem? in
                guard let name = b["name"] as? String else { return nil }
                return DSHBundleItem(
                    name: name,
                    enabled: (b["enabled"] as? Bool) ?? false,
                    version: (b["version"] as? String) ?? "builtin",
                    description: (b["description"] as? String) ?? ""
                )
            }
            let patches = ((rawDsh["patches"] as? [[String: Any]]) ?? []).compactMap { p -> DSHPatchItem? in
                guard let id = p["id"] as? String else { return nil }
                return DSHPatchItem(
                    id: id,
                    name: (p["name"] as? String) ?? id,
                    enabled: (p["enabled"] as? Bool) ?? true,
                    configJSON: Self.prettyJSON(p["config"]),
                    kind: (p["kind"] as? String) ?? "override"
                )
            }
            dshProfile = DSHProfileStatus(
                exists: (rawDsh["exists"] as? Bool) ?? false,
                profileDir: (rawDsh["profile_dir"] as? String) ?? "",
                runtimeAvailable: (rawDsh["runtime_available"] as? Bool) ?? false,
                bundles: bundles,
                patches: patches
            )
        }
    }

    private static func prettyJSON(_ obj: Any?) -> String {
        guard let obj = obj,
              JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    private static func parsePlugin(_ item: [String: Any]) -> PCPluginItem? {
        guard let id = item["id"] as? String else { return nil }
        let skills = ((item["skills"] as? [[String: Any]]) ?? []).map {
            PluginSkillInfo(
                name: ($0["name"] as? String) ?? "",
                path: ($0["path"] as? String) ?? "",
                preview: ($0["preview"] as? String) ?? ""
            )
        }
        let tools = ((item["tools"] as? [[String: Any]]) ?? []).map {
            PluginToolInfo(
                name: ($0["name"] as? String) ?? "",
                relPath: ($0["rel_path"] as? String) ?? "",
                ext: ($0["ext"] as? String) ?? ""
            )
        }
        return PCPluginItem(
            id: id,
            name: (item["name"] as? String) ?? id,
            version: (item["version"] as? String) ?? "1.0.0",
            description: (item["description"] as? String) ?? "",
            author: (item["author"] as? String) ?? "",
            enabled: (item["enabled"] as? Bool) ?? true,
            source: (item["source"] as? String) ?? "local",
            path: (item["path"] as? String) ?? "",
            isDSHBundle: (item["is_dsh_bundle"] as? Bool) ?? false,
            skills: skills,
            tools: tools,
            mcpServers: (item["mcp_servers"] as? [String]) ?? [],
            configJSON: prettyJSON(item["config"]),
            envJSON: prettyJSON(item["env"])
        )
    }

    func installPluginUpload(fileURL: URL, name: String = "", description: String = "") async throws {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: fileURL)
        let payload: [String: Any] = [
            "source_type": "upload",
            "filename": fileURL.lastPathComponent,
            "content_base64": data.base64EncodedString(),
            "name": name,
            "description": description,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let resp = try await request("/api/plugins/install", method: "POST", body: body, timeout: 60)
        if let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] {
            applyPluginsPayload(json)
        }
        Haptics.success()
    }

    func installPluginInline(name: String, description: String, skillMD: String, scriptCode: String, language: String, configJSON: String) async throws {
        var cfgObj: Any = [:]
        if let cd = configJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: cd) {
            cfgObj = parsed
        }
        let payload: [String: Any] = [
            "source_type": "inline",
            "name": name,
            "description": description,
            "skill_markdown": skillMD,
            "script_code": scriptCode,
            "script_language": language,
            "config": cfgObj,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let resp = try await request("/api/plugins/install", method: "POST", body: body)
        if let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] {
            applyPluginsPayload(json)
        }
        Haptics.success()
    }

    func installPluginFromGit(url: String, branch: String = "", name: String = "") async throws {
        let payload: [String: Any] = [
            "source_type": "git",
            "git_url": url,
            "branch": branch,
            "name": name,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let resp = try await request("/api/plugins/install", method: "POST", body: body, timeout: 60)
        if let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] {
            applyPluginsPayload(json)
        }
        Haptics.success()
    }

    func installPluginFromLocalPath(path: String, name: String = "") async throws {
        let payload: [String: Any] = [
            "source_type": "local_path",
            "local_path": path,
            "name": name,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let resp = try await request("/api/plugins/install", method: "POST", body: body)
        if let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] {
            applyPluginsPayload(json)
        }
        Haptics.success()
    }

    func togglePlugin(id: String, enabled: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
        let resp = try await request("/api/plugins/\(id)/toggle", method: "POST", body: body)
        if let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] {
            applyPluginsPayload(json)
        }
        Haptics.light()
    }

    func updatePluginConfig(id: String, configJSON: String, envJSON: String) async throws {
        guard let cData = configJSON.data(using: .utf8),
              let cfgObj = try JSONSerialization.jsonObject(with: cData) as? [String: Any] else {
            throw NSError(domain: "Bridge", code: 400, userInfo: [NSLocalizedDescriptionKey: "配置必须是合法 JSON 对象"])
        }
        var envObj: [String: String] = [:]
        if let eData = envJSON.data(using: .utf8),
           let parsedEnv = try? JSONSerialization.jsonObject(with: eData) as? [String: Any] {
            for (k, v) in parsedEnv { envObj[k] = "\(v)" }
        }
        let payload: [String: Any] = ["config": cfgObj, "env": envObj]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let resp = try await request("/api/plugins/\(id)/config", method: "PUT", body: body)
        if let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] {
            applyPluginsPayload(json)
        }
        Haptics.success()
    }

    func runPluginOnPC(id: String, toolName: String = "", args: [String] = []) async throws -> PluginRunResult {
        let payload: [String: Any] = [
            "tool_name": toolName,
            "args": args,
            "workspace": activeWorkspace,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let resp = try await request("/api/plugins/\(id)/run", method: "POST", body: body, timeout: 60)
        guard let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return PluginRunResult(
            ok: (json["ok"] as? Bool) ?? false,
            pluginId: (json["plugin_id"] as? String) ?? id,
            tool: (json["tool"] as? String) ?? "",
            exitCode: (json["exit_code"] as? Int) ?? -1,
            stdout: (json["stdout"] as? String) ?? "",
            stderr: (json["stderr"] as? String) ?? "",
            durationMs: (json["duration_ms"] as? Double) ?? 0
        )
    }

    func deletePlugin(id: String) async throws {
        let resp = try await request("/api/plugins/\(id)", method: "DELETE")
        if let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] {
            applyPluginsPayload(json)
        }
        Haptics.medium()
    }

    func toggleDSHEntry(kind: String, id: String, enabled: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["kind": kind, "id": id, "enabled": enabled])
        let resp = try await request("/api/plugins/dsh/toggle", method: "POST", body: body)
        if let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] {
            applyPluginsPayload(json)
        }
        Haptics.light()
    }

    func updateDSHPatchConfig(entryId: String, configJSON: String) async throws {
        guard let cData = configJSON.data(using: .utf8),
              let cfgObj = try JSONSerialization.jsonObject(with: cData) as? [String: Any] else {
            throw NSError(domain: "Bridge", code: 400, userInfo: [NSLocalizedDescriptionKey: "DSH Patch 配置必须是合法 JSON"])
        }
        let body = try JSONSerialization.data(withJSONObject: ["entry_id": entryId, "config": cfgObj])
        let resp = try await request("/api/plugins/dsh/config", method: "PUT", body: body)
        if let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] {
            applyPluginsPayload(json)
        }
        Haptics.success()
    }

    func installDSHPackage(spec: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["spec": spec])
        let resp = try await request("/api/plugins/dsh/install", method: "POST", body: body, timeout: 120)
        if let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] {
            applyPluginsPayload(json)
            Haptics.success()
            return (json["stdout"] as? String) ?? "已安装 \(spec)"
        }
        return "完成"
    }

    // MARK: - Sandbox Simulator & Untrusted Code Self-Check

    private static func parseAuditReport(_ raw: [String: Any]) -> SandboxAuditReport {
        let findings = ((raw["findings"] as? [[String: Any]]) ?? []).map {
            SandboxAuditFinding(
                line: ($0["line"] as? Int) ?? 1,
                severity: ($0["severity"] as? String) ?? "low",
                category: ($0["category"] as? String) ?? "",
                message: ($0["message"] as? String) ?? "",
                snippet: ($0["snippet"] as? String) ?? ""
            )
        }
        return SandboxAuditReport(
            language: (raw["language"] as? String) ?? "python",
            riskLevel: (raw["risk_level"] as? String) ?? "safe",
            score: (raw["score"] as? Int) ?? 0,
            safeToAutoRun: (raw["safe_to_auto_run"] as? Bool) ?? true,
            summary: (raw["summary"] as? String) ?? "",
            findings: findings
        )
    }

    func auditUntrustedCode(code: String, language: String) async throws -> SandboxAuditReport {
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "language": language])
        let resp = try await request("/api/sandbox/audit", method: "POST", body: body)
        guard let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return Self.parseAuditReport(json)
    }

    func runSandboxScript(code: String, language: String, timeoutSec: Int = 10, allowNetwork: Bool = false) async throws -> SandboxRunResult {
        let payload: [String: Any] = [
            "code": code,
            "language": language,
            "timeout_sec": timeoutSec,
            "allow_network": allowNetwork,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let resp = try await request("/api/sandbox/run", method: "POST", body: body, timeout: Double(timeoutSec + 15))
        guard let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let auditRaw = (json["audit"] as? [String: Any]) ?? [:]
        let arts = ((json["artifacts"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        return SandboxRunResult(
            ok: (json["ok"] as? Bool) ?? false,
            runId: (json["run_id"] as? String) ?? "",
            language: (json["language"] as? String) ?? language,
            exitCode: (json["exit_code"] as? Int) ?? -1,
            stdout: (json["stdout"] as? String) ?? "",
            stderr: (json["stderr"] as? String) ?? "",
            durationMs: (json["duration_ms"] as? Double) ?? 0,
            timedOut: (json["timed_out"] as? Bool) ?? false,
            audit: Self.parseAuditReport(auditRaw),
            previewHTML: (json["preview_html"] as? String) ?? "",
            artifactNames: arts
        )
    }

    // MARK: - Diagnostics & Logs

    func loadPCDiagnostics() async {
        do {
            let data = try await request("/api/diagnostics/status")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let net = (json["network"] as? [String: Any]) ?? [:]
            let tun = (net["tunnel"] as? [String: Any]) ?? [:]
            let ws = (net["websocket"] as? [String: Any]) ?? [:]
            let http = (net["http"] as? [String: Any]) ?? [:]
            let plug = (json["plugins"] as? [String: Any]) ?? [:]
            pcDiagnostics = PCDiagnosticsStatus(
                version: (json["version"] as? String) ?? "",
                uptimeSec: (json["uptime_sec"] as? Double) ?? 0,
                pid: (json["pid"] as? Int) ?? 0,
                pythonVersion: (json["python_version"] as? String) ?? "",
                platform: (json["platform"] as? String) ?? "",
                memoryMB: json["memory_mb"] as? Double,
                diskFreeGB: json["disk_free_gb"] as? Double,
                tunnelStatus: (tun["status"] as? String) ?? "",
                tunnelURL: (tun["live_url"] as? String) ?? "",
                wsActive: (ws["active_connections"] as? Int) ?? 0,
                wsConnects: (ws["total_connects"] as? Int) ?? 0,
                wsDisconnects: (ws["total_disconnects"] as? Int) ?? 0,
                wsReconnects: (ws["total_reconnects"] as? Int) ?? 0,
                lastDisconnectReason: (ws["last_disconnect_reason"] as? String) ?? "",
                totalHTTPRequests: (http["total_requests"] as? Int) ?? 0,
                totalHTTPErrors: (http["total_errors"] as? Int) ?? 0,
                pluginsTotal: (plug["total"] as? Int) ?? 0,
                pluginsEnabled: (plug["enabled"] as? Int) ?? 0
            )
        } catch {}
    }

    func loadPCLogs(level: String = "ALL", query: String = "") async {
        let lvl = level.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "ALL"
        let qEnc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        do {
            let data = try await request("/api/diagnostics/logs?level=\(lvl)&q=\(qEnc)&limit=150")
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = json["logs"] as? [[String: Any]] {
                pcLogs = Array(raw.compactMap { item in
                    guard let seq = item["seq"] as? Int else { return nil }
                    return PCLogEntry(
                        seq: seq,
                        ts: (item["ts"] as? String) ?? "",
                        level: (item["level"] as? String) ?? "INFO",
                        logger: (item["logger"] as? String) ?? "bridge",
                        message: (item["message"] as? String) ?? ""
                    )
                }.reversed())
            }
        } catch {}
    }

    func clearPCLogs() async {
        _ = try? await request("/api/diagnostics/logs", method: "DELETE")
        pcLogs = []
    }

    func runPCSelfCheck() async {
        do {
            let data = try await request("/api/diagnostics/selfcheck", method: "POST", timeout: 30)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let items = ((json["checks"] as? [[String: Any]]) ?? []).map {
                    SelfCheckItem(
                        key: ($0["key"] as? String) ?? UUID().uuidString,
                        name: ($0["name"] as? String) ?? "",
                        status: ($0["status"] as? String) ?? "ok",
                        detail: ($0["detail"] as? String) ?? "",
                        latencyMs: ($0["latency_ms"] as? Double) ?? 0
                    )
                }
                selfCheckReport = SelfCheckReport(
                    ok: (json["ok"] as? Bool) ?? false,
                    overallStatus: (json["overall_status"] as? String) ?? "ok",
                    checkedAt: (json["checked_at"] as? String) ?? "",
                    checks: items
                )
                Haptics.success()
            }
        } catch {}
    }
}
