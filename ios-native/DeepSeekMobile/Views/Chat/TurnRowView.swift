import SwiftUI
import UIKit

struct TurnRowView: View {
    @EnvironmentObject var client: BridgeClient
    let turn: ChatTurnItem
    var onReviewArtifact: (FileArtifactItem) -> Void
    var onDownloadArtifact: (FileArtifactItem) -> Void
    var onCopyText: (String) -> Void = { _ in }
    var onEditTurn: (ChatTurnItem) -> Void = { _ in }
    var onRegenerateTurn: (ChatTurnItem) -> Void = { _ in }
    var onDeleteTurn: (ChatTurnItem) -> Void = { _ in }

    @ObservedObject private var theme = ThemePreferences.shared
    @State private var expandThoughts: Bool = false
    @State private var expandTools: Bool = false

    var body: some View {
        let radius = CGFloat(theme.bubbleRadius)
        VStack(alignment: .leading, spacing: theme.compactMode ? 7 : 10) {
            if !turn.attachments.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    TurnAttachmentsGridView(
                        attachments: turn.attachments,
                        baseURL: client.normalizedBaseURL,
                        authToken: client.authToken
                    )
                }
            }

            if let userText = turn.userText, !userText.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    Text(userText)
                        .font(.system(size: theme.scaledFont(15.5)))
                        .foregroundStyle(Color.dsPrimary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, theme.compactMode ? 8 : 10.5)
                        .liquidGlass(cornerRadius: radius, prominent: false)
                        .contextMenu {
                            Button {
                                onCopyText(userText)
                            } label: {
                                Label("复制消息", systemImage: "doc.on.doc")
                            }

                            Button {
                                onEditTurn(turn)
                            } label: {
                                Label("编辑并重新发送", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                onDeleteTurn(turn)
                            } label: {
                                Label("删除本轮对话", systemImage: "trash")
                            }
                        }
                }
            }

            // Grouped Process Pills (Deep Thinking & Tool Calls — collapsed by default)
            if !turn.thoughtText.isEmpty || !turn.toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if !turn.thoughtText.isEmpty {
                            Button {
                                Haptics.light()
                                withAnimation(AppleMotion.snappy) {
                                    expandThoughts.toggle()
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.dsAccent)
                                    Text("深度思考 · \(turn.thoughtText.count)字")
                                        .font(.system(size: 12.5, weight: .medium))
                                        .contentTransition(.numericText())
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                        .rotationEffect(.degrees(expandThoughts ? 180 : 0))
                                }
                                .foregroundStyle(Color.dsPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6.5)
                                .cleanWhiteCard(cornerRadius: 999)
                            }
                            .glassPressable(scale: 0.95)
                        }

                        if !turn.toolCalls.isEmpty {
                            Button {
                                Haptics.light()
                                withAnimation(AppleMotion.snappy) {
                                    expandTools.toggle()
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "wrench.and.screwdriver")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.dsAccent)
                                    Text("工具调用 · \(turn.toolCalls.count)次")
                                        .font(.system(size: 12.5, weight: .medium))
                                        .contentTransition(.numericText())
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                        .rotationEffect(.degrees(expandTools ? 180 : 0))
                                }
                                .foregroundStyle(Color.dsPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6.5)
                                .cleanWhiteCard(cornerRadius: 999)
                            }
                            .glassPressable(scale: 0.95)
                        }
                    }

                    if expandThoughts && !turn.thoughtText.isEmpty {
                        Text(turn.thoughtText)
                            .font(.system(size: 13))
                            .lineSpacing(4)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cleanWhiteCard(cornerRadius: 16)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }

                    if expandTools && !turn.toolCalls.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(turn.toolCalls) { tc in
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(tc.argsText)
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        if let res = tc.resultText {
                                            Divider().opacity(0.4)
                                            Text(res.prefix(1200))
                                                .font(.system(size: 11.5, design: .monospaced))
                                                .foregroundStyle(tc.isError ? .red : .secondary)
                                        }
                                    }
                                    .padding(.top, 4)
                                } label: {
                                    HStack {
                                        Text("#\(tc.index) \(tc.name)")
                                            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                            .foregroundStyle(Color.dsPrimary)
                                        Spacer()
                                        Text(tc.resultText == nil ? "执行中" : (tc.isError ? "失败" : "完成"))
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundStyle(tc.isError ? .red : Color.dsAccent)
                                    }
                                }
                                .padding(10)
                                .cleanWhiteCard(cornerRadius: 14)
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                }
            }

            // Agent Team Collaboration Card
            if !turn.teamAgents.isEmpty {
                AgentTeamCardView(
                    agents: turn.teamAgents,
                    onCancelAgent: { aid in
                        Task { await client.cancelSubagent(agentId: aid) }
                    }
                )
            }

            // Compact X/Telegram-style Web Link Cards (tap to slide up full-screen native WKWebView)
            if !turn.browserSessions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(turn.browserSessions) { bState in
                        let liveState = client.activeBrowserSessions[bState.browserId] ?? bState
                        BrowserLinkCardView(
                            state: liveState,
                            onOpen: {
                                client.presentBrowser(liveState.browserId)
                            }
                        )
                    }
                }
            }

            // Claude-Style File Artifact & Review/Download Cards
            if !turn.artifacts.isEmpty {
                VStack(spacing: 10) {
                    ForEach(turn.artifacts) { art in
                        FileArtifactCardView(
                            artifact: art,
                            onReview: { onReviewArtifact(art) },
                            onDownload: { onDownloadArtifact(art) }
                        )
                    }
                }
            }

            if !turn.assistantText.isEmpty {
                FormattedMarkdownView(markdown: turn.assistantText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, theme.compactMode ? 9 : 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cleanWhiteCard(cornerRadius: radius)
                    .contextMenu {
                        Button {
                            onCopyText(turn.assistantText)
                        } label: {
                            Label("复制回复全文", systemImage: "doc.on.doc")
                        }

                        Button {
                            onRegenerateTurn(turn)
                        } label: {
                            Label("重新生成本轮", systemImage: "arrow.clockwise")
                        }

                        Button {
                            onEditTurn(turn)
                        } label: {
                            Label("编辑提问并重发", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            onDeleteTurn(turn)
                        } label: {
                            Label("删除本轮对话", systemImage: "trash")
                        }
                    }
            }

            if turn.usage != nil || (turn.modelSwitchedNote?.isEmpty == false) || !turn.assistantText.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    TurnUsageBadgeView(
                        usage: turn.usage,
                        modelSwitchedNote: turn.modelSwitchedNote
                    )

                    Spacer(minLength: 4)

                    if !turn.assistantText.isEmpty {
                        HStack(spacing: 6) {
                            Button {
                                onCopyText(turn.assistantText)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 26, height: 26)
                                    .cleanWhiteCard(cornerRadius: 999)
                            }

                            Button {
                                onRegenerateTurn(turn)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 26, height: 26)
                                    .cleanWhiteCard(cornerRadius: 999)
                            }

                            Menu {
                                Button {
                                    onCopyText(turn.assistantText)
                                } label: {
                                    Label("复制回复全文", systemImage: "doc.on.doc")
                                }
                                Button {
                                    onRegenerateTurn(turn)
                                } label: {
                                    Label("重新生成本轮", systemImage: "arrow.clockwise")
                                }
                                Button {
                                    onEditTurn(turn)
                                } label: {
                                    Label("编辑提问并重发", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    onDeleteTurn(turn)
                                } label: {
                                    Label("删除本轮对话", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 26, height: 26)
                                    .cleanWhiteCard(cornerRadius: 999)
                            }
                        }
                    }
                }
            }

            if let err = turn.errorText {
                Text("错误: \(err)")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cleanWhiteCard(cornerRadius: 14)
            }
        }
    }
}

