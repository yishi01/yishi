import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ShareSheetItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityViewSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct FilesView: View {
    @EnvironmentObject var client: BridgeClient
    @Binding var activeTab: MainTab

    @State private var editingFile: FileEntryItem?
    @State private var editorContent: String = ""
    @State private var isSaving: Bool = false

    @State private var inspectItem: FileEntryItem?
    @State private var renameTarget: FileEntryItem?
    @State private var renameInput: String = ""
    @State private var deleteTarget: FileEntryItem?

    @State private var showCreateAlert: Bool = false
    @State private var createIsDir: Bool = true
    @State private var createNameInput: String = ""

    @State private var showFileImporter: Bool = false
    @State private var statusBanner: String?
    @State private var downloadedShareItem: ShareSheetItem?

    private let symbols = ["  ", "{", "}", "(", ")", "[", "]", "=", ":", "\"", "'", "/", "#"]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                // 1. Drives (C:, D:, E:) & Quick Shortcuts Section
                drivesAndShortcutsSection

                // 2. Current Path & AI Isolation Status Card
                currentDirectoryHeaderCard

                if let err = client.fileError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(err)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.red)
                        Spacer()
                        Button("关闭") { client.fileError = nil }
                            .font(.system(size: 12))
                    }
                    .padding(12)
                    .cleanWhiteCard(cornerRadius: 14)
                }

                if let banner = statusBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(banner)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.dsPrimary)
                        Spacer()
                    }
                    .padding(12)
                    .cleanWhiteCard(cornerRadius: 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                // 3. Parent Directory Row (Single-Tap Immediate Response)
                if !client.currentParentDir.isEmpty {
                    Button {
                        Haptics.light()
                        Task { await client.loadPCDirectory(client.currentParentDir) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.turn.up.left")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.dsAccent)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color.white.opacity(0.75)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(".. (返回上一级)")
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(Color.dsPrimary)
                                Text(client.currentParentDir)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if client.isLoadingDirectory {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                        .cleanWhiteCard(cornerRadius: 16)
                    }
                    .buttonStyle(SingleTapRowButtonStyle())
                }

                // 4. File & Directory Entries
                ForEach(client.fileEntries) { item in
                    fileEntryRow(item)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, client.clipboard != nil ? 140 : 88)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            filesTopToolbar
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let clip = client.clipboard {
                floatingClipboardBar(clip)
                    .padding(.bottom, 68)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let firstURL = urls.first {
                Task {
                    do {
                        let res = try await client.uploadLocalFileToPC(fileURL: firstURL, targetDir: client.currentDir)
                        showToast("已上传至电脑: \(res.name)")
                    } catch {
                        client.fileError = "上传失败: \(error.localizedDescription)"
                    }
                }
            }
        }
        .sheet(item: $inspectItem) { item in
            FilePropertiesSheet(item: item, activeTab: $activeTab)
                .environmentObject(client)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $downloadedShareItem) { share in
            ActivityViewSheet(items: [share.url])
        }
        .sheet(item: $editingFile) { file in
            fileEditorSheet(file)
        }
        .alert(createIsDir ? "新建文件夹" : "新建文本文件", isPresented: $showCreateAlert) {
            TextField(createIsDir ? "文件夹名称" : "文件名 (如 notes.md)", text: $createNameInput)
            Button("取消", role: .cancel) { createNameInput = "" }
            Button("创建") {
                let name = createNameInput
                createNameInput = ""
                Task {
                    do {
                        try await client.createPCEntry(name: name, isDir: createIsDir)
                        showToast("已创建: \(name)")
                    } catch {
                        client.fileError = error.localizedDescription
                    }
                }
            }
        }
        .alert("重命名", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("新名称", text: $renameInput)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("确定") {
                if let target = renameTarget {
                    let newName = renameInput
                    renameTarget = nil
                    Task {
                        do {
                            try await client.renamePCEntry(item: target, newName: newName)
                            showToast("已重命名为: \(newName)")
                        } catch {
                            client.fileError = error.localizedDescription
                        }
                    }
                }
            }
        }
        .alert("确认删除", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) {
                if let target = deleteTarget {
                    deleteTarget = nil
                    Task {
                        do {
                            try await client.deletePCEntry(target)
                            showToast("已删除: \(target.name)")
                        } catch {
                            client.fileError = error.localizedDescription
                        }
                    }
                }
            }
        } message: {
            Text("确定要在电脑上永久删除「\(deleteTarget?.name ?? "")」吗？")
        }
        .onAppear {
            Task {
                await client.loadPCDrives()
                if client.currentDir.isEmpty {
                    await client.loadPCDirectory(client.activeWorkspace)
                }
            }
        }
    }

    // MARK: - Subviews

    private var filesTopToolbar: some View {
        HStack(spacing: 8) {
            if !client.currentParentDir.isEmpty {
                Button {
                    Haptics.light()
                    Task { await client.loadPCDirectory(client.currentParentDir) }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.dsPrimary)
                        .frame(width: 36, height: 36)
                        .cleanWhiteCard(cornerRadius: 999)
                }
                .buttonStyle(SingleTapRowButtonStyle())
            }

            HStack(spacing: 7) {
                if client.isLoadingDirectory {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "externaldrive.fill.badge.wifi")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.dsAccent)
                }
                Text("电脑全盘文件")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8.5)
            .liquidGlass(cornerRadius: 999, prominent: false)

            Spacer()

            // Upload from iPhone to Current PC Folder
            Button {
                Haptics.light()
                showFileImporter = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.doc.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.dsAccent)
                    Text("上传")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.dsPrimary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .cleanWhiteCard(cornerRadius: 999)
            }
            .glassPressable(scale: 0.94)

            // Create / Hidden Menu
            Menu {
                Button {
                    createIsDir = true
                    createNameInput = ""
                    showCreateAlert = true
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }

                Button {
                    createIsDir = false
                    createNameInput = ""
                    showCreateAlert = true
                } label: {
                    Label("新建文本文件", systemImage: "doc.badge.plus")
                }

                Divider()

                Button {
                    client.showHiddenFiles.toggle()
                    Task { await client.loadPCDirectory(client.currentDir) }
                } label: {
                    Label(
                        client.showHiddenFiles ? "隐藏系统/隐藏文件" : "显示隐藏文件",
                        systemImage: client.showHiddenFiles ? "eye.slash" : "eye"
                    )
                }

                Button {
                    Task {
                        await client.loadPCDrives()
                        await client.loadPCDirectory(client.currentDir)
                    }
                } label: {
                    Label("刷新当前目录", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
                    .frame(width: 36, height: 36)
                    .cleanWhiteCard(cornerRadius: 999)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var drivesAndShortcutsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Drives Row (C:, D:, E:, etc.)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(client.pcDrives) { drive in
                        let isSelected = client.currentDir.uppercased().hasPrefix(drive.letter.uppercased())
                        Button {
                            Haptics.light()
                            Task { await client.loadPCDirectory(drive.path) }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    Image(systemName: "internaldrive.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(isSelected ? Color.dsAccent : .secondary)
                                    Text(drive.name)
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundStyle(Color.dsPrimary)
                                }

                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.black.opacity(0.08))
                                        Capsule()
                                            .fill(isSelected ? Color.dsAccent : Color.secondary.opacity(0.55))
                                            .frame(width: max(6, geo.size.width * drive.usageRatio))
                                    }
                                }
                                .frame(height: 5)

                                Text(drive.formattedCapacity)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 156, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .liquidGlass(cornerRadius: 16, prominent: isSelected)
                        }
                        .buttonStyle(SingleTapRowButtonStyle())
                    }
                }
            }

            // Quick Shortcuts Row (AI Workspace, Desktop, Downloads, Documents)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(client.pcShortcuts) { sc in
                        Button {
                            Haptics.light()
                            Task { await client.loadPCDirectory(sc.path) }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: sc.icon)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Color.dsAccent)
                                Text(sc.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.dsPrimary)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .cleanWhiteCard(cornerRadius: 999)
                        }
                        .buttonStyle(SingleTapRowButtonStyle())
                    }
                }
            }
        }
    }

    private var currentDirectoryHeaderCard: some View {
        let aiAllowed = client.currentDirInAIWorkspace || client.aiAccessMode == "full_access"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前路径")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(client.currentDir.isEmpty ? client.activeWorkspace : client.currentDir)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.dsPrimary)
                        .textSelection(.enabled)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: aiAllowed ? "checkmark.shield.fill" : "lock.shield.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(aiAllowed ? Color.green : Color.orange)
                    Text(aiAllowed ? "AI 可访问此目录" : "AI 已隔离 (仅你可操作)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.dsPrimary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(Capsule().fill(Color.white.opacity(0.65)))

                Spacer()

                if !client.currentDirInAIWorkspace {
                    Button {
                        Haptics.medium()
                        Task {
                            await client.authorizeWorkspace(path: client.currentDir, setActive: true)
                            showToast("已将当前目录设为 AI 工作区")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                            Text("设为 AI 工作区")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.dsPrimary))
                    }
                    .glassPressable(scale: 0.95)
                } else if client.activeWorkspace != client.currentDir {
                    Button {
                        Haptics.light()
                        Task {
                            await client.authorizeWorkspace(path: client.currentDir, setActive: true)
                            showToast("已切换当前 AI 工作区")
                        }
                    } label: {
                        Text("激活为当前工作区")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.dsAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .cleanWhiteCard(cornerRadius: 999)
                    }
                    .glassPressable(scale: 0.95)
                }
            }
        }
        .padding(12)
        .cleanWhiteCard(cornerRadius: 16)
    }

    private func fileEntryRow(_ item: FileEntryItem) -> some View {
        HStack(spacing: 12) {
            Button {
                Haptics.light()
                if item.isDir {
                    Task { await client.loadPCDirectory(item.path) }
                } else {
                    openEditorOrPreview(for: item)
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.white.opacity(0.72))
                            .frame(width: 38, height: 38)
                        Image(systemName: iconForEntry(item))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(item.isDir ? Color.dsAccent : Color.dsPrimary.opacity(0.78))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.name)
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundStyle(Color.dsPrimary)
                                .lineLimit(1)

                            if item.inAIWorkspace {
                                Text("AI")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(Color.dsAccent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.dsAccent.opacity(0.14)))
                            }
                            if item.isReadonly {
                                Text("只读")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("\(item.formattedSize) · \(item.formattedMtime)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SingleTapRowButtonStyle())

            // Context Action Menu Button
            Menu {
                Button {
                    inspectItem = item
                } label: {
                    Label("查看完整属性", systemImage: "info.circle")
                }

                if !item.isDir {
                    Button {
                        openEditorOrPreview(for: item)
                    } label: {
                        Label("打开 / 编辑文本", systemImage: "doc.text.magnifyingglass")
                    }

                    Button {
                        downloadFileToPhone(item)
                    } label: {
                        Label("下载到手机本地", systemImage: "arrow.down.circle")
                    }

                    Button {
                        client.referencedFilePath = item.path
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.80)) {
                            activeTab = .chat
                        }
                    } label: {
                        Label("发送/引用给 AI", systemImage: "sparkles")
                    }
                } else {
                    Button {
                        Task {
                            await client.authorizeWorkspace(path: item.path, setActive: true)
                            showToast("已将「\(item.name)」设为 AI 工作区")
                        }
                    } label: {
                        Label("设为 AI 工作区", systemImage: "sparkles")
                    }
                }

                Divider()

                Button {
                    client.clipboard = FileClipboardItem(source: item, isMove: false)
                    showToast("已复制「\(item.name)」，请前往目标目录粘贴")
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }

                Button {
                    client.clipboard = FileClipboardItem(source: item, isMove: true)
                    showToast("已剪切「\(item.name)」，请前往目标目录点击移动")
                } label: {
                    Label("移动 / 剪切", systemImage: "folder.badge.gearshape")
                }

                Button {
                    renameInput = item.name
                    renameTarget = item
                } label: {
                    Label("重命名", systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    deleteTarget = item
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .cleanWhiteCard(cornerRadius: 16)
    }

    private func floatingClipboardBar(_ clip: FileClipboardItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: clip.isMove ? "scissors" : "doc.on.doc.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.dsAccent)

            VStack(alignment: .leading, spacing: 1) {
                Text(clip.isMove ? "正在移动: \(clip.source.name)" : "已复制: \(clip.source.name)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
                    .lineLimit(1)
                Text("目标: \(client.currentDir)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                Haptics.medium()
                Task {
                    do {
                        try await client.pasteClipboardIntoCurrentDir()
                        showToast(clip.isMove ? "已移动到当前目录" : "已粘贴到当前目录")
                    } catch {
                        client.fileError = error.localizedDescription
                    }
                }
            } label: {
                Text(clip.isMove ? "移动到此处" : "粘贴到此处")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.dsPrimary))
            }
            .glassPressable(scale: 0.95)

            Button {
                client.clipboard = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 20, prominent: true)
        .padding(.horizontal, 12)
    }

    private func fileEditorSheet(_ file: FileEntryItem) -> some View {
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
                    Button {
                        downloadFileToPhone(file)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }

                    Button("@引用") {
                        Haptics.light()
                        client.referencedFilePath = file.path
                        editingFile = nil
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.80)) {
                            activeTab = .chat
                        }
                    }

                    Button(isSaving ? "保存中..." : "保存") {
                        guard !isSaving else { return }
                        Haptics.medium()
                        Task {
                            isSaving = true
                            do {
                                try await client.writePCFile(file.path, content: editorContent)
                                showToast("已保存修改: \(file.name)")
                            } catch {
                                client.fileError = "保存失败: \(error.localizedDescription)"
                                showToast("保存失败: \(error.localizedDescription)")
                            }
                            isSaving = false
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Helpers

    private func iconForEntry(_ item: FileEntryItem) -> String {
        if item.isDir { return "folder.fill" }
        switch item.ext {
        case ".py", ".swift", ".js", ".ts", ".json", ".html", ".css", ".sh", ".bat":
            return "chevron.left.forwardslash.chevron.right"
        case ".md", ".txt", ".log":
            return "doc.text.fill"
        case ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".ico":
            return "photo.fill"
        case ".zip", ".rar", ".7z", ".tar", ".gz":
            return "doc.zipper"
        case ".exe", ".msi", ".ipa", ".dmg":
            return "app.badge.fill"
        default:
            return "doc.fill"
        }
    }

    private func openEditorOrPreview(for item: FileEntryItem) {
        Task {
            do {
                let res = try await client.readPCFile(item.path)
                editorContent = res.content
                editingFile = item
            } catch {
                // If binary or large file, offer direct download or properties inspection
                inspectItem = item
            }
        }
    }

    private func downloadFileToPhone(_ item: FileEntryItem) {
        Task {
            do {
                let url = try await client.downloadPCFileToLocalTemp(pcPath: item.path, filename: item.name)
                downloadedShareItem = ShareSheetItem(url: url)
            } catch {
                client.fileError = "下载失败: \(error.localizedDescription)"
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            statusBanner = text
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            withAnimation(.easeOut(duration: 0.25)) {
                if statusBanner == text {
                    statusBanner = nil
                }
            }
        }
    }
}

// MARK: - Detailed File Properties Sheet

struct FilePropertiesSheet: View {
    @EnvironmentObject var client: BridgeClient
    @Environment(\.dismiss) private var dismiss
    let item: FileEntryItem
    @Binding var activeTab: MainTab
    @State private var shareItem: ShareSheetItem?

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackdropView()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            Image(systemName: item.isDir ? "folder.fill" : "doc.text.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(Color.dsAccent)
                                .frame(width: 54, height: 54)
                                .cleanWhiteCard(cornerRadius: 16)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(Color.dsPrimary)
                                Text(item.mimeType)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .cleanWhiteCard(cornerRadius: 18)

                        VStack(alignment: .leading, spacing: 10) {
                            propertyRow("完整路径", item.path, monospaced: true)
                            Divider().opacity(0.4)
                            propertyRow("类型", item.isDir ? "文件夹 (Directory)" : "文件 (\(item.ext.isEmpty ? "无扩展名" : item.ext))")
                            Divider().opacity(0.4)
                            propertyRow("大小", item.isDir ? "目录" : "\(item.formattedSize) (\(item.size) 字节)")
                            Divider().opacity(0.4)
                            propertyRow("创建时间", item.formattedCtime)
                            Divider().opacity(0.4)
                            propertyRow("修改时间", item.formattedMtime)
                            Divider().opacity(0.4)
                            propertyRow("最后访问", item.formattedAtime)
                            Divider().opacity(0.4)
                            propertyRow("系统属性", "\(item.isReadonly ? "只读" : "可读写") · \(item.isHidden ? "隐藏" : "常规")")
                            Divider().opacity(0.4)
                            propertyRow(
                                "AI 隔离状态",
                                item.aiCanWrite ? "✅ AI 可读写 (位于授权工作区或全盘权限)" : (item.aiCanRead ? "👁️ AI 仅可读 (不可修改)" : "🔒 AI 已隔离 (禁止 AI 访问)")
                            )
                        }
                        .padding(14)
                        .cleanWhiteCard(cornerRadius: 18)

                        // Quick Actions in Properties
                        VStack(spacing: 10) {
                            if !item.isDir {
                                Button {
                                    Task {
                                        if let url = try? await client.downloadPCFileToLocalTemp(pcPath: item.path, filename: item.name) {
                                            shareItem = ShareSheetItem(url: url)
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: "arrow.down.circle.fill")
                                        Text("下载此文件到手机本地")
                                    }
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .background(Capsule().fill(Color.dsPrimary))
                                }
                                .glassPressable(scale: 0.97)
                            }

                            if item.isDir && !item.inAIWorkspace {
                                Button {
                                    Task {
                                        await client.authorizeWorkspace(path: item.path, setActive: true)
                                        dismiss()
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: "sparkles")
                                        Text("将此文件夹授权并设为 AI 工作区")
                                    }
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .background(Capsule().fill(Color.dsAccent))
                                }
                                .glassPressable(scale: 0.97)
                            }

                            Button {
                                client.referencedFilePath = item.path
                                dismiss()
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.80)) {
                                    activeTab = .chat
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "bubble.left.and.bubble.right.fill")
                                    Text("在对话中引用此路径")
                                }
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(Color.dsPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .cleanWhiteCard(cornerRadius: 999)
                            }
                            .glassPressable(scale: 0.97)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("文件属性")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $shareItem) { s in
                ActivityViewSheet(items: [s.url])
            }
        }
    }

    private func propertyRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13.5, design: monospaced ? .monospaced : .default))
                .foregroundStyle(Color.dsPrimary)
                .textSelection(.enabled)
        }
    }
}
