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
    @Published var hasCloudflaredToken: Bool = false
    @Published var tunnelStatus: String = ""
    @Published var rendezvousStatus: String = "自动解析"
    @Published var rendezvousResolvedURLs: [String] = []
    @Published var searchConfig: SearchConfigItem = SearchConfigItem()

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
    @Published var presentedBrowserId: String? = nil
    var userDismissedBrowserIds: Set<String> = []

    // Full PC File Manager State
    @Published var pcDrives: [PCDriveItem] = []
    @Published var pcShortcuts: [PCShortcutItem] = []
    @Published var currentDir: String = ""
    @Published var currentParentDir: String = ""
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
    @Published var referencedFilePath: String?

    var isApplyingSettingsFromServer: Bool = false
    var lastSeq: Int = 0
    var webSocketTask: URLSessionWebSocketTask?
    var wsGeneration: UInt64 = 0
    var wsHeartbeatTask: Task<Void, Never>?
    var wsReconnectTask: Task<Void, Never>?
    var lastWSActivityAt: Date = Date()
    var consecutiveWSErrors: Int = 0
    var wsSynced: Bool = false
    var connectAttemptId: UUID = UUID()
    var failoverTask: Task<String?, Never>?
    var pcDirToken: UInt64 = 0

    // High-Frame-Rate Streaming Token Coalescing Buffer & Deduplicated LiveActivity State
    var streamFlushTask: Task<Void, Never>?
    var pendingTurnIdForBuffer: String = ""
    var bufferedThoughtText: String?
    var bufferedAssistantText: String?
    var lastNotifiedIslandPhase: DeepSeekIslandPhase?
    var lastNotifiedToolCount: Int = -1

    let pathMonitor = NWPathMonitor()
    var lastNetworkSignature: String = ""

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

    lazy var probeSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 8.5
        cfg.timeoutIntervalForResource = 9.5
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    lazy var apiSession: URLSession = {
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
        MobileBrowserManager.shared.onHumanNavigationSettled = { [weak self] browserId, snap in
            Task { @MainActor [weak self] in
                guard let self = self, self.isAuthenticated else { return }
                await self.syncMobileBrowserSnapshot(browserId: browserId, snapshot: snap)
            }
        }
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

    nonisolated static func probeVerifyCandidate(
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

    nonisolated static func probeHealthCandidate(
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
        clearStreamingBuffer()
        wsHeartbeatTask?.cancel()
        wsHeartbeatTask = nil
        wsReconnectTask?.cancel()
        wsReconnectTask = nil
        failoverTask?.cancel()
        failoverTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        hasPairedOnce = false
        isAuthenticated = false
        isConnected = false
        activeSessionId = ""
        sessions = []
        turns = []
        pendingAttachments = []
        pendingApprovals = []
        activeApprovalForPopup = nil
        queuedMessages = []
        editingTurnId = nil
        activeBrowserSessions = [:]
        presentedBrowserId = nil
        userDismissedBrowserIds = []
        lastSeq = 0
        wsSynced = false
        lastNotifiedIslandPhase = nil
        lastNotifiedToolCount = -1
        MobileBrowserManager.shared.clearAllTabs()
        AttachmentImageCache.shared.clearAll()
        LiveActivityController.shared.notifyTurnFinished()
        AppLogger.shared.warn("Auth", "已断开并退出登录")
    }

}
