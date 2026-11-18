import SwiftUI
import UIKit

// MARK: - 1. Image Attachment Cache, Grid & Full-Screen Lightbox

@MainActor
final class AttachmentImageCache: ObservableObject {
    static let shared = AttachmentImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 80
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cache.removeAllObjects()
            }
        }
    }

    private func normalizedCacheKey(for urlString: String) -> String {
        guard let comps = URLComponents(string: urlString) else { return urlString }
        let keptQuery = (comps.queryItems ?? [])
            .filter { $0.name.lowercased() != "token" }
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value ?? "")" }
            .joined(separator: "&")
        return keptQuery.isEmpty ? comps.path : "\(comps.path)?\(keptQuery)"
    }

    func cachedImage(for urlString: String) -> UIImage? {
        let key = normalizedCacheKey(for: urlString) as NSString
        return cache.object(forKey: key)
    }

    func store(_ image: UIImage, for urlString: String) {
        let key = normalizedCacheKey(for: urlString) as NSString
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height }
            ?? Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: key, cost: max(1, cost))
    }

    func clearAll() {
        cache.removeAllObjects()
        for (_, t) in inFlight { t.cancel() }
        inFlight.removeAll()
    }

    func loadImage(urlString: String, token: String) async -> UIImage? {
        let cleanURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return nil }
        if let existing = cachedImage(for: cleanURL) {
            return existing
        }
        let cacheKey = normalizedCacheKey(for: cleanURL)
        if let running = inFlight[cacheKey] {
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

        inFlight[cacheKey] = task
        let result = await task.value
        inFlight.removeValue(forKey: cacheKey)
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
            loadedImage = nil
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
                    guard let img = await ensureFullImage(for: item) else {
                        withAnimation { savedToastText = "图片尚未加载完成" }
                        return
                    }
                    let err = await PhotoLibrarySaveHelper.save(img)
                    if let err = err {
                        Haptics.warning()
                        withAnimation {
                            savedToastText = "保存失败: \(err.localizedDescription)"
                        }
                    } else {
                        Haptics.success()
                        withAnimation {
                            savedToastText = "已保存到系统相册"
                        }
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
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

private final class PhotoLibrarySaveHelper: NSObject {
    private var continuation: CheckedContinuation<Error?, Never>?
    private var retainedSelf: PhotoLibrarySaveHelper?

    @MainActor
    static func save(_ image: UIImage) async -> Error? {
        await withCheckedContinuation { cont in
            let helper = PhotoLibrarySaveHelper()
            helper.continuation = cont
            helper.retainedSelf = helper
            UIImageWriteToSavedPhotosAlbum(
                image,
                helper,
                #selector(PhotoLibrarySaveHelper.image(_:didFinishSavingWithError:contextInfo:)),
                nil
            )
        }
    }

    @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeMutableRawPointer?) {
        continuation?.resume(returning: error)
        continuation = nil
        retainedSelf = nil
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

    private func clampedOffset(_ raw: CGSize, in size: CGSize, scale: CGFloat) -> CGSize {
        let maxX = max(0, size.width * (scale - 1.0) * 0.5)
        let maxY = max(0, size.height * (scale - 1.0) * 0.5)
        return CGSize(
            width: min(max(raw.width, -maxX), maxX),
            height: min(max(raw.height, -maxY), maxY)
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
                                        let clamped = clampedOffset(offset, in: geo.size, scale: scale)
                                        offset = clamped
                                        lastOffset = clamped
                                    }
                                }
                        )
                        .simultaneousGesture(
                            scale > 1.05
                                ? DragGesture(minimumDistance: 6)
                                    .onChanged { value in
                                        let next = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                        offset = clampedOffset(next, in: geo.size, scale: scale)
                                    }
                                    .onEnded { _ in
                                        lastOffset = offset
                                    }
                                : nil
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

