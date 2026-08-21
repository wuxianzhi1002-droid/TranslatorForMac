import Foundation

/// 将网络诊断信息写入用户日志目录。
///
/// 日志不会记录 Authorization 请求头或完整提示词。正常响应仅记录事件
/// 结构和文本长度；只有解析失败时才保留对应原始事件以便排错。
final class NetworkDiagnosticLogger: @unchecked Sendable {
    static let shared = NetworkDiagnosticLogger()

    static let logDirectoryURL: URL = {
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
        return libraryURL
            .appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: "AI.Translator", directoryHint: .isDirectory)
    }()

    static let logURL = logDirectoryURL.appending(path: "network-diagnostics.log")

    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()
    private var isEnabled = false
    private var fileHandle: FileHandle?

    private init() {}

    deinit {
        try? fileHandle?.close()
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled != isEnabled else { return }
        isEnabled = enabled

        if enabled {
            openLogUnlocked()
            writeUnlocked("\n========== 日志已开启 ==========\n")
        } else {
            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    func log(
        requestID: UUID? = nil,
        redacting sensitiveValues: [String] = [],
        _ message: @autoclosure () -> String
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled else { return }

        let requestTag = requestID.map { " [\($0.uuidString.prefix(8))]" } ?? ""
        var fullMessage = message()
        for sensitiveValue in sensitiveValues where !sensitiveValue.isEmpty {
            fullMessage = fullMessage.replacingOccurrences(of: sensitiveValue, with: "<已脱敏>")
        }
        let maximumCharacters = 32_000
        let renderedMessage: String
        if fullMessage.count > maximumCharacters {
            renderedMessage = String(fullMessage.prefix(maximumCharacters)) + "…（日志内容已截断）"
        } else {
            renderedMessage = fullMessage
        }

        writeUnlocked("\(formatter.string(from: Date()))\(requestTag) \(renderedMessage)\n")
    }

    private func openLogUnlocked() {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: Self.logDirectoryURL, withIntermediateDirectories: true)
            rotateLogIfNeeded(fileManager: fileManager)
            if !fileManager.fileExists(atPath: Self.logURL.path) {
                fileManager.createFile(atPath: Self.logURL.path, contents: nil)
            }
            fileHandle = try FileHandle(forWritingTo: Self.logURL)
            try fileHandle?.seekToEnd()
        } catch {
            fileHandle = nil
        }
    }

    private func writeUnlocked(_ string: String) {
        guard let data = string.data(using: .utf8), let fileHandle else { return }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            // 诊断日志不得影响翻译请求本身。
        }
    }

    private func rotateLogIfNeeded(fileManager: FileManager) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: Self.logURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 4 * 1024 * 1024 else {
            return
        }

        let previousURL = Self.logURL.deletingPathExtension().appendingPathExtension("previous.log")
        try? fileManager.removeItem(at: previousURL)
        try? fileManager.moveItem(at: Self.logURL, to: previousURL)
    }
}
