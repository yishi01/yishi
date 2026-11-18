import CryptoKit
import Foundation
import Network
import SwiftUI

@MainActor
final class BridgeClient: ObservableObject {
    static let defaultToken = "_44dVxHP8puOv1RjHTb-uWrgb5LY4k6s"
    static let rendezvousGistID = "746a49e639b95bb92001cd6d864b1631"
    static let initialCloudflareURL = "https://shuttle-hepatitis-attending-documentary.trycloudflare.com"
    static let defaultPresetURLs: [(label: String, url: String)] = [
        ("固定局域网直连", "http://192.168.31.190:8765"),
        ("固定域名 (Tailscale HTTPS)", "https://dsh-pc.tail1e24af.ts.net"),
        ("Tailscale 固定 IP", "http://100.88.121.40:8765"),
    ]

    @AppStorage("ds_server_url") var serverURL: String = "http://192.168.31.190:8765"
    @AppStorage("ds_public_url") var savedPublicURL: String = ""
    @AppStorage("ds_rendezvous_gist_id") var savedRendezvousGistID: String = ""
    @AppStorage("ds_auth_token") var authToken: String = "_44dVxHP8puOv1RjHTb-uWrgb5LY4k6s"
    @AppStorage("ds_active_workspace") var activeWorkspace: String = ""
    @AppStorage("ds_active_workspace_profile_id") var activeWorkspaceProfileId: String = "ws_default"
    @AppStorage("ds_active_session_id") var activeSessionId: String = ""
    @AppStorage("ds_has_paired_once") var hasPairedOnce: Bool = false
    @AppStorage("ds_last_bundled_build") var lastBundledBuild: String = ""

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
    @Published var workspaceProfiles: [WorkspaceProfileItem] = []
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
    @Published var rendezvousStatus: String = "自动解析"
    @Published var rendezvousResolvedURLs: [String] = []
    @Published var searchConfig: SearchConfigItem = SearchConfigItem()
    @Published var dshProfileDir: String = ""

    // Sessions, Chat Turns, Attachments, Queue & Review Approvals
    @Published var sessions: [SessionSummaryItem] = []
    @Published var turns: [ChatTurnItem] = []
    @Published var pendingAttachments: [ChatAttachmentItem] = []
    @Published var editingTurnId: String? = nil
    @Published var pendingApprovals: [PendingApprovalItem] = []
    @Published var activeApprovalForPopup: PendingApprovalItem?
    @Published var queuedMessages: [QueuedMessageItem] = []
    @Published var sessionStatus: String = "idle"

    // v0.9.0 Wallet & Built-in Collaborative Browser
    @Published var walletSummary: WalletSummaryData = WalletSummaryData()
    @Published var activeBrowserSessions: [String: BrowserSessionState] = [:]

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

    // High-Frame-Rate Streaming Token Coalescing Buffer & Deduplicated LiveActivity State
    private var streamFlushTask: Task<Void, Never>?
    private var pendingTurnIdForBuffer: String = ""
    private var bufferedThoughtText: String?
    private var bufferedAssistantText: String?
    private var lastNotifiedIslandPhase: DeepSeekIslandPhase?
    private var lastNotifiedToolCount: Int = -1

    private let pathMonitor = NWPathMonitor()
    private var lastNetworkSignature: String = ""

    var effectiveRendezvousGistID: String {
        let trimmed = savedRendezvousGistID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.rendezvousGistID : trimmed
    }

    var effectivePresetURLs: [(label: String, url: String)] {
        var list: [(label: String, url: String)] = []
        var seen = Set<String>()

        func appendUnique(_ label: String, _ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let norm = Self.normalizeURL(trimmed)
            if !seen.contains(norm) {
                seen.insert(norm)
                list.append((label, norm))
            }
        }

        // Fixed addresses first (LAN IP, Tailscale HTTPS domain, Tailscale IP)
        for item in Self.defaultPresetURLs {
            appendUnique(item.label, item.url)
        }
        // Dynamically decrypted fixed-rendezvous routes (updates on every PC boot)
        for url in rendezvousResolvedURLs {
            let label = url.contains("trycloudflare.com")
                ? "固定解析 · 公网隧道"
                : (url.contains("ts.net") || url.contains("100.")) ? "固定解析 · Tailscale" : "固定解析 · 局域网"
            appendUnique(label, url)
        }
        // Cached or bundled public URL fallback
        appendUnique("Cloudflare 缓存地址", savedPublicURL)
        appendUnique("Cloudflare 外网(内置)", Self.initialCloudflareURL)
        return list
    }

    private lazy var probeSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 8.5
        cfg.timeoutIntervalForResource = 9.5
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

    nonisolated static func normalizeURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = "http://192.168.31.190:8765" }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    nonisolated static func decryptRendezvousEnvelope(_ envelopeString: String, token: String) -> [String] {
        guard let envData = envelopeString.data(using: .utf8),
              let env = try? JSONSerialization.jsonObject(with: envData) as? [String: Any],
              (env["v"] as? Int) == 1,
              let nB64 = env["n"] as? String,
              let cB64 = env["c"] as? String,
              let mB64 = env["m"] as? String,
              let nonce = Data(base64Encoded: nB64),
              let ct = Data(base64Encoded: cB64),
              let tag = Data(base64Encoded: mB64) else {
            return []
        }

        let trimmedTok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seedData = ("ds-route-v1:" + trimmedTok).data(using: .utf8) else { return [] }
        let keyData = Data(SHA256.hash(data: seedData))
        let symKey = SymmetricKey(data: keyData)

        var macInput = Data(nonce)
        macInput.append(ct)
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: macInput, using: symKey) else {
            return []
        }

        var plain = Data(capacity: ct.count)
        var counter: UInt32 = 0
        var offset = 0
        while offset < ct.count {
            var blockInput = Data(keyData)
            blockInput.append(nonce)
            var beCounter = counter.bigEndian
            withUnsafeBytes(of: &beCounter) { blockInput.append(contentsOf: $0) }
            let keystream = Data(SHA256.hash(data: blockInput))
            let end = min(offset + 32, ct.count)
            for i in offset..<end {
                plain.append(ct[i] ^ keystream[i - offset])
            }
            counter &+= 1
            offset = end
        }

        guard let payload = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            return []
        }
        var out: [String] = []
        if let lan = payload["lan_urls"] as? [String] {
            out.append(contentsOf: lan)
        }
        if let ts = payload["tailscale_urls"] as? [String] {
            out.append(contentsOf: ts)
        }
        if let pub = payload["public_url"] as? String, !pub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(pub)
        }
        var unique: [String] = []
        for raw in out {
            let norm = normalizeURL(raw)
            if !norm.isEmpty && !unique.contains(norm) {
                unique.append(norm)
            }
        }
        return unique
    }

    nonisolated static func fetchRendezvousURLs(gistID: String, token: String, session: URLSession) async -> [String] {
        let cleanID = gistID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty,
              let url = URL(string: "https://api.github.com/gists/\(cleanID)") else {
            return []
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5.5
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("DeepSeekMobile", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = root["files"] as? [String: Any] else {
                return []
            }
            let fileObj = (files["endpoint.enc"] as? [String: Any]) ?? (files.values.first as? [String: Any])
            guard let content = fileObj?["content"] as? String else { return [] }
            return decryptRendezvousEnvelope(content, token: token)
        } catch {
            return []
        }
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

    private nonisolated static func probeVerifyCandidate(
        _ candidate: String,
        body: Data,
        session: URLSession
    ) async -> (ok: Bool, url: String, data: Data?, latencyMs: Double, reason: String) {
        guard let endpoint = URL(string: candidate + "/api/auth/verify") else {
            return (false, candidate, nil, 0, "无效地址")
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 8.5
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let t0 = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let ms = Date().timeIntervalSince(t0) * 1000.0
            if let http = resp as? HTTPURLResponse {
                if http.statusCode == 200 {
                    return (true, candidate, data, ms, "")
                } else if http.statusCode == 401 {
                    return (false, candidate, nil, ms, "Auth Token 错误 (401)")
                } else {
                    return (false, candidate, nil, ms, "HTTP \(http.statusCode)")
                }
            }
            return (false, candidate, nil, ms, "响应无效")
        } catch {
            return (false, candidate, nil, 0, error.localizedDescription)
        }
    }

    private nonisolated static func probeHealthCandidate(
        _ cand: String,
        session: URLSession
    ) async -> (url: String, latencyMs: Double)? {
        guard let u = URL(string: cand + "/api/health") else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = 8.0
        let t0 = Date()
        if let (_, resp) = try? await session.data(for: req),
           let http = resp as? HTTPURLResponse,
           http.statusCode == 200 {
            return (cand, Date().timeIntervalSince(t0) * 1000.0)
        }
        return nil
    }

    func bootstrap() async {
        if authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            authToken = Self.defaultToken
        }
        if savedRendezvousGistID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            savedRendezvousGistID = Self.rendezvousGistID
        }
        // Clear stale temporary trycloudflare.com URLs cached from older app builds
        let curBuild = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
        if !curBuild.isEmpty && lastBundledBuild != curBuild {
            lastBundledBuild = curBuild
            if savedPublicURL.contains("trycloudflare.com") {
                savedPublicURL = Self.initialCloudflareURL
            }
            if serverURL.contains("trycloudflare.com") || serverURL == "http://dsh-pc" {
                serverURL = "https://dsh-pc.tail1e24af.ts.net"
            }
            AppLogger.shared.info("Lifecycle", "检测到版本更新 Build \(curBuild)，已启用固定域名与加密路由解析")
        }
        if hasPairedOnce && !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isAuthenticated = true
        }
        await verifyAndLogin(url: serverURL, token: authToken, silentIfPaired: hasPairedOnce)
    }

    func verifyAndLogin(url: String, token: String, silentIfPaired: Bool = false) async {
        let attemptId = UUID()
        connectAttemptId = attemptId
        isConnecting = true
        authError = nil
        probeDiagnostics = []

        let rawURL = Self.normalizeURL(url)
        let rawTok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveToken = rawTok.isEmpty ? Self.defaultToken : rawTok
        self.authToken = effectiveToken
        let gistID = effectiveRendezvousGistID

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
            case success(url: String, data: Data, latencyMs: Double, resolved: [String])
            case failure(url: String, reason: String, resolved: [String])
        }

        var winningURL: String?
        var winningData: Data?
        var winningLatency: Double?
        var failures: [(String, String)] = []

        await withTaskGroup(of: ProbeOutcome.self) { group in
            for candidate in candidates {
                group.addTask {
                    let item = await Self.probeVerifyCandidate(candidate, body: body, session: session)
                    if item.ok, let d = item.data {
                        return .success(url: item.url, data: d, latencyMs: item.latencyMs, resolved: [])
                    }
                    return .failure(url: item.url, reason: item.reason, resolved: [])
                }
            }
            if !gistID.isEmpty {
                group.addTask { [candidates, gistID, effectiveToken, body, session] in
                    let resolved = await Self.fetchRendezvousURLs(gistID: gistID, token: effectiveToken, session: session)
                    let extra = resolved.filter { !candidates.contains($0) }
                    if extra.isEmpty {
                        return .failure(
                            url: "固定解析器",
                            reason: resolved.isEmpty ? "GitHub 暂不可达" : "路由已覆盖",
                            resolved: resolved
                        )
                    }
                    var bestHit: ProbeOutcome?
                    var lastErr = "均不可达"
                    await withTaskGroup(of: (ok: Bool, url: String, data: Data?, latencyMs: Double, reason: String).self) { sub in
                        for ex in extra {
                            sub.addTask {
                                await Self.probeVerifyCandidate(ex, body: body, session: session)
                            }
                        }
                        for await item in sub {
                            if item.ok, let d = item.data {
                                bestHit = .success(url: item.url, data: d, latencyMs: item.latencyMs, resolved: resolved)
                                sub.cancelAll()
                                break
                            } else {
                                lastErr = item.reason
                            }
                        }
                    }
                    return bestHit ?? .failure(url: extra.first ?? "固定解析器", reason: lastErr, resolved: resolved)
                }
            }

            for await outcome in group {
                switch outcome {
                case .success(let okURL, let okData, let ms, let resolved):
                    self.applyResolvedRendezvous(resolved)
                    winningURL = okURL
                    winningData = okData
                    winningLatency = ms
                    group.cancelAll()
                case .failure(let badURL, let reason, let resolved):
                    self.applyResolvedRendezvous(resolved)
                    failures.append((badURL, reason))
                }
                if winningURL != nil { break }
            }
        }

        guard connectAttemptId == attemptId else { return }

        if let okURL = winningURL, let data = winningData {
            self.serverURL = okURL
            self.lastRouteLatencyMs = winningLatency
            self.hasPairedOnce = true
            AppLogger.shared.info("Auth", "并发路由测速成功 -> \(okURL) (\(Int(winningLatency ?? 0))ms)")
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let settings = json["settings"] as? [String: Any] {
                applySettings(settings)
            }
            isAuthenticated = true
            isConnecting = false
            Haptics.success()
            await loadWorkspaceProfiles()
            await loadSessions()
            await loadPCDrives()
            await loadPCDirectory(activeWorkspace)
            await loadPlugins()
            await loadWalletSummary()
            await refreshGitDiff()
        } else {
            isConnecting = false
            probeDiagnostics = failures.map { "\($0.0) → \($0.1)" }
            AppLogger.shared.error("Auth", "全部链路连接失败: \(probeDiagnostics.joined(separator: "; "))")
            let isAuth401 = failures.contains(where: { $0.1.contains("401") })
            if isAuth401 {
                hasPairedOnce = false
                isAuthenticated = false
                authError = "Auth Token 不匹配，请核对电脑端控制台打印的 Token。"
            } else {
                isAuthenticated = silentIfPaired
                authError = "所有链路均未连上电脑，请点击刷新重连，或检查电脑端 bridge 服务是否启动。"
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
        hasPairedOnce = false
        isAuthenticated = false
        isConnected = false
        AppLogger.shared.warn("Auth", "已断开并退出登录")
    }

    // MARK: - Single-Flight Automatic Route Failover & Hardened HTTP Request

    private func applyResolvedRendezvous(_ resolved: [String]) {
        guard !resolved.isEmpty else { return }
        rendezvousResolvedURLs = resolved
        rendezvousStatus = "已解析 (\(resolved.count) 链路)"
        if let pub = resolved.first(where: { $0.contains("trycloudflare.com") }) {
            savedPublicURL = pub
        }
    }

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

            struct FailoverProbe: Sendable {
                let hit: (url: String, latencyMs: Double)?
                let resolved: [String]
            }

            let session = self.probeSession
            let gistID = self.effectiveRendezvousGistID
            let tok = self.authToken
            var chosen: (url: String, latencyMs: Double)?
            await withTaskGroup(of: FailoverProbe.self) { group in
                for cand in candidates {
                    group.addTask {
                        let hit = await Self.probeHealthCandidate(cand, session: session)
                        return FailoverProbe(hit: hit, resolved: [])
                    }
                }
                if !gistID.isEmpty && !tok.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    group.addTask { [candidates, gistID, tok, session] in
                        let resolved = await Self.fetchRendezvousURLs(gistID: gistID, token: tok, session: session)
                        let extra = resolved.filter { !candidates.contains($0) }
                        guard !extra.isEmpty else { return FailoverProbe(hit: nil, resolved: resolved) }
                        var found: (String, Double)?
                        await withTaskGroup(of: (url: String, latencyMs: Double)?.self) { sub in
                            for ex in extra {
                                sub.addTask { await Self.probeHealthCandidate(ex, session: session) }
                            }
                            for await hit in sub {
                                if let hit = hit {
                                    found = hit
                                    sub.cancelAll()
                                    break
                                }
                            }
                        }
                        return FailoverProbe(hit: found, resolved: resolved)
                    }
                }
                for await outcome in group {
                    self.applyResolvedRendezvous(outcome.resolved)
                    if let hit = outcome.hit {
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
        let best = await attemptRouteFailover()
        if isAuthenticated && best != nil {
            if sessions.isEmpty {
                try? await fetchSettings()
                await loadSessions()
                await loadPCDrives()
                await loadPCDirectory(activeWorkspace)
                await loadPlugins()
            } else {
                connectWebSocket(reset: false)
            }
        }
        AppLogger.shared.info("Stability", "触发连接自愈 (\(reason)) -> \(best ?? "未就绪")")
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
        if let gid = json["rendezvous_gist_id"] as? String, !gid.isEmpty {
            savedRendezvousGistID = gid
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
                    supportsVision: (item["supports_vision"] as? Bool) ?? false,
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
                if let gid = json["rendezvous_gist_id"] as? String, !gid.isEmpty {
                    savedRendezvousGistID = gid
                }
                if let rs = json["rendezvous_status"] as? String, !rs.isEmpty {
                    rendezvousStatus = rs == "synced" ? "已加密同步" : rs
                }
            }
        } catch {}
    }

    func syncRendezvousOnPC() async {
        do {
            let data = try await request("/api/tunnel/sync_rendezvous", method: "POST")
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tun = json["tunnel"] as? [String: Any] {
                if let url = tun["live_url"] as? String, !url.isEmpty {
                    savedPublicURL = url
                }
                if let gid = tun["rendezvous_gist_id"] as? String, !gid.isEmpty {
                    savedRendezvousGistID = gid
                }
                let res = json["result"] as? [String: Any]
                if (res?["ok"] as? Bool) == true {
                    rendezvousStatus = "已加密同步"
                    showToastMessage("固定路由已加密同步到云端解析器")
                    Haptics.success()
                } else if let err = res?["error"] as? String {
                    rendezvousStatus = "同步失败: \(err)"
                }
            }
        } catch {
            rendezvousStatus = "请求失败"
        }
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
                if let gid = json["rendezvous_gist_id"] as? String, !gid.isEmpty {
                    savedRendezvousGistID = gid
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
                "supports_vision": p.supportsVision,
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
                        model: (item["model"] as? String) ?? "deepseek-flash",
                        workspaceProfileId: (item["workspace_profile_id"] as? String) ?? "ws_default",
                        workspace: (item["workspace"] as? String) ?? ""
                    )
                }
                self.sessions = parsed
                if activeSessionId.isEmpty || !parsed.contains(where: { $0.sessionId == activeSessionId }) {
                    let matchingWS = parsed.first(where: { $0.workspaceProfileId == activeWorkspaceProfileId })
                    if let chosen = matchingWS ?? parsed.first {
                        activeSessionId = chosen.sessionId
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
            "workspace_profile_id": activeWorkspaceProfileId,
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
                model: (json["model"] as? String) ?? selectedModel,
                workspaceProfileId: (json["workspace_profile_id"] as? String) ?? activeWorkspaceProfileId,
                workspace: (json["workspace"] as? String) ?? ws
            )
            sessions.insert(item, at: 0)
            await selectSession(sid)
            return item
        }
        return nil
    }

    func selectSession(_ sessionId: String) async {
        flushStreamingBufferImmediate()
        lastNotifiedIslandPhase = nil
        lastNotifiedToolCount = -1
        activeSessionId = sessionId
        editingTurnId = nil
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

    private func flushStreamingBufferImmediate() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        guard bufferedThoughtText != nil || bufferedAssistantText != nil else { return }
        let thought = bufferedThoughtText
        let assistant = bufferedAssistantText
        let targetTid = pendingTurnIdForBuffer
        bufferedThoughtText = nil
        bufferedAssistantText = nil
        pendingTurnIdForBuffer = ""

        var tx = Transaction(animation: nil)
        tx.disablesAnimations = true
        withTransaction(tx) {
            let tIdx = activeTurnIndex(for: targetTid)
            if let thought = thought {
                turns[tIdx].thoughtText = thought
            }
            if let assistant = assistant {
                turns[tIdx].assistantText = assistant
            }
        }
    }

    private func scheduleStreamBufferFlush() {
        guard streamFlushTask == nil else { return }
        streamFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 36_000_000)
            guard !Task.isCancelled, let self = self else { return }
            self.streamFlushTask = nil
            self.flushStreamingBufferImmediate()
        }
    }

    private func handleSocketPayload(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        if type == "ping" || type == "pong" { return }
        if type == "sync_complete" {
            flushStreamingBufferImmediate()
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
        let turnId = (d["turn_id"] as? String) ?? (msg["turn_id"] as? String) ?? ""
        if let sess = d["session"] as? [String: Any] {
            applySessionSummary(sess)
        }

        switch type {
        case "user_message":
            flushStreamingBufferImmediate()
            lastNotifiedIslandPhase = nil
            lastNotifiedToolCount = -1
            let text = (d["text"] as? String) ?? ""
            let atts = Self.parseAttachmentItems((d["attachments"] as? [[String: Any]]) ?? [])
            if !turnId.isEmpty, let existingIdx = turns.firstIndex(where: { $0.turnId == turnId || $0.id == turnId }) {
                turns[existingIdx].userText = text
                if !atts.isEmpty {
                    turns[existingIdx].attachments = atts
                }
            } else {
                turns.append(
                    ChatTurnItem(
                        id: turnId.isEmpty ? UUID().uuidString : turnId,
                        turnId: turnId,
                        userText: text,
                        attachments: atts
                    )
                )
            }
            if wsSynced {
                LiveActivityController.shared.notifyTurnStarted(sessionTitle: "DeepSeek")
            }

        case "turn_deleted":
            flushStreamingBufferImmediate()
            let tid = (d["turn_id"] as? String) ?? turnId
            if !tid.isEmpty {
                turns.removeAll { $0.turnId == tid || $0.id == tid }
            }

        case "turns_truncated":
            flushStreamingBufferImmediate()
            if let removed = d["removed_turn_ids"] as? [String], !removed.isEmpty {
                turns.removeAll { removed.contains($0.turnId) || removed.contains($0.id) }
            } else if let fromTid = d["from_turn_id"] as? String,
                      !fromTid.isEmpty,
                      let idx = turns.firstIndex(where: { $0.turnId == fromTid || $0.id == fromTid }) {
                turns.removeSubrange(idx..<turns.count)
            }

        case "session_updated":
            let sid = (d["session_id"] as? String) ?? activeSessionId
            if let idx = sessions.firstIndex(where: { $0.sessionId == sid }) {
                if let title = d["title"] as? String, !title.isEmpty {
                    sessions[idx].title = title
                }
                if let st = d["status"] as? String, !st.isEmpty {
                    sessions[idx].status = st
                }
                if let m = d["model"] as? String, !m.isEmpty {
                    sessions[idx].model = m
                }
                if let wpid = d["workspace_profile_id"] as? String, !wpid.isEmpty {
                    sessions[idx].workspaceProfileId = wpid
                }
                if let ws = d["workspace"] as? String, !ws.isEmpty {
                    sessions[idx].workspace = ws
                }
            }

        case "image_attachment":
            flushStreamingBufferImmediate()
            let rawAtt = (d["attachment"] as? [String: Any]) ?? d
            if let att = Self.parseAttachmentItem(rawAtt) {
                let tIdx = activeTurnIndex(for: turnId)
                if !turns[tIdx].attachments.contains(where: { $0.attId == att.attId }) {
                    turns[tIdx].attachments.append(att)
                }
            }

        case "browser_state":
            flushStreamingBufferImmediate()
            let rawBrowser = (d["browser"] as? [String: Any]) ?? (d["snapshot"] as? [String: Any]) ?? d
            if let state = Self.parseBrowserSessionState(rawBrowser) {
                activeBrowserSessions[state.browserId] = state
                let tIdx = activeTurnIndex(for: turnId)
                if let bIdx = turns[tIdx].browserSessions.firstIndex(where: { $0.browserId == state.browserId }) {
                    turns[tIdx].browserSessions[bIdx] = state
                } else {
                    turns[tIdx].browserSessions.append(state)
                }
            }

        case "agent_team_update":
            flushStreamingBufferImmediate()
            let rawAgents = (d["agents"] as? [[String: Any]]) ?? (d["subagents"] as? [[String: Any]]) ?? []
            let agents = Self.parseTeamAgents(rawAgents)
            let tIdx = activeTurnIndex(for: turnId)
            turns[tIdx].teamAgents = agents

        case "model_auto_switched":
            flushStreamingBufferImmediate()
            let tIdx = activeTurnIndex(for: turnId)
            turns[tIdx].modelSwitchedNote = (d["reason"] as? String) ?? (d["message"] as? String) ?? "已自动切换模型"
            if let newModel = (d["to_model"] as? String) ?? (d["model"] as? String), !newModel.isEmpty {
                selectedModel = newModel
            }
            if let newProf = (d["to_profile_id"] as? String) ?? (d["profile_id"] as? String), !newProf.isEmpty {
                activeProfileId = newProf
            }

        case "thought_delta":
            if !turnId.isEmpty && !pendingTurnIdForBuffer.isEmpty && turnId != pendingTurnIdForBuffer {
                flushStreamingBufferImmediate()
            }
            let tIdx = activeTurnIndex(for: turnId)
            if !turnId.isEmpty {
                pendingTurnIdForBuffer = turnId
            }
            if let full = d["full_text"] as? String {
                bufferedThoughtText = full
            } else if let delta = d["text"] as? String {
                let base = bufferedThoughtText ?? turns[tIdx].thoughtText
                bufferedThoughtText = base + delta
            }
            if wsSynced {
                scheduleStreamBufferFlush()
                let curTools = turns[tIdx].toolCalls.count
                if lastNotifiedIslandPhase != .thinking || lastNotifiedToolCount != curTools {
                    lastNotifiedIslandPhase = .thinking
                    lastNotifiedToolCount = curTools
                    LiveActivityController.shared.notifyPhaseChanged(
                        .thinking,
                        toolCount: curTools,
                        queuedCount: queuedMessages.count
                    )
                }
            } else {
                flushStreamingBufferImmediate()
            }

        case "tool_call":
            flushStreamingBufferImmediate()
            let tIdx = activeTurnIndex(for: turnId)
            let tcId = (d["id"] as? String) ?? UUID().uuidString
            let name = (d["name"] as? String) ?? "tool"
            let argsObj = d["args"] ?? [:]
            let argsData = (try? JSONSerialization.data(withJSONObject: argsObj, options: [.prettyPrinted])) ?? Data()
            let argsStr = String(data: argsData, encoding: .utf8) ?? "{}"
            let idx = turns[tIdx].toolCalls.count + 1
            turns[tIdx].toolCalls.append(
                ToolCallItem(id: tcId, index: idx, name: name, argsText: argsStr)
            )
            if wsSynced {
                Haptics.light()
                lastNotifiedIslandPhase = .callingTool
                lastNotifiedToolCount = idx
                LiveActivityController.shared.notifyPhaseChanged(
                    .callingTool,
                    toolCount: idx,
                    queuedCount: queuedMessages.count
                )
            }

        case "tool_result":
            flushStreamingBufferImmediate()
            let tIdx = activeTurnIndex(for: turnId)
            let tcId = (d["id"] as? String) ?? ""
            let errStr = d["error"] as? String
            let resStr = (d["result"] as? String) ?? ""
            if let pos = turns[tIdx].toolCalls.firstIndex(where: { $0.id == tcId }) {
                turns[tIdx].toolCalls[pos].resultText = errStr ?? resStr
                turns[tIdx].toolCalls[pos].isError = (errStr != nil)
            }

        case "file_artifact":
            flushStreamingBufferImmediate()
            let tIdx = activeTurnIndex(for: turnId)
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
                preview: (d["preview"] as? String) ?? "",
                isImage: (d["is_image"] as? Bool) ?? false,
                attId: (d["att_id"] as? String) ?? "",
                imageURL: (d["image_url"] as? String) ?? "",
                thumbURL: (d["thumb_url"] as? String) ?? "",
                imageWidth: (d["width"] as? NSNumber)?.intValue ?? (d["width"] as? Int) ?? 0,
                imageHeight: (d["height"] as? NSNumber)?.intValue ?? (d["height"] as? Int) ?? 0
            )
            if let existingIdx = turns[tIdx].artifacts.firstIndex(where: { $0.path == art.path }) {
                turns[tIdx].artifacts[existingIdx] = art
            } else {
                turns[tIdx].artifacts.append(art)
            }
            if wsSynced { Haptics.light() }

        case "text_delta":
            if !turnId.isEmpty && !pendingTurnIdForBuffer.isEmpty && turnId != pendingTurnIdForBuffer {
                flushStreamingBufferImmediate()
            }
            let tIdx = activeTurnIndex(for: turnId)
            if !turnId.isEmpty {
                pendingTurnIdForBuffer = turnId
            }
            if let full = d["full_text"] as? String {
                bufferedAssistantText = full
            } else if let delta = d["text"] as? String {
                let base = bufferedAssistantText ?? turns[tIdx].assistantText
                bufferedAssistantText = base + delta
            }
            if wsSynced {
                scheduleStreamBufferFlush()
                let curTools = turns[tIdx].toolCalls.count
                if lastNotifiedIslandPhase != .answering || lastNotifiedToolCount != curTools {
                    lastNotifiedIslandPhase = .answering
                    lastNotifiedToolCount = curTools
                    LiveActivityController.shared.notifyPhaseChanged(
                        .answering,
                        toolCount: curTools,
                        queuedCount: queuedMessages.count
                    )
                }
            } else {
                flushStreamingBufferImmediate()
            }

        case "approval_request":
            flushStreamingBufferImmediate()
            if wsSynced {
                Haptics.warning()
                let first = pendingApprovals.first
                let reqId = (d["request_id"] as? String) ?? first?.id ?? ""
                let tool = (d["tool_name"] as? String) ?? first?.toolName ?? "tool"
                let risk = (d["risk_level"] as? String) ?? first?.riskLevel ?? "medium"
                let summary = (d["review_summary"] as? String) ?? first?.reviewSummary ?? (first?.argsJSON ?? "")
                lastNotifiedIslandPhase = .waitingApproval
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
            flushStreamingBufferImmediate()
            lastNotifiedIslandPhase = nil
            lastNotifiedToolCount = -1
            if let u = (d["usage"] as? [String: Any]) ?? (msg["usage"] as? [String: Any]) {
                let tIdx = activeTurnIndex(for: turnId)
                turns[tIdx].usage = Self.parseTurnUsage(u)
            }
            sessionStatus = "idle"
            if wsSynced {
                Haptics.success()
                LiveActivityController.shared.notifyTurnFinished()
                Task { await loadWalletSummary() }
            }

        case "error":
            flushStreamingBufferImmediate()
            lastNotifiedIslandPhase = nil
            lastNotifiedToolCount = -1
            let tIdx = activeTurnIndex(for: turnId)
            turns[tIdx].errorText = (d["message"] as? String) ?? "连接中断，请重试"
            sessionStatus = "error"
            if wsSynced {
                LiveActivityController.shared.notifyTurnFinished()
            }

        default:
            break
        }
    }

    @discardableResult
    private func activeTurnIndex(for turnId: String = "") -> Int {
        if !turnId.isEmpty, let idx = turns.firstIndex(where: { $0.turnId == turnId || $0.id == turnId }) {
            return idx
        }
        if turns.isEmpty {
            turns.append(ChatTurnItem(id: turnId.isEmpty ? UUID().uuidString : turnId, turnId: turnId))
            return 0
        }
        if !turnId.isEmpty && turns[turns.count - 1].turnId.isEmpty {
            turns[turns.count - 1].turnId = turnId
        }
        return turns.count - 1
    }

    private func ensureActiveTurn(turnId: String = "") {
        _ = activeTurnIndex(for: turnId)
    }

    static func parseAttachmentItem(_ raw: [String: Any]) -> ChatAttachmentItem? {
        let attId = (raw["att_id"] as? String)
            ?? (raw["attachment_id"] as? String)
            ?? (raw["id"] as? String)
            ?? ""
        guard !attId.isEmpty else { return nil }
        return ChatAttachmentItem(
            attId: attId,
            filename: (raw["filename"] as? String) ?? (raw["name"] as? String) ?? "image.jpg",
            mimeType: (raw["mime_type"] as? String) ?? "image/jpeg",
            width: (raw["width"] as? NSNumber)?.intValue ?? 0,
            height: (raw["height"] as? NSNumber)?.intValue ?? 0,
            size: (raw["size"] as? NSNumber)?.intValue ?? 0,
            url: (raw["url"] as? String) ?? "/api/attachments/\(attId)",
            thumbURL: (raw["thumb_url"] as? String) ?? "/api/attachments/\(attId)/thumb",
            source: (raw["source"] as? String) ?? "upload"
        )
    }

    static func parseAttachmentItems(_ list: [[String: Any]]) -> [ChatAttachmentItem] {
        list.compactMap { parseAttachmentItem($0) }
    }

    static func parseTurnUsage(_ u: [String: Any]) -> TurnUsageInfo {
        let pTok = (u["prompt_tokens"] as? NSNumber)?.intValue ?? 0
        let cHit = (u["cache_hit_tokens"] as? NSNumber)?.intValue
            ?? (u["prompt_cache_hit_tokens"] as? NSNumber)?.intValue
            ?? 0
        let compTok = (u["completion_tokens"] as? NSNumber)?.intValue ?? 0
        let reasTok = (u["reasoning_tokens"] as? NSNumber)?.intValue ?? 0
        let totTok = (u["total_tokens"] as? NSNumber)?.intValue ?? (pTok + compTok)
        let cost = (u["cost"] as? NSNumber)?.doubleValue ?? 0.0
        return TurnUsageInfo(
            promptTokens: pTok,
            cacheHitTokens: cHit,
            completionTokens: compTok,
            reasoningTokens: reasTok,
            totalTokens: totTok,
            cost: cost,
            currency: (u["currency"] as? String) ?? "CNY",
            model: (u["model"] as? String) ?? "",
            estimated: (u["estimated"] as? Bool) ?? false
        )
    }

    static func parseBrowserSessionState(_ raw: [String: Any]) -> BrowserSessionState? {
        let bid = (raw["browser_id"] as? String) ?? (raw["id"] as? String) ?? ""
        guard !bid.isEmpty else { return nil }
        let rawEls = (raw["elements"] as? [[String: Any]]) ?? []
        let els: [BrowserElementItem] = rawEls.compactMap { e in
            guard let eid = (e["id"] as? NSNumber)?.intValue ?? (e["id"] as? Int) else { return nil }
            let bboxRaw = (e["bbox"] as? [Any]) ?? []
            let bbox = bboxRaw.compactMap { ($0 as? NSNumber)?.intValue ?? ($0 as? Int) }
            return BrowserElementItem(
                id: eid,
                tag: (e["tag"] as? String) ?? "a",
                type: (e["type"] as? String) ?? "link",
                text: (e["text"] as? String) ?? "",
                href: (e["href"] as? String) ?? "",
                value: (e["value"] as? String) ?? "",
                bbox: bbox
            )
        }
        return BrowserSessionState(
            browserId: bid,
            sessionId: (raw["session_id"] as? String) ?? "global",
            url: (raw["url"] as? String) ?? "about:blank",
            title: (raw["title"] as? String) ?? "浏览器",
            controlOwner: (raw["control_owner"] as? String) ?? "agent",
            humanRequired: (raw["human_required"] as? Bool) ?? false,
            humanReason: (raw["human_reason"] as? String) ?? "",
            scrollY: (raw["scroll_y"] as? NSNumber)?.intValue ?? 0,
            elements: els,
            textMarkdown: (raw["text_markdown"] as? String) ?? "",
            frameB64: (raw["frame_b64"] as? String) ?? (raw["last_frame_b64"] as? String) ?? ""
        )
    }

    static func parseTeamAgents(_ list: [[String: Any]]) -> [TeamSubagentItem] {
        list.compactMap { item in
            let aid = (item["agent_id"] as? String) ?? (item["id"] as? String) ?? ""
            guard !aid.isEmpty else { return nil }
            let rawStatus = (item["status"] as? String) ?? "running"
            let normalizedStatus = (rawStatus == "idle") ? "done" : rawStatus
            let usageDict = item["usage"] as? [String: Any]
            let costVal = (item["cost"] as? NSNumber)?.doubleValue
                ?? (usageDict?["cost"] as? NSNumber)?.doubleValue
                ?? 0.0
            return TeamSubagentItem(
                agentId: aid,
                role: (item["role"] as? String) ?? "Subagent",
                task: (item["task"] as? String) ?? (item["goal"] as? String) ?? (item["title"] as? String) ?? "",
                status: normalizedStatus,
                model: (item["model"] as? String) ?? "",
                roundsUsed: (item["rounds_used"] as? NSNumber)?.intValue ?? (item["rounds"] as? NSNumber)?.intValue ?? 1,
                cost: costVal,
                resultSummary: (item["result_summary"] as? String)
                    ?? (item["summary_text"] as? String)
                    ?? (item["summary"] as? String)
                    ?? (item["result"] as? String)
                    ?? "",
                transcriptPreview: (item["transcript_preview"] as? String)
                    ?? (item["preview"] as? String)
                    ?? (item["summary_text"] as? String)
                    ?? ""
            )
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
        if let sid = sess["session_id"] as? String,
           let idx = sessions.firstIndex(where: { $0.sessionId == sid }) {
            if let title = sess["title"] as? String, !title.isEmpty {
                sessions[idx].title = title
            }
            if let st = sess["status"] as? String, !st.isEmpty {
                sessions[idx].status = st
            }
            if let m = sess["model"] as? String, !m.isEmpty {
                sessions[idx].model = m
            }
            if let wpid = sess["workspace_profile_id"] as? String, !wpid.isEmpty {
                sessions[idx].workspaceProfileId = wpid
            }
            if let ws = sess["workspace"] as? String, !ws.isEmpty {
                sessions[idx].workspace = ws
            }
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
        guard (!clean.isEmpty || !pendingAttachments.isEmpty), !activeSessionId.isEmpty else { return }
        Haptics.light()
        let attIds = pendingAttachments.map(\.attId)
        pendingAttachments = []

        if let editTid = editingTurnId, !editTid.isEmpty {
            editingTurnId = nil
            await editAndResendTurn(editTid, newText: clean, attachments: attIds)
            return
        }

        let effectivePrompt = clean.isEmpty ? "请查看并分析这些图片" : clean
        do {
            let body = try JSONSerialization.data(withJSONObject: [
                "prompt": effectivePrompt,
                "attachments": attIds,
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

    // MARK: - Module C: Session & Turn Operations

    func renameSession(_ sessionId: String, title: String) async {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["title": clean])
            let data = try await request("/api/sessions/\(sessionId)", method: "PATCH", body: body)
            if let idx = sessions.firstIndex(where: { $0.sessionId == sessionId }) {
                sessions[idx].title = clean
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sess = json["session"] as? [String: Any] {
                applySessionSummary(sess)
            }
            Haptics.light()
            showToastMessage("会话已重命名")
        } catch {
            showToastMessage("重命名失败: \(error.localizedDescription)")
        }
    }

    func deleteSession(_ sessionId: String) async {
        do {
            _ = try await request("/api/sessions/\(sessionId)", method: "DELETE")
            sessions.removeAll { $0.sessionId == sessionId }
            Haptics.medium()
            if activeSessionId == sessionId {
                let matchingWS = sessions.first(where: { $0.workspaceProfileId == activeWorkspaceProfileId })
                if let next = matchingWS ?? sessions.first {
                    await selectSession(next.sessionId)
                } else {
                    _ = try? await createNewSession()
                }
            }
        } catch {
            showToastMessage("删除会话失败: \(error.localizedDescription)")
        }
    }

    func deleteTurn(_ turnId: String) async {
        guard !activeSessionId.isEmpty, !turnId.isEmpty else { return }
        turns.removeAll { $0.turnId == turnId || $0.id == turnId }
        Haptics.medium()
        do {
            let encTid = turnId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? turnId
            _ = try await request("/api/sessions/\(activeSessionId)/turns/\(encTid)", method: "DELETE")
        } catch {
            showToastMessage("删除消息失败: \(error.localizedDescription)")
        }
    }

    func editAndResendTurn(_ turnId: String, newText: String, attachments: [String] = []) async {
        guard !activeSessionId.isEmpty, !turnId.isEmpty else { return }
        if let idx = turns.firstIndex(where: { $0.turnId == turnId || $0.id == turnId }) {
            turns.removeSubrange(idx..<turns.count)
        }
        Haptics.light()
        do {
            let encTid = turnId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? turnId
            let payload: [String: Any] = [
                "new_text": newText,
                "text": newText,
                "prompt": newText,
                "attachments": attachments,
                "model": selectedModel,
                "profile_id": activeProfileId,
            ]
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await request(
                "/api/sessions/\(activeSessionId)/turns/\(encTid)/edit",
                method: "POST",
                body: body
            )
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sess = json["session"] as? [String: Any] {
                applySessionSummary(sess)
            }
        } catch {
            showToastMessage("重发失败: \(error.localizedDescription)")
        }
    }

    func regenerateTurn(_ turnId: String) async {
        guard !activeSessionId.isEmpty, !turnId.isEmpty else { return }
        if let idx = turns.firstIndex(where: { $0.turnId == turnId || $0.id == turnId }) {
            let userMsg = turns[idx].userText ?? ""
            turns.removeSubrange(idx..<turns.count)
            if !userMsg.isEmpty && turns.isEmpty {
                // Server will re-emit user_message or stream response
            }
        }
        Haptics.light()
        do {
            let encTid = turnId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? turnId
            let payload: [String: Any] = [
                "model": selectedModel,
                "profile_id": activeProfileId,
            ]
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await request(
                "/api/sessions/\(activeSessionId)/turns/\(encTid)/regenerate",
                method: "POST",
                body: body
            )
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sess = json["session"] as? [String: Any] {
                applySessionSummary(sess)
            }
        } catch {
            showToastMessage("重新生成失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Module A: Workspace Profiles

    private static func parseWorkspaceProfile(_ raw: [String: Any]) -> WorkspaceProfileItem? {
        guard let id = raw["id"] as? String else { return nil }
        return WorkspaceProfileItem(
            id: id,
            name: (raw["name"] as? String) ?? id,
            icon: (raw["icon"] as? String) ?? "folder.fill",
            color: (raw["color"] as? String) ?? "blue",
            rootPaths: (raw["root_paths"] as? [String]) ?? [],
            defaultProfileId: (raw["default_profile_id"] as? String) ?? "deepseek-flash",
            defaultApprovalMode: (raw["default_approval_mode"] as? String) ?? "ask_commands",
            sharedNotes: (raw["shared_notes"] as? String) ?? "",
            crossSessionRead: (raw["cross_session_read"] as? Bool) ?? true,
            sessionCount: (raw["session_count"] as? NSNumber)?.intValue ?? 0
        )
    }

    func loadWorkspaceProfiles() async {
        do {
            let data = try await request("/api/workspace-profiles")
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let rawList = (json["profiles"] as? [[String: Any]])
                    ?? (json["workspace_profiles"] as? [[String: Any]])
                    ?? []
                let parsed = rawList.compactMap { Self.parseWorkspaceProfile($0) }
                if !parsed.isEmpty {
                    workspaceProfiles = parsed
                    if !parsed.contains(where: { $0.id == activeWorkspaceProfileId }),
                       let first = parsed.first {
                        activeWorkspaceProfileId = first.id
                    }
                }
            }
        } catch {}
    }

    func selectWorkspaceProfile(_ profileId: String) async {
        activeWorkspaceProfileId = profileId
        if let prof = workspaceProfiles.first(where: { $0.id == profileId }) {
            if let firstRoot = prof.rootPaths.first, !firstRoot.isEmpty {
                activeWorkspace = firstRoot
            }
            if !prof.defaultProfileId.isEmpty {
                activeProfileId = prof.defaultProfileId
                if let matchedModel = modelProfiles.first(where: { $0.id == prof.defaultProfileId })?.model {
                    selectedModel = matchedModel
                }
            }
            if !prof.defaultApprovalMode.isEmpty {
                approvalMode = prof.defaultApprovalMode
            }
            showToastMessage("已切换工作区: \(prof.name)")
        }
        Haptics.light()
        await loadSessions()
        let matched = sessions.first(where: { $0.workspaceProfileId == profileId })
        if let matched = matched {
            if activeSessionId != matched.sessionId {
                await selectSession(matched.sessionId)
            }
        } else {
            _ = try? await createNewSession()
        }
    }

    func saveWorkspaceProfile(
        id: String?,
        name: String,
        icon: String,
        color: String,
        rootPaths: [String],
        defaultProfileId: String,
        defaultApprovalMode: String,
        sharedNotes: String,
        crossSessionRead: Bool
    ) async {
        let payload: [String: Any] = [
            "name": name,
            "icon": icon,
            "color": color,
            "root_paths": rootPaths,
            "default_profile_id": defaultProfileId,
            "default_approval_mode": defaultApprovalMode,
            "shared_notes": sharedNotes,
            "cross_session_read": crossSessionRead,
        ]
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data: Data
            if let id = id, !id.isEmpty {
                data = try await request("/api/workspace-profiles/\(id)", method: "PUT", body: body)
            } else {
                data = try await request("/api/workspace-profiles", method: "POST", body: body)
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let profDict = (json["profile"] as? [String: Any]) ?? json as [String: Any]?,
               let saved = Self.parseWorkspaceProfile(profDict) {
                if let idx = workspaceProfiles.firstIndex(where: { $0.id == saved.id }) {
                    workspaceProfiles[idx] = saved
                } else {
                    workspaceProfiles.append(saved)
                }
            }
            await loadWorkspaceProfiles()
            Haptics.success()
            showToastMessage("工作区配置已保存")
        } catch {
            showToastMessage("保存工作区失败: \(error.localizedDescription)")
        }
    }

    func deleteWorkspaceProfile(_ profileId: String, deleteSessions: Bool = false) async {
        guard profileId != "ws_default" else {
            showToastMessage("默认工作区不可删除")
            return
        }
        do {
            let flag = deleteSessions ? "true" : "false"
            _ = try await request("/api/workspace-profiles/\(profileId)?delete_sessions=\(flag)", method: "DELETE")
            workspaceProfiles.removeAll { $0.id == profileId }
            if activeWorkspaceProfileId == profileId {
                activeWorkspaceProfileId = "ws_default"
            }
            await loadWorkspaceProfiles()
            await loadSessions()
            Haptics.medium()
            showToastMessage("已删除工作区")
        } catch {
            showToastMessage("删除工作区失败: \(error.localizedDescription)")
        }
    }

    func moveSessionToWorkspaceProfile(_ sessionId: String, workspaceProfileId: String) async {
        do {
            let payload: [String: Any] = [
                "workspace_profile_id": workspaceProfileId,
                "target_workspace_profile_id": workspaceProfileId,
            ]
            let body = try JSONSerialization.data(withJSONObject: payload)
            _ = try await request("/api/sessions/\(sessionId)/move", method: "POST", body: body)
            if let idx = sessions.firstIndex(where: { $0.sessionId == sessionId }) {
                sessions[idx].workspaceProfileId = workspaceProfileId
            }
            await loadWorkspaceProfiles()
            Haptics.light()
            showToastMessage("已移动会话到目标工作区")
        } catch {
            showToastMessage("移动会话失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Module B: Attachments & PC Screenshots

    @discardableResult
    func uploadImageAttachment(data: Data, filename: String = "photo.jpg") async -> ChatAttachmentItem? {
        let b64 = data.base64EncodedString()
        let payload: [String: Any] = [
            "filename": filename,
            "base64_data": b64,
            "content_base64": b64,
            "data_base64": b64,
            "session_id": activeSessionId.isEmpty ? "global" : activeSessionId,
        ]
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let resp = try await request("/api/attachments", method: "POST", body: body, timeout: 60)
            if let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] {
                let rawAtt = (json["attachment"] as? [String: Any]) ?? json
                if let item = Self.parseAttachmentItem(rawAtt) {
                    if !pendingAttachments.contains(where: { $0.attId == item.attId }) {
                        pendingAttachments.append(item)
                    }
                    Haptics.light()
                    return item
                }
            }
        } catch {
            showToastMessage("图片上传失败: \(error.localizedDescription)")
        }
        return nil
    }

    func removePendingAttachment(_ attId: String) {
        pendingAttachments.removeAll { $0.attId == attId }
        Haptics.light()
    }

    @discardableResult
    func capturePCScreenshot(target: String = "full", windowTitle: String = "") async -> ChatAttachmentItem? {
        let payload: [String: Any] = [
            "target": target,
            "window_title": windowTitle,
            "session_id": activeSessionId.isEmpty ? "global" : activeSessionId,
        ]
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let resp = try await request("/api/pc/screenshot", method: "POST", body: body, timeout: 30)
            if let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] {
                let rawAtt = (json["attachment"] as? [String: Any]) ?? json
                if let item = Self.parseAttachmentItem(rawAtt) {
                    if !pendingAttachments.contains(where: { $0.attId == item.attId }) {
                        pendingAttachments.append(item)
                    }
                    Haptics.success()
                    showToastMessage("已抓取电脑屏幕并添加到待发栏")
                    return item
                }
            }
        } catch {
            showToastMessage("电脑截屏失败: \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - Module E: API Wallet & Token Ledger

    func loadWalletSummary(forceBalance: Bool = false) async {
        let flag = forceBalance ? "true" : "false"
        do {
            let data = try await request("/api/wallet/summary?force_balance=\(flag)")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            let bal = (json["balance"] as? [String: Any]) ?? json
            let today = (json["today"] as? [String: Any]) ?? json
            let curHour = (json["current_hour"] as? [String: Any]) ?? [:]
            let rawRules = (json["rules"] as? [String: Any]) ?? [:]

            let rawByModel = (today["by_model"] as? [[String: Any]]) ?? (json["by_model"] as? [[String: Any]]) ?? []
            let byModelItems: [WalletModelUsageItem] = rawByModel.compactMap { m in
                guard let modelName = m["model"] as? String else { return nil }
                return WalletModelUsageItem(
                    model: modelName,
                    totalTokens: (m["total_tokens"] as? NSNumber)?.intValue ?? 0,
                    promptTokens: (m["prompt_tokens"] as? NSNumber)?.intValue ?? 0,
                    completionTokens: (m["completion_tokens"] as? NSNumber)?.intValue ?? 0,
                    cost: (m["cost"] as? NSNumber)?.doubleValue ?? 0.0,
                    turns: (m["turns"] as? NSNumber)?.intValue ?? 0
                )
            }

            let rawDays = (json["last_7_days"] as? [[String: Any]]) ?? []
            let dayItems: [WalletDayItem] = rawDays.compactMap { d in
                guard let dateStr = d["date"] as? String else { return nil }
                return WalletDayItem(
                    date: dateStr,
                    totalTokens: (d["total_tokens"] as? NSNumber)?.intValue
                        ?? (d["tokens"] as? NSNumber)?.intValue
                        ?? 0,
                    cost: (d["cost"] as? NSNumber)?.doubleValue ?? 0.0,
                    turns: (d["turns"] as? NSNumber)?.intValue ?? 0
                )
            }

            let rawHours = (json["hourly_today"] as? [[String: Any]]) ?? []
            let hourItems: [WalletHourItem] = rawHours.compactMap { h in
                guard let hr = h["hour"] as? String else { return nil }
                return WalletHourItem(
                    hour: hr,
                    tokens: (h["tokens"] as? NSNumber)?.intValue
                        ?? (h["total_tokens"] as? NSNumber)?.intValue
                        ?? 0,
                    cost: (h["cost"] as? NSNumber)?.doubleValue ?? 0.0
                )
            }

            let parsedRules = WalletRulesItem(
                enabled: (rawRules["enabled"] as? Bool) ?? true,
                balanceBelow: (rawRules["balance_below"] as? NSNumber)?.doubleValue ?? 5.0,
                dailySpendAbove: (rawRules["daily_spend_above"] as? NSNumber)?.doubleValue ?? 20.0,
                fallbackProfileId: (rawRules["fallback_profile_id"] as? String) ?? "deepseek-flash",
                notifyBark: (rawRules["notify_bark"] as? Bool) ?? true,
                hysteresis: (rawRules["hysteresis"] as? NSNumber)?.doubleValue ?? 1.0,
                manualBalance: (rawRules["manual_balance"] as? NSNumber)?.doubleValue,
                currency: (rawRules["currency"] as? String) ?? "CNY"
            )

            walletSummary = WalletSummaryData(
                balanceAvailable: (bal["available"] as? Bool) ?? (json["balance_available"] as? Bool) ?? false,
                balanceSource: (bal["source"] as? String) ?? (json["balance_source"] as? String) ?? "unavailable",
                totalBalance: (bal["total_balance"] as? NSNumber)?.doubleValue,
                grantedBalance: (bal["granted_balance"] as? NSNumber)?.doubleValue ?? 0.0,
                toppedUpBalance: (bal["topped_up_balance"] as? NSNumber)?.doubleValue ?? 0.0,
                currency: (bal["currency"] as? String) ?? parsedRules.currency,
                todayPromptTokens: (today["prompt_tokens"] as? NSNumber)?.intValue ?? 0,
                todayCacheHitTokens: (today["cache_hit_tokens"] as? NSNumber)?.intValue ?? 0,
                todayCompletionTokens: (today["completion_tokens"] as? NSNumber)?.intValue ?? 0,
                todayTotalTokens: (today["total_tokens"] as? NSNumber)?.intValue ?? 0,
                todayCost: (today["cost"] as? NSNumber)?.doubleValue ?? 0.0,
                todayTurns: (today["turns"] as? NSNumber)?.intValue ?? 0,
                currentHourTokens: (curHour["total_tokens"] as? NSNumber)?.intValue
                    ?? (curHour["tokens"] as? NSNumber)?.intValue
                    ?? 0,
                currentHourCost: (curHour["cost"] as? NSNumber)?.doubleValue ?? 0.0,
                byModel: byModelItems,
                last7Days: dayItems,
                hourlyToday: hourItems,
                rules: parsedRules,
                downgradeActive: (json["downgrade_active"] as? Bool) ?? false
            )
        } catch {}
    }

    func saveWalletRules(_ rules: WalletRulesItem) async {
        var payload: [String: Any] = [
            "enabled": rules.enabled,
            "balance_below": rules.balanceBelow,
            "daily_spend_above": rules.dailySpendAbove,
            "fallback_profile_id": rules.fallbackProfileId,
            "notify_bark": rules.notifyBark,
            "hysteresis": rules.hysteresis,
            "currency": rules.currency,
        ]
        if let manual = rules.manualBalance {
            payload["manual_balance"] = manual
        } else {
            payload["manual_balance"] = NSNull()
        }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            _ = try await request("/api/wallet/rules", method: "PUT", body: body)
            await loadWalletSummary(forceBalance: true)
            Haptics.success()
            showToastMessage("已保存钱包与自动降级规则")
        } catch {
            showToastMessage("保存钱包规则失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Module F: Built-in Collaborative Browser

    private func upsertBrowserStateInChat(_ state: BrowserSessionState) {
        activeBrowserSessions[state.browserId] = state
        for idx in turns.indices {
            if let bIdx = turns[idx].browserSessions.firstIndex(where: { $0.browserId == state.browserId }) {
                turns[idx].browserSessions[bIdx] = state
                return
            }
        }
        let tIdx = activeTurnIndex()
        turns[tIdx].browserSessions.append(state)
    }

    func openBrowserInChat(url: String = "https://www.deepseek.com") async {
        let createPayload: [String: Any] = [
            "session_id": activeSessionId.isEmpty ? "global" : activeSessionId,
            "workspace_profile_id": activeWorkspaceProfileId,
        ]
        do {
            let createBody = try JSONSerialization.data(withJSONObject: createPayload)
            let createData = try await request("/api/browser/sessions", method: "POST", body: createBody)
            guard let createJSON = try JSONSerialization.jsonObject(with: createData) as? [String: Any] else { return }
            let rawBrowser = (createJSON["browser"] as? [String: Any]) ?? (createJSON["session"] as? [String: Any]) ?? createJSON
            let bid = (rawBrowser["browser_id"] as? String) ?? (createJSON["browser_id"] as? String) ?? ""
            guard !bid.isEmpty else { return }

            let navPayload: [String: Any] = [
                "url": url,
                "actor": "human",
            ]
            let navBody = try JSONSerialization.data(withJSONObject: navPayload)
            let navData = try await request("/api/browser/sessions/\(bid)/navigate", method: "POST", body: navBody, timeout: 30)
            if let navJSON = try JSONSerialization.jsonObject(with: navData) as? [String: Any] {
                let snapDict = (navJSON["browser"] as? [String: Any]) ?? (navJSON["snapshot"] as? [String: Any]) ?? navJSON
                if let state = Self.parseBrowserSessionState(snapDict) {
                    upsertBrowserStateInChat(state)
                    Haptics.light()
                }
            }
        } catch {
            showToastMessage("启动内置浏览器失败: \(error.localizedDescription)")
        }
    }

    func browserNavigate(browserId: String, url: String) async {
        guard !browserId.isEmpty else { return }
        let payload: [String: Any] = ["url": url, "actor": "human"]
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await request("/api/browser/sessions/\(browserId)/navigate", method: "POST", body: body, timeout: 30)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let snapDict = (json["browser"] as? [String: Any]) ?? (json["snapshot"] as? [String: Any]) ?? json
                if let state = Self.parseBrowserSessionState(snapDict) {
                    upsertBrowserStateInChat(state)
                }
            }
        } catch {
            showToastMessage("网页跳转失败: \(error.localizedDescription)")
        }
    }

    func browserHistoryAction(browserId: String, action: String) async {
        guard !browserId.isEmpty else { return }
        let act = action.lowercased()
        if act == "close" {
            _ = try? await request("/api/browser/sessions/\(browserId)", method: "DELETE")
            activeBrowserSessions.removeValue(forKey: browserId)
            for idx in turns.indices {
                turns[idx].browserSessions.removeAll { $0.browserId == browserId }
            }
            Haptics.light()
            return
        }
        do {
            let payload: [String: Any] = ["action": act, "actor": "human"]
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await request("/api/browser/sessions/\(browserId)/\(act)", method: "POST", body: body, timeout: 25)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let snapDict = (json["browser"] as? [String: Any]) ?? (json["snapshot"] as? [String: Any]) ?? json
                if let state = Self.parseBrowserSessionState(snapDict) {
                    upsertBrowserStateInChat(state)
                }
            }
        } catch {
            // Fallback to unified /input endpoint if backend routes back/forward/reload via /input
            await browserSendInput(browserId: browserId, action: act)
        }
    }

    func browserSendInput(
        browserId: String,
        action: String,
        elementId: Int? = nil,
        x: Int? = nil,
        y: Int? = nil,
        text: String = "",
        submit: Bool = false,
        deltaY: Int = 320
    ) async {
        guard !browserId.isEmpty else { return }
        var payload: [String: Any] = [
            "action": action,
            "actor": "human",
            "text": text,
            "submit": submit,
            "delta_y": deltaY,
        ]
        if let elementId = elementId {
            payload["element_id"] = elementId
        }
        if let x = x {
            payload["x"] = x
        }
        if let y = y {
            payload["y"] = y
        }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await request("/api/browser/sessions/\(browserId)/input", method: "POST", body: body, timeout: 25)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let snapDict = (json["browser"] as? [String: Any]) ?? (json["snapshot"] as? [String: Any]) ?? json
                if let state = Self.parseBrowserSessionState(snapDict) {
                    upsertBrowserStateInChat(state)
                }
            }
        } catch {
            showToastMessage("浏览器操作失败: \(error.localizedDescription)")
        }
    }

    func browserSetControl(browserId: String, owner: String) async {
        guard !browserId.isEmpty else { return }
        let payload: [String: Any] = [
            "owner": owner,
            "control_owner": owner,
        ]
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await request("/api/browser/sessions/\(browserId)/control", method: "POST", body: body)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let snapDict = (json["browser"] as? [String: Any]) ?? (json["snapshot"] as? [String: Any]) ?? json
                if let state = Self.parseBrowserSessionState(snapDict) {
                    upsertBrowserStateInChat(state)
                    Haptics.light()
                    showToastMessage(owner == "agent" ? "已将浏览器交还给 AI 操作" : "真人已接管浏览器")
                }
            }
        } catch {
            showToastMessage("切换控制权失败: \(error.localizedDescription)")
        }
    }

    func browserScreenshotToChat(browserId: String) async {
        guard !browserId.isEmpty else { return }
        do {
            let payload: [String: Any] = [
                "session_id": activeSessionId.isEmpty ? "global" : activeSessionId,
            ]
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await request("/api/browser/sessions/\(browserId)/screenshot", method: "POST", body: body)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let rawAtt = (json["attachment"] as? [String: Any]) ?? json
                if let item = Self.parseAttachmentItem(rawAtt) {
                    if !pendingAttachments.contains(where: { $0.attId == item.attId }) {
                        pendingAttachments.append(item)
                    }
                    Haptics.success()
                    showToastMessage("已将浏览器画面插入待发附件")
                }
            }
        } catch {
            showToastMessage("浏览器截图失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Module D: Agent Team Control

    func cancelSubagent(agentId: String) async {
        guard !activeSessionId.isEmpty, !agentId.isEmpty else { return }
        Haptics.medium()
        do {
            _ = try await request("/api/sessions/\(activeSessionId)/agents/\(agentId)/cancel", method: "POST")
            for tIdx in turns.indices {
                if let aIdx = turns[tIdx].teamAgents.firstIndex(where: { $0.agentId == agentId }) {
                    turns[tIdx].teamAgents[aIdx].status = "cancelled"
                }
            }
            showToastMessage("已取消子代理任务")
        } catch {
            showToastMessage("取消子代理失败: \(error.localizedDescription)")
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
