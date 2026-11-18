import SwiftUI

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

