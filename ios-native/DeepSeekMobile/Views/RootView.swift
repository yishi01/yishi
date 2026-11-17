import SwiftUI

enum MainTab: String, CaseIterable {
    case chat = "对话"
    case files = "文件"
    case settings = "变更·设置"

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .files: return "folder"
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

                    // One-Tap Route Presets (LAN Wi-Fi + Tailscale)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(BridgeClient.defaultPresetURLs, id: \.url) { preset in
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
                case .settings:
                    GitSettingsView(activeTab: $activeTab)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.34, dampingFraction: 0.84), value: activeTab)

            // Floating iOS Liquid Glass Tab Bar with Fluid Morphing Droplet Pill
            HStack(spacing: 4) {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    let isSelected = (activeTab == tab)
                    Button {
                        guard activeTab != tab else { return }
                        Haptics.light()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.80)) {
                            activeTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 14.5, weight: isSelected ? .semibold : .regular))
                                .scaleEffect(isSelected ? 1.05 : 1.0)
                            Text(tab.rawValue)
                                .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                        }
                        .foregroundStyle(isSelected ? Color.dsPrimary : Color.secondary)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 10)
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
        }
        .sheet(isPresented: $showSessionDrawer) {
            SessionDrawerSheet()
                .environmentObject(client)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

struct SessionDrawerSheet: View {
    @EnvironmentObject var client: BridgeClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackdropView()

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(client.sessions) { s in
                            let isCurrent = (s.sessionId == client.activeSessionId)
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
                                        Text("\(s.model) · \(s.status)")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if isCurrent {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(Color.dsAccent)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .cleanWhiteCard(cornerRadius: 16)
                            }
                            .glassPressable(scale: 0.98)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("对话历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
