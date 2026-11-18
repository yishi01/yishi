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
                                            do {
                                                let url = try await client.downloadPCFileToLocalTemp(pcPath: art.path, filename: art.name)
                                                downloadedShareItem = ShareSheetItem(url: url)
                                            } catch {
                                                client.showToastMessage("下载失败: \(error.localizedDescription)")
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
                    do {
                        let uploaded = try await client.uploadLocalFileToPC(fileURL: firstURL, targetDir: nil)
                        let attachNote = "我已将文件上传到电脑本地路径 `\(uploaded.path)`，请查看或按需求处理该文件："
                        promptText = promptText.isEmpty ? attachNote : "\(promptText)\n\(attachNote)"
                        isComposerCollapsed = false
                        bumpIdleTimer()
                    } catch {
                        client.showToastMessage("上传文件失败: \(error.localizedDescription)")
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
                    _ = try? await client.createNewSession()
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
                        Button("deepseek-flash") {
                            client.selectedModel = "deepseek-flash"
                            client.activeProfileId = "deepseek-flash"
                        }
                        Button("deepseek-chat") {
                            client.selectedModel = "deepseek-chat"
                            client.activeProfileId = "deepseek-chat"
                        }
                        Button("deepseek-reasoner") {
                            client.selectedModel = "deepseek-reasoner"
                            client.activeProfileId = "deepseek-reasoner"
                        }
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

