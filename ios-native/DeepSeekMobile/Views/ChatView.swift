import SwiftUI

struct ChatView: View {
    @EnvironmentObject var client: BridgeClient
    @Binding var showSessionDrawer: Bool
    @State private var promptText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            topHeaderBar

            ScrollViewReader { proxy in
                ScrollView {
                    if client.turns.isEmpty {
                        VStack(spacing: 10) {
                            Spacer(minLength: 140)
                            Text("今天有什么可以帮你？")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Color.dsPrimary)
                            Text("支持深度思考与工具调用默认收纳 · 后台灵动岛实时同步")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(client.turns) { turn in
                                TurnRowView(turn: turn)
                                    .id(turn.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                }
                .onChange(of: client.turns.count) { _ in
                    if let lastId = client.turns.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }

            if !client.pendingApprovals.isEmpty {
                pendingApprovalsBar
            }

            composerBar
        }
        .onChange(of: client.referencedFilePath) { path in
            if let path = path {
                promptText = promptText.isEmpty
                    ? "请查看或修改工作区文件 `\(path)`："
                    : "\(promptText)\n请查看或修改工作区文件 `\(path)`："
                client.referencedFilePath = nil
            }
        }
    }

    private var topHeaderBar: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.light()
                showSessionDrawer = true
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.dsPrimary)
                    .frame(width: 36, height: 36)
            }

            Spacer()

            VStack(spacing: 2) {
                Text(currentSessionTitle)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Circle()
                        .fill(client.isConnected ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(client.isConnected ? "已连接" : "重连中")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Task {
                    if let s = try? await client.createNewSession() {
                        await client.selectSession(s.sessionId)
                    }
                }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.dsPrimary)
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }

    private var currentSessionTitle: String {
        client.sessions.first(where: { $0.sessionId == client.activeSessionId })?.title ?? "DeepSeek"
    }

    private var pendingApprovalsBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if client.pendingApprovals.count > 1 {
                HStack {
                    Text("待审批 (\(client.pendingApprovals.count) 项)")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("全部允许") {
                        Task { await client.resolveApproval(requestId: "all", allow: true) }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.dsPrimary))
                    .foregroundStyle(.white)

                    Button("全部转自动") {
                        Task { await client.resolveApproval(requestId: "all", allow: true, setAutoMode: true) }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .cleanWhiteCard(cornerRadius: 999)
                }
            }

            ForEach(client.pendingApprovals) { req in
                VStack(alignment: .leading, spacing: 6) {
                    Text("⚠️ 审批请求: \(req.toolName)")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(req.argsJSON)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)

                    HStack(spacing: 8) {
                        Button("允许执行") {
                            Task { await client.resolveApproval(requestId: req.id, allow: true) }
                        }
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.dsPrimary))
                        .foregroundStyle(.white)

                        Button("允许并转自动") {
                            Task { await client.resolveApproval(requestId: req.id, allow: true, setAutoMode: true) }
                        }
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .cleanWhiteCard(cornerRadius: 999)

                        Button("拒绝") {
                            Task { await client.resolveApproval(requestId: req.id, allow: false) }
                        }
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
                .padding(10)
                .cleanWhiteCard(cornerRadius: 14)
            }
        }
        .padding(12)
        .liquidGlass(cornerRadius: 20)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var composerBar: some View {
        VStack(spacing: 6) {
            TextField("给 DeepSeek 发送消息...", text: $promptText, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 16))
                .padding(.horizontal, 6)
                .padding(.top, 4)

            HStack {
                Menu {
                    Button("deepseek-flash") { client.selectedModel = "deepseek-flash" }
                    Button("deepseek-chat") { client.selectedModel = "deepseek-chat" }
                    Button("deepseek-reasoner") { client.selectedModel = "deepseek-reasoner" }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                        Text(client.selectedModel)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.dsSurface))
                }

                Spacer()

                if client.sessionStatus == "running" || client.sessionStatus == "waiting_input" {
                    Button {
                        Task { await client.cancelCurrentTurn() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.dsPrimary))
                    }
                } else {
                    Button {
                        let text = promptText
                        promptText = ""
                        Task { await client.sendPrompt(text) }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle().fill(
                                    promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? Color.gray.opacity(0.35)
                                        : Color.dsPrimary
                                )
                            )
                    }
                    .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlass(cornerRadius: 24)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

struct TurnRowView: View {
    let turn: ChatTurnItem
    // Both Deep Thinking & Tool Calls are COLLAPSED by default
    @State private var expandThoughts: Bool = false
    @State private var expandTools: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let userText = turn.userText, !userText.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    Text(userText)
                        .font(.system(size: 15.5))
                        .foregroundStyle(Color.dsPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.dsSurface2)
                        )
                }
            }

            // Grouped Process Pills (Deep Thinking & Tool Calls — collapsed by default)
            if !turn.thoughtText.isEmpty || !turn.toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if !turn.thoughtText.isEmpty {
                            Button {
                                Haptics.light()
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                    expandThoughts.toggle()
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.dsAccent)
                                    Text("深度思考 · \(turn.thoughtText.count)字")
                                        .font(.system(size: 12.5, weight: .medium))
                                    Image(systemName: expandThoughts ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundStyle(Color.dsPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .cleanWhiteCard(cornerRadius: 999)
                            }
                            .buttonStyle(.plain)
                        }

                        if !turn.toolCalls.isEmpty {
                            Button {
                                Haptics.light()
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                    expandTools.toggle()
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "wrench.and.screwdriver")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.dsAccent)
                                    Text("工具调用 · \(turn.toolCalls.count)次")
                                        .font(.system(size: 12.5, weight: .medium))
                                    Image(systemName: expandTools ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundStyle(Color.dsPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .cleanWhiteCard(cornerRadius: 999)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if expandThoughts && !turn.thoughtText.isEmpty {
                        Text(turn.thoughtText)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.dsSurface)
                            )
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
                                            Divider()
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
                                        Spacer()
                                        Text(tc.resultText == nil ? "执行中" : (tc.isError ? "失败" : "完成"))
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(tc.isError ? .red : .secondary)
                                    }
                                }
                                .padding(10)
                                .cleanWhiteCard(cornerRadius: 12)
                            }
                        }
                    }
                }
            }

            if !turn.assistantText.isEmpty {
                FormattedMarkdownView(markdown: turn.assistantText)
            }

            if let err = turn.errorText {
                Text("错误: \(err)")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.red.opacity(0.08))
                    )
            }
        }
    }
}

struct FormattedMarkdownView: View {
    let markdown: String

    var body: some View {
        if let attr = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attr)
                .font(.system(size: 15.5))
                .lineSpacing(5)
                .foregroundStyle(Color.dsPrimary)
                .textSelection(.enabled)
        } else {
            Text(markdown)
                .font(.system(size: 15.5))
                .lineSpacing(5)
                .foregroundStyle(Color.dsPrimary)
                .textSelection(.enabled)
        }
    }
}
