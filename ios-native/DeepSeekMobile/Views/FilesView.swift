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
        NavigationStack {
            List {
                if !client.currentDir.isEmpty {
                    Button {
                        let parts = client.currentDir.split(separator: "/").dropLast()
                        let parent = parts.joined(separator: "/")
                        Task { await client.loadDirectory(parent) }
                    } label: {
                        Label(".. (返回上一级)", systemImage: "arrow.turn.up.left")
                            .font(.system(size: 15, weight: .medium))
                    }
                }

                ForEach(client.fileEntries) { item in
                    Button {
                        if item.isDir {
                            Task { await client.loadDirectory(item.path) }
                        } else {
                            openEditor(for: item)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.isDir ? "folder.fill" : "doc.text")
                                .foregroundStyle(item.isDir ? Color.dsAccent : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.dsPrimary)
                                Text(item.isDir ? "目录" : "\(item.size) B")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(client.currentDir.isEmpty ? "工作区文件" : client.currentDir)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(client.workspaces, id: \.self) { ws in
                            Button(ws) {
                                client.activeWorkspace = ws
                                Task { await client.loadDirectory("") }
                            }
                        }
                    } label: {
                        Image(systemName: "shippingbox")
                    }
                }
            }
            .sheet(item: $editingFile) { file in
                NavigationStack {
                    VStack(spacing: 0) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(symbols, id: \.self) { sym in
                                    Button(sym == "  " ? "Tab" : sym) {
                                        editorContent += sym
                                    }
                                    .font(.system(size: 13, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .cleanWhiteCard(cornerRadius: 8)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .background(Color.dsSurface)

                        TextEditor(text: $editorContent)
                            .font(.system(size: 14, design: .monospaced))
                            .padding(8)
                    }
                    .navigationTitle(file.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("返回") { editingFile = nil }
                        }
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button("@引用") {
                                client.referencedFilePath = file.path
                                editingFile = nil
                                activeTab = .chat
                            }
                            Button(isSaving ? "保存中..." : "保存") {
                                Task {
                                    isSaving = true
                                    if let newMtime = try? await client.writeFile(
                                        file.path,
                                        content: editorContent,
                                        expectedMtime: editorMtime
                                    ) {
                                        editorMtime = newMtime
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
