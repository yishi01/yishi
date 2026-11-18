import Foundation
import SwiftUI

@MainActor
extension BridgeClient {
    // MARK: - Module B: Attachments & PC Screenshots

    @discardableResult
    func uploadImageAttachment(data: Data, filename: String = "photo.jpg", addToPending: Bool = true) async -> ChatAttachmentItem? {
        let b64 = data.base64EncodedString()
        let payload: [String: Any] = [
            "filename": filename,
            "base64_data": b64,
            "content_base64": b64,
            "data_base64": b64,
            "session_id": activeSessionId.isEmpty ? "global" : activeSessionId,
        ]
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let resp = try await request("/api/attachments", method: "POST", body: body, timeout: 60)
            if let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] {
                let rawAtt = (json["attachment"] as? [String: Any]) ?? json
                if let item = Self.parseAttachmentItem(rawAtt) {
                    if addToPending && !pendingAttachments.contains(where: { $0.attId == item.attId }) {
                        pendingAttachments.append(item)
                    }
                    Haptics.light()
                    return item
                }
            }
        } catch {
            showToastMessage("图片上传失败: \(error.localizedDescription)")
        }
        return nil
    }

    func removePendingAttachment(_ attId: String) {
        pendingAttachments.removeAll { $0.attId == attId }
        Haptics.light()
    }

    @discardableResult
    func capturePCScreenshot(target: String = "full", windowTitle: String = "") async -> ChatAttachmentItem? {
        let payload: [String: Any] = [
            "target": target,
            "window_title": windowTitle,
            "session_id": activeSessionId.isEmpty ? "global" : activeSessionId,
        ]
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let resp = try await request("/api/pc/screenshot", method: "POST", body: body, timeout: 30)
            if let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any] {
                let rawAtt = (json["attachment"] as? [String: Any]) ?? json
                if let item = Self.parseAttachmentItem(rawAtt) {
                    if !pendingAttachments.contains(where: { $0.attId == item.attId }) {
                        pendingAttachments.append(item)
                    }
                    Haptics.success()
                    showToastMessage("已抓取电脑屏幕并添加到待发栏")
                    return item
                }
            }
        } catch {
            showToastMessage("电脑截屏失败: \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - Module E: API Wallet & Token Ledger

    func loadWalletSummary(forceBalance: Bool = false) async {
        let flag = forceBalance ? "true" : "false"
        do {
            let data = try await request("/api/wallet/summary?force_balance=\(flag)")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            let bal = (json["balance"] as? [String: Any]) ?? json
            let today = (json["today"] as? [String: Any]) ?? json
            let curHour = (json["current_hour"] as? [String: Any]) ?? [:]
            let rawRules = (json["rules"] as? [String: Any]) ?? [:]

            let rawByModel = (today["by_model"] as? [[String: Any]]) ?? (json["by_model"] as? [[String: Any]]) ?? []
            let byModelItems: [WalletModelUsageItem] = rawByModel.compactMap { m in
                guard let modelName = m["model"] as? String else { return nil }
                return WalletModelUsageItem(
                    model: modelName,
                    totalTokens: (m["total_tokens"] as? NSNumber)?.intValue ?? 0,
                    promptTokens: (m["prompt_tokens"] as? NSNumber)?.intValue ?? 0,
                    completionTokens: (m["completion_tokens"] as? NSNumber)?.intValue ?? 0,
                    cost: (m["cost"] as? NSNumber)?.doubleValue ?? 0.0,
                    turns: (m["turns"] as? NSNumber)?.intValue ?? 0
                )
            }

            let rawDays = (json["last_7_days"] as? [[String: Any]]) ?? []
            let dayItems: [WalletDayItem] = rawDays.compactMap { d in
                guard let dateStr = d["date"] as? String else { return nil }
                return WalletDayItem(
                    date: dateStr,
                    totalTokens: (d["total_tokens"] as? NSNumber)?.intValue
                        ?? (d["tokens"] as? NSNumber)?.intValue
                        ?? 0,
                    cost: (d["cost"] as? NSNumber)?.doubleValue ?? 0.0,
                    turns: (d["turns"] as? NSNumber)?.intValue ?? 0
                )
            }

            let rawHours = (json["hourly_today"] as? [[String: Any]]) ?? []
            let hourItems: [WalletHourItem] = rawHours.compactMap { h in
                guard let hr = h["hour"] as? String else { return nil }
                return WalletHourItem(
                    hour: hr,
                    tokens: (h["tokens"] as? NSNumber)?.intValue
                        ?? (h["total_tokens"] as? NSNumber)?.intValue
                        ?? 0,
                    cost: (h["cost"] as? NSNumber)?.doubleValue ?? 0.0
                )
            }

            let parsedRules = WalletRulesItem(
                enabled: (rawRules["enabled"] as? Bool) ?? true,
                balanceBelow: (rawRules["balance_below"] as? NSNumber)?.doubleValue ?? 5.0,
                dailySpendAbove: (rawRules["daily_spend_above"] as? NSNumber)?.doubleValue ?? 20.0,
                fallbackProfileId: (rawRules["fallback_profile_id"] as? String) ?? "deepseek-flash",
                notifyBark: (rawRules["notify_bark"] as? Bool) ?? true,
                hysteresis: (rawRules["hysteresis"] as? NSNumber)?.doubleValue ?? 1.0,
                manualBalance: (rawRules["manual_balance"] as? NSNumber)?.doubleValue,
                currency: (rawRules["currency"] as? String) ?? "CNY"
            )

            walletSummary = WalletSummaryData(
                balanceAvailable: (bal["available"] as? Bool) ?? (json["balance_available"] as? Bool) ?? false,
                balanceSource: (bal["source"] as? String) ?? (json["balance_source"] as? String) ?? "unavailable",
                totalBalance: (bal["total_balance"] as? NSNumber)?.doubleValue,
                grantedBalance: (bal["granted_balance"] as? NSNumber)?.doubleValue ?? 0.0,
                toppedUpBalance: (bal["topped_up_balance"] as? NSNumber)?.doubleValue ?? 0.0,
                currency: (bal["currency"] as? String) ?? parsedRules.currency,
                todayPromptTokens: (today["prompt_tokens"] as? NSNumber)?.intValue ?? 0,
                todayCacheHitTokens: (today["cache_hit_tokens"] as? NSNumber)?.intValue ?? 0,
                todayCompletionTokens: (today["completion_tokens"] as? NSNumber)?.intValue ?? 0,
                todayTotalTokens: (today["total_tokens"] as? NSNumber)?.intValue ?? 0,
                todayCost: (today["cost"] as? NSNumber)?.doubleValue ?? 0.0,
                todayTurns: (today["turns"] as? NSNumber)?.intValue ?? 0,
                currentHourTokens: (curHour["total_tokens"] as? NSNumber)?.intValue
                    ?? (curHour["tokens"] as? NSNumber)?.intValue
                    ?? 0,
                currentHourCost: (curHour["cost"] as? NSNumber)?.doubleValue ?? 0.0,
                byModel: byModelItems,
                last7Days: dayItems,
                hourlyToday: hourItems,
                rules: parsedRules,
                downgradeActive: (json["downgrade_active"] as? Bool) ?? false
            )
        } catch {}
    }

    func saveWalletRules(_ rules: WalletRulesItem) async {
        var payload: [String: Any] = [
            "enabled": rules.enabled,
            "balance_below": rules.balanceBelow,
            "daily_spend_above": rules.dailySpendAbove,
            "fallback_profile_id": rules.fallbackProfileId,
            "notify_bark": rules.notifyBark,
            "hysteresis": rules.hysteresis,
            "currency": rules.currency,
        ]
        if let manual = rules.manualBalance {
            payload["manual_balance"] = manual
        } else {
            payload["manual_balance"] = NSNull()
        }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            _ = try await request("/api/wallet/rules", method: "PUT", body: body)
            await loadWalletSummary(forceBalance: true)
            Haptics.success()
            showToastMessage("已保存钱包与自动降级规则")
        } catch {
            showToastMessage("保存钱包规则失败: \(error.localizedDescription)")
        }
    }
}
