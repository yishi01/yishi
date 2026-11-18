import Foundation
import SwiftUI

@MainActor
extension BridgeClient {
    // MARK: - Single-Flight Automatic Route Failover & Hardened HTTP Request

    func applyResolvedRendezvous(_ resolved: [String]) {
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

    func request(
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

    func performSingleRequest(
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
}
