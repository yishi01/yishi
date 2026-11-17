import Foundation
import SwiftUI

struct ToolCallItem: Identifiable, Hashable {
    let id: String
    let index: Int
    let name: String
    let argsText: String
    var resultText: String?
    var isError: Bool = false
}

struct FileArtifactItem: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let title: String
    let summary: String
    let size: Int
    let ext: String
    let mode: String // "review" | "download"
    let isText: Bool
    let preview: String

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

struct ChatTurnItem: Identifiable, Hashable {
    let id: String
    var userText: String?
    var thoughtText: String = ""
    var toolCalls: [ToolCallItem] = []
    var artifacts: [FileArtifactItem] = []
    var assistantText: String = ""
    var errorText: String?
}

struct PendingApprovalItem: Identifiable, Hashable {
    let id: String
    let toolName: String
    let argsJSON: String
}

struct PCDriveItem: Identifiable, Hashable {
    var id: String { path }
    let letter: String
    let name: String
    let label: String
    let path: String
    let totalBytes: Int64
    let usedBytes: Int64
    let freeBytes: Int64

    var usageRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    var formattedCapacity: String {
        let freeStr = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        let totalStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "可用 \(freeStr) / 共 \(totalStr)"
    }
}

struct PCShortcutItem: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let icon: String
}

struct FileEntryItem: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let parentPath: String
    let isDir: Bool
    let size: Int
    let mtime: Double
    let ctime: Double
    let atime: Double
    let ext: String
    let mimeType: String
    let isReadonly: Bool
    let isHidden: Bool
    let inAIWorkspace: Bool
    let aiCanRead: Bool
    let aiCanWrite: Bool

    var formattedSize: String {
        isDir ? "文件夹" : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var formattedMtime: String {
        Self.formatTimestamp(mtime)
    }

    var formattedCtime: String {
        Self.formatTimestamp(ctime)
    }

    var formattedAtime: String {
        Self.formatTimestamp(atime)
    }

    static func formatTimestamp(_ ts: Double) -> String {
        guard ts > 0 else { return "-" }
        let d = Date(timeIntervalSince1970: ts)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: d)
    }
}

struct FileClipboardItem: Equatable {
    let source: FileEntryItem
    let isMove: Bool // true = 移动(剪切), false = 复制
}

struct SessionSummaryItem: Identifiable, Hashable {
    var id: String { sessionId }
    let sessionId: String
    var title: String
    var status: String
    var model: String
}

@MainActor
final class BridgeClient: ObservableObject {
    static let defaultToken = "_44dVxHP8puOv1RjHTb-uWrgb5LY4k6s"

    @AppStorage("ds_server_url") var serverURL: String = "http://dsh-pc"
    @AppStorage("ds_auth_token") var authToken: String = "_44dVxHP8puOv1RjHTb-uWrgb5LY4k6s"
    @AppStorage("ds_active_workspace") var activeWorkspace: String = ""
    @AppStorage("ds_active_session_id") var activeSessionId: String = ""

    @Published var isAuthenticated: Bool = false
    @Published var isConnecting: Bool = false
    @Published var isConnected: Bool = false
    @Published var authError: String?

    @Published var workspaces: [String] = []
    @Published var aiAccessMode: String = "workspace_only" // "workspace_only" | "workspace_read_all" | "full_access"
    @Published var selectedModel: String = "deepseek-chat"
    @Published var approvalMode: String = "ask_commands"
    @Published var deepseekBaseURL: String = "https://api.deepseek.com"
    @Published var barkURL: String = ""
    @Published var hasAPIKey: Bool = false

    @Published var sessions: [SessionSummaryItem] = []
    @Published var turns: [ChatTurnItem] = []
    @Published var pendingApprovals: [PendingApprovalItem] = []
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
    @Published var clipboard: FileClipboardItem?
    @Published var fileError: String?

    // Git & Cross-Tab References
    @Published var gitBranch: String = ""
    @Published var gitDiff: String = ""
    @Published var isGitRepo: Bool = false
    @Published var referencedFilePath: String?
    @Published var activeArtifactForReview: FileArtifactItem?

    private var lastSeq: Int = 0
    private var webSocketTask: URLSessionWebSocketTask?
    private var wsSynced: Bool = false

    var normalizedBaseURL: String {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = "http://dsh-pc" }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    func bootstrap() async {
        if authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            authToken = Self.defaultToken
        }
        await verifyAndLogin(url: serverURL, token: authToken)
    }

    func verifyAndLogin(url: String, token: String) async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        var rawURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawURL.isEmpty { rawURL = "http://dsh-pc" }
        if !rawURL.lowercased().hasPrefix("http://") && !rawURL.lowercased().hasPrefix("https://") {
            rawURL = "http://" + rawURL
        }
        while rawURL.hasSuffix("/") { rawURL.removeLast() }

        let rawTok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authToken = rawTok.isEmpty ? Self.defaultToken : rawTok
        self.authError = nil

        var candidates: [String] = [rawURL]
        for fallback in ["http://dsh-pc", "https://dsh-pc.tail1e24af.ts.net", "http://100.88.121.40:8765"] {
            if !candidates.contains(fallback) {
                candidates.append(fallback)
            }
        }

        var lastErr: Error?
        for candidate in candidates {
            self.serverURL = candidate
            do {
                let body = try JSONSerialization.data(withJSONObject: ["token": self.authToken])
                let data = try await request("/api/auth/verify", method: "POST", body: body, useAuth: false, timeout: 8)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let settings = json["settings"] as? [String: Any] {
                    applySettings(settings)
                }
                isAuthenticated = true
                Haptics.success()
                await loadSessions()
                await loadPCDrives()
                await loadPCDirectory(activeWorkspace)
                await refreshGitDiff()
                return
            } catch {
                lastErr = error
            }
        }
        authError = "连接失败: \(lastErr?.localizedDescription ?? "请确认手机已开启 Tailscale")"
        isAuthenticated = false
    }

    func logout() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isAuthenticated = false
        isConnected = false
    }

    // MARK: - HTTP Helper

    private func request(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        useAuth: Bool = true,
        timeout: TimeInterval = 25
    ) async throws -> Data {
        guard let url = URL(string: normalizedBaseURL + path) else {
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
        let (data, resp) = try await URLSession.shared.data(for: req)
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

    func fetchSettings() async throws {
        let data = try await request("/api/settings")
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            applySettings(json)
        }
    }

    private func applySettings(_ json: [String: Any]) {
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
        if let mode = json["default_approval_mode"] as? String {
            approvalMode = mode
        }
        if let base = json["deepseek_base_url"] as? String {
            deepseekBaseURL = base
        }
        if let bark = json["bark_url"] as? String {
            barkURL = bark
        }
        hasAPIKey = (json["has_api_key"] as? Bool) ?? false
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

    func authorizeWorkspace(path: String, setActive: Bool = true) async {
        do {
            let payload: [String: Any] = [
                "path": path,
                "set_active": setActive,
                "session_id": activeSessionId,
            ]
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await request("/api/workspaces/authorize", method: "POST", body: body)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                applySettings(json)
            }
            await loadPCDrives()
            await loadPCDirectory(currentDir)
            Haptics.success()
        } catch {
            fileError = error.localizedDescription
        }
    }

    func removeWorkspace(_ path: String) async {
        guard workspaces.count > 1 else {
            fileError = "至少需要保留一个 AI 工作区目录"
            return
        }
        workspaces.removeAll { $0 == path }
        if activeWorkspace == path {
            activeWorkspace = workspaces.first ?? ""
        }
        try? await saveSettings(apiKey: "")
        await loadPCDirectory(currentDir)
    }

    // MARK: - Sessions & WebSocket

    func loadSessions() async {
        do {
            let data = try await request("/api/sessions")
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rawList = json?["sessions"] as? [[String: Any]] ?? []
            var parsed: [SessionSummaryItem] = rawList.compactMap { item in
                guard let sid = item["session_id"] as? String else { return nil }
                return SessionSummaryItem(
                    sessionId: sid,
                    title: (item["title"] as? String) ?? "Session",
                    status: (item["status"] as? String) ?? "idle",
                    model: (item["model"] as? String) ?? "deepseek-chat"
                )
            }
            if parsed.isEmpty {
                if let created = try await createNewSession() {
                    parsed = [created]
                }
            }
            sessions = parsed
            if !sessions.contains(where: { $0.sessionId == activeSessionId }),
               let first = sessions.first {
                activeSessionId = first.sessionId
            }
            await selectSession(activeSessionId)
        } catch {}
    }

    func createNewSession() async throws -> SessionSummaryItem? {
        let payload: [String: Any] = [
            "workspace": activeWorkspace,
            "title": "New Session",
            "model": selectedModel,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request("/api/sessions", method: "POST", body: body)
        guard let item = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = item["session_id"] as? String else { return nil }
        let s = SessionSummaryItem(
            sessionId: sid,
            title: (item["title"] as? String) ?? "New Session",
            status: (item["status"] as? String) ?? "idle",
            model: (item["model"] as? String) ?? selectedModel
        )
        sessions.insert(s, at: 0)
        return s
    }

    func selectSession(_ sessionId: String) async {
        guard !sessionId.isEmpty else { return }
        activeSessionId = sessionId
        lastSeq = 0
        turns.removeAll()
        pendingApprovals.removeAll()
        connectWebSocket(reset: true)
    }

    func connectWebSocket(reset: Bool = false) {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        guard !activeSessionId.isEmpty, !authToken.isEmpty else { return }

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
        task.resume()
        isConnected = true
        receiveNextMessage(from: task)
    }

    private func receiveNextMessage(from task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self = self, self.webSocketTask === task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handleSocketPayload(json)
                    }
                    self.receiveNextMessage(from: task)
                case .failure:
                    self.isConnected = false
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if self.webSocketTask === task {
                        self.connectWebSocket(reset: false)
                    }
                }
            }
        }
    }

    private func handleSocketPayload(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        if type == "ping" { return }
        if type == "sync_complete" {
            wsSynced = true
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
                    toolCount: turns.last?.toolCalls.count ?? 0
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
                LiveActivityController.shared.notifyPhaseChanged(.callingTool, toolCount: idx)
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
            // Replace if same path already in this turn's artifacts, else append
            if let existingIdx = turns[turns.count - 1].artifacts.firstIndex(where: { $0.path == art.path }) {
                turns[turns.count - 1].artifacts[existingIdx] = art
            } else {
                turns[turns.count - 1].artifacts.append(art)
            }
            if wsSynced {
                Haptics.light()
            }

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
                    toolCount: turns.last?.toolCalls.count ?? 0
                )
            }

        case "approval_request":
            if wsSynced {
                Haptics.warning()
                LiveActivityController.shared.notifyPhaseChanged(
                    .waitingApproval,
                    toolCount: turns.last?.toolCalls.count ?? 0
                )
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

    private func applySessionSummary(_ sess: [String: Any]) {
        if let st = sess["status"] as? String {
            sessionStatus = st
        }
        if let rawApprovals = sess["pending_approvals"] as? [[String: Any]] {
            pendingApprovals = rawApprovals.compactMap { item in
                guard let reqId = item["request_id"] as? String else { return nil }
                let tool = (item["tool_name"] as? String) ?? "tool"
                let argsObj = item["args"] ?? [:]
                let argsData = (try? JSONSerialization.data(withJSONObject: argsObj, options: [.prettyPrinted])) ?? Data()
                let argsStr = String(data: argsData, encoding: .utf8) ?? "{}"
                return PendingApprovalItem(id: reqId, toolName: tool, argsJSON: argsStr)
            }
        }
    }

    // MARK: - Actions

    func sendPrompt(_ prompt: String) async {
        let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !activeSessionId.isEmpty else { return }
        Haptics.light()
        do {
            let body = try JSONSerialization.data(withJSONObject: [
                "prompt": clean,
                "model": selectedModel,
            ])
            let data = try await request("/api/sessions/\(activeSessionId)/message", method: "POST", body: body)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sess = json["session"] as? [String: Any] {
                applySessionSummary(sess)
            }
        } catch {}
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
        }
    }

    // MARK: - Full PC File System Manager (Drives C/D/E, Metadata, Move/Copy/Upload/Download)

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
                        label: (d["label"] as? String) ?? "磁盘",
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
                    return PCShortcutItem(
                        name: name,
                        path: path,
                        icon: (s["icon"] as? String) ?? "folder"
                    )
                }
            }
        } catch {}
    }

    func loadPCDirectory(_ path: String) async {
        fileError = nil
        let target = path.isEmpty ? activeWorkspace : path
        let pathEnc = target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let hiddenFlag = showHiddenFiles ? "true" : "false"
        do {
            let data = try await request("/api/pc/list?path=\(pathEnc)&show_hidden=\(hiddenFlag)")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = json["entries"] as? [[String: Any]] else { return }
            currentDir = (json["path"] as? String) ?? target
            currentParentDir = (json["parent_path"] as? String) ?? ""
            currentDrive = (json["drive"] as? String) ?? "C:"
            currentDirInAIWorkspace = (json["in_ai_workspace"] as? Bool) ?? false
            fileEntries = entries.compactMap { Self.parseFileEntry($0) }
        } catch {
            fileError = error.localizedDescription
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
        if (json["is_binary"] as? Bool) == true {
            throw NSError(domain: "Bridge", code: 400, userInfo: [NSLocalizedDescriptionKey: "该文件为二进制格式，请使用「下载到手机」查看"])
        }
        if (json["too_large"] as? Bool) == true {
            throw NSError(domain: "Bridge", code: 400, userInfo: [NSLocalizedDescriptionKey: "文件超过 2MB，请使用「下载到手机」查看"])
        }
        return (
            content: (json["content"] as? String) ?? "",
            mtime: (json["mtime"] as? Double) ?? 0
        )
    }

    func writePCFile(_ fullPath: String, content: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "path": fullPath,
            "content": content,
        ])
        _ = try await request("/api/pc/write", method: "PUT", body: body)
        Haptics.success()
        await loadPCDirectory(currentDir)
    }

    func createPCEntry(name: String, isDir: Bool, content: String = "") async throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        let sep = currentDir.hasSuffix("\\") || currentDir.hasSuffix("/") ? "" : "\\"
        let fullPath = "\(currentDir)\(sep)\(cleanName)"
        let body = try JSONSerialization.data(withJSONObject: [
            "path": fullPath,
            "is_dir": isDir,
            "content": content,
        ])
        _ = try await request("/api/pc/create", method: "POST", body: body)
        Haptics.success()
        await loadPCDirectory(currentDir)
    }

    func renamePCEntry(item: FileEntryItem, newName: String) async throws {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let parent = item.parentPath.isEmpty ? currentDir : item.parentPath
        let sep = parent.hasSuffix("\\") || parent.hasSuffix("/") ? "" : "\\"
        let dst = "\(parent)\(sep)\(clean)"
        let body = try JSONSerialization.data(withJSONObject: [
            "src_path": item.path,
            "dst_path": dst,
            "overwrite": false,
        ])
        _ = try await request("/api/pc/move", method: "POST", body: body)
        Haptics.success()
        await loadPCDirectory(currentDir)
    }

    func pasteClipboardIntoCurrentDir() async throws {
        guard let clip = clipboard else { return }
        let sep = currentDir.hasSuffix("\\") || currentDir.hasSuffix("/") ? "" : "\\"
        let dst = "\(currentDir)\(sep)\(clip.source.name)"
        let endpoint = clip.isMove ? "/api/pc/move" : "/api/pc/copy"
        let body = try JSONSerialization.data(withJSONObject: [
            "src_path": clip.source.path,
            "dst_path": dst,
            "overwrite": false,
        ])
        _ = try await request(endpoint, method: "POST", body: body)
        if clip.isMove {
            clipboard = nil
        }
        Haptics.success()
        await loadPCDirectory(currentDir)
    }

    func deletePCEntry(_ item: FileEntryItem) async throws {
        let pathEnc = item.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        _ = try await request("/api/pc/delete?path=\(pathEnc)", method: "DELETE")
        Haptics.success()
        await loadPCDirectory(currentDir)
    }

    func uploadLocalFileToPC(fileURL: URL, targetDir: String? = nil) async throws -> (name: String, path: String) {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let fileData = try Data(contentsOf: fileURL)
        let b64 = fileData.base64EncodedString()
        let filename = fileURL.lastPathComponent
        let dir = targetDir ?? currentDir
        let body = try JSONSerialization.data(withJSONObject: [
            "dir_path": dir,
            "filename": filename,
            "base64_data": b64,
        ])
        let respData = try await request("/api/pc/upload", method: "POST", body: body)
        let json = (try? JSONSerialization.jsonObject(with: respData) as? [String: Any]) ?? [:]
        let savedPath = (json["path"] as? String) ?? ""
        let savedName = (json["name"] as? String) ?? filename
        Haptics.success()
        if targetDir == nil || targetDir == currentDir {
            await loadPCDirectory(currentDir)
        }
        return (name: savedName, path: savedPath)
    }

    func downloadPCFileToLocalTemp(pcPath: String, filename: String) async throws -> URL {
        let pathEnc = pcPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let data = try await request("/api/pc/download?path=\(pathEnc)")
        let safeName = (filename as NSString).lastPathComponent
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }
        try data.write(to: tempURL, options: .atomic)
        Haptics.success()
        return tempURL
    }

    func refreshGitDiff() async {
        let wsEnc = activeWorkspace.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        do {
            let data = try await request("/api/git/status?workspace=\(wsEnc)")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            isGitRepo = (json["is_git_repo"] as? Bool) ?? false
            gitBranch = (json["branch"] as? String) ?? ""
            gitDiff = (json["diff"] as? String) ?? (json["message"] as? String) ?? ""
        } catch {}
    }
}
