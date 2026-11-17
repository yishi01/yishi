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
    @State private var urlInput: String = "http://dsh-pc"
    @State private var tokenInput: String = ""
    @Namespace private var tabGlassNamespace

    var body: some View {
        ZStack {
            // Ambient refractive light canvas for true iOS Liquid Glass
            LiquidGlassBackdropView()

            if !client.isAuthenticated {
                authGateView
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                mainAuthenticatedView
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: client.isAuthenticated)
        .onAppear {
            urlInput = client.serverURL
            tokenInput = client.authToken
        }
    }

    private var authGateView: some View {
        VStack(spacing: 20) {
            Spacer()

            // Official DSH Logo with Liquid Glass Frame
            Image("DSHLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 82, height: 82)
                .shadow(color: Color(red: 0.15, green: 0.28, blue: 0.58).opacity(0.16), radius: 18, x: 0, y: 8)

            VStack(spacing: 6) {
                Text("DeepSeek Go")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.dsPrimary)

                Text("连接电脑端 DSH 本地工作区与 DeepSeek Agent")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 13) {
                HStack(spacing: 10) {
                    Image(systemName: "network")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.dsAccent)
                        .frame(width: 22)
                    TextField("服务器地址 (如 http://dsh-pc)", text: $urlInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 15))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .cleanWhiteCard(cornerRadius: 16)

                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.dsAccent)
                        .frame(width: 22)
                    SecureField("粘贴电脑端 Auth Token", text: $tokenInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 15))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .cleanWhiteCard(cornerRadius: 16)

                Button {
                    Haptics.medium()
                    Task {
                        await client.verifyAndLogin(url: urlInput, token: tokenInput)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("连接工作区")
                            .font(.system(size: 16, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.12, green: 0.16, blue: 0.24),
                                        Color.dsPrimary,
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                            )
                            .shadow(color: Color.dsPrimary.opacity(0.22), radius: 12, x: 0, y: 6)
                    )
                }
                .glassPressable(scale: 0.97)
                .padding(.top, 4)
            }
            .padding(20)
            .liquidGlass(cornerRadius: 28, prominent: true)
            .padding(.horizontal, 22)

            if let err = client.authError {
                Text(err)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .cleanWhiteCard(cornerRadius: 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            Spacer()
        }
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
