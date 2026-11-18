import Foundation

// MARK: - Chat & Session Models

struct ToolCallItem: Identifiable, Hashable {
    let id: String
    let index: Int
    let name: String
    let argsText: String
    var resultText: String?
    var isError: Bool = false
}

struct FileArtifactItem: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let title: String
    let summary: String
    let size: Int
    let ext: String
    let mode: String // "review" | "download"
    let isText: Bool
    let preview: String

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

struct ChatAttachmentItem: Identifiable, Hashable {
    var id: String { attId }
    let attId: String
    let filename: String
    let mimeType: String
    let width: Int
    let height: Int
    let size: Int
    let url: String
    let thumbURL: String
    let source: String
}

struct TurnUsageInfo: Hashable {
    let promptTokens: Int
    let cacheHitTokens: Int
    let completionTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    let cost: Double
    let currency: String
    let model: String
    let estimated: Bool
}

struct BrowserElementItem: Identifiable, Hashable {
    let id: Int
    let tag: String
    let type: String
    let text: String
    let href: String
    let value: String
    let bbox: [Int]
}

struct BrowserSessionState: Identifiable, Hashable {
    var id: String { browserId }
    let browserId: String
    var sessionId: String
    var url: String
    var title: String
    var controlOwner: String // "agent" | "human"
    var humanRequired: Bool
    var humanReason: String
    var scrollY: Int
    var elements: [BrowserElementItem]
    var textMarkdown: String
    var frameB64: String
}

struct TeamSubagentItem: Identifiable, Hashable {
    var id: String { agentId }
    let agentId: String
    var role: String
    var task: String
    var status: String // "running" | "done" | "failed" | "cancelled"
    var model: String
    var roundsUsed: Int
    var cost: Double
    var resultSummary: String
    var transcriptPreview: String
}

struct ChatTurnItem: Identifiable, Hashable {
    let id: String
    var turnId: String = ""
    var userText: String?
    var attachments: [ChatAttachmentItem] = []
    var thoughtText: String = ""
    var toolCalls: [ToolCallItem] = []
    var artifacts: [FileArtifactItem] = []
    var browserSessions: [BrowserSessionState] = []
    var teamAgents: [TeamSubagentItem] = []
    var assistantText: String = ""
    var errorText: String?
    var usage: TurnUsageInfo? = nil
    var modelSwitchedNote: String? = nil
}

struct PendingApprovalItem: Identifiable, Hashable {
    let id: String
    let toolName: String
    let argsJSON: String
    var riskLevel: String = "medium"
    var reviewSummary: String = ""
    var reviewScore: Int = 0
}

struct QueuedMessageItem: Identifiable, Hashable {
    let id: String
    let prompt: String
    let model: String
    let profileId: String
    let createdAt: String
}

// MARK: - File Manager Models

struct PCDriveItem: Identifiable, Hashable {
    var id: String { path }
    let letter: String
    let name: String
    let label: String
    let path: String
    let totalBytes: Int64
    let usedBytes: Int64
    let freeBytes: Int64

    var usageRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    var formattedCapacity: String {
        let freeStr = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        let totalStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "可用 \(freeStr) / 共 \(totalStr)"
    }
}

struct PCShortcutItem: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let icon: String
}

struct FileEntryItem: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let parentPath: String
    let isDir: Bool
    let size: Int
    let mtime: Double
    let ctime: Double
    let atime: Double
    let ext: String
    let mimeType: String
    let isReadonly: Bool
    let isHidden: Bool
    let inAIWorkspace: Bool
    let aiCanRead: Bool
    let aiCanWrite: Bool

    var formattedSize: String {
        isDir ? "文件夹" : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var formattedMtime: String { Self.formatTimestamp(mtime) }
    var formattedCtime: String { Self.formatTimestamp(ctime) }
    var formattedAtime: String { Self.formatTimestamp(atime) }

    static func formatTimestamp(_ ts: Double) -> String {
        guard ts > 0 else { return "-" }
        let d = Date(timeIntervalSince1970: ts)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: d)
    }
}

struct FileClipboardItem: Equatable {
    let source: FileEntryItem
    let isMove: Bool
}

struct SessionSummaryItem: Identifiable, Hashable {
    var id: String { sessionId }
    let sessionId: String
    var title: String
    var status: String
    var model: String
    var workspaceProfileId: String = "ws_default"
    var workspace: String = ""
}

struct WorkspaceProfileItem: Identifiable, Hashable {
    let id: String
    var name: String
    var icon: String
    var color: String
    var rootPaths: [String]
    var defaultProfileId: String
    var defaultApprovalMode: String
    var sharedNotes: String
    var crossSessionRead: Bool
    var sessionCount: Int
}

// MARK: - Model Profiles & Search Settings Models

struct ModelProfileItem: Identifiable, Hashable {
    var id: String
    var name: String
    var provider: String // "openai_compatible" | "anthropic" | "gemini_openai"
    var baseURL: String
    var model: String
    var temperature: Double
    var maxTokens: Int
    var supportsTools: Bool
    var supportsReasoning: Bool
    var supportsVision: Bool = false
    var hasAPIKey: Bool
    var apiKeyMasked: String
    var inheritsGlobalKey: Bool
}

struct SearchConfigItem: Equatable {
    var enabled: Bool = true
    var provider: String = "duckduckgo" // duckduckgo | tavily | brave | serper | bocha | custom
    var baseURL: String = ""
    var maxResults: Int = 6
    var timeoutSec: Int = 12
    var hasAPIKey: Bool = false
    var apiKeyMasked: String = ""
}

struct SearchResultEntry: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let url: String
    let snippet: String
}

struct SearchTestResponse {
    let ok: Bool
    let provider: String
    let latencyMs: Double
    let error: String
    let results: [SearchResultEntry]
}

// MARK: - PC DSH Plugin System Models

struct PluginSkillInfo: Identifiable, Hashable {
    var id: String { name + path }
    let name: String
    let path: String
    let preview: String
}

struct PluginToolInfo: Identifiable, Hashable {
    var id: String { relPath }
    let name: String
    let relPath: String
    let ext: String
}

struct PCPluginItem: Identifiable, Hashable {
    let id: String
    let name: String
    let version: String
    let description: String
    let author: String
    var enabled: Bool
    let source: String
    let path: String
    let isDSHBundle: Bool
    let skills: [PluginSkillInfo]
    let tools: [PluginToolInfo]
    let mcpServers: [String]
    var configJSON: String
    var envJSON: String
}

struct DSHBundleItem: Identifiable, Hashable {
    var id: String { name }
    let name: String
    var enabled: Bool
    let version: String
    let description: String
}

struct DSHPatchItem: Identifiable, Hashable {
    let id: String
    let name: String
    var enabled: Bool
    var configJSON: String
    let kind: String
}

struct DSHProfileStatus {
    var exists: Bool = false
    var profileDir: String = ""
    var runtimeAvailable: Bool = false
    var bundles: [DSHBundleItem] = []
    var patches: [DSHPatchItem] = []
}

struct PluginRunResult {
    let ok: Bool
    let pluginId: String
    let tool: String
    let exitCode: Int
    let stdout: String
    let stderr: String
    let durationMs: Double
}

// MARK: - Sandbox Simulator & Security Self-Check Models

struct SandboxAuditFinding: Identifiable, Hashable {
    let id = UUID()
    let line: Int
    let severity: String // low | medium | high | critical
    let category: String
    let message: String
    let snippet: String
}

struct SandboxAuditReport {
    let language: String
    let riskLevel: String // safe | low | medium | high | critical
    let score: Int
    let safeToAutoRun: Bool
    let summary: String
    let findings: [SandboxAuditFinding]
}

struct SandboxRunResult {
    let ok: Bool
    let runId: String
    let language: String
    let exitCode: Int
    let stdout: String
    let stderr: String
    let durationMs: Double
    let timedOut: Bool
    let audit: SandboxAuditReport
    let previewHTML: String
    let artifactNames: [String]
}

// MARK: - Diagnostics & Self-Check Models

struct PCLogEntry: Identifiable, Hashable {
    var id: Int { seq }
    let seq: Int
    let ts: String
    let level: String
    let logger: String
    let message: String
}

struct PCDiagnosticsStatus {
    let version: String
    let uptimeSec: Double
    let pid: Int
    let pythonVersion: String
    let platform: String
    let memoryMB: Double?
    let diskFreeGB: Double?
    let tunnelStatus: String
    let tunnelURL: String
    let wsActive: Int
    let wsConnects: Int
    let wsDisconnects: Int
    let wsReconnects: Int
    let lastDisconnectReason: String
    let totalHTTPRequests: Int
    let totalHTTPErrors: Int
    let pluginsTotal: Int
    let pluginsEnabled: Int
}

struct SelfCheckItem: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let name: String
    let status: String // ok | warn | fail
    let detail: String
    let latencyMs: Double
}

struct SelfCheckReport {
    let ok: Bool
    let overallStatus: String
    let checkedAt: String
    let checks: [SelfCheckItem]
}

// MARK: - API Wallet & Token Ledger Models

struct WalletModelUsageItem: Identifiable, Hashable {
    var id: String { model }
    let model: String
    let totalTokens: Int
    let promptTokens: Int
    let completionTokens: Int
    let cost: Double
    let turns: Int
}

struct WalletDayItem: Identifiable, Hashable {
    var id: String { date }
    let date: String
    let totalTokens: Int
    let cost: Double
    let turns: Int
}

struct WalletHourItem: Identifiable, Hashable {
    var id: String { hour }
    let hour: String
    let tokens: Int
    let cost: Double
}

struct WalletRulesItem: Equatable {
    var enabled: Bool = true
    var balanceBelow: Double = 5.0
    var dailySpendAbove: Double = 20.0
    var fallbackProfileId: String = "deepseek-flash"
    var notifyBark: Bool = true
    var hysteresis: Double = 1.0
    var manualBalance: Double? = nil
    var currency: String = "CNY"
}

struct WalletSummaryData {
    var balanceAvailable: Bool = false
    var balanceSource: String = "unavailable"
    var totalBalance: Double? = nil
    var grantedBalance: Double = 0
    var toppedUpBalance: Double = 0
    var currency: String = "CNY"
    var todayPromptTokens: Int = 0
    var todayCacheHitTokens: Int = 0
    var todayCompletionTokens: Int = 0
    var todayTotalTokens: Int = 0
    var todayCost: Double = 0
    var todayTurns: Int = 0
    var currentHourTokens: Int = 0
    var currentHourCost: Double = 0
    var byModel: [WalletModelUsageItem] = []
    var last7Days: [WalletDayItem] = []
    var hourlyToday: [WalletHourItem] = []
    var rules: WalletRulesItem = WalletRulesItem()
    var downgradeActive: Bool = false
}
