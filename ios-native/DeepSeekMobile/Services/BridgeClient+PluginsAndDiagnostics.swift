import Foundation
import SwiftUI

@MainActor
extension BridgeClient {
    // MARK: - DSH Plugins System (Configured on Mobile, Executed on PC)

    func loadPlugins() async {
        do {
            let data = try await request("/api/plugins")
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                applyPluginsPayload(json)
            }
        } catch {}
    }

    func applyPluginsPayload(_ json: [String: Any]) {
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
