import Foundation

struct TranslationRequest: Sendable {
    let provider: ProviderConfiguration
    let model: ModelConfiguration
    let apiKey: String
    let prompt: String
}

enum TranslationClientError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case malformedStream
    case emptyResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "服务商网址无效，请在设置中检查基础网址。"
        case .invalidResponse:
            return "服务端返回了无法识别的响应。"
        case .httpError(let statusCode, let message):
            if message.isEmpty {
                return "请求失败（HTTP \(statusCode)）。"
            }
            return "请求失败（HTTP \(statusCode)）：\(message)"
        case .malformedStream:
            return "服务端返回的流式数据格式不正确。"
        case .emptyResponse:
            return "模型没有返回译文。"
        case .serverError(let message):
            return message
        }
    }
}

final class TranslationClient {
    private let session: URLSession
    private let diagnosticLogger: NetworkDiagnosticLogger

    init(
        session: URLSession? = nil,
        diagnosticLogger: NetworkDiagnosticLogger = .shared
    ) {
        self.diagnosticLogger = diagnosticLogger
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 300
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func streamTranslation(request translationRequest: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let requestID = UUID()
            let task = Task {
                do {
                    var includeOptimizations = true
                    var attempt = 1

                    requestAttempts: while true {
                        try Task.checkCancellation()
                        let preparedRequest = try makeURLRequest(
                            from: translationRequest,
                            includeOptimizations: includeOptimizations
                        )
                        let request = preparedRequest.urlRequest
                        diagnosticLogger.log(
                            requestID: requestID,
                            "开始翻译请求：attempt=\(attempt)，url=\(request.url?.absoluteString ?? "<无效>")，"
                                + "apiStyle=\(translationRequest.provider.apiStyle.rawValue)，"
                                + "preset=\(translationRequest.provider.resolvedOptimizationPreset.rawValue)，"
                                + "optimization=\(preparedRequest.optimizationDescription ?? "none")，"
                                + "model=\(Self.logField(translationRequest.model.apiName))，"
                                + "promptUTF8Bytes=\(translationRequest.prompt.utf8.count)，stream=true"
                        )
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let httpResponse = response as? HTTPURLResponse else {
                            throw TranslationClientError.invalidResponse
                        }

                        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                        diagnosticLogger.log(
                            requestID: requestID,
                            "收到响应头：status=\(httpResponse.statusCode)，contentType=\(contentType.isEmpty ? "<缺失>" : contentType)"
                        )

                        guard (200...299).contains(httpResponse.statusCode) else {
                            let body = try await collect(bytes: bytes, limit: 64 * 1024)
                            let message = Self.serverMessage(from: body)
                            if preparedRequest.optimizationDescription != nil,
                               Self.canRetryWithoutOptimizations(statusCode: httpResponse.statusCode) {
                                diagnosticLogger.log(
                                    requestID: requestID,
                                    redacting: [translationRequest.apiKey],
                                    "服务端拒绝翻译优化参数，改用通用请求重试一次：\(message)"
                                )
                                includeOptimizations = false
                                attempt += 1
                                continue requestAttempts
                            }
                            diagnosticLogger.log(
                                requestID: requestID,
                                redacting: [translationRequest.apiKey],
                                "HTTP 错误响应：\(String(data: body, encoding: .utf8) ?? "<非 UTF-8 数据>")"
                            )
                            throw TranslationClientError.httpError(
                                statusCode: httpResponse.statusCode,
                                message: message
                            )
                        }

                        try await consumeResponseBody(
                            bytes: bytes,
                            contentType: contentType,
                            apiStyle: translationRequest.provider.apiStyle,
                            requestID: requestID,
                            redactedValues: [translationRequest.apiKey],
                            continuation: continuation
                        )
                        diagnosticLogger.log(requestID: requestID, "翻译响应处理完成。")
                        break requestAttempts
                    }
                    continuation.finish()
                } catch is CancellationError {
                    diagnosticLogger.log(requestID: requestID, "翻译请求已取消。")
                    continuation.finish(throwing: CancellationError())
                } catch {
                    diagnosticLogger.log(
                        requestID: requestID,
                        redacting: [translationRequest.apiKey],
                        "翻译请求失败：\(String(reflecting: error))；\(error.localizedDescription)"
                    )
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private struct PreparedRequest {
        let urlRequest: URLRequest
        let optimizationDescription: String?
    }

    private func makeURLRequest(
        from translationRequest: TranslationRequest,
        includeOptimizations: Bool
    ) throws -> PreparedRequest {
        let endpoint = try Self.endpointURL(
            baseURLString: translationRequest.provider.baseURL,
            apiStyle: translationRequest.provider.apiStyle
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(translationRequest.apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any]
        switch translationRequest.provider.apiStyle {
        case .responses:
            body = [
                "model": translationRequest.model.apiName,
                "input": translationRequest.prompt,
                "stream": true,
                "store": false,
            ]
        case .chatCompletions:
            body = [
                "model": translationRequest.model.apiName,
                "messages": [
                    ["role": "user", "content": translationRequest.prompt],
                ],
                "stream": true,
            ]
        }
        let optimizationDescription = includeOptimizations
            ? Self.applyTranslationOptimizations(to: &body, provider: translationRequest.provider)
            : nil
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return PreparedRequest(
            urlRequest: request,
            optimizationDescription: optimizationDescription
        )
    }

    private static func applyTranslationOptimizations(
        to body: inout [String: Any],
        provider: ProviderConfiguration
    ) -> String? {
        guard provider.resolvedTranslationOptimizationsEnabled else { return nil }

        switch (provider.resolvedOptimizationPreset, provider.apiStyle) {
        case (.openAI, .responses), (.alibabaCloud, .responses):
            body["reasoning"] = ["effort": "none"]
            return "reasoning.effort=none"
        case (.openAI, .chatCompletions):
            body["reasoning_effort"] = "none"
            return "reasoning_effort=none"
        case (.alibabaCloud, .chatCompletions):
            body["enable_thinking"] = false
            return "enable_thinking=false"
        case (.zhipu, .chatCompletions):
            body["thinking"] = ["type": "disabled"]
            return "thinking.type=disabled"
        case (.xiaomi, .chatCompletions):
            body["thinking"] = ["type": "disabled"]
            return "thinking.type=disabled"
        case (.xiaomi, .responses):
            body["reasoning"] = ["effort": "none"]
            return "reasoning.effort=none"
        case (.generic, _), (.zhipu, .responses):
            return nil
        }
    }

    private static func canRetryWithoutOptimizations(statusCode: Int) -> Bool {
        statusCode == 400 || statusCode == 422
    }

    private static func endpointURL(baseURLString: String, apiStyle: APIStyle) throws -> URL {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw TranslationClientError.invalidBaseURL
        }

        components.query = nil
        components.fragment = nil
        guard let baseURL = components.url else {
            throw TranslationClientError.invalidBaseURL
        }

        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = apiStyle.endpointComponent
        if normalizedPath == endpointPath || normalizedPath.hasSuffix("/\(endpointPath)") {
            return baseURL
        }
        return baseURL.appending(path: endpointPath)
    }

    private enum ResponseBodyMode {
        case eventStream
        case plainJSON
    }

    /// Some OpenAI-compatible services return an SSE body with a missing or
    /// incorrect Content-Type. Sniff the first meaningful line so streaming
    /// still works, while retaining support for ordinary JSON responses.
    private func consumeResponseBody(
        bytes: URLSession.AsyncBytes,
        contentType: String,
        apiStyle: APIStyle,
        requestID: UUID,
        redactedValues: [String],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let declaresEventStream = contentType.contains("text/event-stream")
        let maximumPlainBodySize = 10 * 1024 * 1024
        var mode: ResponseBodyMode?
        var isFirstLine = true
        var eventName = ""
        var dataLines: [String] = []
        var plainLines: [String] = []
        var plainBodySize = 0
        var receivedText = false
        var reachedStreamCompletion = false

        func flushEvent() throws -> Bool {
            guard !dataLines.isEmpty else {
                eventName = ""
                return false
            }
            let data = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            defer { eventName = "" }

            let outcome: SSEOutcome
            do {
                outcome = try Self.parseSSEEvent(data: data, eventName: eventName, apiStyle: apiStyle)
            } catch {
                diagnosticLogger.log(
                    requestID: requestID,
                    redacting: redactedValues,
                    "流式事件解析失败：event=\(eventName.isEmpty ? "<缺失>" : eventName)，data=\(data)"
                )
                throw error
            }
            for delta in outcome.deltas where !delta.isEmpty {
                receivedText = true
                continuation.yield(delta)
            }
            return outcome.isComplete
        }

        /// 标准 SSE 使用空行分隔事件，但部分兼容服务会连续发送
        /// `data: {...}` 行。JSON 一旦完整便立即消费，从而兼容两种格式。
        func appendEventData(_ data: String) throws -> Bool {
            if !dataLines.isEmpty,
               Self.isCompleteEventData(dataLines.joined(separator: "\n")),
               try flushEvent() {
                return true
            }

            dataLines.append(data)
            if Self.isCompleteEventData(dataLines.joined(separator: "\n")) {
                return try flushEvent()
            }
            return false
        }

        func consumeEventStreamLine(_ line: String) throws -> Bool {
            if line.isEmpty {
                return try flushEvent()
            }

            let fieldLine = line.drop(while: { $0 == " " || $0 == "\t" })
            if fieldLine.hasPrefix(":") {
                return false
            }
            if fieldLine.hasPrefix("event:") {
                eventName = String(fieldLine.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if fieldLine.hasPrefix("data:") {
                let data = String(fieldLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                return try appendEventData(data)
            } else {
                let rawData = String(fieldLine).trimmingCharacters(in: .whitespaces)
                if rawData.hasPrefix("{") || rawData.hasPrefix("[") {
                    // 兼容 Content-Type 为 text/event-stream、但正文使用逐行 JSON 的服务。
                    return try appendEventData(rawData)
                }
            }
            // id:, retry:, and extension fields do not affect translation text.
            return false
        }

        func appendPlainLine(_ line: String) throws {
            plainBodySize += line.utf8.count + 1
            guard plainBodySize <= maximumPlainBodySize else {
                throw TranslationClientError.invalidResponse
            }
            plainLines.append(line)
        }

        responseLines: for try await rawLine in bytes.lines {
            try Task.checkCancellation()

            var line = rawLine
            if line.last == "\r" {
                line.removeLast()
            }
            if isFirstLine {
                isFirstLine = false
                if line.first == "\u{FEFF}" {
                    line.removeFirst()
                }
            }

            diagnosticLogger.log(
                requestID: requestID,
                redacting: redactedValues,
                "响应行：\(Self.diagnosticDescription(for: line))"
            )

            if mode == nil {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                if Self.looksLikeEventStreamLine(trimmed)
                    || declaresEventStream
                    || Self.looksLikeStreamingJSON(trimmed, apiStyle: apiStyle) {
                    mode = .eventStream
                    diagnosticLogger.log(requestID: requestID, "响应正文识别为流式数据。")
                } else if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                    mode = .plainJSON
                    diagnosticLogger.log(requestID: requestID, "响应正文暂识别为普通 JSON。")
                } else {
                    mode = .plainJSON
                    diagnosticLogger.log(requestID: requestID, "响应正文缺少流式标记，按普通响应处理。")
                }
            }

            switch mode {
            case .eventStream:
                if try consumeEventStreamLine(line) {
                    reachedStreamCompletion = true
                    break responseLines
                }
            case .plainJSON:
                try appendPlainLine(line)
                let candidate = plainLines.joined(separator: "\n")
                if Self.looksLikeStreamingJSON(candidate, apiStyle: apiStyle) {
                    // 第一块 JSON 可能跨多行，完整后再切换至流式模式。
                    mode = .eventStream
                    plainLines.removeAll(keepingCapacity: true)
                    plainBodySize = 0
                    diagnosticLogger.log(requestID: requestID, "检测到逐行 JSON 流，切换为流式处理。")
                    if try appendEventData(candidate) {
                        reachedStreamCompletion = true
                        break responseLines
                    }
                }
            case nil:
                break
            }
        }

        switch mode {
        case .eventStream:
            if !reachedStreamCompletion && !dataLines.isEmpty {
                _ = try flushEvent()
            }
            guard receivedText else {
                throw TranslationClientError.emptyResponse
            }

        case .plainJSON:
            guard let body = plainLines.joined(separator: "\n").data(using: .utf8) else {
                throw TranslationClientError.invalidResponse
            }
            let text = try Self.extractNonStreamingText(from: body, apiStyle: apiStyle)
            guard !text.isEmpty else {
                throw TranslationClientError.emptyResponse
            }
            continuation.yield(text)

        case nil:
            throw TranslationClientError.emptyResponse
        }
    }

    private static func looksLikeEventStreamLine(_ line: String) -> Bool {
        line.hasPrefix("data:")
            || line.hasPrefix("event:")
            || line.hasPrefix("id:")
            || line.hasPrefix("retry:")
            || line.hasPrefix(":")
    }

    /// 成功响应只记录结构和长度，避免服务端在推理内容中回显原文时
    /// 将待翻译文本长期写入日志。无法解析的事件仍会在实际报错处记录原文。
    private static func diagnosticDescription(for line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "<空行>" }

        let payload: String
        let prefix: String
        if trimmed.hasPrefix("data:") {
            payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            prefix = "data:"
        } else if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            payload = trimmed
            prefix = "json:"
        } else {
            return trimmed
        }

        if payload == "[DONE]" {
            return "\(prefix)[DONE]"
        }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "\(prefix)<暂不可解析，characters=\(payload.count)>"
        }

        var fields: [String] = []
        if let type = object["type"] as? String {
            fields.append("type=\(type)")
        } else if let objectType = object["object"] as? String {
            fields.append("object=\(objectType)")
        }
        if let sequenceNumber = object["sequence_number"] {
            fields.append("sequence=\(sequenceNumber)")
        }
        if let delta = object["delta"] as? String {
            fields.append("deltaCharacters=\(delta.count)")
        }
        if let choices = object["choices"] as? [[String: Any]],
           let first = choices.first {
            if let deltaObject = first["delta"] as? [String: Any] {
                if let content = deltaObject["content"] as? String {
                    fields.append("contentCharacters=\(content.count)")
                }
                if let reasoning = deltaObject["reasoning_content"] as? String {
                    fields.append("reasoningCharacters=\(reasoning.count)")
                }
            }
            if let finishReason = first["finish_reason"] as? String {
                fields.append("finishReason=\(finishReason)")
            }
        } else if object["choices"] is [Any] {
            fields.append("choices=empty")
        }
        if let usage = object["usage"] as? [String: Any],
           let totalTokens = usage["total_tokens"] {
            fields.append("totalTokens=\(totalTokens)")
        }
        if fields.isEmpty {
            fields.append("characters=\(payload.count)")
        }
        return "\(prefix){\(fields.joined(separator: ", "))}"
    }

    private static func isCompleteEventData(_ data: String) -> Bool {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" {
            return true
        }
        guard let jsonData = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: jsonData, options: [.fragmentsAllowed])) != nil
    }

    private static func looksLikeStreamingJSON(_ text: String, apiStyle: APIStyle) -> Bool {
        guard isCompleteEventData(text),
              text.trimmingCharacters(in: .whitespacesAndNewlines) != "[DONE]",
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        switch apiStyle {
        case .responses:
            guard let type = object["type"] as? String else { return false }
            return type.hasPrefix("response.")
        case .chatCompletions:
            if let objectType = object["object"] as? String,
               objectType.hasSuffix(".chunk") {
                return true
            }
            let choices = object["choices"] as? [[String: Any]] ?? []
            return choices.contains { $0["delta"] is [String: Any] }
        }
    }

    private struct SSEOutcome {
        let deltas: [String]
        let isComplete: Bool
    }

    private static func parseSSEEvent(data: String, eventName: String, apiStyle: APIStyle) throws -> SSEOutcome {
        if data == "[DONE]" {
            return SSEOutcome(deltas: [], isComplete: true)
        }

        guard let jsonData = data.data(using: .utf8) else {
            throw TranslationClientError.malformedStream
        }
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            throw TranslationClientError.malformedStream
        }
        guard let object = decoded as? [String: Any] else {
            throw TranslationClientError.malformedStream
        }

        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "服务端返回了未知错误。"
            throw TranslationClientError.serverError(message)
        }
        if object["code"] != nil, let message = object["message"] as? String {
            throw TranslationClientError.serverError(message)
        }

        switch apiStyle {
        case .responses:
            let type = (object["type"] as? String) ?? eventName
            if type == "response.output_text.delta" || type.hasSuffix("output_text.delta") {
                let delta = object["delta"] as? String ?? ""
                return SSEOutcome(deltas: [delta], isComplete: false)
            }
            if type == "response.failed" || type == "error" {
                let response = object["response"] as? [String: Any]
                let nestedError = response?["error"] as? [String: Any]
                let message = nestedError?["message"] as? String ?? "翻译请求失败。"
                throw TranslationClientError.serverError(message)
            }
            let done = type == "response.completed" || type == "response.incomplete"
            return SSEOutcome(deltas: [], isComplete: done)

        case .chatCompletions:
            guard let choices = object["choices"] as? [[String: Any]],
                  let first = choices.first else {
                return SSEOutcome(deltas: [], isComplete: false)
            }
            let deltaObject = first["delta"] as? [String: Any]
            let content: String
            if let text = deltaObject?["content"] as? String {
                content = text
            } else if let parts = deltaObject?["content"] as? [[String: Any]] {
                content = parts.compactMap { $0["text"] as? String }.joined()
            } else {
                content = ""
            }
            let finishReason = first["finish_reason"]
            let done = finishReason != nil && !(finishReason is NSNull)
            return SSEOutcome(deltas: [content], isComplete: done)
        }
    }

    private func collect(bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { break }
            data.append(byte)
        }
        return data
    }

    private static func serverMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return object["message"] as? String ?? ""
    }

    private static func extractNonStreamingText(from data: Data, apiStyle: APIStyle) throws -> String {
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TranslationClientError.invalidResponse
        }
        guard let object = decoded as? [String: Any] else {
            throw TranslationClientError.invalidResponse
        }
        if let error = object["error"] as? [String: Any] {
            throw TranslationClientError.serverError(error["message"] as? String ?? "翻译请求失败。")
        }

        switch apiStyle {
        case .responses:
            if let outputText = object["output_text"] as? String {
                return outputText
            }
            let output = object["output"] as? [[String: Any]] ?? []
            return output
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .compactMap { $0["text"] as? String }
                .joined()
        case .chatCompletions:
            let choices = object["choices"] as? [[String: Any]] ?? []
            let message = choices.first?["message"] as? [String: Any]
            return message?["content"] as? String ?? ""
        }
    }

    private static func logField(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
