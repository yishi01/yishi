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
            // Lock Screen minimal banner
            HStack(spacing: 12) {
                Image(systemName: context.state.phase.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(phaseColor(context.state.phase))

                Text("DeepSeek")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Text(context.state.phase.expandedTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .activityBackgroundTint(Color.white.opacity(0.92))
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded Region: clean Doubao-style single-bar status (no verbose content)
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: context.state.phase.symbolName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(phaseColor(context.state.phase))
                        Text("DeepSeek")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.phase.expandedTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(phaseColor(context.state.phase))
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    EmptyView()
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
        }
    }

    private func phaseColor(_ phase: DeepSeekIslandPhase) -> Color {
        switch phase {
        case .thinking:
            return Color(red: 0.30, green: 0.42, blue: 1.0)
        case .callingTool:
            return Color(red: 0.38, green: 0.35, blue: 0.95)
        case .waitingApproval:
            return Color.orange
        case .answering:
            return Color(red: 0.30, green: 0.42, blue: 1.0)
        case .completed:
            return Color.green
        }
    }
}
