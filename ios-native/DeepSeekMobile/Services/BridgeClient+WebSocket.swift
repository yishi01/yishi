import Foundation
import SwiftUI

@MainActor
extension BridgeClient {
    // MARK: - Sessions & WebSocket Streaming with Heartbeat + Backoff

    func loadSessions(autoConnect: Bool = true) async {
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
                if autoConnect {
                    connectWebSocket(reset: true)
                }
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
        clearStreamingBuffer()
        lastNotifiedIslandPhase = nil
        lastNotifiedToolCount = -1
        activeSessionId = sessionId
        editingTurnId = nil
        presentedBrowserId = nil
        activeApprovalForPopup = nil
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
        let urlStr = "\(wsScheme)\(hostPart)/ws/sessions/\(activeSessionId)?token=\(encodedToken)&after_seq=\(after)&client_browser=1"
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
                    self.wsGeneration &+= 1
                    self.webSocketTask?.cancel(with: .goingAway, reason: nil)
                    self.webSocketTask = nil
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
            defer { self?.wsReconnectTask = nil }
            try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            guard !Task.isCancelled, let self = self, self.isAuthenticated else { return }
            if tryFailoverFirst {
                _ = await self.attemptRouteFailover()
            }
            guard !Task.isCancelled, self.isAuthenticated else { return }
            self.connectWebSocket(reset: false)
        }
    }

    func clearStreamingBuffer() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        pendingTurnIdForBuffer = ""
        bufferedThoughtText = nil
        bufferedAssistantText = nil
    }

    func flushStreamingBufferImmediate() {
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

    func scheduleStreamBufferFlush() {
        guard streamFlushTask == nil else { return }
        streamFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 36_000_000)
            guard !Task.isCancelled, let self = self else { return }
            self.streamFlushTask = nil
            self.flushStreamingBufferImmediate()
        }
    }

    func handleSocketPayload(_ msg: [String: Any]) {
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
                let title = sessions.first(where: { $0.sessionId == activeSessionId })?.title ?? "DeepSeek"
                LiveActivityController.shared.notifyTurnStarted(sessionTitle: title)
            }

        case "turn_deleted":
            clearStreamingBuffer()
            let tid = (d["turn_id"] as? String) ?? turnId
            if !tid.isEmpty {
                turns.removeAll { $0.turnId == tid || $0.id == tid }
            }

        case "turns_truncated":
            clearStreamingBuffer()
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
                if state.humanRequired {
                    userDismissedBrowserIds.remove(state.browserId)
                    withAnimation(AppleMotion.smooth) {
                        presentedBrowserId = state.browserId
                    }
                }
            }

        case "browser_rpc":
            let cmdId = (d["cmd_id"] as? String) ?? ""
            let bid = (d["browser_id"] as? String) ?? ""
            let action = (d["action"] as? String) ?? "snapshot"
            if !cmdId.isEmpty && !bid.isEmpty {
                if (action == "navigate" || action == "open"), !userDismissedBrowserIds.contains(bid) {
                    withAnimation(AppleMotion.smooth) {
                        presentedBrowserId = bid
                    }
                }
                let paramsCopy = d
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    var rpcRes = await MobileBrowserManager.shared.executeRPC(
                        browserId: bid,
                        action: action,
                        params: paramsCopy,
                        uploadScreenshot: { jpegData, fname in
                            await self.uploadImageAttachment(data: jpegData, filename: fname, addToPending: false)
                        }
                    )
                    rpcRes["cmd_id"] = cmdId
                    rpcRes["session_id"] = self.activeSessionId.isEmpty ? "global" : self.activeSessionId
                    await self.submitMobileBrowserRPCResult(browserId: bid, payload: rpcRes)
                    if (rpcRes["human_required"] as? Bool) == true {
                        self.userDismissedBrowserIds.remove(bid)
                        withAnimation(AppleMotion.smooth) {
                            self.presentedBrowserId = bid
                        }
                    }
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
            if !turnId.isEmpty && ((bufferedThoughtText != nil || bufferedAssistantText != nil) && pendingTurnIdForBuffer != turnId) {
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
            if !turnId.isEmpty && ((bufferedThoughtText != nil || bufferedAssistantText != nil) && pendingTurnIdForBuffer != turnId) {
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
    func activeTurnIndex(for turnId: String = "") -> Int {
        if !turnId.isEmpty, let idx = turns.firstIndex(where: { $0.turnId == turnId || $0.id == turnId }) {
            return idx
        }
        if turns.isEmpty {
            turns.append(ChatTurnItem(id: turnId.isEmpty ? UUID().uuidString : turnId, turnId: turnId))
            return 0
        }
        if !turnId.isEmpty {
            if turns[turns.count - 1].turnId.isEmpty {
                turns[turns.count - 1].turnId = turnId
                return turns.count - 1
            }
            turns.append(ChatTurnItem(id: turnId, turnId: turnId))
            return turns.count - 1
        }
        return turns.count - 1
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
            canGoBack: (raw["can_go_back"] as? Bool) ?? false,
            canGoForward: (raw["can_go_forward"] as? Bool) ?? false,
            mode: (raw["mode"] as? String) ?? "mobile_wkwebview",
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

    static func parseQueuedMessages(_ raw: [[String: Any]]) -> [QueuedMessageItem] {
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

    func applySessionSummary(_ sess: [String: Any]) {
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
}
