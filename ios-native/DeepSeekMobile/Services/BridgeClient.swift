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

struct ChatTurnItem: Identifiable, Hashable {
    let id: String
    var userText: String?
    var thoughtText: String = ""
    var toolCalls: [ToolCallItem] = []
    var assistantText: String = ""
    var errorText: String?
}

struct PendingApprovalItem: Identifiable, Hashable {
    let id: String
    let toolName: String
    let argsJSON: String
}

struct FileEntryItem: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDir: Bool
    let size: Int
    let mtime: Double
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
    @AppStorage("ds_server_url") var serverURL: String = "http://dsh-pc"
    @AppStorage("ds_auth_token") var authToken: String = ""
    @AppStorage("ds_active_workspace") var activeWorkspace: String = ""
    @AppStorage("ds_active_session_id") var activeSessionId: String = ""

    @Published var isAuthenticated: Bool = false
    @Published var isConnected: Bool = false
    @Published var authError: String?

    @Published var workspaces: [String] = []
    @Published var selectedModel: String = "deepseek-chat"
    @Published var approvalMode: String = "ask_commands"
    @Published var deepseekBaseURL: String = "https://api.deepseek.com"
    @Published var barkURL: String = ""
    @Published var hasAPIKey: Bool = false

    @Published var sessions: [SessionSummaryItem] = []
    @Published var turns: [ChatTurnItem] = []
    @Published var pendingApprovals: [PendingApprovalItem] = []
    @Published var sessionStatus: String = "idle"

    @Published var currentDir: String = ""
    @Published var fileEntries: [FileEntryItem] = []
    @Published var gitBranch: String = ""
    @Published var gitDiff: String = ""
    @Published var isGitRepo: Bool = false
    @Published var referencedFilePath: String?

    private var lastSeq: Int = 0
    private var webSocketTask: URLSessionWebSocketTask?
    private var wsSynced: Bool = false

    var normalizedBaseURL: String {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = "http://dsh-pc" }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    func bootstrap() async {
        guard !authToken.isEmpty else {
            isAuthenticated = false
            return
        }
        do {
            try await fetchSettings()
            isAuthenticated = true
            await loadSessions()
            await loadDirectory("")
            await refreshGitDiff()
        } catch {
            isAuthenticated = false
        }
    }

    func verifyAndLogin(url: String, token: String) async {
        self.serverURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authError = nil
        do {
            let body = try JSONSerialization.data(withJSONObject: ["token": self.authToken])
            let data = try await request("/api/auth/verify", method: "POST", body: body, useAuth: false)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let settings = json["settings"] as? [String: Any] {
                applySettings(settings)
            }
            isAuthenticated = true
            Haptics.success()
            await loadSessions()
            await loadDirectory("")
            await refreshGitDiff()
        } catch {
            authError = error.localizedDescription
            isAuthenticated = false
        }
    }

    func logout() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        authToken = ""
        isAuthenticated = false
        isConnected = false
    }

    // MARK: - HTTP Helper

    private func request(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        useAuth: Bool = true
    ) async throws -> Data {
        guard let url = URL(string: normalizedBaseURL + path) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 25
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
                activeWorkspace = ws.first ?? ""
            }
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
        Haptics.success()
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

    // MARK: - Files & Git

    func loadDirectory(_ relPath: String) async {
        currentDir = relPath
        let wsEnc = activeWorkspace.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let pathEnc = relPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        do {
            let data = try await request("/api/files/tree?workspace=\(wsEnc)&path=\(pathEnc)")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = json["entries"] as? [[String: Any]] else { return }
            fileEntries = entries.compactMap { e in
                guard let name = e["name"] as? String,
                      let path = e["path"] as? String else { return nil }
                return FileEntryItem(
                    name: name,
                    path: path,
                    isDir: (e["is_dir"] as? Bool) ?? false,
                    size: (e["size"] as? Int) ?? 0,
                    mtime: (e["mtime"] as? Double) ?? 0
                )
            }
        } catch {}
    }

    func readFile(_ relPath: String) async throws -> (content: String, mtime: Double) {
        let wsEnc = activeWorkspace.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let pathEnc = relPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let data = try await request("/api/files/read?workspace=\(wsEnc)&path=\(pathEnc)")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        if (json["is_binary"] as? Bool) == true {
            throw NSError(domain: "Bridge", code: 400, userInfo: [NSLocalizedDescriptionKey: "二进制文件暂不支持文本编辑"])
        }
        return (
            content: (json["content"] as? String) ?? "",
            mtime: (json["mtime"] as? Double) ?? 0
        )
    }

    func writeFile(_ relPath: String, content: String, expectedMtime: Double) async throws -> Double {
        let payload: [String: Any] = [
            "workspace": activeWorkspace,
            "path": relPath,
            "content": content,
            "expected_mtime": expectedMtime,
            "force": true,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request("/api/files/write", method: "PUT", body: body)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        Haptics.success()
        return (json["mtime"] as? Double) ?? expectedMtime
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
