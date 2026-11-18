import SwiftUI
import UIKit

// MARK: - 1. Image Attachment Cache, Grid & Full-Screen Lightbox

@MainActor
final class AttachmentImageCache: ObservableObject {
    static let shared = AttachmentImageCache()

    private var cache: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {}

    func cachedImage(for key: String) -> UIImage? {
        cache[key]
    }

    func store(_ image: UIImage, for key: String) {
        if cache.count > 120 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = image
    }

    func loadImage(urlString: String, token: String) async -> UIImage? {
        let cleanURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return nil }
        if let existing = cache[cleanURL] {
            return existing
        }
        if let running = inFlight[cleanURL] {
            return await running.value
        }

        let task = Task<UIImage?, Never> {
            guard let url = URL(string: cleanURL) else { return nil }
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedToken.isEmpty {
                req.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    return nil
                }
                guard let uiImage = UIImage(data: data) else { return nil }
                return uiImage
            } catch {
                return nil
            }
        }

        inFlight[cleanURL] = task
        let result = await task.value
        inFlight.removeValue(forKey: cleanURL)
        if let img = result {
            store(img, for: cleanURL)
        }
        return result
    }

    nonisolated static func buildAuthenticatedURL(
        baseURL: String,
        pathOrURL: String,
        token: String
    ) -> String {
        let raw = pathOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }

        let full: String
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
            full = raw
        } else {
            var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasSuffix("/") { base.removeLast() }
            let rel = raw.hasPrefix("/") ? raw : "/" + raw
            full = base + rel
        }

        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty, !full.contains("token=") else {
            return full
        }
        let encoded = cleanToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cleanToken
        let sep = full.contains("?") ? "&" : "?"
        return "\(full)\(sep)token=\(encoded)"
    }
}

struct RemoteAttachmentImageView: View {
    @EnvironmentObject var client: BridgeClient
    let attachment: ChatAttachmentItem
    var useThumbnail: Bool = true
    var baseURL: String? = nil
    var authToken: String? = nil
    var contentMode: ContentMode = .fill

    @State private var loadedImage: UIImage?
    @State private var loadFailed: Bool = false

    private var resolvedBaseURL: String {
        if let baseURL, !baseURL.isEmpty { return baseURL }
        return client.normalizedBaseURL
    }

    private var resolvedToken: String {
        if let authToken, !authToken.isEmpty { return authToken }
        return client.authToken
    }

    private var targetURLString: String {
        let path = (useThumbnail && !attachment.thumbURL.isEmpty) ? attachment.thumbURL : attachment.url
        return AttachmentImageCache.buildAuthenticatedURL(
            baseURL: resolvedBaseURL,
            pathOrURL: path,
            token: resolvedToken
        )
    }

    var body: some View {
        ZStack {
            if let img = loadedImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if loadFailed {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(attachment.filename)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.35))
            } else {
                ZStack {
                    Color.white.opacity(0.32)
                    ProgressView()
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: targetURLString) {
            loadFailed = false
            if let cached = AttachmentImageCache.shared.cachedImage(for: targetURLString) {
                loadedImage = cached
                return
            }
            if let fetched = await AttachmentImageCache.shared.loadImage(
                urlString: targetURLString,
                token: resolvedToken
            ) {
                loadedImage = fetched
            } else {
                loadFailed = true
            }
        }
    }
}

struct TurnAttachmentsGridView: View {
    @EnvironmentObject var client: BridgeClient
    let attachments: [ChatAttachmentItem]
    var baseURL: String? = nil
    var authToken: String? = nil

    @State private var selectedIndex: Int?

    private var showLightboxBinding: Binding<Bool> {
        Binding(
            get: { selectedIndex != nil },
            set: { if !$0 { selectedIndex = nil } }
        )
    }

    private func sourceLabel(for source: String) -> (icon: String, text: String)? {
        switch source {
        case "pc_screenshot":
            return ("display", "电脑截图")
        case "browser":
            return ("globe", "浏览器画面")
        default:
            return nil
        }
    }

    var body: some View {
        if !attachments.isEmpty {
            Group {
                if attachments.count == 1, let first = attachments.first {
                    singleAttachmentCard(first)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(attachments.enumerated()), id: \.element.id) { idx, item in
                                thumbnailCell(item, index: idx)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .fullScreenCover(isPresented: showLightboxBinding) {
                ImageLightboxSheet(
                    attachments: attachments,
                    initialIndex: selectedIndex ?? 0,
                    baseURL: baseURL ?? client.normalizedBaseURL,
                    authToken: authToken ?? client.authToken
                )
                .environmentObject(client)
            }
        }
    }

    private func singleAttachmentCard(_ item: ChatAttachmentItem) -> some View {
        Button {
            Haptics.light()
            selectedIndex = 0
        } label: {
            ZStack(alignment: .bottomLeading) {
                RemoteAttachmentImageView(
                    attachment: item,
                    useThumbnail: true,
                    baseURL: baseURL,
                    authToken: authToken,
                    contentMode: .fill
                )
                .frame(width: 220, height: 156)
                .clipped()

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.62)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(height: 54)

                HStack(spacing: 6) {
                    if let badge = sourceLabel(for: item.source) {
                        Label(badge.text, systemImage: badge.icon)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(Color.dsAccent.opacity(0.85)))
                    }
                    if item.width > 0 && item.height > 0 {
                        Text("\(item.width)×\(item.height)")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .frame(width: 220, height: 156)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.75), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(SingleTapRowButtonStyle())
    }

    private func thumbnailCell(_ item: ChatAttachmentItem, index: Int) -> some View {
        Button {
            Haptics.light()
            selectedIndex = index
        } label: {
            ZStack(alignment: .bottomLeading) {
                RemoteAttachmentImageView(
                    attachment: item,
                    useThumbnail: true,
                    baseURL: baseURL,
                    authToken: authToken,
                    contentMode: .fill
                )
                .frame(width: 124, height: 124)
                .clipped()

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.58)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(height: 40)

                HStack(spacing: 4) {
                    if let badge = sourceLabel(for: item.source) {
                        Image(systemName: badge.icon)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    if item.width > 0 && item.height > 0 {
                        Text("\(item.width)×\(item.height)")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    Spacer()
                }
                .padding(.horizontal, 7)
                .padding(.bottom, 6)
            }
            .frame(width: 124, height: 124)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.75), lineWidth: 1)
            )
        }
        .buttonStyle(SingleTapRowButtonStyle())
    }
}

private struct LightboxSharePayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct LightboxActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ImageLightboxSheet: View {
    @EnvironmentObject var client: BridgeClient
    @Environment(\.dismiss) private var dismiss

    let attachments: [ChatAttachmentItem]
    let initialIndex: Int
    var baseURL: String? = nil
    var authToken: String? = nil

    @State private var currentIndex: Int = 0
    @State private var loadedFullImages: [String: UIImage] = [:]
    @State private var savedToastText: String?
    @State private var sharePayload: LightboxSharePayload?

    private var currentAttachment: ChatAttachmentItem? {
        guard attachments.indices.contains(currentIndex) else { return attachments.first }
        return attachments[currentIndex]
    }

    private var resolvedBaseURL: String {
        if let baseURL, !baseURL.isEmpty { return baseURL }
        return client.normalizedBaseURL
    }

    private var resolvedToken: String {
        if let authToken, !authToken.isEmpty { return authToken }
        return client.authToken
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
                .ignoresSafeArea()

            if !attachments.isEmpty {
                TabView(selection: $currentIndex) {
                    ForEach(Array(attachments.enumerated()), id: \.element.id) { idx, item in
                        LightboxZoomablePage(
                            attachment: item,
                            baseURL: resolvedBaseURL,
                            authToken: resolvedToken,
                            onImageLoaded: { img in
                                loadedFullImages[item.attId] = img
                            }
                        )
                        .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: attachments.count > 1 ? .automatic : .never))
                .ignoresSafeArea()
            }

            VStack {
                topOverlayBar
                Spacer()
                if let toast = savedToastText {
                    Text(toast)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.green.opacity(0.88)))
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .scale))
                }
                bottomOverlayBar
            }
        }
        .onAppear {
            currentIndex = min(max(0, initialIndex), max(0, attachments.count - 1))
        }
        .sheet(item: $sharePayload) { payload in
            LightboxActivityShareSheet(items: [payload.image])
        }
    }

    private var topOverlayBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let item = currentAttachment {
                    Text(item.filename)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text("\(currentIndex + 1) / \(max(1, attachments.count))")
                        if item.width > 0 && item.height > 0 {
                            Text("\(item.width)×\(item.height)")
                        }
                        if item.size > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                        }
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                }
            }

            Spacer()

            Button {
                Haptics.light()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.88))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.45))
    }

    private var bottomOverlayBar: some View {
        HStack(spacing: 16) {
            Button {
                guard let item = currentAttachment else { return }
                Task {
                    guard let img = await ensureFullImage(for: item) else { return }
                    Haptics.success()
                    UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                    withAnimation {
                        savedToastText = "已保存到系统相册"
                    }
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    withAnimation {
                        savedToastText = nil
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                    Text("保存相册")
                }
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.white.opacity(0.18)))
            }

            Button {
                guard let item = currentAttachment else { return }
                Task {
                    guard let img = await ensureFullImage(for: item) else { return }
                    Haptics.light()
                    sharePayload = LightboxSharePayload(image: img)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("分享原图")
                }
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.dsAccent))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func ensureFullImage(for item: ChatAttachmentItem) async -> UIImage? {
        if let existing = loadedFullImages[item.attId] {
            return existing
        }
        let fullURL = AttachmentImageCache.buildAuthenticatedURL(
            baseURL: resolvedBaseURL,
            pathOrURL: item.url,
            token: resolvedToken
        )
        if let img = await AttachmentImageCache.shared.loadImage(urlString: fullURL, token: resolvedToken) {
            loadedFullImages[item.attId] = img
            return img
        }
        return nil
    }
}

private struct LightboxZoomablePage: View {
    let attachment: ChatAttachmentItem
    let baseURL: String
    let authToken: String
    let onImageLoaded: (UIImage) -> Void

    @State private var fullImage: UIImage?
    @State private var isLoading: Bool = true
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private var fullURLString: String {
        AttachmentImageCache.buildAuthenticatedURL(
            baseURL: baseURL,
            pathOrURL: attachment.url,
            token: authToken
        )
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let img = fullImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { val in
                                    let next = lastScale * val
                                    scale = min(max(1.0, next), 5.0)
                                }
                                .onEnded { _ in
                                    if scale <= 1.05 {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                            scale = 1.0
                                            lastScale = 1.0
                                            offset = .zero
                                            lastOffset = .zero
                                        }
                                    } else {
                                        lastScale = scale
                                    }
                                }
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: scale > 1.05 ? 4 : 1000)
                                .onChanged { value in
                                    guard scale > 1.05 else { return }
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    lastOffset = offset
                                }
                        )
                        .onTapGesture(count: 2) {
                            Haptics.light()
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                                if scale > 1.1 {
                                    scale = 1.0
                                    lastScale = 1.0
                                    offset = .zero
                                    lastOffset = .zero
                                } else {
                                    scale = 2.5
                                    lastScale = 2.5
                                }
                            }
                        }
                } else if isLoading {
                    ProgressView("加载高清原图中...")
                        .tint(.white)
                        .foregroundStyle(.white)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                        Text("无法加载图片")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: fullURLString) {
            isLoading = true
            if let img = await AttachmentImageCache.shared.loadImage(urlString: fullURLString, token: authToken) {
                fullImage = img
                onImageLoaded(img)
            }
            isLoading = false
        }
    }
}

// MARK: - 2. Inline Collaborative Browser Window (BrowserInlineCardView)

struct BrowserInlineCardView: View {
    let state: BrowserSessionState
    var onNavigate: (String) -> Void = { _ in }
    var onBack: () -> Void = {}
    var onForward: () -> Void = {}
    var onReload: () -> Void = {}
    var onScreenshot: () -> Void = {}
    var onToggleControl: (String) -> Void = { _ in }
    var onTapCoordinate: (Int, Int) -> Void = { _, _ in }
    var onClickElement: (Int) -> Void = { _ in }
    var onTypeText: (Int, String, Bool) -> Void = { _, _, _ in }
    var onScroll: (Int) -> Void = { _ in }

    @State private var isExpanded: Bool = false
    @State private var urlDraft: String = ""
    @State private var activeInputElement: BrowserElementItem?
    @State private var elementTextDraft: String = ""
    @State private var lastTapMarker: CGPoint?

    private var viewportHeight: CGFloat {
        isExpanded ? 430 : 230
    }

    private var decodedFrameImage: UIImage? {
        let raw = state.frameB64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let clean: String
        if let commaRange = raw.range(of: ";base64,") {
            clean = String(raw[commaRange.upperBound...])
        } else {
            clean = raw
        }
        guard let data = Data(base64Encoded: clean, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return UIImage(data: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar
            navigationToolbar
            viewportCanvas
            if let inputEl = activeInputElement {
                elementInputBar(for: inputEl)
            }
            if !state.elements.isEmpty {
                interactiveElementsStrip
            }
        }
        .padding(12)
        .liquidGlass(cornerRadius: 20, prominent: true)
        .onAppear {
            urlDraft = state.url
        }
        .onChange(of: state.url) { newURL in
            if !newURL.isEmpty {
                urlDraft = newURL
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            statusPill

            Spacer(minLength: 4)

            Button {
                Haptics.medium()
                let nextOwner = state.controlOwner == "human" ? "agent" : "human"
                onToggleControl(nextOwner)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: state.controlOwner == "human" ? "cpu" : "hand.raised.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(state.controlOwner == "human" ? "交还 AI" : "真人接管")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5.5)
                .background(
                    Capsule().fill(state.controlOwner == "human" ? Color.dsAccent : Color.orange)
                )
            }
            .glassPressable(scale: 0.95)

            Button {
                Haptics.light()
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text(isExpanded ? "收起" : "展开")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Color.dsPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5.5)
                .cleanWhiteCard(cornerRadius: 999)
            }
            .glassPressable(scale: 0.95)
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if state.humanRequired {
            let reason = state.humanReason.isEmpty ? "需验证或登录" : state.humanReason
            Text("⚠️ 需真人操作: \(reason)")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.red.opacity(0.88)))
        } else if state.controlOwner == "human" {
            Text("🖐️ 真人操控中")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.orange))
        } else {
            Text("🤖 AI 浏览中")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(Color.dsAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.dsAccent.opacity(0.14)))
        }
    }

    private var navigationToolbar: some View {
        HStack(spacing: 6) {
            Button {
                Haptics.light()
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
                    .frame(width: 28, height: 28)
                    .cleanWhiteCard(cornerRadius: 8)
            }

            Button {
                Haptics.light()
                onForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
                    .frame(width: 28, height: 28)
                    .cleanWhiteCard(cornerRadius: 8)
            }

            Button {
                Haptics.light()
                onReload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
                    .frame(width: 28, height: 28)
                    .cleanWhiteCard(cornerRadius: 8)
            }

            TextField("输入网址...", text: $urlDraft)
                .font(.system(size: 12, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit {
                    let target = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !target.isEmpty {
                        onNavigate(target)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5.5)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.72))
                )

            Button {
                Haptics.light()
                let target = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.isEmpty {
                    onNavigate(target)
                }
            } label: {
                Text("前往")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.dsPrimary))
            }

            Button {
                Haptics.medium()
                onScreenshot()
            } label: {
                Text("📸 截图")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .cleanWhiteCard(cornerRadius: 999)
            }
        }
    }

    private var viewportCanvas: some View {
        GeometryReader { geo in
            let containerSize = geo.size
            let aspect: CGFloat = 960.0 / 640.0
            let fitWidth = min(containerSize.width, containerSize.height * aspect)
            let fitHeight = fitWidth / aspect
            let originX = (containerSize.width - fitWidth) / 2.0
            let originY = (containerSize.height - fitHeight) / 2.0

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.12, blue: 0.16))

                if let uiImage = decodedFrameImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .frame(width: fitWidth, height: fitHeight)
                        .position(x: containerSize.width / 2.0, y: containerSize.height / 2.0)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    let loc = value.location
                                    let localX = loc.x - originX
                                    let localY = loc.y - originY
                                    guard fitWidth > 1, fitHeight > 1 else { return }
                                    let clampedX = min(max(0, localX), fitWidth)
                                    let clampedY = min(max(0, localY), fitHeight)
                                    let vx = Int((clampedX / fitWidth) * 960.0)
                                    let vy = Int((clampedY / fitHeight) * 640.0)
                                    Haptics.light()
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        lastTapMarker = CGPoint(x: originX + clampedX, y: originY + clampedY)
                                    }
                                    onTapCoordinate(vx, vy)
                                }
                        )
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "globe")
                                .foregroundStyle(Color.dsAccent)
                            Text(state.title.isEmpty ? (state.url.isEmpty ? "就绪" : state.url) : state.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        if !state.textMarkdown.isEmpty {
                            ScrollView {
                                Text(state.textMarkdown.prefix(900))
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            Spacer()
                            HStack {
                                Spacer()
                                Text("点击上方「前往」或操作按钮实时渲染页面画面")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.65))
                                Spacer()
                            }
                            Spacer()
                        }
                    }
                    .padding(12)
                }

                if let marker = lastTapMarker {
                    Circle()
                        .strokeBorder(Color.orange, lineWidth: 2.5)
                        .background(Circle().fill(Color.orange.opacity(0.28)))
                        .frame(width: 26, height: 26)
                        .position(marker)
                        .allowsHitTesting(false)
                }

                // Floating Scroll Up / Down controls on the right edge
                VStack(spacing: 8) {
                    Button {
                        Haptics.light()
                        onScroll(-320)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.black.opacity(0.58)))
                    }

                    Button {
                        Haptics.light()
                        onScroll(320)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.black.opacity(0.58)))
                    }
                }
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(height: viewportHeight)
    }

    private func isTextInputElement(_ el: BrowserElementItem) -> Bool {
        let tag = el.tag.lowercased()
        let typ = el.type.lowercased()
        if tag == "textarea" { return true }
        if tag == "input" {
            let nonText = ["submit", "button", "checkbox", "radio", "file", "image", "reset", "hidden"]
            return !nonText.contains(typ)
        }
        return false
    }

    private var interactiveElementsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.elements.prefix(12)) { el in
                    let isInput = isTextInputElement(el)
                    let label = el.text.isEmpty ? (el.value.isEmpty ? el.tag : el.value) : el.text
                    Button {
                        Haptics.light()
                        if isInput {
                            activeInputElement = el
                            elementTextDraft = el.value
                        } else {
                            onClickElement(el.id)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isInput ? "character.cursor.ibeam" : "hand.point.up.left.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(isInput ? Color.orange : Color.dsAccent)
                            Text("[\(el.id)] \(label)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.dsPrimary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(Color.white.opacity(0.75))
                        )
                    }
                    .buttonStyle(SingleTapRowButtonStyle())
                }
            }
        }
    }

    private func elementInputBar(for element: BrowserElementItem) -> some View {
        HStack(spacing: 8) {
            Text("输入 [\(element.id)]")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.dsAccent)

            TextField(element.text.isEmpty ? "输入文本内容..." : element.text, text: $elementTextDraft)
                .font(.system(size: 12.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.85))
                )
                .onSubmit {
                    onTypeText(element.id, elementTextDraft, true)
                    activeInputElement = nil
                }

            Button {
                Haptics.medium()
                onTypeText(element.id, elementTextDraft, true)
                activeInputElement = nil
            } label: {
                Text("填入并提交")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(Capsule().fill(Color.dsAccent))
            }

            Button {
                activeInputElement = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .cleanWhiteCard(cornerRadius: 12)
    }
}

// MARK: - 3. Agent Team Collaboration Card (AgentTeamCardView)

struct AgentTeamCardView: View {
    let agents: [TeamSubagentItem]
    var onCancelAgent: (String) -> Void = { _ in }

    @State private var expandedAgentIds: Set<String> = []

    private var runningCount: Int {
        agents.filter { $0.status == "running" }.count
    }

    private var totalCost: Double {
        agents.reduce(0.0) { $0 + $1.cost }
    }

    private func roleIcon(for role: String) -> String {
        let lower = role.lowercased()
        if lower.contains("research") || lower.contains("调研") || lower.contains("分析") {
            return "magnifyingglass.circle.fill"
        }
        if lower.contains("test") || lower.contains("测试") || lower.contains("qa") || lower.contains("验证") {
            return "checkmark.shield.fill"
        }
        if lower.contains("code") || lower.contains("dev") || lower.contains("研发") || lower.contains("实现") {
            return "hammer.circle.fill"
        }
        return "person.crop.circle.badge.checkmark"
    }

    var body: some View {
        if !agents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("👥 智能体协作团队 (\(agents.count) 名子 Agent)")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Color.dsPrimary)

                    Spacer()

                    if runningCount > 0 {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("\(runningCount) 运行中")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.dsAccent)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.dsAccent.opacity(0.14)))
                    }

                    Text("¥\(String(format: "%.4f", totalCost))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.white.opacity(0.65)))
                }

                VStack(spacing: 8) {
                    ForEach(agents) { agent in
                        subagentRow(agent)
                    }
                }
            }
            .padding(13)
            .liquidGlass(cornerRadius: 20, prominent: true)
        }
    }

    private func subagentRow(_ agent: TeamSubagentItem) -> some View {
        let isExpanded = expandedAgentIds.contains(agent.agentId)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Haptics.light()
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                        if isExpanded {
                            expandedAgentIds.remove(agent.agentId)
                        } else {
                            expandedAgentIds.insert(agent.agentId)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: roleIcon(for: agent.role))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.dsAccent)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(agent.role)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.dsPrimary)
                                    .lineLimit(1)

                                statusBadge(for: agent.status)
                            }

                            HStack(spacing: 6) {
                                Text("\(agent.model) · \(agent.roundsUsed)轮")
                                Text("·")
                                Text("¥\(String(format: "%.4f", agent.cost))")
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(SingleTapRowButtonStyle())

                if agent.status == "running" {
                    Button {
                        Haptics.warning()
                        onCancelAgent(agent.agentId)
                    } label: {
                        Text("取消")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.red.opacity(0.12)))
                    }
                    .buttonStyle(SingleTapRowButtonStyle())
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !agent.task.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("任务目标")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(agent.task)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.dsPrimary)
                        }
                    }
                    if !agent.resultSummary.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("结论摘要")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(agent.resultSummary)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.dsPrimary)
                        }
                    }
                    if !agent.transcriptPreview.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("执行轨迹预览")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(agent.transcriptPreview)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(8)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.55))
                )
            }
        }
        .padding(10)
        .cleanWhiteCard(cornerRadius: 14)
    }

    @ViewBuilder
    private func statusBadge(for status: String) -> some View {
        switch status {
        case "running":
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("运行中")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.dsAccent)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.dsAccent.opacity(0.14)))
        case "done":
            Text("已完成")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.green.opacity(0.14)))
        case "failed":
            Text("失败")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.red.opacity(0.14)))
        default:
            Text("已取消")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.gray.opacity(0.16)))
        }
    }
}

// MARK: - 4. Per-Turn Token & Cost Footer (TurnUsageBadgeView)

struct TurnUsageBadgeView: View {
    let usage: TurnUsageInfo?
    var modelSwitchedNote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let note = modelSwitchedNote, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 5) {
                    Text("🔄 \(note)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.orange)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(
                    Capsule().fill(Color.orange.opacity(0.13))
                )
            }

            if let u = usage {
                HStack(spacing: 5) {
                    Text(
                        "⚡ 输入 \(u.promptTokens) (命中 \(u.cacheHitTokens)) → 输出 \(u.completionTokens) tokens · ¥\(String(format: "%.4f", u.cost))"
                    )
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                    if u.estimated {
                        Text("估算")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .cleanWhiteCard(cornerRadius: 999)
            }
        }
    }
}

// MARK: - 5. Workspace Profiles Manager Sheet (WorkspaceProfilesSheet)

struct WorkspaceProfilesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let profiles: [WorkspaceProfileItem]
    let activeProfileId: String
    var authorizedPaths: [String] = []
    var onSelectProfile: (WorkspaceProfileItem) -> Void = { _ in }
    var onCreateProfile: (WorkspaceProfileItem) -> Void = { _ in }
    var onUpdateProfile: (WorkspaceProfileItem) -> Void = { _ in }
    var onDeleteProfile: (String) -> Void = { _ in }

    @State private var editingProfile: WorkspaceProfileItem?
    @State private var isCreatingNew: Bool = false

    private let colorOptions: [(id: String, label: String, color: Color)] = [
        ("blue", "晴空蓝", Color(red: 0.24, green: 0.42, blue: 0.98)),
        ("indigo", "深海靛", Color(red: 0.34, green: 0.32, blue: 0.94)),
        ("teal", "冰川青", Color(red: 0.06, green: 0.62, blue: 0.78)),
        ("emerald", "翡翠绿", Color(red: 0.12, green: 0.68, blue: 0.48)),
        ("violet", "星云紫", Color(red: 0.56, green: 0.30, blue: 0.96)),
        ("rose", "绯樱粉", Color(red: 0.90, green: 0.28, blue: 0.46)),
    ]

    private func badgeColor(for colorName: String) -> Color {
        colorOptions.first(where: { $0.id == colorName })?.color ?? Color.dsAccent
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackdropView()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("多工作区记忆档案")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(Color.dsPrimary)
                                Text("为不同项目隔离或共享跨对话上下文与根目录权限")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                Haptics.light()
                                isCreatingNew = true
                                editingProfile = WorkspaceProfileItem(
                                    id: "",
                                    name: "新工作区档案",
                                    icon: "folder.badge.gearshape",
                                    color: "blue",
                                    rootPaths: authorizedPaths.isEmpty ? [] : [authorizedPaths[0]],
                                    defaultProfileId: "deepseek-flash",
                                    defaultApprovalMode: "ask_commands",
                                    sharedNotes: "",
                                    crossSessionRead: true,
                                    sessionCount: 0
                                )
                            } label: {
                                Label("新建工作区", systemImage: "plus")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Capsule().fill(Color.dsAccent))
                            }
                            .glassPressable(scale: 0.95)
                        }

                        ForEach(profiles) { profile in
                            profileCard(profile)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("工作区管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editingProfile) { draft in
                WorkspaceProfileEditorSheet(
                    initialProfile: draft,
                    isNew: isCreatingNew,
                    authorizedPaths: authorizedPaths,
                    onSave: { updated in
                        if isCreatingNew {
                            onCreateProfile(updated)
                        } else {
                            onUpdateProfile(updated)
                        }
                        editingProfile = nil
                    }
                )
            }
        }
    }

    private func profileCard(_ profile: WorkspaceProfileItem) -> some View {
        let isActive = profile.id == activeProfileId
        let tint = badgeColor(for: profile.color)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.16))
                        .frame(width: 42, height: 42)
                    Image(systemName: profile.icon.isEmpty ? "folder.fill" : profile.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.dsPrimary)

                        if isActive {
                            Text("当前使用")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(tint))
                        }

                        if profile.crossSessionRead {
                            Text("跨对话读取已开启")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.dsAccent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.dsAccent.opacity(0.13)))
                        }
                    }

                    Text("\(profile.sessionCount) 个对话 · 审批策略: \(profile.defaultApprovalMode)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Haptics.light()
                    isCreatingNew = false
                    editingProfile = profile
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.dsPrimary)
                        .frame(width: 32, height: 32)
                        .cleanWhiteCard(cornerRadius: 999)
                }
            }

            if !profile.rootPaths.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(profile.rootPaths.prefix(3), id: \.self) { p in
                        HStack(spacing: 5) {
                            Image(systemName: "folder")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            Text(p)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            if !profile.sharedNotes.isEmpty {
                Text(profile.sharedNotes)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dsPrimary.opacity(0.85))
                    .lineLimit(2)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.55))
                    )
            }

            HStack(spacing: 10) {
                Button {
                    Haptics.medium()
                    onSelectProfile(profile)
                } label: {
                    Text(isActive ? "已激活该工作区" : "切换到此工作区")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(isActive ? tint : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8.5)
                        .background(
                            Capsule().fill(isActive ? tint.opacity(0.14) : Color.dsPrimary)
                        )
                }
                .glassPressable(scale: 0.96)

                if profile.id != "ws_default" {
                    Button {
                        Haptics.warning()
                        onDeleteProfile(profile.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(width: 36, height: 34)
                            .background(Capsule().fill(Color.red.opacity(0.12)))
                    }
                }
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 20, prominent: isActive)
    }
}

private struct WorkspaceProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialProfile: WorkspaceProfileItem
    let isNew: Bool
    let authorizedPaths: [String]
    let onSave: (WorkspaceProfileItem) -> Void

    @State private var name: String = ""
    @State private var icon: String = "folder.fill"
    @State private var color: String = "blue"
    @State private var rootPaths: [String] = []
    @State private var customPathInput: String = ""
    @State private var sharedNotes: String = ""
    @State private var crossSessionRead: Bool = true
    @State private var defaultApprovalMode: String = "ask_commands"

    private let icons = [
        "folder.fill", "terminal.fill", "cpu.fill", "globe.americas.fill",
        "paintbrush.fill", "shippingbox.fill", "doc.text.fill", "sparkles"
    ]
    private let colors = ["blue", "indigo", "teal", "emerald", "violet", "rose"]
    private let approvalModes = [
        ("auto", "全自动执行"),
        ("ask_commands", "危险命令询问"),
        ("strict", "严格逐项审批"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("工作区名称", text: $name)

                    Picker("图标", selection: $icon) {
                        ForEach(icons, id: \.self) { ic in
                            Label(ic, systemImage: ic).tag(ic)
                        }
                    }

                    Picker("主题色", selection: $color) {
                        ForEach(colors, id: \.self) { c in
                            Text(c).tag(c)
                        }
                    }
                }

                Section("跨对话记忆与安全策略") {
                    Toggle("允许跨对话检索历史记录", isOn: $crossSessionRead)

                    Picker("默认审批模式", selection: $defaultApprovalMode) {
                        ForEach(approvalModes, id: \.0) { mode in
                            Text(mode.1).tag(mode.0)
                        }
                    }
                }

                Section("工作区共享提示词 / 备注 (Shared Notes)") {
                    TextEditor(text: $sharedNotes)
                        .frame(minHeight: 80)
                }

                Section("绑定电脑目录 (Root Paths)") {
                    ForEach(rootPaths, id: \.self) { path in
                        HStack {
                            Text(path)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Button(role: .destructive) {
                                rootPaths.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                        }
                    }

                    if !authorizedPaths.isEmpty {
                        Menu("从已授权目录添加...") {
                            ForEach(authorizedPaths, id: \.self) { p in
                                Button(p) {
                                    if !rootPaths.contains(p) {
                                        rootPaths.append(p)
                                    }
                                }
                            }
                        }
                    }

                    HStack {
                        TextField("手动输入电脑目录路径...", text: $customPathInput)
                            .font(.system(size: 12, design: .monospaced))
                        Button("添加") {
                            let trimmed = customPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty && !rootPaths.contains(trimmed) {
                                rootPaths.append(trimmed)
                                customPathInput = ""
                            }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "新建工作区档案" : "编辑工作区档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        var updated = initialProfile
                        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "未命名工作区"
                            : name.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.icon = icon
                        updated.color = color
                        updated.rootPaths = rootPaths
                        updated.sharedNotes = sharedNotes
                        updated.crossSessionRead = crossSessionRead
                        updated.defaultApprovalMode = defaultApprovalMode
                        onSave(updated)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                name = initialProfile.name
                icon = initialProfile.icon.isEmpty ? "folder.fill" : initialProfile.icon
                color = initialProfile.color.isEmpty ? "blue" : initialProfile.color
                rootPaths = initialProfile.rootPaths
                sharedNotes = initialProfile.sharedNotes
                crossSessionRead = initialProfile.crossSessionRead
                defaultApprovalMode = initialProfile.defaultApprovalMode
            }
        }
    }
}

// MARK: - 6. API Wallet Dashboard Card (WalletDashboardCardView)

struct WalletDashboardCardView: View {
    let wallet: WalletSummaryData
    var modelProfiles: [ModelProfileItem] = []
    var onRefresh: () -> Void = {}
    var onSaveRules: (WalletRulesItem) -> Void = { _ in }

    @State private var draftRules: WalletRulesItem = WalletRulesItem()
    @State private var manualBalanceText: String = ""
    @State private var showSavedBadge: Bool = false

    private var maxDayCost: Double {
        max(0.0001, wallet.last7Days.map(\.cost).max() ?? 0.01)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            balanceHeroCard
            todayMetricsRow
            if !wallet.last7Days.isEmpty {
                sevenDayTrendSection
            }
            if !wallet.byModel.isEmpty {
                modelBreakdownSection
            }
            autoDowngradeRulesSection
        }
        .onAppear {
            syncDraftFromWallet()
        }
        .onChange(of: wallet.rules) { _ in
            syncDraftFromWallet()
        }
    }

    private func syncDraftFromWallet() {
        draftRules = wallet.rules
        if let manual = wallet.rules.manualBalance {
            manualBalanceText = String(format: "%.2f", manual)
        } else {
            manualBalanceText = ""
        }
    }

    private var balanceHeroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("💰 DeepSeek API 余额与账单")
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundStyle(Color.dsPrimary)

                        if wallet.downgradeActive {
                            Text("⚠️ 自动降级中")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange))
                        }
                    }

                    Text("数据源: \(wallet.balanceSource)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Haptics.light()
                    onRefresh()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("刷新")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dsAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .cleanWhiteCard(cornerRadius: 999)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                if let total = wallet.totalBalance {
                    Text("¥\(String(format: "%.2f", total))")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(total <= wallet.rules.balanceBelow ? Color.orange : Color.dsPrimary)
                } else {
                    Text("估算/未配置")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("赠金: ¥\(String(format: "%.2f", wallet.grantedBalance))")
                    Text("充值: ¥\(String(format: "%.2f", wallet.toppedUpBalance))")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 20, prominent: true)
    }

    private var todayMetricsRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("今日消耗 (\(wallet.todayTurns) 轮)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("¥\(String(format: "%.4f", wallet.todayCost))")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.dsPrimary)
                Text("共 \(wallet.todayTotalTokens) tokens (命中 \(wallet.todayCacheHitTokens))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cleanWhiteCard(cornerRadius: 16)

            VStack(alignment: .leading, spacing: 4) {
                Text("当前小时速率")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("¥\(String(format: "%.4f", wallet.currentHourCost))")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.dsAccent)
                Text("\(wallet.currentHourTokens) tokens / hr")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cleanWhiteCard(cornerRadius: 16)
        }
    }

    private var sevenDayTrendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("📊 近 7 天消费趋势")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.dsPrimary)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(wallet.last7Days.suffix(7)) { day in
                    let ratio = min(1.0, max(0.08, day.cost / maxDayCost))
                    VStack(spacing: 4) {
                        Text("¥\(String(format: "%.2f", day.cost))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.dsAccent.opacity(0.82))
                            .frame(height: CGFloat(ratio * 58.0))

                        Text(String(day.date.suffix(5)))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 92)
        }
        .padding(13)
        .cleanWhiteCard(cornerRadius: 16)
    }

    private var modelBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🤖 模型 Token 与费用明细")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.dsPrimary)

            ForEach(wallet.byModel) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.model)
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.dsPrimary)
                        Text("\(item.turns) 轮 · 输入 \(item.promptTokens) / 输出 \(item.completionTokens)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("¥\(String(format: "%.4f", item.cost))")
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.dsPrimary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(13)
        .cleanWhiteCard(cornerRadius: 16)
    }

    private var autoDowngradeRulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("🛡️ 预算告警与自动降级规则")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.dsPrimary)
                Spacer()
                Toggle("", isOn: $draftRules.enabled)
                    .labelsHidden()
            }

            HStack {
                Text("余额低于阈值自动切换 (¥)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("5.0", value: $draftRules.balanceBelow, format: .number)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 12.5, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.75)))
            }

            HStack {
                Text("单日消费上限阈值 (¥)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("20.0", value: $draftRules.dailySpendAbove, format: .number)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 12.5, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.75)))
            }

            HStack {
                Text("手动校准余额 (可选 ¥)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("留空自动查询", text: $manualBalanceText)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.75)))
            }

            HStack {
                Text("降级备用模型")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("备用模型", selection: $draftRules.fallbackProfileId) {
                    if modelProfiles.isEmpty {
                        Text("deepseek-flash").tag("deepseek-flash")
                        Text("deepseek-chat").tag("deepseek-chat")
                    } else {
                        ForEach(modelProfiles) { mp in
                            Text(mp.name).tag(mp.id)
                        }
                    }
                }
                .pickerStyle(.menu)
            }

            Toggle("触发阈值时发送 Bark 推送提醒", isOn: $draftRules.notifyBark)
                .font(.system(size: 12))

            Button {
                Haptics.success()
                let trimmedManual = manualBalanceText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let val = Double(trimmedManual) {
                    draftRules.manualBalance = val
                } else {
                    draftRules.manualBalance = nil
                }
                onSaveRules(draftRules)
                showSavedBadge = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    showSavedBadge = false
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showSavedBadge ? "checkmark.circle.fill" : "tray.and.arrow.down.fill")
                    Text(showSavedBadge ? "策略已保存" : "保存预算与自动降级规则")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Capsule().fill(showSavedBadge ? Color.green : Color.dsPrimary))
            }
            .glassPressable(scale: 0.96)
        }
        .padding(13)
        .cleanWhiteCard(cornerRadius: 16)
    }
}
