import Foundation

/// Minimal, dependency-free client for the local Ollama HTTP API.
///
/// Only ever talks to `127.0.0.1`; there is no code path in this app that sends
/// conversation data anywhere else.
public final class OllamaClient: Sendable {

    public let baseURL: URL
    private let session: URLSession

    public convenience init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!) {
        self.init(baseURL: baseURL, transport: [])
    }

    /// `transport` schiebt einen eigenen `URLProtocol` unter. Ausschließlich für
    /// Tests gedacht: das NDJSON-Parsen, die Fehlerabbildung und die
    /// Metrikauswertung sind die einzige Stelle, an der die App fremde Daten
    /// auslegt – und ohne diesen Haken ließe sich das nur mit einem laufenden
    /// Ollama prüfen, also gar nicht in der CI.
    init(baseURL: URL, transport: [AnyClass]) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        if !transport.isEmpty { configuration.protocolClasses = transport }
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 6
        // Local loopback only – make sure no proxy ever sees this traffic.
        configuration.connectionProxyDictionary = [:]
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Health & inventory

    public func version(timeout: TimeInterval? = nil) async throws -> String {
        let data = try await get("/api/version", timeout: timeout)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String else {
            throw OllamaError.decoding("version")
        }
        return version
    }

    public func isReachable(timeout: TimeInterval? = nil) async -> Bool {
        (try? await version(timeout: timeout)) != nil
    }

    public func installedModels() async throws -> [OllamaModel] {
        let data = try await get("/api/tags")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else {
            throw OllamaError.decoding("tags")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return models.map { entry in
            let details = entry["details"] as? [String: Any] ?? [:]
            return OllamaModel(
                name: entry["name"] as? String ?? "?",
                sizeBytes: (entry["size"] as? NSNumber)?.int64Value ?? 0,
                parameterSize: details["parameter_size"] as? String ?? "",
                quantization: details["quantization_level"] as? String ?? "",
                family: details["family"] as? String ?? "",
                modifiedAt: (entry["modified_at"] as? String).flatMap { formatter.date(from: $0) }
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// Models currently resident in memory, with their unload deadline.
    public func loadedModels() async throws -> [String] {
        let data = try await get("/api/ps")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    // MARK: - Chat

    /// Streams a chat completion. Cancelling the surrounding `Task` aborts the
    /// generation on the server too, which is what lets a new question
    /// immediately supersede an in-flight answer.
    public func chatStream(
        model: String,
        messages: [ChatMessage],
        options: GenerationOptions = GenerationOptions(),
        format: ResponseFormat = .free,
        think: Bool? = nil,
        keepAlive: String = "30m"
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": true,
            "keep_alive": keepAlive
        ]
        let optionPayload = options.payload
        if !optionPayload.isEmpty { body["options"] = optionPayload }
        if let formatPayload = format.payload { body["format"] = formatPayload }
        if let think { body["think"] = think }

        return stream(path: "/api/chat", body: body)
    }

    /// Convenience wrapper that collects a full response.
    public func chat(
        model: String,
        messages: [ChatMessage],
        options: GenerationOptions = GenerationOptions(),
        format: ResponseFormat = .free,
        think: Bool? = nil,
        keepAlive: String = "30m"
    ) async throws -> (text: String, metrics: GenerationMetrics) {
        var text = ""
        var metrics = GenerationMetrics()
        for try await chunk in chatStream(
            model: model, messages: messages, options: options,
            format: format, think: think, keepAlive: keepAlive
        ) {
            text += chunk.text
            if let final = chunk.metrics { metrics = final }
        }
        return (text, metrics)
    }

    /// Loads a model into memory without generating anything, so the first real
    /// request does not pay the load cost.
    public func warmUp(model: String, keepAlive: String = "30m") async throws {
        let body: [String: Any] = [
            "model": model,
            "messages": [],
            "stream": false,
            "keep_alive": keepAlive
        ]
        _ = try await post("/api/chat", body: body)
    }

    // MARK: - Pull

    public struct PullProgress: Sendable {
        public var status: String
        public var completedBytes: Int64
        public var totalBytes: Int64
        public var fraction: Double {
            totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0
        }
    }

    public func pull(model: String) -> AsyncThrowingStream<PullProgress, Error> {
        let body: [String: Any] = ["model": model, "stream": true]
        guard let raw = try? rawStream(path: "/api/pull", body: body) else {
            return AsyncThrowingStream { $0.finish(throwing: OllamaError.decoding("request body")) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var receivedSuccess = false
                    for try await line in raw {
                        guard let object = Self.decode(line) else { continue }
                        if let error = object["error"] as? String {
                            throw OllamaError.httpStatus(500, error)
                        }
                        if (object["status"] as? String)?.lowercased() == "success" {
                            receivedSuccess = true
                        }
                        continuation.yield(PullProgress(
                            status: object["status"] as? String ?? "",
                            completedBytes: (object["completed"] as? NSNumber)?.int64Value ?? 0,
                            totalBytes: (object["total"] as? NSNumber)?.int64Value ?? 0
                        ))
                    }
                    guard receivedSuccess else {
                        throw OllamaPullError.incomplete(model)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Transport

    private func stream(path: String, body: [String: Any]) -> AsyncThrowingStream<StreamChunk, Error> {
        let raw: AsyncThrowingStream<Data, Error>
        do {
            raw = try rawStream(path: path, body: body)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                let start = Clock.now()
                var firstTokenAt: Double?
                do {
                    for try await line in raw {
                        guard let object = Self.decode(line) else { continue }
                        if let error = object["error"] as? String {
                            throw OllamaError.httpStatus(500, error)
                        }
                        var chunk = StreamChunk()
                        if let message = object["message"] as? [String: Any] {
                            chunk.text = message["content"] as? String ?? ""
                            chunk.thinking = message["thinking"] as? String ?? ""
                        } else {
                            chunk.text = object["response"] as? String ?? ""
                            chunk.thinking = object["thinking"] as? String ?? ""
                        }
                        if !chunk.text.isEmpty && firstTokenAt == nil {
                            firstTokenAt = Clock.now()
                        }
                        chunk.isDone = (object["done"] as? Bool) ?? false
                        if chunk.isDone {
                            var metrics = GenerationMetrics()
                            metrics.promptTokens = (object["prompt_eval_count"] as? NSNumber)?.intValue ?? 0
                            metrics.completionTokens = (object["eval_count"] as? NSNumber)?.intValue ?? 0
                            metrics.promptEvalMilliseconds = nanosToMillis(object["prompt_eval_duration"])
                            metrics.evalMilliseconds = nanosToMillis(object["eval_duration"])
                            metrics.loadMilliseconds = nanosToMillis(object["load_duration"])
                            metrics.totalMilliseconds = nanosToMillis(object["total_duration"])
                            metrics.timeToFirstTokenMilliseconds =
                                ((firstTokenAt ?? Clock.now()) - start) * 1000
                            chunk.metrics = metrics
                        }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Yields one raw NDJSON line per element. Decoding happens in the consumer
    /// so nothing non-`Sendable` crosses the stream boundary.
    private func rawStream(path: String, body: [String: Any]) throws -> AsyncThrowingStream<Data, Error> {
        let request = try makeRequest(path: path, body: body)
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        var message = ""
                        for try await line in bytes.lines { message += line }
                        throw OllamaError.httpStatus(http.statusCode, message)
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch let error as URLError where error.code == .cannotConnectToHost {
                    continuation.finish(throwing: OllamaError.serverUnreachable)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func decode(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func makeRequest(
        path: String,
        body: [String: Any]?,
        timeout: TimeInterval? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        if let timeout {
            guard timeout.isFinite, timeout > 0 else { throw URLError(.timedOut) }
            request.timeoutInterval = timeout
        }
        request.httpMethod = body == nil ? "GET" : "POST"
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func get(_ path: String, timeout: TimeInterval? = nil) async throws -> Data {
        let request = try makeRequest(path: path, body: nil, timeout: timeout)
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                throw OllamaError.httpStatus(http.statusCode, String(decoding: data, as: UTF8.self))
            }
            return data
        } catch let error as URLError {
            throw error.code == .cannotConnectToHost ? OllamaError.serverUnreachable : error
        }
    }

    @discardableResult
    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        let request = try makeRequest(path: path, body: body)
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                throw OllamaError.httpStatus(http.statusCode, String(decoding: data, as: UTF8.self))
            }
            return data
        } catch let error as URLError {
            throw error.code == .cannotConnectToHost ? OllamaError.serverUnreachable : error
        }
    }

    private func nanosToMillis(_ value: Any?) -> Double {
        guard let number = value as? NSNumber else { return 0 }
        return number.doubleValue / 1_000_000
    }
}

enum OllamaPullError: LocalizedError, Equatable {
    case incomplete(String)

    var errorDescription: String? {
        switch self {
        case .incomplete(let model):
            return "Der Download von „\(model)“ wurde beendet, ohne als vollständig bestätigt zu werden."
        }
    }
}
