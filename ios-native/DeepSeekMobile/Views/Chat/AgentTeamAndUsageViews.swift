import SwiftUI

// MARK: - 3. Agent Team Collaboration Card (AgentTeamCardView)

struct AgentTeamCardView: View {
    let agents: [TeamSubagentItem]
    var onCancelAgent: (String) -> Void = { _ in }

    @State private var expandedAgentIds: Set<String> = []

    private var runningCount: Int {
        agents.filter { $0.status == "running" }.count
    }

    private var totalCost: Double {
        agents.reduce(0.0) { $0 + $1.cost }
    }

    private func roleIcon(for role: String) -> String {
        let lower = role.lowercased()
        if lower.contains("research") || lower.contains("调研") || lower.contains("分析") {
            return "magnifyingglass.circle.fill"
        }
        if lower.contains("test") || lower.contains("测试") || lower.contains("qa") || lower.contains("验证") {
            return "checkmark.shield.fill"
        }
        if lower.contains("code") || lower.contains("dev") || lower.contains("研发") || lower.contains("实现") {
            return "hammer.circle.fill"
        }
        return "person.crop.circle.badge.checkmark"
    }

    var body: some View {
        if !agents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("👥 智能体协作团队 (\(agents.count) 名子 Agent)")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Color.dsPrimary)

                    Spacer()

                    if runningCount > 0 {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("\(runningCount) 运行中")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.dsAccent)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.dsAccent.opacity(0.14)))
                    }

                    Text("¥\(String(format: "%.4f", totalCost))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.white.opacity(0.65)))
                }

                VStack(spacing: 8) {
                    ForEach(agents) { agent in
                        subagentRow(agent)
                    }
                }
            }
            .padding(13)
            .liquidGlass(cornerRadius: 20, prominent: true)
        }
    }

    private func subagentRow(_ agent: TeamSubagentItem) -> some View {
        let isExpanded = expandedAgentIds.contains(agent.agentId)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Haptics.light()
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                        if isExpanded {
                            expandedAgentIds.remove(agent.agentId)
                        } else {
                            expandedAgentIds.insert(agent.agentId)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: roleIcon(for: agent.role))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.dsAccent)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(agent.role)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.dsPrimary)
                                    .lineLimit(1)

                                statusBadge(for: agent.status)
                            }

                            HStack(spacing: 6) {
                                Text("\(agent.model) · \(agent.roundsUsed)轮")
                                Text("·")
                                Text("¥\(String(format: "%.4f", agent.cost))")
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(SingleTapRowButtonStyle())

                if agent.status == "running" {
                    Button {
                        Haptics.warning()
                        onCancelAgent(agent.agentId)
                    } label: {
                        Text("取消")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.red.opacity(0.12)))
                    }
                    .buttonStyle(SingleTapRowButtonStyle())
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !agent.task.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("任务目标")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(agent.task)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.dsPrimary)
                        }
                    }
                    if !agent.resultSummary.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("结论摘要")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(agent.resultSummary)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.dsPrimary)
                        }
                    }
                    if !agent.transcriptPreview.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("执行轨迹预览")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(agent.transcriptPreview)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(8)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.55))
                )
            }
        }
        .padding(10)
        .cleanWhiteCard(cornerRadius: 14)
    }

    @ViewBuilder
    private func statusBadge(for status: String) -> some View {
        switch status {
        case "running":
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("运行中")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.dsAccent)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.dsAccent.opacity(0.14)))
        case "done":
            Text("已完成")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.green.opacity(0.14)))
        case "failed":
            Text("失败")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.red.opacity(0.14)))
        default:
            Text("已取消")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.gray.opacity(0.16)))
        }
    }
}

// MARK: - 4. Per-Turn Token & Cost Footer (TurnUsageBadgeView)

struct TurnUsageBadgeView: View {
    let usage: TurnUsageInfo?
    var modelSwitchedNote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let note = modelSwitchedNote, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 5) {
                    Text("🔄 \(note)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.orange)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(
                    Capsule().fill(Color.orange.opacity(0.13))
                )
            }

            if let u = usage {
                HStack(spacing: 5) {
                    Text(
                        "⚡ 输入 \(u.promptTokens) (命中 \(u.cacheHitTokens)) → 输出 \(u.completionTokens) tokens · ¥\(String(format: "%.4f", u.cost))"
                    )
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                    if u.estimated {
                        Text("估算")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .cleanWhiteCard(cornerRadius: 999)
            }
        }
    }
}

