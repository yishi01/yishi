import SwiftUI

struct ApprovalReviewSheet: View {
    @EnvironmentObject var client: BridgeClient
    @Environment(\.dismiss) private var dismiss
    let item: PendingApprovalItem

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackdropView()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Header Card
                        HStack(spacing: 12) {
                            Image(systemName: riskIcon)
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(riskColor)
                                .frame(width: 48, height: 48)
                                .background(Circle().fill(riskColor.opacity(0.14)))

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(item.toolName)
                                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.dsPrimary)
                                    Text(riskBadgeText)
                                        .font(.system(size: 11, weight: .bold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(riskColor.opacity(0.16)))
                                        .foregroundStyle(riskColor)
                                }
                                Text(item.reviewSummary.isEmpty ? "AI 请求在你的电脑端执行受保护工具操作" : item.reviewSummary)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .liquidGlass(cornerRadius: 20, prominent: true)

                        // Arguments / Command Payload
                        VStack(alignment: .leading, spacing: 8) {
                            Text("完整调用参数与代码审查")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)

                            ScrollView(.horizontal, showsIndicators: true) {
                                Text(item.argsJSON)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(Color.dsPrimary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .cleanWhiteCard(cornerRadius: 16)
                        }

                        // Action Confirmation Buttons
                        VStack(spacing: 10) {
                            Button {
                                Haptics.success()
                                Task {
                                    await client.resolveApproval(requestId: item.id, allow: true)
                                    dismiss()
                                }
                            } label: {
                                Label("✓ 允许本次执行", systemImage: "checkmark.shield.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .background(Capsule().fill(Color.dsPrimary))
                            }
                            .glassPressable(scale: 0.96)

                            Button {
                                Haptics.medium()
                                Task {
                                    await client.resolveApproval(requestId: item.id, allow: true, setAutoMode: true)
                                    dismiss()
                                }
                            } label: {
                                Label("允许并切换本会话为「自动放行」", systemImage: "bolt.shield.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.dsAccent)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .cleanWhiteCard(cornerRadius: 999)
                            }
                            .glassPressable(scale: 0.96)

                            Button(role: .destructive) {
                                Haptics.warning()
                                Task {
                                    await client.resolveApproval(requestId: item.id, allow: false)
                                    dismiss()
                                }
                            } label: {
                                Label("✕ 拒绝该操作", systemImage: "xmark.shield.fill")
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .cleanWhiteCard(cornerRadius: 999)
                            }
                            .glassPressable(scale: 0.96)
                        }
                        .padding(.top, 4)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("安全审查确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var riskColor: Color {
        switch item.riskLevel.lowercased() {
        case "critical", "high": return .red
        case "medium": return .orange
        case "low": return .blue
        default: return .green
        }
    }

    private var riskIcon: String {
        switch item.riskLevel.lowercased() {
        case "critical", "high": return "exclamationmark.shield.fill"
        case "medium": return "shield.lefthalf.filled"
        default: return "checkmark.shield.fill"
        }
    }

    private var riskBadgeText: String {
        switch item.riskLevel.lowercased() {
        case "critical": return "极高风险 (\(item.reviewScore))"
        case "high": return "高风险 (\(item.reviewScore))"
        case "medium": return "中风险 (\(item.reviewScore))"
        case "low": return "低风险 (\(item.reviewScore))"
        default: return "低风险 / 安全"
        }
    }
}
