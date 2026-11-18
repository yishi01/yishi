import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DeepSeekIslandBundle: WidgetBundle {
    var body: some Widget {
        DeepSeekIslandLiveActivity()
    }
}

struct DeepSeekIslandLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DeepSeekIslandAttributes.self) { context in
            // Lock Screen Live Activity Banner — Obsidian Aurora Glass Design
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    phaseOrbView(phase: context.state.phase, size: 34, iconSize: 15)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("DeepSeek Go")
                                .font(.system(size: 14.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)

                            if context.state.toolCount > 0 {
                                Text("工具×\(context.state.toolCount)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color(red: 0.68, green: 0.78, blue: 1.0))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(Color.white.opacity(0.10))
                                    )
                            }
                        }

                        Text(context.attributes.sessionTitle.isEmpty ? "智能体实时工作流" : context.attributes.sessionTitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .lineLimit(1)
                    }

                    Spacer()

                    statusCapsulePill(state: context.state)
                }

                if context.state.phase == .waitingApproval {
                    reviewCardContent(state: context.state)
                } else {
                    pipelineProgressRow(state: context.state)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .activityBackgroundTint(Color(red: 0.06, green: 0.08, blue: 0.14).opacity(0.92))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        phaseOrbView(phase: context.state.phase, size: 30, iconSize: 13.5)

                        VStack(alignment: .leading, spacing: 1.5) {
                            Text("DeepSeek Go")
                                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text(context.attributes.sessionTitle.isEmpty ? "实时协同中" : context.attributes.sessionTitle)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    statusCapsulePill(state: context.state)
                        .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if context.state.phase == .waitingApproval {
                            reviewCardContent(state: context.state)
                        } else {
                            pipelineProgressRow(state: context.state)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                }
            } compactLeading: {
                phaseOrbView(phase: context.state.phase, size: 22, iconSize: 11)
                    .padding(.leading, 2)
            } compactTrailing: {
                HStack(spacing: 4) {
                    Text(context.state.phase.compactLabel)
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(phaseAccentLight(context.state.phase))

                    if context.state.toolCount > 0 && context.state.phase == .callingTool {
                        Text("\(context.state.toolCount)")
                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(phaseColor(context.state.phase).opacity(0.85))
                            )
                            .contentTransition(.numericText())
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(phaseColor(context.state.phase).opacity(0.18))
                        .overlay(
                            Capsule()
                                .strokeBorder(phaseColor(context.state.phase).opacity(0.42), lineWidth: 0.8)
                        )
                )
            } minimal: {
                phaseOrbView(phase: context.state.phase, size: 22, iconSize: 11)
            }
            .widgetURL(deepLinkURL(action: "review", id: context.state.pendingApprovalId))
        }
    }

    // MARK: - Glowing Aurora Orb Badge

    @ViewBuilder
    private func phaseOrbView(phase: DeepSeekIslandPhase, size: CGFloat, iconSize: CGFloat) -> some View {
        let colors = phaseGradientColors(phase)
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: colors[0].opacity(0.55), radius: 5, x: 0, y: 2)

            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.65), Color.white.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
                .frame(width: size, height: size)

            Image(systemName: phase.symbolName)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Trailing Status Capsule Pill

    @ViewBuilder
    private func statusCapsulePill(state: DeepSeekIslandAttributes.ContentState) -> some View {
        if state.phase == .waitingApproval && !state.pendingRiskLevel.isEmpty {
            let rColor = riskColor(state.pendingRiskLevel)
            HStack(spacing: 4) {
                Circle()
                    .fill(rColor)
                    .frame(width: 6, height: 6)
                Text(riskBadgeText(state.pendingRiskLevel))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(rColor)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(
                Capsule()
                    .fill(rColor.opacity(0.18))
                    .overlay(
                        Capsule()
                            .strokeBorder(rColor.opacity(0.48), lineWidth: 0.9)
                    )
            )
        } else {
            let pColor = phaseColor(state.phase)
            HStack(spacing: 5) {
                Circle()
                    .fill(phaseAccentLight(state.phase))
                    .frame(width: 5.5, height: 5.5)
                Text(state.phase.compactLabel)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(phaseAccentLight(state.phase))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(
                Capsule()
                    .fill(pColor.opacity(0.20))
                    .overlay(
                        Capsule()
                            .strokeBorder(pColor.opacity(0.45), lineWidth: 0.9)
                    )
            )
        }
    }

    // MARK: - 4-Stage Visual Progress Pipeline Track

    @ViewBuilder
    private func pipelineProgressRow(state: DeepSeekIslandAttributes.ContentState) -> some View {
        let stages: [(phase: DeepSeekIslandPhase, title: String, icon: String)] = [
            (.thinking, "思考", "sparkles"),
            (.callingTool, "工具", "wrench.and.screwdriver.fill"),
            (.answering, "生成", "waveform"),
            (.completed, "完成", "checkmark.circle.fill"),
        ]
        let activeIdx = stageIndex(for: state.phase)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(0..<stages.count, id: \.self) { idx in
                    let item = stages[idx]
                    let isDone = idx < activeIdx || state.phase == .completed
                    let isCurrent = idx == activeIdx && state.phase != .completed
                    let nodeColor = isCurrent
                        ? phaseAccentLight(state.phase)
                        : (isDone ? Color(red: 0.30, green: 0.88, blue: 0.65) : Color.white.opacity(0.25))

                    HStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(
                                    isCurrent
                                        ? phaseColor(state.phase).opacity(0.32)
                                        : (isDone ? Color.green.opacity(0.24) : Color.white.opacity(0.08))
                                )
                                .frame(width: 20, height: 20)
                            Image(systemName: isDone ? "checkmark" : item.icon)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(nodeColor)
                        }

                        Text(item.title)
                            .font(.system(size: 11, weight: isCurrent ? .bold : .medium, design: .rounded))
                            .foregroundStyle(isCurrent ? .white : (isDone ? Color.white.opacity(0.82) : Color.white.opacity(0.40)))
                    }

                    if idx < stages.count - 1 {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        idx < activeIdx ? Color(red: 0.30, green: 0.88, blue: 0.65).opacity(0.75) : Color.white.opacity(0.14),
                                        idx + 1 <= activeIdx ? phaseColor(state.phase).opacity(0.75) : Color.white.opacity(0.10),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(height: 1.5)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 5)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
                    )
            )

            HStack(spacing: 10) {
                Text(state.phase.expandedTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))

                Spacer()

                if state.toolCount > 0 {
                    Label("已执行 \(state.toolCount) 项工具", systemImage: "bolt.fill")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.65, green: 0.78, blue: 1.0))
                        .contentTransition(.numericText())
                }

                if state.queuedCount > 0 {
                    Label("队列 \(state.queuedCount)", systemImage: "tray.full.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.orange)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Interactive Security Review & Approval Card

    @ViewBuilder
    private func reviewCardContent(state: DeepSeekIslandAttributes.ContentState) -> some View {
        let reqId = state.pendingApprovalId
        VStack(alignment: .leading, spacing: 9) {
            if !state.pendingToolName.isEmpty || !state.pendingSummary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !state.pendingToolName.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(Color.orange)
                            Text("请求执行：\(state.pendingToolName)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }
                    if !state.pendingSummary.isEmpty {
                        Text(state.pendingSummary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.78))
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.orange.opacity(0.32), lineWidth: 0.8)
                        )
                )
            }

            HStack(spacing: 8) {
                if let approveURL = deepLinkURL(action: "approve", id: reqId) {
                    Link(destination: approveURL) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text("允许执行")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7.5)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.14, green: 0.78, blue: 0.52),
                                            Color(red: 0.08, green: 0.62, blue: 0.44),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .foregroundStyle(.white)
                    }
                }

                if let reviewURL = deepLinkURL(action: "review", id: reqId) {
                    Link(destination: reviewURL) {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 11, weight: .semibold))
                            Text("详情")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7.5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8)
                                )
                        )
                        .foregroundStyle(.white)
                    }
                }

                if let denyURL = deepLinkURL(action: "deny", id: reqId) {
                    Link(destination: denyURL) {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                            Text("拒绝")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7.5)
                        .background(
                            Capsule()
                                .fill(Color.red.opacity(0.22))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.red.opacity(0.45), lineWidth: 0.8)
                                )
                        )
                        .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func stageIndex(for phase: DeepSeekIslandPhase) -> Int {
        switch phase {
        case .thinking: return 0
        case .callingTool, .waitingApproval: return 1
        case .answering: return 2
        case .completed: return 3
        }
    }

    private func deepLinkURL(action: String, id: String) -> URL? {
        let cleanId = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        return URL(string: "deepseekgo://\(action)?id=\(cleanId)")
    }

    private func phaseGradientColors(_ phase: DeepSeekIslandPhase) -> [Color] {
        switch phase {
        case .thinking:
            return [Color(red: 0.32, green: 0.48, blue: 1.0), Color(red: 0.52, green: 0.30, blue: 0.96)]
        case .callingTool:
            return [Color(red: 0.48, green: 0.34, blue: 0.98), Color(red: 0.20, green: 0.62, blue: 0.96)]
        case .waitingApproval:
            return [Color(red: 1.0, green: 0.60, blue: 0.14), Color(red: 0.94, green: 0.34, blue: 0.24)]
        case .answering:
            return [Color(red: 0.14, green: 0.68, blue: 0.96), Color(red: 0.28, green: 0.42, blue: 0.98)]
        case .completed:
            return [Color(red: 0.16, green: 0.82, blue: 0.54), Color(red: 0.08, green: 0.62, blue: 0.46)]
        }
    }

    private func phaseColor(_ phase: DeepSeekIslandPhase) -> Color {
        switch phase {
        case .thinking: return Color(red: 0.34, green: 0.46, blue: 1.0)
        case .callingTool: return Color(red: 0.46, green: 0.36, blue: 0.98)
        case .waitingApproval: return Color.orange
        case .answering: return Color(red: 0.18, green: 0.64, blue: 0.98)
        case .completed: return Color(red: 0.16, green: 0.80, blue: 0.52)
        }
    }

    private func phaseAccentLight(_ phase: DeepSeekIslandPhase) -> Color {
        switch phase {
        case .thinking: return Color(red: 0.68, green: 0.78, blue: 1.0)
        case .callingTool: return Color(red: 0.76, green: 0.70, blue: 1.0)
        case .waitingApproval: return Color(red: 1.0, green: 0.76, blue: 0.38)
        case .answering: return Color(red: 0.58, green: 0.86, blue: 1.0)
        case .completed: return Color(red: 0.46, green: 0.94, blue: 0.72)
        }
    }

    private func riskColor(_ risk: String) -> Color {
        switch risk.lowercased() {
        case "critical", "high": return Color(red: 1.0, green: 0.42, blue: 0.42)
        case "medium": return Color(red: 1.0, green: 0.72, blue: 0.28)
        case "low": return Color(red: 0.54, green: 0.78, blue: 1.0)
        default: return Color(red: 0.42, green: 0.90, blue: 0.68)
        }
    }

    private func riskBadgeText(_ risk: String) -> String {
        switch risk.lowercased() {
        case "critical": return "极高风险"
        case "high": return "高风险"
        case "medium": return "中风险"
        case "low": return "低风险"
        case "safe": return "安全"
        default: return "待确认"
        }
    }
}
