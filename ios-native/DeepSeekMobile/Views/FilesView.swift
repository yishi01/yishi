import SwiftUI

struct FilesView: View {
    @EnvironmentObject var client: BridgeClient
    @Binding var activeTab: MainTab
    @State private var editingFile: FileEntryItem?
    @State private var editorContent: String = ""
    @State private var editorMtime: Double = 0
    @State private var isSaving: Bool = false

    private let symbols = ["  ", "{", "}", "(", ")", "[", "]", "=", ":", "\"", "'", "/", "#"]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if !client.currentDir.isEmpty {
                    Button {
                        Haptics.light()
                        let parts = client.currentDir.split(separator: "/").dropLast()
                        let parent = parts.joined(separator: "/")
                        Task { await client.loadDirectory(parent) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.turn.up.left")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.dsAccent)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.white.opacity(0.65)))
                            Text(".. (返回上一级)")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(Color.dsPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .cleanWhiteCard(cornerRadius: 16)
                    }
                    .glassPressable(scale: 0.98)
                }

                ForEach(client.fileEntries) { item in
                    Button {
                        Haptics.light()
                        if item.isDir {
                            Task { await client.loadDirectory(item.path) }
                        } else {
                            openEditor(for: item)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.isDir ? "folder.fill" : "doc.text.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(item.isDir ? Color.dsAccent : Color.secondary)
                                .frame(width: 34, height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.white.opacity(0.68))
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.dsPrimary)
                                    .lineLimit(1)
                                Text(item.isDir ? "目录" : "\(item.size) B")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary.opacity(0.6))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .cleanWhiteCard(cornerRadius: 16)
                    }
                    .glassPressable(scale: 0.98)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 84) // Scrolls cleanly behind the floating Liquid Glass tab bar
            .animation(.spring(response: 0.32, dampingFraction: 0.84), value: client.currentDir)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            filesTopHeader
        }
        .sheet(item: $editingFile) { file in
            NavigationStack {
                ZStack {
                    LiquidGlassBackdropView()

                    VStack(spacing: 10) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(symbols, id: \.self) { sym in
                                    Button(sym == "  " ? "Tab" : sym) {
                                        Haptics.light()
                                        editorContent += sym
                                    }
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.dsPrimary)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6.5)
                                    .cleanWhiteCard(cornerRadius: 10)
                                    .glassPressable(scale: 0.93)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                        }

                        TextEditor(text: $editorContent)
                            .font(.system(size: 13.5, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .cleanWhiteCard(cornerRadius: 18)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }
                }
                .navigationTitle(file.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("返回") { editingFile = nil }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("@引用") {
                            Haptics.light()
                            client.referencedFilePath = file.path
                            editingFile = nil
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.80)) {
                                activeTab = .chat
                            }
                        }
                        Button(isSaving ? "保存中..." : "保存") {
                            Haptics.medium()
                            Task {
                                isSaving = true
                                if let newMtime = try? await client.writeFile(
                                    file.path,
                                    content: editorContent,
                                    expectedMtime: editorMtime
                                ) {
                                    editorMtime = newMtime
                                    Haptics.success()
                                }
                                isSaving = false
                            }
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    private var filesTopHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill.badge.gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.dsAccent)
                Text(client.currentDir.isEmpty ? "工作区文件" : client.currentDir)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .liquidGlass(cornerRadius: 999, prominent: false)

            Spacer()

            Menu {
                ForEach(client.workspaces, id: \.self) { ws in
                    Button(ws) {
                        client.activeWorkspace = ws
                        Task { await client.loadDirectory("") }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.dsAccent)
                    Text("切换目录")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.dsPrimary)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .cleanWhiteCard(cornerRadius: 999)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func openEditor(for item: FileEntryItem) {
        Task {
            if let res = try? await client.readFile(item.path) {
                editorContent = res.content
                editorMtime = res.mtime
                editingFile = item
            }
        }
    }
}
