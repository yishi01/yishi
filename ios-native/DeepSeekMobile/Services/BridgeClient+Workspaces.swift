import Foundation
import SwiftUI

@MainActor
extension BridgeClient {
    // MARK: - Module A: Workspace Profiles

    static func parseWorkspaceProfile(_ raw: [String: Any]) -> WorkspaceProfileItem? {
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
        await loadSessions(autoConnect: false)
        let matched = sessions.first(where: { $0.workspaceProfileId == profileId })
        if let matched = matched {
            if activeSessionId != matched.sessionId {
                await selectSession(matched.sessionId)
            } else {
                connectWebSocket(reset: false)
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
}
