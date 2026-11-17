import SwiftUI

struct ChatView: View {
    @EnvironmentObject var client: BridgeClient
    @Binding var showSessionDrawer: Bool
    @State private var promptText: String = ""

    private let quickPrompts = [
        ("sparkles", "检查 Git 状态与变更"),
        ("folder.badge.gearshape", "梳理当前工作区架构"),
        ("checkmark.shield", "运行测试并排查问题"),
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if client.turns.isEmpty {
                    emptyWelcomeView
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(client.turns) { turn in
                            TurnRowView(turn: turn)
                                .id(turn.id)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .animation(.spring(response: 0.34, dampingFraction: 0.84), value: client.turns.count)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                topHeaderBar
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if !client.pendingApprovals.isEmpty {
                        pendingApprovalsBar
                            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
                    }
                    composerBar
                }
                .padding(.bottom, 64) // Leaves room for the floating Liquid Glass Tab Bar
                .animation(.spring(response: 0.32, dampingFraction: 0.80), value: client.pendingApprovals.count)
            }
            .onChange(of: client.turns.count) { _ in
                if let lastId = client.turns.last?.id {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
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

    private var emptyWelcomeView: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 90)

            Image("DSHLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .shadow(color: Color(red: 0.15, green: 0.28, blue: 0.58).opacity(0.14), radius: 16, x: 0, y: 6)

            Text("今天有什么可以帮你？")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color.dsPrimary)

            Text("深度思考与工具调用默认折叠 · 切后台自动登上灵动岛")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(quickPrompts, id: \.1) { icon, title in
                    Button {
                        Haptics.light()
                        Task { await client.sendPrompt(title) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.dsAccent)
                                .frame(width: 24)
                            Text(title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.dsPrimary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .cleanWhiteCard(cornerRadius: 16)
                    }
                    .glassPressable(scale: 0.97)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    // Floating iOS Liquid Glass Header Capsule
    private var topHeaderBar: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.light()
                showSessionDrawer = true
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
                    .frame(width: 38, height: 38)
                    .cleanWhiteCard(cornerRadius: 999)
            }
            .glassPressable(scale: 0.92)

            Spacer()

            HStack(spacing: 8) {
                Image("DSHLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(currentSessionTitle)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Color.dsPrimary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(client.isConnected ? Color.green : Color.orange)
                            .frame(width: 5.5, height: 5.5)
                        Text(client.isConnected ? "DSH 已连接" : "正在重连")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .liquidGlass(cornerRadius: 999, prominent: false)

            Spacer()

            Button {
                Haptics.light()
                Task {
                    if let s = try? await client.createNewSession() {
                        await client.selectSession(s.sessionId)
                    }
                }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
                    .frame(width: 38, height: 38)
                    .cleanWhiteCard(cornerRadius: 999)
            }
            .glassPressable(scale: 0.92)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
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
                        Haptics.medium()
                        Task { await client.resolveApproval(requestId: "all", allow: true) }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5.5)
                    .background(Capsule().fill(Color.dsPrimary))
                    .foregroundStyle(.white)
                    .glassPressable(scale: 0.95)

                    Button("全部转自动") {
                        Haptics.medium()
                        Task { await client.resolveApproval(requestId: "all", allow: true, setAutoMode: true) }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5.5)
                    .cleanWhiteCard(cornerRadius: 999)
                    .glassPressable(scale: 0.95)
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
                            Haptics.light()
                            Task { await client.resolveApproval(requestId: req.id, allow: true) }
                        }
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.dsPrimary))
                        .foregroundStyle(.white)
                        .glassPressable(scale: 0.95)

                        Button("允许并转自动") {
                            Haptics.light()
                            Task { await client.resolveApproval(requestId: req.id, allow: true, setAutoMode: true) }
                        }
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .cleanWhiteCard(cornerRadius: 999)
                        .glassPressable(scale: 0.95)

                        Button("拒绝") {
                            Haptics.warning()
                            Task { await client.resolveApproval(requestId: req.id, allow: false) }
                        }
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassPressable(scale: 0.95)
                    }
                }
                .padding(10)
                .cleanWhiteCard(cornerRadius: 14)
            }
        }
        .padding(12)
        .liquidGlass(cornerRadius: 22, prominent: true)
        .padding(.horizontal, 12)
    }

    private var composerBar: some View {
        let isRunning = (client.sessionStatus == "running" || client.sessionStatus == "waiting_input")
        let isEmptyPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(spacing: 7) {
            TextField("给 DeepSeek 发送消息...", text: $promptText, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 15.5))
                .padding(.horizontal, 6)
                .padding(.top, 4)

            HStack {
                Menu {
                    Button("deepseek-flash (极速)") { client.selectedModel = "deepseek-flash" }
                    Button("deepseek-chat (V3)") { client.selectedModel = "deepseek-chat" }
                    Button("deepseek-reasoner (R1)") { client.selectedModel = "deepseek-reasoner" }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.dsAccent)
                        Text(client.selectedModel)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dsPrimary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .cleanWhiteCard(cornerRadius: 999)
                }

                Spacer()

                if isRunning {
                    Button {
                        Haptics.medium()
                        Task { await client.cancelCurrentTurn() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.dsPrimary))
                            .shadow(color: Color.dsPrimary.opacity(0.25), radius: 6, x: 0, y: 3)
                    }
                    .glassPressable(scale: 0.90)
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Button {
                        Haptics.light()
                        let text = promptText
                        promptText = ""
                        Task { await client.sendPrompt(text) }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle().fill(
                                    isEmptyPrompt
                                        ? Color.gray.opacity(0.32)
                                        : Color.dsPrimary
                                )
                            )
                            .shadow(
                                color: isEmptyPrompt ? .clear : Color.dsPrimary.opacity(0.22),
                                radius: 6,
                                x: 0,
                                y: 3
                            )
                    }
                    .disabled(isEmptyPrompt)
                    .glassPressable(scale: 0.90)
                    .animation(.spring(response: 0.25, dampingFraction: 0.78), value: isEmptyPrompt)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .liquidGlass(cornerRadius: 24, prominent: true)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
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
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10.5)
                        .liquidGlass(cornerRadius: 20, prominent: false)
                }
            }

            // Grouped Process Pills (Deep Thinking & Tool Calls — collapsed by default)
            if !turn.thoughtText.isEmpty || !turn.toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if !turn.thoughtText.isEmpty {
                            Button {
                                Haptics.light()
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
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
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
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

            if !turn.assistantText.isEmpty {
                FormattedMarkdownView(markdown: turn.assistantText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cleanWhiteCard(cornerRadius: 20)
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
