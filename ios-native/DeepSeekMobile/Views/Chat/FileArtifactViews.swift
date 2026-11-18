import SwiftUI
import UIKit

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
                            guard !isSaving else { return }
                            Task {
                                isSaving = true
                                do {
                                    try await client.writePCFile(artifact.path, content: fullContent)
                                    savedToast = true
                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                    savedToast = false
                                } catch {
                                    client.showToastMessage("保存失败: \(error.localizedDescription)")
                                }
                                isSaving = false
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
