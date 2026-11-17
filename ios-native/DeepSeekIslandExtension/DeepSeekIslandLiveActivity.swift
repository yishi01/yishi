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
            // Lock Screen banner (expands to show review popup details + confirmation links when waitingApproval)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: context.state.phase.symbolName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(phaseColor(context.state.phase))

                    Text("DeepSeek")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)

                    if !context.state.pendingRiskLevel.isEmpty && context.state.phase == .waitingApproval {
                        Text(riskBadgeText(context.state.pendingRiskLevel))
                            .font(.system(size: 10.5, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(riskColor(context.state.pendingRiskLevel).opacity(0.16)))
                            .foregroundStyle(riskColor(context.state.pendingRiskLevel))
                    }

                    Spacer()

                    Text(context.state.phase.expandedTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(phaseColor(context.state.phase))
                }

                if context.state.phase == .waitingApproval {
                    reviewCardContent(state: context.state)
                } else if context.state.queuedCount > 0 {
                    Text("队列中还有 \(context.state.queuedCount) 条待发消息")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .activityBackgroundTint(Color.white.opacity(0.94))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        Image(systemName: context.state.phase.symbolName)
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(phaseColor(context.state.phase))
                        Text("DeepSeek")
                            .font(.system(size: 14.5, weight: .semibold))
                    }
                    .padding(.leading, 6)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 6) {
                        if context.state.phase == .waitingApproval && !context.state.pendingRiskLevel.isEmpty {
                            Text(riskBadgeText(context.state.pendingRiskLevel))
                                .font(.system(size: 10.5, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(riskColor(context.state.pendingRiskLevel).opacity(0.22)))
                                .foregroundStyle(riskColor(context.state.pendingRiskLevel))
                        } else {
                            Text(context.state.phase.expandedTitle)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(phaseColor(context.state.phase))
                        }
                    }
                    .padding(.trailing, 6)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.phase == .waitingApproval {
                        reviewCardContent(state: context.state)
                            .padding(.horizontal, 6)
                            .padding(.top, 4)
                    } else if context.state.queuedCount > 0 {
                        Text("队列排队中：\(context.state.queuedCount) 条消息")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    } else {
                        EmptyView()
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.phase.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(phaseColor(context.state.phase))
            } compactTrailing: {
                Text(context.state.phase.compactLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(phaseColor(context.state.phase))
            } minimal: {
                Image(systemName: context.state.phase.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(phaseColor(context.state.phase))
            }
            .widgetURL(deepLinkURL(action: "review", id: context.state.pendingApprovalId))
        }
    }

    @ViewBuilder
    private func reviewCardContent(state: DeepSeekIslandAttributes.ContentState) -> some View {
        let reqId = state.pendingApprovalId
        VStack(alignment: .leading, spacing: 8) {
            if !state.pendingToolName.isEmpty || !state.pendingSummary.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    if !state.pendingToolName.isEmpty {
                        Text("操作审查：\(state.pendingToolName)")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    if !state.pendingSummary.isEmpty {
                        Text(state.pendingSummary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            HStack(spacing: 8) {
                if let approveURL = deepLinkURL(action: "approve", id: reqId) {
                    Link(destination: approveURL) {
                        Label("允许执行", systemImage: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6.5)
                            .background(Capsule().fill(Color.green.opacity(0.90)))
                            .foregroundStyle(.white)
                    }
                }

                if let reviewURL = deepLinkURL(action: "review", id: reqId) {
                    Link(destination: reviewURL) {
                        Text("审查详情")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6.5)
                            .background(Capsule().fill(Color.blue.opacity(0.16)))
                            .foregroundStyle(Color.blue)
                    }
                }

                if let denyURL = deepLinkURL(action: "deny", id: reqId) {
                    Link(destination: denyURL) {
                        Label("拒绝", systemImage: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6.5)
                            .background(Capsule().fill(Color.red.opacity(0.16)))
                            .foregroundStyle(Color.red)
                    }
                }
            }
        }
    }

    private func deepLinkURL(action: String, id: String) -> URL? {
        let cleanId = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        return URL(string: "deepseekgo://\(action)?id=\(cleanId)")
    }

    private func phaseColor(_ phase: DeepSeekIslandPhase) -> Color {
        switch phase {
        case .thinking: return Color(red: 0.30, green: 0.42, blue: 1.0)
        case .callingTool: return Color(red: 0.38, green: 0.35, blue: 0.95)
        case .waitingApproval: return Color.orange
        case .answering: return Color(red: 0.30, green: 0.42, blue: 1.0)
        case .completed: return Color.green
        }
    }

    private func riskColor(_ risk: String) -> Color {
        switch risk.lowercased() {
        case "critical", "high": return .red
        case "medium": return .orange
        case "low": return .blue
        default: return .green
        }
    }

    private func riskBadgeText(_ risk: String) -> String {
        switch risk.lowercased() {
        case "critical": return "极高风险"
        case "high": return "高风险"
        case "medium": return "中风险"
        case "low": return "低风险"
        case "safe": return "安全"
        default: return "待审查"
        }
    }
}
