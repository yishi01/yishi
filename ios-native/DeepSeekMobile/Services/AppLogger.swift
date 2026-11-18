import Foundation

struct ClientLogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let level: String // INFO | WARN | ERROR
    let category: String
    let message: String

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        return fmt
    }()

    var formattedTime: String {
        Self.timeFormatter.string(from: timestamp)
    }
}

@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published private(set) var entries: [ClientLogEntry] = []
    private let maxEntries = 350

    private init() {
        let info = Bundle.main.infoDictionary
        let ver = (info?["CFBundleShortVersionString"] as? String) ?? "0.9.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "18"
        log("INFO", category: "Lifecycle", "DeepSeek Go v\(ver) (Build \(build)) initialized")
    }

    func log(_ level: String, category: String, _ message: String) {
        let item = ClientLogEntry(
            timestamp: Date(),
            level: level.uppercased(),
            category: category,
            message: message
        )
        entries.append(item)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func info(_ category: String, _ message: String) {
        log("INFO", category: category, message)
    }

    func warn(_ category: String, _ message: String) {
        log("WARN", category: category, message)
    }

    func error(_ category: String, _ message: String) {
        log("ERROR", category: category, message)
    }

    func clear() {
        entries.removeAll()
        info("Logger", "已清空手机端本地日志")
    }

    func exportText() -> String {
        entries.map { "[\($0.formattedTime)] [\($0.level)] [\($0.category)] \($0.message)" }
            .joined(separator: "\n")
    }
}
