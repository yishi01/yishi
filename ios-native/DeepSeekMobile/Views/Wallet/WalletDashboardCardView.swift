import SwiftUI

// MARK: - 6. API Wallet Dashboard Card (WalletDashboardCardView)

struct WalletDashboardCardView: View {
    let wallet: WalletSummaryData
    var modelProfiles: [ModelProfileItem] = []
    var onRefresh: () -> Void = {}
    var onSaveRules: (WalletRulesItem) -> Void = { _ in }

    @State private var draftRules: WalletRulesItem = WalletRulesItem()
    @State private var manualBalanceText: String = ""
    @State private var showSavedBadge: Bool = false
    @State private var hasUnsavedEdits: Bool = false
    @State private var isSyncingDraft: Bool = false

    private var maxDayCost: Double {
        max(0.0001, wallet.last7Days.map(\.cost).max() ?? 0.01)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            balanceHeroCard
            todayMetricsRow
            if !wallet.last7Days.isEmpty {
                sevenDayTrendSection
            }
            if !wallet.byModel.isEmpty {
                modelBreakdownSection
            }
            autoDowngradeRulesSection
        }
        .onAppear {
            syncDraftFromWallet()
        }
        .onChange(of: wallet.rules) { _ in
            if !hasUnsavedEdits {
                syncDraftFromWallet()
            }
        }
        .onChange(of: draftRules) { _ in
            if !isSyncingDraft { hasUnsavedEdits = true }
        }
        .onChange(of: manualBalanceText) { _ in
            if !isSyncingDraft { hasUnsavedEdits = true }
        }
    }

    private func syncDraftFromWallet() {
        isSyncingDraft = true
        draftRules = wallet.rules
        if let manual = wallet.rules.manualBalance {
            manualBalanceText = String(format: "%.2f", manual)
        } else {
            manualBalanceText = ""
        }
        hasUnsavedEdits = false
        Task { @MainActor in
            isSyncingDraft = false
        }
    }

    private var balanceHeroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("💰 DeepSeek API 余额与账单")
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundStyle(Color.dsPrimary)

                        if wallet.downgradeActive {
                            Text("⚠️ 自动降级中")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange))
                        }
                    }

                    Text("数据源: \(wallet.balanceSource)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Haptics.light()
                    onRefresh()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("刷新")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dsAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .cleanWhiteCard(cornerRadius: 999)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                if let total = wallet.totalBalance {
                    Text("¥\(String(format: "%.2f", total))")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(total <= wallet.rules.balanceBelow ? Color.orange : Color.dsPrimary)
                } else {
                    Text("估算/未配置")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("赠金: ¥\(String(format: "%.2f", wallet.grantedBalance))")
                    Text("充值: ¥\(String(format: "%.2f", wallet.toppedUpBalance))")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 20, prominent: true)
    }

    private var todayMetricsRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("今日消耗 (\(wallet.todayTurns) 轮)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("¥\(String(format: "%.4f", wallet.todayCost))")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.dsPrimary)
                Text("共 \(wallet.todayTotalTokens) tokens (命中 \(wallet.todayCacheHitTokens))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cleanWhiteCard(cornerRadius: 16)

            VStack(alignment: .leading, spacing: 4) {
                Text("当前小时速率")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("¥\(String(format: "%.4f", wallet.currentHourCost))")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.dsAccent)
                Text("\(wallet.currentHourTokens) tokens / hr")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cleanWhiteCard(cornerRadius: 16)
        }
    }

    private var sevenDayTrendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("📊 近 7 天消费趋势")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.dsPrimary)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(wallet.last7Days.suffix(7)) { day in
                    let ratio = min(1.0, max(0.08, day.cost / maxDayCost))
                    VStack(spacing: 4) {
                        Text("¥\(String(format: "%.2f", day.cost))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.dsAccent.opacity(0.82))
                            .frame(height: CGFloat(ratio * 58.0))

                        Text(String(day.date.suffix(5)))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 92)
        }
        .padding(13)
        .cleanWhiteCard(cornerRadius: 16)
    }

    private var modelBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🤖 模型 Token 与费用明细")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.dsPrimary)

            ForEach(wallet.byModel) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.model)
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.dsPrimary)
                        Text("\(item.turns) 轮 · 输入 \(item.promptTokens) / 输出 \(item.completionTokens)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("¥\(String(format: "%.4f", item.cost))")
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.dsPrimary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(13)
        .cleanWhiteCard(cornerRadius: 16)
    }

    private var autoDowngradeRulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("🛡️ 预算告警与自动降级规则")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.dsPrimary)
                Spacer()
                Toggle("", isOn: $draftRules.enabled)
                    .labelsHidden()
            }

            HStack {
                Text("余额低于阈值自动切换 (¥)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("5.0", value: $draftRules.balanceBelow, format: .number)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 12.5, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.75)))
            }

            HStack {
                Text("单日消费上限阈值 (¥)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("20.0", value: $draftRules.dailySpendAbove, format: .number)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 12.5, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.75)))
            }

            HStack {
                Text("手动校准余额 (可选 ¥)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("留空自动查询", text: $manualBalanceText)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.75)))
            }

            HStack {
                Text("降级备用模型")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("备用模型", selection: $draftRules.fallbackProfileId) {
                    if modelProfiles.isEmpty {
                        Text("deepseek-flash").tag("deepseek-flash")
                        Text("deepseek-chat").tag("deepseek-chat")
                    } else {
                        ForEach(modelProfiles) { mp in
                            Text(mp.name).tag(mp.id)
                        }
                    }
                }
                .pickerStyle(.menu)
            }

            Toggle("触发阈值时发送 Bark 推送提醒", isOn: $draftRules.notifyBark)
                .font(.system(size: 12))

            Button {
                Haptics.success()
                let trimmedManual = manualBalanceText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let val = Double(trimmedManual) {
                    draftRules.manualBalance = val
                } else {
                    draftRules.manualBalance = nil
                }
                hasUnsavedEdits = false
                onSaveRules(draftRules)
                showSavedBadge = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    showSavedBadge = false
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showSavedBadge ? "checkmark.circle.fill" : "tray.and.arrow.down.fill")
                    Text(showSavedBadge ? "策略已保存" : "保存预算与自动降级规则")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Capsule().fill(showSavedBadge ? Color.green : Color.dsPrimary))
            }
            .glassPressable(scale: 0.96)
        }
        .padding(13)
        .cleanWhiteCard(cornerRadius: 16)
    }
}
