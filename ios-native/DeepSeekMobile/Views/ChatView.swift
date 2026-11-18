import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var client: BridgeClient
    @ObservedObject private var theme = ThemePreferences.shared
    @Binding var showSessionDrawer: Bool

    @State private var promptText: String = ""
    @FocusState private var isComposerFocused: Bool
    @State private var isComposerCollapsed: Bool = false
    @State private var idleTimerTask: Task<Void, Never>?
    @State private var currentNavIndex: Int = 0

    @State private var showChatFileImporter: Bool = false
    @State private var showPhotoPicker: Bool = false
    @State private var isUploadingAttachment: Bool = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showWorkspaceProfilesSheet: Bool = false
    @State private var reviewingArtifact: FileArtifactItem?
    @State private var previewingImageArtifact: ChatAttachmentItem?
    @State private var downloadedShareItem: ShareSheetItem?

    private let quickPrompts = [
        ("sparkles", "检查 Git 状态与变更"),
        ("doc.badge.arrow.up", "创建一个示例脚本并发送给我审查"),
        ("checkmark.shield", "运行测试并排查问题"),
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    Color.clear
                        .frame(height: 1)
                        .id("chatTopAnchor")

                    if client.turns.isEmpty {
                        emptyWelcomeView
                    } else {
                        LazyVStack(alignment: .leading, spacing: theme.compactMode ? 10 : 16) {
                            ForEach(Array(client.turns.enumerated()), id: \.element.id) { idx, turn in
                                TurnRowView(
                                    turn: turn,
                                    onReviewArtifact: { art in
                                        if art.effectiveIsImage {
                                            previewingImageArtifact = art.asChatAttachment
                                        } else {
                                            reviewingArtifact = art
                                        }
                                    },
                                    onDownloadArtifact: { art in
                                        Task {
                                            if let url = try? await client.downloadPCFileToLocalTemp(pcPath: art.path, filename: art.name) {
                                                downloadedShareItem = ShareSheetItem(url: url)
                                            }
                                        }
                                    },
                                    onCopyText: { text in
                                        UIPasteboard.general.string = text
                                        Haptics.light()
                                        client.showToastMessage("已复制内容")
                                    },
                                    onEditTurn: { t in
                                        let tid = t.turnId.isEmpty ? t.id : t.turnId
                                        client.editingTurnId = tid
                                        promptText = t.userText ?? ""
                                        withAnimation(AppleMotion.smooth) {
                                            isComposerCollapsed = false
                                        }
                                        isComposerFocused = true
                                    },
                                    onRegenerateTurn: { t in
                                        let tid = t.turnId.isEmpty ? t.id : t.turnId
                                        Task { await client.regenerateTurn(tid) }
                                    },
                                    onDeleteTurn: { t in
                                        let tid = t.turnId.isEmpty ? t.id : t.turnId
                                        Task { await client.deleteTurn(tid) }
                                    }
                                )
                                .id(turn.id)
                                .onAppear {
                                    currentNavIndex = idx
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .padding(.bottom, 22)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("chatBottomAnchor")
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 14).onChanged { _ in
                        if theme.autoHideComposer
                            && !isComposerFocused
                            && promptText.isEmpty
                            && client.pendingAttachments.isEmpty
                            && client.pendingApprovals.isEmpty
                            && !showPhotoPicker
                        {
                            withAnimation(AppleMotion.smooth) {
                                isComposerCollapsed = true
                            }
                        }
                    }
                )
                .onTapGesture {
                    if isComposerFocused {
                        isComposerFocused = false
                    } else {
                        bumpIdleTimer()
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
                        if !client.queuedMessages.isEmpty {
                            queuedMessagesTray
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        if isComposerCollapsed && theme.autoHideComposer && client.pendingApprovals.isEmpty {
                            collapsedComposerPill
                                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)))
                        } else {
                            composerBar
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .padding(.bottom, 64)
                    .animation(AppleMotion.smooth, value: isComposerCollapsed)
                    .animation(AppleMotion.smooth, value: client.pendingApprovals.count)
                    .animation(AppleMotion.snappy, value: client.queuedMessages.count)
                }

                // Quick Context Up/Down Navigation Bar
                if !client.turns.isEmpty {
                    quickNavigationPill(proxy: proxy)
                        .padding(.trailing, 8)
                        .padding(.bottom, isComposerCollapsed ? 120 : 185)
                        .transition(.opacity)
                }
            }
            .onChange(of: client.turns.count) { newCount in
                if newCount > 0 {
                    currentNavIndex = max(0, newCount - 1)
                }
                withAnimation(AppleMotion.smooth) {
                    proxy.scrollTo("chatBottomAnchor", anchor: .bottom)
                }
            }
        }
        .onAppear {
            bumpIdleTimer()
        }
        .onDisappear {
            idleTimerTask?.cancel()
        }
        .onChange(of: isComposerFocused) { focused in
            if focused {
                idleTimerTask?.cancel()
                withAnimation(AppleMotion.smooth) {
                    isComposerCollapsed = false
                }
            } else {
                bumpIdleTimer()
            }
        }
        .onChange(of: promptText) { _ in
            bumpIdleTimer()
        }
        .onChange(of: theme.autoHideComposer) { enabled in
            if !enabled {
                idleTimerTask?.cancel()
                withAnimation(AppleMotion.smooth) {
                    isComposerCollapsed = false
                }
            } else {
                bumpIdleTimer()
            }
        }
        .onChange(of: client.referencedFilePath) { path in
            if let path = path {
                promptText = promptText.isEmpty
                    ? "请查看或处理电脑文件 `\(path)`："
                    : "\(promptText)\n请查看或处理电脑文件 `\(path)`："
                client.referencedFilePath = nil
                withAnimation(AppleMotion.smooth) { isComposerCollapsed = false }
                bumpIdleTimer()
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 6,
            matching: .images
        )
        .onChange(of: showPhotoPicker) { isOpen in
            if isOpen {
                idleTimerTask?.cancel()
                withAnimation(AppleMotion.smooth) {
                    isComposerCollapsed = false
                }
            } else {
                bumpIdleTimer()
            }
        }
        .fileImporter(
            isPresented: $showChatFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let firstURL = urls.first {
                Task {
                    isUploadingAttachment = true
                    if let uploaded = try? await client.uploadLocalFileToPC(fileURL: firstURL, targetDir: nil) {
                        let attachNote = "我已将文件上传到电脑本地路径 `\(uploaded.path)`，请查看或按需求处理该文件："
                        promptText = promptText.isEmpty ? attachNote : "\(promptText)\n\(attachNote)"
                        isComposerCollapsed = false
                        bumpIdleTimer()
                    }
                    isUploadingAttachment = false
                }
            }
        }
        .sheet(item: $reviewingArtifact) { art in
            ArtifactReviewSheet(artifact: art)
                .environmentObject(client)
        }
        .fullScreenCover(item: $previewingImageArtifact) { att in
            ImageLightboxSheet(
                attachments: [att],
                initialIndex: 0,
                baseURL: client.normalizedBaseURL,
                authToken: client.authToken
            )
            .environmentObject(client)
        }
        .sheet(item: $downloadedShareItem) { share in
            ActivityViewSheet(items: [share.url])
        }
        .sheet(isPresented: $showWorkspaceProfilesSheet) {
            WorkspaceProfilesSheet(
                profiles: client.workspaceProfiles,
                activeProfileId: client.activeWorkspaceProfileId,
                authorizedPaths: client.workspaces,
                onSelectProfile: { wp in
                    Task { await client.selectWorkspaceProfile(wp.id) }
                },
                onCreateProfile: { wp in
                    Task {
                        await client.saveWorkspaceProfile(
                            id: nil,
                            name: wp.name,
                            icon: wp.icon,
                            color: wp.color,
                            rootPaths: wp.rootPaths,
                            defaultProfileId: wp.defaultProfileId,
                            defaultApprovalMode: wp.defaultApprovalMode,
                            sharedNotes: wp.sharedNotes,
                            crossSessionRead: wp.crossSessionRead
                        )
                    }
                },
                onUpdateProfile: { wp in
                    Task {
                        await client.saveWorkspaceProfile(
                            id: wp.id,
                            name: wp.name,
                            icon: wp.icon,
                            color: wp.color,
                            rootPaths: wp.rootPaths,
                            defaultProfileId: wp.defaultProfileId,
                            defaultApprovalMode: wp.defaultApprovalMode,
                            sharedNotes: wp.sharedNotes,
                            crossSessionRead: wp.crossSessionRead
                        )
                    }
                },
                onDeleteProfile: { pid in
                    Task { await client.deleteWorkspaceProfile(pid) }
                }
            )
        }
        .onChange(of: selectedPhotoItems) { newItems in
            guard !newItems.isEmpty else { return }
            let itemsToProcess = newItems
            selectedPhotoItems = []
            Task {
                isUploadingAttachment = true
                for (index, item) in itemsToProcess.enumerated() {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        _ = await client.uploadImageAttachment(
                            data: data,
                            filename: "photo_\(Int(Date().timeIntervalSince1970))_\(index + 1).jpg"
                        )
                    }
                }
                isUploadingAttachment = false
                withAnimation(AppleMotion.smooth) {
                    isComposerCollapsed = false
                }
                bumpIdleTimer()
            }
        }
    }

    private func bumpIdleTimer() {
        idleTimerTask?.cancel()
        guard theme.autoHideComposer else {
            isComposerCollapsed = false
            return
        }
        let delayNs = UInt64(max(1.5, theme.autoHideDelaySec) * 1_000_000_000)
        idleTimerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            let empty = promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let anyModalOpen = showPhotoPicker
                || showChatFileImporter
                || showWorkspaceProfilesSheet
                || reviewingArtifact != nil
                || previewingImageArtifact != nil
                || client.editingTurnId != nil
            if theme.autoHideComposer
                && !isComposerFocused
                && empty
                && !anyModalOpen
                && client.pendingAttachments.isEmpty
                && client.pendingApprovals.isEmpty
                && client.queuedMessages.isEmpty
            {
                withAnimation(AppleMotion.smooth) {
                    isComposerCollapsed = true
                }
            }
        }
    }

    private func quickNavigationPill(proxy: ScrollViewProxy) -> some View {
        let total = client.turns.count
        let clamped = min(max(0, currentNavIndex), max(0, total - 1))
        return VStack(spacing: 4) {
            Button {
                Haptics.light()
                bumpIdleTimer()
                currentNavIndex = 0
                withAnimation(.easeInOut(duration: 0.28)) {
                    proxy.scrollTo("chatTopAnchor", anchor: .top)
                }
            } label: {
                Image(systemName: "arrow.up.to.line")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Color.dsPrimary)
                    .frame(width: 30, height: 28)
            }

            Button {
                Haptics.light()
                bumpIdleTimer()
                let prev = max(0, clamped - 1)
                currentNavIndex = prev
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(client.turns[prev].id, anchor: .top)
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(clamped > 0 ? Color.dsAccent : .secondary.opacity(0.45))
                    .frame(width: 30, height: 26)
            }
            .disabled(clamped <= 0)

            Text("\(clamped + 1)/\(total)")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.vertical, 1)

            Button {
                Haptics.light()
                bumpIdleTimer()
                let next = min(total - 1, clamped + 1)
                currentNavIndex = next
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(client.turns[next].id, anchor: .top)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(clamped < total - 1 ? Color.dsAccent : .secondary.opacity(0.45))
                    .frame(width: 30, height: 26)
            }
            .disabled(clamped >= total - 1)

            Button {
                Haptics.light()
                bumpIdleTimer()
                currentNavIndex = max(0, total - 1)
                withAnimation(.easeInOut(duration: 0.28)) {
                    proxy.scrollTo("chatBottomAnchor", anchor: .bottom)
                }
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Color.dsPrimary)
                    .frame(width: 30, height: 28)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 3)
        .liquidGlass(cornerRadius: 18, prominent: false)
    }

    private var collapsedComposerPill: some View {
        let isRunning = (client.sessionStatus == "running" || client.sessionStatus == "waiting_input")
        return HStack(spacing: 8) {
            Spacer()
            if isRunning {
                Button {
                    Haptics.medium()
                    Task { await client.cancelCurrentTurn() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10.5, weight: .bold))
                        Text("停止")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8.5)
                    .background(Capsule().fill(Color.red.opacity(0.88)))
                }
                .glassPressable(scale: 0.94)
            }

            Button {
                Haptics.light()
                withAnimation(AppleMotion.smooth) {
                    isComposerCollapsed = false
                }
                bumpIdleTimer()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                    Text("展开输入")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.dsPrimary)
                    Text(client.selectedModel)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .liquidGlass(cornerRadius: 999, prominent: true)
            }
            .glassPressable(scale: 0.95)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private var queuedMessagesTray: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("消息排队中 (\(client.queuedMessages.count))", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
                Spacer()
                Button("全部清空") {
                    Haptics.light()
                    Task { await client.clearQueuedMessages() }
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            }

            ForEach(Array(client.queuedMessages.enumerated()), id: \.element.id) { idx, q in
                HStack(spacing: 8) {
                    Text("#\(idx + 1)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.accentColor)
                    Text(q.prompt)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.dsPrimary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        Haptics.light()
                        Task { await client.promoteQueuedMessage(q.id) }
                    } label: {
                        Text(client.sessionStatus == "idle" ? "立即发送" : "插队")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                    }
                    Button {
                        Haptics.light()
                        Task { await client.deleteQueuedMessage(q.id) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .cleanWhiteCard(cornerRadius: 12)
            }
        }
        .padding(10)
        .liquidGlass(cornerRadius: 18, prominent: false)
        .padding(.horizontal, 12)
    }

    private var emptyWelcomeView: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 80)

            Image("DSHLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .shadow(color: Color(red: 0.15, green: 0.28, blue: 0.58).opacity(0.14), radius: 16, x: 0, y: 6)

            Text("今天有什么可以帮你？")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color.dsPrimary)

            Text("支持互传文件与 Claude 式文件卡片审查 · 切后台自动登上灵动岛")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

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

    private var activeWorkspaceProfileName: String {
        client.workspaceProfiles.first(where: { $0.id == client.activeWorkspaceProfileId })?.name ?? "默认工作区"
    }

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

            Menu {
                Section("切换工作区记忆档案") {
                    ForEach(client.workspaceProfiles) { wp in
                        Button {
                            Task { await client.selectWorkspaceProfile(wp.id) }
                        } label: {
                            HStack {
                                Label(wp.name, systemImage: wp.icon.isEmpty ? "folder.fill" : wp.icon)
                                if wp.id == client.activeWorkspaceProfileId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Section {
                    Button {
                        showWorkspaceProfilesSheet = true
                    } label: {
                        Label("管理工作区档案...", systemImage: "folder.badge.gearshape")
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image("DSHLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(currentSessionTitle)
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(Color.dsPrimary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 4) {
                            Circle()
                                .fill(client.isConnected ? Color.green : Color.orange)
                                .frame(width: 5.5, height: 5.5)
                            Text(client.isConnected ? "\(activeWorkspaceProfileName) · \(aiModeShortLabel)" : "正在重连")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .liquidGlass(cornerRadius: 999, prominent: false)
            }

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

    private var aiModeShortLabel: String {
        switch client.aiAccessMode {
        case "full_access": return "AI全盘权限"
        case "workspace_read_all": return "全盘只读"
        default: return "工作区隔离"
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
                    HStack(spacing: 6) {
                        Text("⚠️ 审批请求: \(req.toolName)")
                            .font(.system(size: 13.5, weight: .semibold))
                        Spacer()
                        Button {
                            Haptics.light()
                            client.activeApprovalForPopup = req
                        } label: {
                            Label("审查弹窗", systemImage: "shield.lefthalf.filled")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                        }
                    }
                    if !req.reviewSummary.isEmpty {
                        Text(req.reviewSummary)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(req.riskLevel == "high" || req.riskLevel == "critical" ? .red : .orange)
                    }
                    Text(req.argsJSON)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)

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
        let canSend = !isEmptyPrompt || !client.pendingAttachments.isEmpty

        return VStack(alignment: .leading, spacing: 7) {
            if client.editingTurnId != nil {
                HStack(spacing: 8) {
                    Text("✏️ 正在编辑历史消息（发送后将截断并重新生成后续回复）")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .lineLimit(1)
                    Spacer()
                    Button("取消") {
                        Haptics.light()
                        client.editingTurnId = nil
                        promptText = ""
                    }
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.orange.opacity(0.14))
                )
            }

            if !client.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(client.pendingAttachments) { att in
                            ZStack(alignment: .topTrailing) {
                                RemoteAttachmentImageView(
                                    attachment: att,
                                    useThumbnail: true,
                                    baseURL: client.normalizedBaseURL,
                                    authToken: client.authToken,
                                    contentMode: .fill
                                )
                                .frame(width: 58, height: 58)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                                )

                                Button {
                                    client.removePendingAttachment(att.attId)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.white, Color.black.opacity(0.68))
                                }
                                .offset(x: 4, y: -4)
                            }
                            .padding(.top, 4)
                            .padding(.trailing, 4)
                        }
                    }
                }
            }

            TextField("给 AI 发送消息（支持发图/内置浏览器/让AI截图）...", text: $promptText, axis: .vertical)
                .focused($isComposerFocused)
                .lineLimit(1...5)
                .font(.system(size: theme.scaledFont(15.5)))
                .padding(.horizontal, 6)
                .padding(.top, 4)

            HStack(spacing: 7) {
                Button {
                    Haptics.light()
                    idleTimerTask?.cancel()
                    showPhotoPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.accentColor)
                        Text("相册")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dsPrimary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5.5)
                    .cleanWhiteCard(cornerRadius: 999)
                }
                .glassPressable(scale: 0.94)

                Menu {
                    Button {
                        Haptics.light()
                        Task { await client.openBrowserInChat(url: "https://www.deepseek.com") }
                    } label: {
                        Label("🌐 内置浏览器", systemImage: "globe")
                    }

                    Button {
                        Haptics.light()
                        idleTimerTask?.cancel()
                        showChatFileImporter = true
                    } label: {
                        Label("📎 传电脑文件", systemImage: "paperclip")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isUploadingAttachment ? "arrow.triangle.2.circlepath" : "plus.circle.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(theme.accentColor)
                        Text(isUploadingAttachment ? "处理中" : "工具")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dsPrimary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5.5)
                    .cleanWhiteCard(cornerRadius: 999)
                }

                Menu {
                    if !client.modelProfiles.isEmpty {
                        ForEach(client.modelProfiles) { prof in
                            Button {
                                Task { await client.switchModelProfile(prof) }
                            } label: {
                                HStack {
                                    Text(prof.supportsVision ? "👁️ \(prof.name)" : prof.name)
                                    if prof.id == client.activeProfileId {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } else {
                        Button("deepseek-flash") { client.selectedModel = "deepseek-flash" }
                        Button("deepseek-chat") { client.selectedModel = "deepseek-chat" }
                        Button("deepseek-reasoner") { client.selectedModel = "deepseek-reasoner" }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.accentColor)
                        Text(client.selectedModel)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dsPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .cleanWhiteCard(cornerRadius: 999)
                }

                if theme.autoHideComposer {
                    Button {
                        Haptics.light()
                        isComposerFocused = false
                        withAnimation(AppleMotion.smooth) {
                            isComposerCollapsed = true
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isRunning && canSend {
                    Button {
                        Haptics.light()
                        let text = promptText
                        promptText = ""
                        Task { await client.sendPrompt(text) }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "text.badge.plus")
                                .font(.system(size: 12, weight: .bold))
                            Text("排队")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(theme.accentColor))
                    }
                    .glassPressable(scale: 0.92)
                }

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
                } else {
                    Button {
                        Haptics.light()
                        let text = promptText
                        promptText = ""
                        isComposerFocused = false
                        Task { await client.sendPrompt(text) }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle().fill(
                                    !canSend
                                        ? Color.gray.opacity(0.32)
                                        : Color.dsPrimary
                                )
                            )
                            .shadow(
                                color: !canSend ? .clear : Color.dsPrimary.opacity(0.22),
                                radius: 6,
                                x: 0,
                                y: 3
                            )
                    }
                    .disabled(!canSend)
                    .glassPressable(scale: 0.90)
                    .animation(AppleMotion.snappy, value: canSend)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .liquidGlass(cornerRadius: CGFloat(theme.bubbleRadius + 4), prominent: true)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

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

            // Inline Collaborative Browser Sessions
            if !turn.browserSessions.isEmpty {
                VStack(spacing: 10) {
                    ForEach(turn.browserSessions) { bState in
                        let liveState = client.activeBrowserSessions[bState.browserId] ?? bState
                        BrowserInlineCardView(
                            state: liveState,
                            onNavigate: { url in
                                Task { await client.browserNavigate(browserId: liveState.browserId, url: url) }
                            },
                            onBack: {
                                Task { await client.browserHistoryAction(browserId: liveState.browserId, action: "back") }
                            },
                            onForward: {
                                Task { await client.browserHistoryAction(browserId: liveState.browserId, action: "forward") }
                            },
                            onReload: {
                                Task { await client.browserHistoryAction(browserId: liveState.browserId, action: "reload") }
                            },
                            onScreenshot: {
                                Task { await client.browserScreenshotToChat(browserId: liveState.browserId) }
                            },
                            onToggleControl: { owner in
                                Task { await client.browserSetControl(browserId: liveState.browserId, owner: owner) }
                            },
                            onTapCoordinate: { vx, vy in
                                Task {
                                    await client.browserSendInput(
                                        browserId: liveState.browserId,
                                        action: "click_xy",
                                        x: vx,
                                        y: vy
                                    )
                                }
                            },
                            onClickElement: { elId in
                                Task {
                                    await client.browserSendInput(
                                        browserId: liveState.browserId,
                                        action: "click",
                                        elementId: elId
                                    )
                                }
                            },
                            onTypeText: { elId, txt, sub in
                                Task {
                                    await client.browserSendInput(
                                        browserId: liveState.browserId,
                                        action: "type",
                                        elementId: elId,
                                        text: txt,
                                        submit: sub
                                    )
                                }
                            },
                            onScroll: { dy in
                                Task {
                                    await client.browserSendInput(
                                        browserId: liveState.browserId,
                                        action: "scroll",
                                        deltaY: dy
                                    )
                                }
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

// MARK: - Claude-Style Interactive File Artifact Card

struct FileArtifactCardView: View {
    @EnvironmentObject var client: BridgeClient
    let artifact: FileArtifactItem
    let onReview: () -> Void
    let onDownload: () -> Void

    private var iconName: String {
        if artifact.effectiveIsImage {
            return "photo.on.rectangle.angled"
        }
        return artifact.isText ? "doc.text.magnifyingglass" : "arrow.down.doc.fill"
    }

    private var badgeText: String {
        if artifact.effectiveIsImage {
            return "图片预览"
        }
        return artifact.mode == "download" ? "供下载" : "供审查"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.dsAccent.opacity(0.14))
                        .frame(width: 42, height: 42)
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.dsAccent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(artifact.title)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(Color.dsPrimary)
                            .lineLimit(1)

                        Text(badgeText)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.dsAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.dsAccent.opacity(0.14)))
                    }

                    Text("\(artifact.name) · \(artifact.formattedSize)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            if !artifact.summary.isEmpty {
                Text(artifact.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            if artifact.effectiveIsImage {
                Button {
                    Haptics.light()
                    onReview()
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        RemoteAttachmentImageView(
                            attachment: artifact.asChatAttachment,
                            useThumbnail: false,
                            baseURL: client.normalizedBaseURL,
                            authToken: client.authToken,
                            contentMode: .fit
                        )
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 150, maxHeight: 240)
                        .background(Color.black.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 10, weight: .bold))
                            Text(
                                artifact.imageWidth > 0
                                    ? "\(artifact.imageWidth)×\(artifact.imageHeight) · 点击全屏缩放"
                                    : "点击全屏预览"
                            )
                            .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.62)))
                        .padding(8)
                    }
                }
                .buttonStyle(.plain)
            } else if artifact.isText && !artifact.preview.isEmpty {
                Text(artifact.preview.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).joined(separator: "\n"))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.dsPrimary.opacity(0.85))
                    .lineLimit(6)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.55))
                    )
            }

            HStack(spacing: 10) {
                Button {
                    Haptics.light()
                    onReview()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: artifact.effectiveIsImage ? "photo.badge.magnifyingglass" : "eye.fill")
                            .font(.system(size: 12))
                        Text(artifact.effectiveIsImage ? "全屏预览图片" : "审查 / 编辑内容")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.dsPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .cleanWhiteCard(cornerRadius: 999)
                }
                .glassPressable(scale: 0.96)

                Button {
                    Haptics.medium()
                    onDownload()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12.5))
                        Text("下载到手机")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.dsPrimary))
                }
                .glassPressable(scale: 0.96)
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 20, prominent: true)
    }
}

// MARK: - Full-Screen Claude-Style Artifact Review & Edit Sheet

struct ArtifactReviewSheet: View {
    @EnvironmentObject var client: BridgeClient
    @Environment(\.dismiss) private var dismiss
    let artifact: FileArtifactItem

    @State private var fullContent: String = ""
    @State private var isLoading: Bool = true
    @State private var isSaving: Bool = false
    @State private var savedToast: Bool = false
    @State private var shareItem: ShareSheetItem?

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackdropView()

                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artifact.path)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text("文件大小: \(artifact.formattedSize)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task {
                                if let url = try? await client.downloadPCFileToLocalTemp(pcPath: artifact.path, filename: artifact.name) {
                                    shareItem = ShareSheetItem(url: url)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("下载到手机")
                            }
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.dsPrimary))
                        }
                        .glassPressable(scale: 0.95)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)

                    if isLoading {
                        Spacer()
                        ProgressView("正在加载完整文件内容...")
                        Spacer()
                    } else {
                        TextEditor(text: $fullContent)
                            .font(.system(size: 13.5, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .cleanWhiteCard(cornerRadius: 18)
                            .padding(.horizontal, 12)
                    }

                    HStack(spacing: 10) {
                        Button {
                            client.referencedFilePath = artifact.path
                            dismiss()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkles")
                                Text("让 AI 继续修改")
                            }
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color.dsPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .cleanWhiteCard(cornerRadius: 999)
                        }
                        .glassPressable(scale: 0.96)

                        Button {
                            Task {
                                isSaving = true
                                try? await client.writePCFile(artifact.path, content: fullContent)
                                isSaving = false
                                savedToast = true
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                savedToast = false
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: savedToast ? "checkmark.circle.fill" : "square.and.arrow.down")
                                Text(savedToast ? "已保存至电脑" : (isSaving ? "保存中..." : "保存修改到电脑"))
                            }
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(savedToast ? Color.green : Color.dsAccent))
                        }
                        .glassPressable(scale: 0.96)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }
            .navigationTitle(artifact.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $shareItem) { s in
                ActivityViewSheet(items: [s.url])
            }
            .onAppear {
                fullContent = artifact.preview
                Task {
                    if let res = try? await client.readPCFile(artifact.path) {
                        fullContent = res.content
                    }
                    isLoading = false
                }
            }
        }
    }
}

struct FormattedMarkdownView: View {
    let markdown: String
    @ObservedObject private var theme = ThemePreferences.shared
    @State private var cachedAttr: AttributedString?
    @State private var lastParsedText: String = ""

    var body: some View {
        let fSize = theme.scaledFont(15.5)
        Group {
            if let attr = cachedAttr {
                Text(attr)
            } else {
                Text(markdown)
            }
        }
        .font(.system(size: fSize))
        .lineSpacing(theme.compactMode ? 3.5 : 5)
        .foregroundStyle(Color.dsPrimary)
        .textSelection(.enabled)
        .onAppear {
            parseIfNeeded(markdown)
        }
        .onChange(of: markdown) { newText in
            parseIfNeeded(newText)
        }
    }

    private func parseIfNeeded(_ text: String) {
        guard text != lastParsedText else { return }
        lastParsedText = text
        guard text.count <= 4500 else {
            cachedAttr = nil
            return
        }
        cachedAttr = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }
}
