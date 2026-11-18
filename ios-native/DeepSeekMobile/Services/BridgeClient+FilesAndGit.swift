import Foundation
import SwiftUI

@MainActor
extension BridgeClient {
    // MARK: - Full PC File System Manager (Race-Free Single Tap)

    func loadPCDrives() async {
        do {
            let data = try await request("/api/pc/drives")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let rawDrives = json["drives"] as? [[String: Any]] {
                pcDrives = rawDrives.compactMap { d in
                    guard let letter = d["letter"] as? String,
                          let path = d["path"] as? String else { return nil }
                    return PCDriveItem(
                        letter: letter,
                        name: (d["name"] as? String) ?? letter,
                        label: (d["label"] as? String) ?? letter,
                        path: path,
                        totalBytes: (d["total_bytes"] as? NSNumber)?.int64Value ?? 0,
                        usedBytes: (d["used_bytes"] as? NSNumber)?.int64Value ?? 0,
                        freeBytes: (d["free_bytes"] as? NSNumber)?.int64Value ?? 0
                    )
                }
            }
            if let rawShortcuts = json["shortcuts"] as? [[String: Any]] {
                pcShortcuts = rawShortcuts.compactMap { s in
                    guard let name = s["name"] as? String,
                          let path = s["path"] as? String else { return nil }
                    return PCShortcutItem(name: name, path: path, icon: (s["icon"] as? String) ?? "folder")
                }
            }
        } catch {}
    }

    func loadPCDirectory(_ path: String) async {
        fileError = nil
        pcDirToken &+= 1
        let myToken = pcDirToken
        isLoadingDirectory = true
        defer {
            if pcDirToken == myToken {
                isLoadingDirectory = false
            }
        }

        let target = path.isEmpty ? activeWorkspace : path
        let pathEnc = target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let hiddenFlag = showHiddenFiles ? "true" : "false"
        do {
            let data = try await request("/api/pc/list?path=\(pathEnc)&show_hidden=\(hiddenFlag)")
            guard pcDirToken == myToken else { return }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = json["entries"] as? [[String: Any]] else { return }
            currentDir = (json["path"] as? String) ?? target
            currentParentDir = (json["parent_path"] as? String) ?? ""
            currentDirInAIWorkspace = (json["in_ai_workspace"] as? Bool) ?? false
            fileEntries = entries.compactMap { Self.parseFileEntry($0) }
        } catch {
            if pcDirToken == myToken {
                fileError = error.localizedDescription
            }
        }
    }

    static func parseFileEntry(_ e: [String: Any]) -> FileEntryItem? {
        guard let name = e["name"] as? String,
              let path = e["path"] as? String else { return nil }
        return FileEntryItem(
            name: name,
            path: path,
            parentPath: (e["parent_path"] as? String) ?? "",
            isDir: (e["is_dir"] as? Bool) ?? false,
            size: (e["size"] as? Int) ?? 0,
            mtime: (e["mtime"] as? Double) ?? 0,
            ctime: (e["ctime"] as? Double) ?? 0,
            atime: (e["atime"] as? Double) ?? 0,
            ext: (e["ext"] as? String) ?? "",
            mimeType: (e["mime_type"] as? String) ?? "application/octet-stream",
            isReadonly: (e["is_readonly"] as? Bool) ?? false,
            isHidden: (e["is_hidden"] as? Bool) ?? false,
            inAIWorkspace: (e["in_ai_workspace"] as? Bool) ?? false,
            aiCanRead: (e["ai_can_read"] as? Bool) ?? false,
            aiCanWrite: (e["ai_can_write"] as? Bool) ?? false
        )
    }

    func readPCFile(_ fullPath: String) async throws -> (content: String, mtime: Double) {
        let pathEnc = fullPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let data = try await request("/api/pc/read?path=\(pathEnc)")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return ((json["content"] as? String) ?? "", (json["mtime"] as? Double) ?? 0)
    }

    func writePCFile(_ fullPath: String, content: String) async throws {
        let payload: [String: Any] = ["path": fullPath, "content": content]
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await request("/api/pc/write", method: "PUT", body: body)
        await loadPCDirectory(currentDir)
        Haptics.success()
    }

    func createPCEntry(name: String, isDir: Bool, content: String = "") async throws {
        let payload: [String: Any] = [
            "parent_path": currentDir,
            "name": name,
            "is_dir": isDir,
            "content": content,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await request("/api/pc/create", method: "POST", body: body)
        await loadPCDirectory(currentDir)
        Haptics.success()
    }

    func renamePCEntry(item: FileEntryItem, newName: String) async throws {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let sep = item.path.contains("/") ? "/" : "\\"
        let destPath = item.parentPath.hasSuffix(sep) ? "\(item.parentPath)\(clean)" : "\(item.parentPath)\(sep)\(clean)"
        let payload: [String: Any] = ["src_path": item.path, "dest_path": destPath]
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await request("/api/pc/move", method: "POST", body: body)
        await loadPCDirectory(currentDir)
        Haptics.success()
    }

    func pasteClipboardIntoCurrentDir() async throws {
        guard let clip = clipboard else { return }
        let sep = currentDir.contains("/") ? "/" : "\\"
        let destPath = currentDir.hasSuffix(sep) ? "\(currentDir)\(clip.source.name)" : "\(currentDir)\(sep)\(clip.source.name)"
        let payload: [String: Any] = ["src_path": clip.source.path, "dest_path": destPath]
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await request(clip.isMove ? "/api/pc/move" : "/api/pc/copy", method: "POST", body: body)
        if clip.isMove { clipboard = nil }
        await loadPCDirectory(currentDir)
        Haptics.success()
    }

    func deletePCEntry(_ item: FileEntryItem) async throws {
        let pathEnc = item.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        _ = try await request("/api/pc/delete?path=\(pathEnc)", method: "DELETE")
        await loadPCDirectory(currentDir)
        Haptics.medium()
    }

    func uploadLocalFileToPC(fileURL: URL, targetDir: String? = nil) async throws -> (name: String, path: String) {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        let fileData = try Data(contentsOf: fileURL)
        let b64 = fileData.base64EncodedString()
        let dest = (targetDir?.isEmpty == false) ? targetDir! : (currentDir.isEmpty ? activeWorkspace : currentDir)
        let payload: [String: Any] = ["dir_path": dest, "filename": fileURL.lastPathComponent, "content_base64": b64]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let respData = try await request("/api/pc/upload_base64", method: "POST", body: body, timeout: 60)
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let savedPath = json["path"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        await loadPCDirectory(currentDir)
        Haptics.success()
        return (fileURL.lastPathComponent, savedPath)
    }

    func downloadPCFileToLocalTemp(pcPath: String, filename: String) async throws -> URL {
        let pathEnc = pcPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let data = try await request("/api/pc/download?path=\(pathEnc)", timeout: 60)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: tempURL, options: .atomic)
        return tempURL
    }

    // MARK: - Git Status & Diff

    func refreshGitDiff() async {
        let wsEnc = activeWorkspace.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        do {
            let data = try await request("/api/git/status?workspace=\(wsEnc)")
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                gitBranch = (json["branch"] as? String) ?? ""
                let diffStr = (json["diff"] as? String) ?? ""
                let reasonStr = (json["reason"] as? String) ?? ""
                gitDiff = diffStr.isEmpty ? reasonStr : diffStr
            }
        } catch {}
    }
}
