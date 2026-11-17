import ActivityKit
import Foundation

/// Minimalist Doubao-style Dynamic Island state:
/// Shows ONLY the high-level phase (Deep Thinking / Tool Call / Waiting Approval / Completed)
/// without exposing verbose thoughts or tool arguments on the island.
public enum DeepSeekIslandPhase: String, Codable, Hashable {
    case thinking = "thinking"
    case callingTool = "calling_tool"
    case waitingApproval = "waiting_approval"
    case answering = "answering"
    case completed = "completed"

    public var compactLabel: String {
        switch self {
        case .thinking: return "深度思考"
        case .callingTool: return "工具调用"
        case .waitingApproval: return "待确认"
        case .answering: return "回复中"
        case .completed: return "输出完成"
        }
    }

    public var expandedTitle: String {
        switch self {
        case .thinking: return "正在深度思考..."
        case .callingTool: return "正在使用工具调用..."
        case .waitingApproval: return "等待你的操作确认"
        case .answering: return "正在生成回复..."
        case .completed: return "输出已完成"
        }
    }

    public var symbolName: String {
        switch self {
        case .thinking: return "sparkles"
        case .callingTool: return "wrench.and.screwdriver.fill"
        case .waitingApproval: return "bell.badge.fill"
        case .answering: return "waveform"
        case .completed: return "checkmark.circle.fill"
        }
    }
}

public struct DeepSeekIslandAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var phase: DeepSeekIslandPhase
        public var toolCount: Int

        public init(phase: DeepSeekIslandPhase, toolCount: Int = 0) {
            self.phase = phase
            self.toolCount = toolCount
        }
    }

    public var sessionTitle: String

    public init(sessionTitle: String) {
        self.sessionTitle = sessionTitle
    }
}
