import SwiftUI

enum MainTab: String, CaseIterable {
    case chat = "对话"
    case files = "文件"
    case plugins = "插件"
    case settings = "设置"

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .files: return "folder"
        case .plugins: return "puzzlepiece.extension"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var client: BridgeClient
    @State private var activeTab: MainTab = .chat
    @State private var showSessionDrawer: Bool = false
    @State private var urlInput: String = "http://192.168.31.190:8765"
    @State private var tokenInput: String = BridgeClient.defaultToken
    @Namespace private var tabGlassNamespace

    var body: some View {
        ZStack {
            // Ambient refractive light canvas for true iOS Liquid Glass
            LiquidGlassBackdropView()

            if !client.isAuthenticated {
                authGateView
            } else {
                mainAuthenticatedView
            }
        }
        .onAppear {
            urlInput = client.serverURL.isEmpty ? "http://192.168.31.190:8765" : client.serverURL
            tokenInput = client.authToken.isEmpty ? BridgeClient.defaultToken : client.authToken
        }
        .onChange(of: client.serverURL) { newVal in
            if !newVal.isEmpty {
                urlInput = newVal
            }
        }
    }

    private var authGateView: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 42)

                // Official DSH Logo
                Image("DSHLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 78, height: 78)
                    .shadow(color: Color(red: 0.15, green: 0.28, blue: 0.58).opacity(0.16), radius: 18, x: 0, y: 8)

                VStack(spacing: 5) {
                    Text("DeepSeek Go")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.dsPrimary)

                    Text("连接电脑端 DSH 全盘工作区与 DeepSeek Agent")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "network")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.dsAccent)
                            .frame(width: 22)
                        TextField("服务器地址 (如 http://192.168.31.190:8765)", text: $urlInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.next)
                            .font(.system(size: 14.5))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .cleanWhiteCard(cornerRadius: 16)

                    // One-Tap Route Presets (Cloudflare Public + LAN Wi-Fi + Tailscale)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(client.effectivePresetURLs, id: \.url) { preset in
                                let isPicked = (urlInput == preset.url)
                                Button {
                                    Haptics.light()
                                    urlInput = preset.url
                                } label: {
                                    Text(preset.label)
                                        .font(.system(size: 11.5, weight: isPicked ? .semibold : .medium))
                                        .foregroundStyle(isPicked ? Color.dsAccent : Color.dsPrimary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5.5)
                                        .cleanWhiteCard(cornerRadius: 999)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.dsAccent)
                            .frame(width: 22)
                        TextField("粘贴电脑端 Auth Token", text: $tokenInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit {
                                Task { await client.verifyAndLogin(url: urlInput, token: tokenInput) }
                            }
                            .font(.system(size: 13.5, design: .monospaced))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .cleanWhiteCard(cornerRadius: 16)

                    Button {
                        Haptics.medium()
                        Task {
                            await client.verifyAndLogin(url: urlInput, token: tokenInput)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if client.isConnecting {
                                ProgressView()
                                    .tint(.white)
                                Text("正在并发探测所有线路...")
                                    .font(.system(size: 15.5, weight: .semibold))
                            } else {
                                Text("连接工作区 (自动极速选路)")
                                    .font(.system(size: 15.5, weight: .semibold))
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 14, weight: .bold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            Capsule()
                                .fill(Color.dsPrimary)
                                .shadow(color: Color.dsPrimary.opacity(0.22), radius: 12, x: 0, y: 6)
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(18)
                .liquidGlass(cornerRadius: 28, prominent: true)
                .padding(.horizontal, 18)

                if let err = client.authError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(err)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.red)

                        if !client.probeDiagnostics.isEmpty {
                            Divider().opacity(0.4)
                            ForEach(client.probeDiagnostics, id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .cleanWhiteCard(cornerRadius: 16)
                    .padding(.horizontal, 18)
                }

                Spacer(minLength: 24)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var mainAuthenticatedView: some View {
        ZStack(alignment: .bottom) {
            // Content extends full height behind the floating Liquid Glass tab bar for real optical refraction
            ZStack {
                switch activeTab {
                case .chat:
                    ChatView(showSessionDrawer: $showSessionDrawer)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                case .files:
                    FilesView(activeTab: $activeTab)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                case .plugins:
                    PluginsSimulatorView()
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                case .settings:
                    GitSettingsView(activeTab: $activeTab)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.34, dampingFraction: 0.84), value: activeTab)

            // Floating iOS Liquid Glass Tab Bar with 4 Compact Pills
            HStack(spacing: 3) {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    let isSelected = (activeTab == tab)
                    Button {
                        guard activeTab != tab else { return }
                        Haptics.light()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.80)) {
                            activeTab = tab
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                                .scaleEffect(isSelected ? 1.05 : 1.0)
                            Text(tab.rawValue)
                                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        }
                        .foregroundStyle(isSelected ? Color.dsPrimary : Color.secondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9.5)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0.92),
                                                Color.white.opacity(0.68),
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.95), lineWidth: 1)
                                    )
                                    .shadow(
                                        color: Color(red: 0.15, green: 0.28, blue: 0.58).opacity(0.10),
                                        radius: 8,
                                        x: 0,
                                        y: 3
                                    )
                                    .matchedGeometryEffect(id: "activeTabDroplet", in: tabGlassNamespace)
                            }
                        }
                    }
                    .glassPressable(scale: 0.95)
                }
            }
            .padding(5)
            .liquidGlass(cornerRadius: 999, prominent: true)
            .padding(.bottom, 6)

            if let toast = client.globalToast {
                VStack {
                    Text(toast)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.dsPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .liquidGlass(cornerRadius: 999, prominent: true)
                        .padding(.top, 56)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if !client.isConnected {
                VStack {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(client.isConnecting ? "正在并发探测最优连接线路..." : "连接中断，可切换网络或点此重连")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.dsPrimary)
                        Button("重连") {
                            Haptics.light()
                            Task {
                                await client.verifyAndLogin(url: client.serverURL, token: client.authToken, silentIfPaired: true)
                            }
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.dsAccent)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .liquidGlass(cornerRadius: 999, prominent: true)
                    .padding(.top, 54)
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showSessionDrawer) {
            SessionDrawerSheet()
                .environmentObject(client)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $client.activeApprovalForPopup) { approval in
            ApprovalReviewSheet(item: approval)
                .environmentObject(client)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

struct SessionDrawerSheet: View {
    @EnvironmentObject var client: BridgeClient
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProfileFilter: String = ""
    @State private var showWorkspaceProfilesManager: Bool = false
    @State private var renamingSession: SessionSummaryItem?
    @State private var renameDraftTitle: String = ""
    @State private var showRenameAlert: Bool = false

    private var filteredSessions: [SessionSummaryItem] {
        guard !selectedProfileFilter.isEmpty else { return client.sessions }
        return client.sessions.filter { $0.workspaceProfileId == selectedProfileFilter }
    }

    private func workspaceName(for profileId: String) -> String {
        client.workspaceProfiles.first(where: { $0.id == profileId })?.name ?? "默认工作区"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackdropView()

                VStack(spacing: 0) {
                    workspaceFilterHeader
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(filteredSessions) { s in
                                sessionRow(s)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("对话历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.light()
                        showWorkspaceProfilesManager = true
                    } label: {
                        Label("工作区档案", systemImage: "folder.badge.gearshape")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("修改对话标题", isPresented: $showRenameAlert) {
                TextField("输入新标题...", text: $renameDraftTitle)
                Button("取消", role: .cancel) {
                    renamingSession = nil
                }
                Button("保存") {
                    if let target = renamingSession {
                        let newTitle = renameDraftTitle
                        Task { await client.renameSession(target.sessionId, title: newTitle) }
                    }
                    renamingSession = nil
                }
            } message: {
                Text("为该对话设置便于检索的名称")
            }
            .sheet(isPresented: $showWorkspaceProfilesManager) {
                WorkspaceProfilesSheet(
                    profiles: client.workspaceProfiles,
                    activeProfileId: client.activeWorkspaceProfileId,
                    authorizedPaths: client.workspaces,
                    onSelectProfile: { wp in
                        selectedProfileFilter = wp.id
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
        }
    }

    private var workspaceFilterHeader: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let allSelected = selectedProfileFilter.isEmpty
                Button {
                    Haptics.light()
                    selectedProfileFilter = ""
                } label: {
                    Text("全部对话 (\(client.sessions.count))")
                        .font(.system(size: 12, weight: allSelected ? .bold : .medium))
                        .foregroundStyle(allSelected ? .white : Color.dsPrimary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(allSelected ? Color.dsAccent : Color.white.opacity(0.68))
                        )
                }
                .buttonStyle(SingleTapRowButtonStyle())

                ForEach(client.workspaceProfiles) { wp in
                    let isSelected = (selectedProfileFilter == wp.id)
                    Button {
                        Haptics.light()
                        selectedProfileFilter = wp.id
                        Task { await client.selectWorkspaceProfile(wp.id) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: wp.icon.isEmpty ? "folder.fill" : wp.icon)
                                .font(.system(size: 11))
                            Text(wp.name)
                                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                        }
                        .foregroundStyle(isSelected ? .white : Color.dsPrimary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(isSelected ? Color.dsAccent : Color.white.opacity(0.68))
                        )
                    }
                    .buttonStyle(SingleTapRowButtonStyle())
                }

                Button {
                    Haptics.light()
                    showWorkspaceProfilesManager = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11))
                        Text("管理工作区")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Color.dsAccent)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .cleanWhiteCard(cornerRadius: 999)
                }
                .buttonStyle(SingleTapRowButtonStyle())
            }
        }
    }

    private func sessionRow(_ s: SessionSummaryItem) -> some View {
        let isCurrent = (s.sessionId == client.activeSessionId)
        return HStack(spacing: 10) {
            Button {
                Haptics.light()
                Task {
                    await client.selectSession(s.sessionId)
                    dismiss()
                }
            } label: {
                HStack(spacing: 12) {
                    Image("DSHLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title)
                            .font(.system(size: 15, weight: isCurrent ? .semibold : .medium))
                            .foregroundStyle(Color.dsPrimary)
                            .lineLimit(1)
                        Text("\(workspaceName(for: s.workspaceProfileId)) · \(s.model) · \(s.status)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.dsAccent)
                    }
                }
            }
            .buttonStyle(SingleTapRowButtonStyle())

            Menu {
                sessionMenuActions(s)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .cleanWhiteCard(cornerRadius: 16)
        .contextMenu {
            sessionMenuActions(s)
        }
    }

    @ViewBuilder
    private func sessionMenuActions(_ s: SessionSummaryItem) -> some View {
        Button {
            renamingSession = s
            renameDraftTitle = s.title
            showRenameAlert = true
        } label: {
            Label("修改对话标题", systemImage: "pencil")
        }

        if !client.workspaceProfiles.isEmpty {
            Menu {
                ForEach(client.workspaceProfiles) { wp in
                    Button {
                        Task {
                            await client.moveSessionToWorkspaceProfile(
                                s.sessionId,
                                workspaceProfileId: wp.id
                            )
                        }
                    } label: {
                        HStack {
                            Label(wp.name, systemImage: wp.icon.isEmpty ? "folder.fill" : wp.icon)
                            if s.workspaceProfileId == wp.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("移动到工作区档案...", systemImage: "folder.badge.plus")
            }
        }

        Button(role: .destructive) {
            Task { await client.deleteSession(s.sessionId) }
        } label: {
            Label("删除该对话", systemImage: "trash")
        }
    }
}
