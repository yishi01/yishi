import Foundation
import SwiftUI

@MainActor
extension BridgeClient {
    // MARK: - Module F: Mobile Native WKWebView Collaborative Browser

    func presentBrowser(_ browserId: String) {
        userDismissedBrowserIds.remove(browserId)
        withAnimation(AppleMotion.smooth) {
            presentedBrowserId = browserId
        }
        // Ensure local WKWebView loads the session URL if currently blank
        if let state = activeBrowserSessions[browserId] {
            let tab = MobileBrowserManager.shared.tab(for: browserId)
            if tab.currentURL.isEmpty && !state.url.isEmpty && state.url != "about:blank" {
                Task { _ = await tab.loadURL(state.url, waitForSettle: false) }
            }
        }
    }

    func dismissPresentedBrowser() {
        if let bid = presentedBrowserId {
            userDismissedBrowserIds.insert(bid)
        }
        withAnimation(AppleMotion.smooth) {
            presentedBrowserId = nil
        }
    }

    func submitMobileBrowserRPCResult(browserId: String, payload: [String: Any]) async {
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await request("/api/browser/sessions/\(browserId)/rpc_result", method: "POST", body: body, timeout: 15)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let snapDict = (json["browser"] as? [String: Any]) ?? (json["snapshot"] as? [String: Any]) ?? json
                if let state = Self.parseBrowserSessionState(snapDict) {
                    upsertBrowserStateInChat(state)
                }
            }
        } catch {}
    }

    func syncMobileBrowserSnapshot(browserId: String, snapshot: [String: Any]) async {
        var payload = snapshot
        payload["cmd_id"] = ""
        payload["session_id"] = activeSessionId.isEmpty ? "global" : activeSessionId
        await submitMobileBrowserRPCResult(browserId: browserId, payload: payload)
    }

    func upsertBrowserStateInChat(_ state: BrowserSessionState) {
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

            let initial = BrowserSessionState(
                browserId: bid,
                sessionId: activeSessionId.isEmpty ? "global" : activeSessionId,
                url: url,
                title: URL(string: url)?.host ?? "正在加载...",
                controlOwner: "human",
                humanRequired: false,
                humanReason: "",
                scrollY: 0,
                canGoBack: false,
                canGoForward: false,
                mode: "mobile_wkwebview",
                elements: [],
                textMarkdown: "",
                frameB64: ""
            )
            upsertBrowserStateInChat(initial)
            presentBrowser(bid)
            Haptics.light()

            let tab = MobileBrowserManager.shared.tab(for: bid)
            let snap = await tab.loadURL(url, waitForSettle: true)
            await syncMobileBrowserSnapshot(browserId: bid, snapshot: snap)
        } catch {
            showToastMessage("启动内置浏览器失败: \(error.localizedDescription)")
        }
    }

    func browserNavigate(browserId: String, url: String) async {
        guard !browserId.isEmpty else { return }
        let tab = MobileBrowserManager.shared.tab(for: browserId)
        let snap = await tab.loadURL(url, waitForSettle: true)
        await syncMobileBrowserSnapshot(browserId: browserId, snapshot: snap)
    }

    func browserHistoryAction(browserId: String, action: String) async {
        guard !browserId.isEmpty else { return }
        let act = action.lowercased()
        if act == "close" {
            MobileBrowserManager.shared.removeTab(browserId)
            _ = try? await request("/api/browser/sessions/\(browserId)/close", method: "POST")
            activeBrowserSessions.removeValue(forKey: browserId)
            if presentedBrowserId == browserId {
                presentedBrowserId = nil
            }
            for idx in turns.indices {
                turns[idx].browserSessions.removeAll { $0.browserId == browserId }
            }
            Haptics.light()
            return
        }
        let tab = MobileBrowserManager.shared.tab(for: browserId)
        let snap: [String: Any]
        if act == "back" {
            snap = await tab.goBack(waitForSettle: true)
        } else if act == "forward" {
            snap = await tab.goForward(waitForSettle: true)
        } else {
            snap = await tab.reload(waitForSettle: true)
        }
        await syncMobileBrowserSnapshot(browserId: browserId, snapshot: snap)
    }

    func browserSetControl(browserId: String, owner: String) async {
        guard !browserId.isEmpty else { return }
        if owner == "agent" {
            let tab = MobileBrowserManager.shared.tab(for: browserId)
            let freshSnap = await tab.runSnapshotJS()
            await syncMobileBrowserSnapshot(browserId: browserId, snapshot: freshSnap)
        }
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
        let tab = MobileBrowserManager.shared.tab(for: browserId)
        if let jpeg = await tab.captureSnapshotJPEG(),
           let att = await uploadImageAttachment(data: jpeg, filename: "web_\(Int(Date().timeIntervalSince1970)).jpg", addToPending: true) {
            Haptics.success()
            showToastMessage("已将网页截图 (\(att.width)×\(att.height)) 加入待发附件")
            return
        }
        showToastMessage("网页截图失败")
    }
}
