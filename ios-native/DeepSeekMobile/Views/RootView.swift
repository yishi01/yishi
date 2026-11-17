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

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            if !client.isAuthenticated {
                authGateView
            } else {
                mainAuthenticatedView
            }
        }
        .onAppear {
            urlInput = client.serverURL
            tokenInput = client.authToken
        }
    }

    private var authGateView: some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 64, height: 64)
                    .cleanWhiteCard(cornerRadius: 20)

                Image(systemName: "cube.transparent")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.dsAccent)
            }

            Text("DeepSeek Go")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color.dsPrimary)

            Text("连接电脑端本地工作区与 DeepSeek Agent")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                TextField("服务器地址 (如 http://dsh-pc)", text: $urlInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(13)
                    .cleanWhiteCard(cornerRadius: 14)

                SecureField("粘贴电脑端 Auth Token", text: $tokenInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(13)
                    .cleanWhiteCard(cornerRadius: 14)

                Button {
                    Task {
                        await client.verifyAndLogin(url: urlInput, token: tokenInput)
                    }
                } label: {
                    Text("连接工作区")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(Color.dsPrimary))
                }
            }
            .padding(.horizontal, 28)

            if let err = client.authError {
                Text(err)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
            }

            Spacer()
        }
    }

    private var mainAuthenticatedView: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch activeTab {
                case .chat:
                    ChatView(showSessionDrawer: $showSessionDrawer)
                case .files:
                    FilesView(activeTab: $activeTab)
                case .settings:
                    GitSettingsView(activeTab: $activeTab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 64)

            // Floating iOS Liquid Glass Tab Bar
            HStack(spacing: 6) {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    let isSelected = (activeTab == tab)
                    Button {
                        Haptics.light()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            activeTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                            Text(tab.rawValue)
                                .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                        }
                        .foregroundStyle(isSelected ? Color.dsPrimary : Color.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.white : Color.clear)
                                .shadow(color: Color.black.opacity(isSelected ? 0.06 : 0), radius: 6, x: 0, y: 2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(5)
            .liquidGlass(cornerRadius: 999)
            .padding(.bottom, 8)
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
            List {
                ForEach(client.sessions) { s in
                    Button {
                        Task {
                            await client.selectSession(s.sessionId)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.title)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.dsPrimary)
                                Text("\(s.model) · \(s.status)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if s.sessionId == client.activeSessionId {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.dsAccent)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
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
