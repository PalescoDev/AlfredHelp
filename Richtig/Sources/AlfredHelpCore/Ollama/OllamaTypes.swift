import Foundation

public struct ChatMessage: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable {
        case system, user, assistant
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ text: String) -> ChatMessage { .init(role: .system, content: text) }
    public static func user(_ text: String) -> ChatMessage { .init(role: .user, content: text) }
    public static func assistant(_ text: String) -> ChatMessage { .init(role: .assistant, content: text) }
}

/// Sampling and context settings passed straight through to Ollama.
public struct GenerationOptions: Sendable, Equatable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    /// Hard cap on generated tokens – the main latency lever.
    public var numPredict: Int?
    /// Context window. Larger costs prompt-processing time on every call.
    public var numCtx: Int?
    public var repeatPenalty: Double?
    public var stop: [String]?
    public var seed: Int?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        numPredict: Int? = nil,
        numCtx: Int? = nil,
        repeatPenalty: Double? = nil,
        stop: [String]? = nil,
        seed: Int? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.numPredict = numPredict
        self.numCtx = numCtx
        self.repeatPenalty = repeatPenalty
        self.stop = stop
        self.seed = seed
    }

    var payload: [String: Any] {
        var dictionary: [String: Any] = [:]
        if let temperature { dictionary["temperature"] = temperature }
        if let topP { dictionary["top_p"] = topP }
        if let topK { dictionary["top_k"] = topK }
        if let numPredict { dictionary["num_predict"] = numPredict }
        if let numCtx { dictionary["num_ctx"] = numCtx }
        if let repeatPenalty { dictionary["repeat_penalty"] = repeatPenalty }
        if let stop, !stop.isEmpty { dictionary["stop"] = stop }
        if let seed { dictionary["seed"] = seed }
        return dictionary
    }
}

/// Response format constraint. `schema` carries the JSON Schema as text so the
/// value stays `Sendable`; Ollama then constrains decoding to match it, which
/// removes a whole class of "model answered in prose instead of JSON" failures.
public enum ResponseFormat: Sendable, Equatable {
    case free
    case json
    case schema(String)

    var payload: Any? {
        switch self {
        case .free:
            return nil
        case .json:
            return "json"
        case .schema(let text):
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                return "json"
            }
            return object
        }
    }

    /// Builds a flat object schema. `properties` maps a field name to its JSON
    /// Schema fragment; every field is required, which is what makes the local
    /// models fill them in reliably.
    public static func object(_ properties: [(name: String, schema: String)]) -> ResponseFormat {
        let fields = properties
            .map { "\"\($0.name)\":\($0.schema)" }
            .joined(separator: ",")
        let required = properties
            .map { "\"\($0.name)\"" }
            .joined(separator: ",")
        return .schema(
            "{\"type\":\"object\",\"properties\":{\(fields)},\"required\":[\(required)]}"
        )
    }
}

/// Timing information Ollama reports with the final chunk of a stream.
public struct GenerationMetrics: Sendable, Equatable {
    public var promptTokens: Int = 0
    public var completionTokens: Int = 0
    public var promptEvalMilliseconds: Double = 0
    public var evalMilliseconds: Double = 0
    public var loadMilliseconds: Double = 0
    public var totalMilliseconds: Double = 0
    /// Measured client-side: time until the first visible token arrived.
    public var timeToFirstTokenMilliseconds: Double = 0

    public var tokensPerSecond: Double {
        guard evalMilliseconds > 0 else { return 0 }
        return Double(completionTokens) / (evalMilliseconds / 1000)
    }

    public init() {}
}

/// One piece of a streaming response.
public struct StreamChunk: Sendable {
    public var text: String = ""
    /// Reasoning content for models that expose it separately (gpt-oss, qwen3…).
    public var thinking: String = ""
    public var isDone: Bool = false
    public var metrics: GenerationMetrics?
}

public struct OllamaModel: Sendable, Identifiable, Hashable {
    public let name: String
    public let sizeBytes: Int64
    public let parameterSize: String
    public let quantization: String
    public let family: String
    public let modifiedAt: Date?

    public var id: String { name }

    /// Parsed parameter count in billions, or `nil` when Ollama does not report it.
    public var parameterBillions: Double? {
        let trimmed = parameterSize.trimmingCharacters(in: .whitespaces).uppercased()
        guard let last = trimmed.last else { return nil }
        let numberPart = String(trimmed.dropLast())
        guard let value = Double(numberPart.replacingOccurrences(of: ",", with: ".")) else {
            return Double(trimmed.replacingOccurrences(of: ",", with: "."))
        }
        switch last {
        case "B": return value
        case "M": return value / 1000
        default: return nil
        }
    }
}

/// Whether a model understands the `think` request field. Sending it to a
/// model without a reasoning mode makes Ollama reject the whole request.
public func modelSupportsThinking(_ name: String) -> Bool {
    let lowered = name.lowercased()
    return lowered.contains("qwen3") || lowered.contains("gpt-oss")
        || lowered.contains("deepseek-r1") || lowered.contains("magistral")
}

public enum OllamaError: LocalizedError {
    case serverUnreachable
    case httpStatus(Int, String)
    case decoding(String)
    case modelMissing(String)

    public var errorDescription: String? {
        switch self {
        case .serverUnreachable:
            return "Ollama ist nicht erreichbar. Läuft der lokale Dienst?"
        case .httpStatus(let code, let body):
            return "Ollama antwortete mit HTTP \(code): \(body.prefix(200))"
        case .decoding(let detail):
            return "Antwort von Ollama nicht lesbar: \(detail)"
        case .modelMissing(let name):
            return "Das Modell „\(name)“ ist lokal nicht installiert."
        }
    }
}
