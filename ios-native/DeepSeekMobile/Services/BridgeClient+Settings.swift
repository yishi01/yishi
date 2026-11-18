import Foundation
import SwiftUI

@MainActor
extension BridgeClient {
    // MARK: - Settings, Model Profiles & Search Config

    func fetchSettings() async throws {
        let data = try await request("/api/settings")
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            applySettings(json)
        }
    }

    func applySettings(_ json: [String: Any]) {
        isApplyingSettingsFromServer = true
        defer { isApplyingSettingsFromServer = false }
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
}
