import Foundation
import SwiftUI

@MainActor
extension BridgeClient {
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
            let staleBrowserIds = activeBrowserSessions.values
                .filter { $0.sessionId == sessionId }
                .map { $0.browserId }
            for bid in staleBrowserIds {
                activeBrowserSessions.removeValue(forKey: bid)
                userDismissedBrowserIds.remove(bid)
                if presentedBrowserId == bid { presentedBrowserId = nil }
            }
            MobileBrowserManager.shared.removeTabs(matching: staleBrowserIds)
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
        clearStreamingBuffer()
        let snapshot = turns
        turns.removeAll { $0.turnId == turnId || $0.id == turnId }
        Haptics.medium()
        do {
            let encTid = turnId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? turnId
            _ = try await request("/api/sessions/\(activeSessionId)/turns/\(encTid)", method: "DELETE")
        } catch {
            turns = snapshot
            showToastMessage("删除消息失败: \(error.localizedDescription)")
        }
    }

    func editAndResendTurn(_ turnId: String, newText: String, attachments: [String] = []) async {
        guard !activeSessionId.isEmpty, !turnId.isEmpty else { return }
        clearStreamingBuffer()
        let snapshot = turns
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
            turns = snapshot
            showToastMessage("重发失败: \(error.localizedDescription)")
        }
    }

    func regenerateTurn(_ turnId: String) async {
        guard !activeSessionId.isEmpty, !turnId.isEmpty else { return }
        clearStreamingBuffer()
        let snapshot = turns
        if let idx = turns.firstIndex(where: { $0.turnId == turnId || $0.id == turnId }) {
            turns.removeSubrange(idx..<turns.count)
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
            turns = snapshot
            showToastMessage("重新生成失败: \(error.localizedDescription)")
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

    @discardableResult
    func resolveApproval(requestId: String, allow: Bool, setAutoMode: Bool = false) async -> Bool {
        guard !activeSessionId.isEmpty else { return false }
        Haptics.medium()
        var payload: [String: Any] = ["allow": allow]
        if setAutoMode {
            payload["set_approval_mode"] = "auto"
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        do {
            let data = try await request(
                "/api/sessions/\(activeSessionId)/approvals/\(requestId)",
                method: "POST",
                body: body
            )
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sess = json["session"] as? [String: Any] {
                applySessionSummary(sess)
                if pendingApprovals.isEmpty {
                    LiveActivityController.shared.clearPendingApproval()
                }
            }
            return true
        } catch {
            showToastMessage("审批提交失败: \(error.localizedDescription)")
            return false
        }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "deepseekgo" else { return }
        let action = (url.host ?? "").lowercased()
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let reqId = comps?.queryItems?.first(where: { $0.name == "id" })?.value ?? ""
        AppLogger.shared.info("DeepLink", "收到灵动岛操作: \(action) id=\(reqId)")

        Task {
            guard isAuthenticated else {
                showToastMessage("请先连接 PC 后再执行审批")
                return
            }
            if !activeSessionId.isEmpty {
                if let data = try? await request("/api/sessions/\(activeSessionId)/events?after_seq=\(lastSeq)"),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sess = json["session"] as? [String: Any] {
                    applySessionSummary(sess)
                }
            }
            let targetId = !reqId.isEmpty ? reqId : (pendingApprovals.first?.id ?? "")
            if action == "approve" && !targetId.isEmpty {
                let ok = await resolveApproval(requestId: targetId, allow: true)
                if ok { showToastMessage("已从灵动岛批准执行") }
            } else if action == "deny" && !targetId.isEmpty {
                let ok = await resolveApproval(requestId: targetId, allow: false)
                if ok { showToastMessage("已从灵动岛拒绝操作") }
            } else if let matched = pendingApprovals.first(where: { $0.id == targetId }) ?? pendingApprovals.first {
                activeApprovalForPopup = matched
            }
        }
    }
}
