import SwiftUI
import WebKit

// MARK: - 2. X / Twitter-Style Native WKWebView Browser & Compact Chat Link Card

struct NativeWKWebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .white
        attachWebView(to: host)
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if webView.superview !== uiView {
            attachWebView(to: uiView)
        }
    }

    private func attachWebView(to host: UIView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: host.topAnchor),
            webView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
    }
}

struct BrowserLinkCardView: View {
    let state: BrowserSessionState
    var onOpen: () -> Void

    private var domainLabel: String {
        if let u = URL(string: state.url), let host = u.host, !host.isEmpty {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return state.url == "about:blank" || state.url.isEmpty ? "新建网页标签" : state.url
    }

    var body: some View {
        Button {
            Haptics.light()
            onOpen()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            state.humanRequired
                                ? Color.red.opacity(0.14)
                                : (state.controlOwner == "human" ? Color.orange.opacity(0.14) : Color.dsAccent.opacity(0.14))
                        )
                        .frame(width: 42, height: 42)
                    Image(systemName: state.humanRequired ? "exclamationmark.shield.fill" : "safari.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(
                            state.humanRequired
                                ? .red
                                : (state.controlOwner == "human" ? .orange : Color.dsAccent)
                        )
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(state.title.isEmpty ? domainLabel : state.title)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(Color.dsPrimary)
                            .lineLimit(1)

                        Text(state.humanRequired ? "需验证" : (state.controlOwner == "human" ? "真人" : "AI"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(
                                state.humanRequired ? .red : (state.controlOwner == "human" ? .orange : Color.dsAccent)
                            )
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(
                                    (state.humanRequired ? Color.red : (state.controlOwner == "human" ? Color.orange : Color.dsAccent)).opacity(0.13)
                                )
                            )
                    }

                    Text(domainLabel)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                HStack(spacing: 3) {
                    Text(state.humanRequired ? "去处理" : "打开")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 6.5)
                .background(
                    Capsule().fill(state.humanRequired ? Color.red : Color.dsPrimary)
                )
            }
            .padding(12)
            .cleanWhiteCard(cornerRadius: 18)
        }
        .buttonStyle(SingleTapRowButtonStyle())
    }
}

/// Twitter / X style native iOS in-app browser sheet:
/// Full-bleed WKWebView above, floating `[X] [domain ⋮] [↻]` capsule bar, and bottom conversation peek drawer.
struct TwitterStyleBrowserOverlay: View {
    let state: BrowserSessionState
    @ObservedObject var tab: BrowserTabController
    let sessionTitle: String
    let lastSnippet: String
    var onClose: () -> Void
    var onNavigate: (String) -> Void
    var onBack: () -> Void
    var onForward: () -> Void
    var onReload: () -> Void
    var onScreenshot: () -> Void
    var onToggleControl: (String) -> Void
    var onCloseTab: () -> Void

    @State private var showURLPrompt: Bool = false
    @State private var urlInputDraft: String = ""
    @State private var dragOffsetY: CGFloat = 0

    private var activeURL: String {
        tab.currentURL.isEmpty ? state.url : tab.currentURL
    }

    private var domainText: String {
        if let u = URL(string: activeURL), let host = u.host, !host.isEmpty {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return activeURL == "about:blank" || activeURL.isEmpty ? "新建网页" : activeURL
    }

    private var bottomStatusCopy: String {
        if state.humanRequired {
            return "⚠️ \(state.humanReason.isEmpty ? "请完成人机验证或登录，完成后点右侧「交还 AI」" : state.humanReason)"
        }
        if state.controlOwner == "human" {
            return "🖐️ 你正在操作页面 · 完成后可交还 AI 继续"
        }
        if !lastSnippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return lastSnippet.replacingOccurrences(of: "\n", with: " ")
        }
        return "🤖 AI 正在协同浏览 · 可随时直接触摸接管"
    }

    var body: some View {
        GeometryReader { outerGeo in
            let bottomReserve = max(72, 68 + outerGeo.safeAreaInsets.bottom)
            ZStack(alignment: .bottom) {
                // Native WKWebView fills everything above the bottom peek sheet
                VStack(spacing: 0) {
                    if tab.isLoading {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.15))
                                Rectangle()
                                    .fill(Color.dsAccent)
                                    .frame(width: max(18, geo.size.width * CGFloat(tab.estimatedProgress)))
                                    .animation(.linear(duration: 0.15), value: tab.estimatedProgress)
                            }
                        }
                        .frame(height: 2.5)
                    }

                    NativeWKWebViewContainer(webView: tab.webView)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Color.white
                        .frame(height: bottomReserve)
                }
                .background(Color.white)
                .ignoresSafeArea(.container, edges: .bottom)

                // Floating Twitter/X Browser Control Row + Bottom Peek Drawer
                VStack(spacing: 12) {
                    floatingPillToolbar
                        .padding(.horizontal, 16)

                    bottomConversationPeekDrawer
                }
                .offset(y: max(0, dragOffsetY))
            }
        }
        .alert("打开网址", isPresented: $showURLPrompt) {
            TextField("https://", text: $urlInputDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("前往") {
                let trimmed = urlInputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    onNavigate(trimmed)
                }
            }
        }
    }

    private var floatingPillToolbar: some View {
        HStack(spacing: 12) {
            // Left Circular Close Button
            Button {
                Haptics.light()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
                    .frame(width: 44, height: 44)
                    .liquidGlass(cornerRadius: 999, prominent: true)
            }
            .glassPressable(scale: 0.92)

            // Center Domain Pill with Triple-Dot Menu
            HStack(spacing: 8) {
                Circle()
                    .fill(
                        state.humanRequired
                            ? Color.red
                            : (state.controlOwner == "human" ? Color.orange : Color.green)
                    )
                    .frame(width: 7, height: 7)

                Button {
                    urlInputDraft = activeURL == "about:blank" ? "https://" : activeURL
                    showURLPrompt = true
                } label: {
                    Text(domainText)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Color.dsPrimary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)

                Menu {
                    Button {
                        onBack()
                    } label: {
                        Label("后退", systemImage: "chevron.left")
                    }
                    .disabled(!tab.canGoBack)

                    Button {
                        onForward()
                    } label: {
                        Label("前进", systemImage: "chevron.right")
                    }
                    .disabled(!tab.canGoForward)

                    Button {
                        urlInputDraft = activeURL == "about:blank" ? "https://" : activeURL
                        showURLPrompt = true
                    } label: {
                        Label("输入网址前往...", systemImage: "globe")
                    }

                    Divider()

                    Button {
                        Haptics.medium()
                        onScreenshot()
                    } label: {
                        Label("📸 截图发给 AI", systemImage: "camera.viewfinder")
                    }

                    Button {
                        Haptics.medium()
                        onToggleControl(state.controlOwner == "human" ? "agent" : "human")
                    } label: {
                        Label(
                            state.controlOwner == "human" ? "🤖 交还 AI 操作" : "🖐️ 切换为真人操控",
                            systemImage: state.controlOwner == "human" ? "cpu" : "hand.raised"
                        )
                    }

                    Button {
                        UIPasteboard.general.string = activeURL
                    } label: {
                        Label("复制网址", systemImage: "doc.on.doc")
                    }

                    Divider()

                    Button(role: .destructive) {
                        onCloseTab()
                    } label: {
                        Label("关闭此网页标签", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.dsPrimary.opacity(0.75))
                        .frame(width: 26, height: 28)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .liquidGlass(cornerRadius: 999, prominent: true)

            // Right Circular Reload / Stop Button
            Button {
                Haptics.light()
                onReload()
            } label: {
                Image(systemName: tab.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
                    .frame(width: 44, height: 44)
                    .liquidGlass(cornerRadius: 999, prominent: true)
            }
            .glassPressable(scale: 0.92)
        }
    }

    private var bottomConversationPeekDrawer: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(Color.gray.opacity(0.32))
                .frame(width: 38, height: 4.5)
                .padding(.top, 9)

            HStack(spacing: 11) {
                Image("DSHLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(sessionTitle.isEmpty ? "DeepSeek Go" : sessionTitle)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(Color.dsPrimary)
                            .lineLimit(1)

                        Text(state.controlOwner == "human" ? "真人接管中" : "AI 协同中")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    Text(bottomStatusCopy)
                        .font(.system(size: 12))
                        .foregroundStyle(state.humanRequired ? .red : .secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if state.controlOwner == "human" {
                    Button {
                        Haptics.medium()
                        onToggleControl("agent")
                    } label: {
                        Text("交还 AI")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.dsPrimary))
                    }
                    .glassPressable(scale: 0.94)
                } else {
                    Button {
                        Haptics.light()
                        onClose()
                    } label: {
                        Text("回对话")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color.dsPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.gray.opacity(0.12)))
                    }
                    .glassPressable(scale: 0.94)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 24,
                style: .continuous
            )
            .fill(Color.white)
            .shadow(color: Color.black.opacity(0.10), radius: 14, x: 0, y: -4)
            .ignoresSafeArea(.container, edges: .bottom)
        )
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { val in
                    if val.translation.height > 0 {
                        dragOffsetY = val.translation.height
                    }
                }
                .onEnded { val in
                    if val.translation.height > 55 {
                        onClose()
                    }
                    withAnimation(AppleMotion.snappy) {
                        dragOffsetY = 0
                    }
                }
        )
    }
}

