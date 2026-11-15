import Foundation

// Minimal OpenAI-compatible wire types. We decode the fields we use and stay
// lenient about the rest so a wide range of clients work — but tool-calling
// fields are validated strictly (see `ChatCompletionRequest.validate`).

// MARK: - Arbitrary JSON (for tool `parameters` schemas)

/// A decoded JSON value, used to carry a tool's `parameters` JSON Schema through
/// verbatim so we can re-serialize it into the model prompt.
enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported JSON value in `parameters`")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// A Foundation object suitable for `JSONSerialization`.
    private var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .object(let o): return o.mapValues(\.foundation)
        }
    }

    /// Compact JSON string for embedding in the model prompt.
    var jsonString: String {
        guard JSONSerialization.isValidJSONObject(foundation),
              let data = try? JSONSerialization.data(withJSONObject: foundation),
              let s = String(data: data, encoding: .utf8) else {
            // Scalars aren't valid top-level JSONSerialization objects; fall back.
            switch self {
            case .string(let s): return "\"\(s)\""
            case .bool(let b): return b ? "true" : "false"
            case .number(let n): return String(n)
            case .null: return "null"
            default: return "{}"
            }
        }
        return s
    }
}

// MARK: - Tools (request)

struct Tool: Decodable {
    let type: String
    let function: FunctionDef

    struct FunctionDef: Decodable {
        let name: String
        let description: String?
        let parameters: JSONValue?
        let strict: Bool?
    }
}

/// OpenAI `tool_choice`: a string ("auto"/"none"/"required") or an object
/// forcing a specific function.
enum ToolChoice: Decodable {
    case auto
    case none
    case required
    case function(name: String)

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            switch s {
            case "auto": self = .auto
            case "none": self = .none
            case "required": self = .required
            default:
                throw ProxyRequestError("`tool_choice` string must be one of \"auto\", \"none\", \"required\" (got \"\(s)\")")
            }
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        guard type == "function" else {
            throw ProxyRequestError("`tool_choice.type` must be \"function\" (got \"\(type)\")")
        }
        let fn = try c.decode(FunctionRef.self, forKey: .function)
        self = .function(name: fn.name)
    }

    private enum CodingKeys: String, CodingKey { case type, function }
    private struct FunctionRef: Decodable { let name: String }
}

// MARK: - Tool calls (both request assistant messages and responses)

/// A function tool call. `arguments` is a JSON-encoded STRING, per OpenAI.
struct ToolCall: Codable {
    let id: String
    let type: String
    let function: Function

    struct Function: Codable {
        let name: String
        let arguments: String
    }

    init(id: String, name: String, arguments: String) {
        self.id = id
        self.type = "function"
        self.function = Function(name: name, arguments: arguments)
    }
}

// MARK: - Request

struct ChatCompletionRequest: Decodable {
    let model: String?
    let messages: [ChatMessage]
    let stream: Bool?
    let tools: [Tool]?
    let tool_choice: ToolChoice?
    /// Claude only: OpenAI's `reasoning_effort`. Absent keeps the CLI default.
    let reasoning_effort: String?
    /// Claude only: keep a booted Claude CLI waiting for the next request.
    let keep_warm: Bool?

    /// Semantic validation beyond what Codable enforces. Throws a
    /// `ProxyRequestError` (→ HTTP 400) with a precise, client-facing message.
    /// With `acceptsOtherModels`, a model id outside the list is passed to the
    /// backend, which reports whether it exists. Another provider's alias is
    /// still refused.
    func validate(allowedModels: [String] = ChatModel.allowedIDs, acceptsOtherModels: Bool = false) throws {
        let allowed = allowedModels.joined(separator: ", ")
        guard let model, !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ProxyRequestError("`model` is required; allowed models: \(allowed)")
        }
        if acceptsOtherModels {
            guard allowedModels.contains(model)
                    || (ChatModel(rawValue: model) == nil && Self.isPassableModelID(model)) else {
                throw ProxyRequestError("`model` \"\(model)\" is not a valid model id for this endpoint")
            }
        } else {
            guard allowedModels.contains(model) else {
                throw ProxyRequestError("`model` \"\(model)\" is not supported; allowed models: \(allowed)")
            }
        }
        guard !messages.isEmpty else {
            throw ProxyRequestError("`messages` must be a non-empty array")
        }
        let validRoles: Set<String> = ["system", "user", "assistant", "tool"]
        for (i, m) in messages.enumerated() {
            guard validRoles.contains(m.role) else {
                throw ProxyRequestError("messages[\(i)].role must be one of system|user|assistant|tool (got \"\(m.role)\")")
            }
            if m.role == "tool", (m.toolCallId ?? "").isEmpty {
                throw ProxyRequestError("messages[\(i)] has role \"tool\" but is missing `tool_call_id`")
            }
            for (j, tc) in (m.toolCalls ?? []).enumerated() {
                if tc.id.isEmpty {
                    throw ProxyRequestError("messages[\(i)].tool_calls[\(j)].id must not be empty")
                }
                if tc.type != "function" {
                    throw ProxyRequestError("messages[\(i)].tool_calls[\(j)].type must be \"function\" (got \"\(tc.type)\")")
                }
                if tc.function.name.isEmpty {
                    throw ProxyRequestError("messages[\(i)].tool_calls[\(j)].function.name must not be empty")
                }
            }
        }
        for (i, t) in (tools ?? []).enumerated() {
            guard t.type == "function" else {
                throw ProxyRequestError("tools[\(i)].type must be \"function\" (got \"\(t.type)\"); only function tools are supported")
            }
            if t.function.name.isEmpty {
                throw ProxyRequestError("tools[\(i)].function.name must not be empty")
            }
        }
        if case .function(let name) = tool_choice {
            let known = Set((tools ?? []).map { $0.function.name })
            guard known.contains(name) else {
                throw ProxyRequestError("`tool_choice` names function \"\(name)\", which is not present in `tools`")
            }
        }
    }
}

extension ChatCompletionRequest {
    /// A model id that can safely become the CLI's `--model` value: it cannot
    /// start with `-`, so it is never read as a flag.
    static func isPassableModelID(_ id: String) -> Bool {
        id.count <= 128 && id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:\[\]-]*$"#, options: .regularExpression) != nil
    }

    var effort: ReasoningEffort? { reasoning_effort.flatMap(ReasoningEffort.init(rawValue:)) }

    /// The Claude endpoint acts on `reasoning_effort`, so an unknown level is
    /// an error there rather than silently ignored.
    func validateClaudeOptions() throws {
        if let reasoning_effort, ReasoningEffort(rawValue: reasoning_effort) == nil {
            let levels = ReasoningEffort.allCases.map(\.rawValue).joined(separator: ", ")
            throw ProxyRequestError("`reasoning_effort` must be one of \(levels) (got \"\(reasoning_effort)\")")
        }
    }
}

/// OpenAI's `reasoning_effort` levels.
enum ReasoningEffort: String, CaseIterable, Sendable {
    case off = "none", minimal, low, medium, high
}

struct ChatMessage: Decodable {
    let role: String
    let content: String?        // nil when absent/null (e.g. assistant tool call)
    let parts: [MessagePart]    // content in order, including images; empty when content is nil
    let name: String?           // optional; function name on some tool messages
    let toolCalls: [ToolCall]?  // assistant tool calls being replayed
    let toolCallId: String?     // links a role:"tool" result to its call

    private enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)

        // `content` is a string, an array of typed parts (vision/multimodal), or
        // null/absent. `content` keeps only the text — every existing text path
        // reads it — while `parts` keeps text and images in their original order.
        // nil is preserved so tool-call assistant turns encode correctly.
        if !c.contains(.content) || ((try? c.decodeNil(forKey: .content)) == true) {
            content = nil
            parts = []
        } else if let text = try? c.decode(String.self, forKey: .content) {
            content = text
            parts = [.text(text)]
        } else {
            let decoded: [ContentPart]
            do {
                decoded = try c.decode([ContentPart].self, forKey: .content)
            } catch let e as ProxyRequestError {
                throw e
            } catch {
                throw ProxyRequestError("messages: `content` must be a string, an array of content parts, or null")
            }
            parts = decoded.map(\.part)
            content = parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        }
    }

    /// One content part in any of the spellings clients use: OpenAI
    /// (`image_url`, object or bare string), Anthropic (`image` + `source`), and
    /// Responses (`input_text` / `input_image`). An image we cannot forward is a
    /// hard error — dropping it would return a confident answer about a picture
    /// the model never saw.
    private struct ContentPart: Decodable {
        let part: MessagePart

        private enum CodingKeys: String, CodingKey { case type, text, image_url, source }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decodeIfPresent(String.self, forKey: .type) ?? "text"
            switch type {
            case "text", "input_text", "output_text":
                part = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
            case "image_url", "input_image":
                guard let ref = try c.decodeIfPresent(ImageURL.self, forKey: .image_url) else {
                    throw ProxyRequestError("content part of type \"\(type)\" is missing `image_url`")
                }
                part = .image(try ImageBlock(url: ref.url))
            case "image":
                guard let source = try c.decodeIfPresent(ImageSource.self, forKey: .source) else {
                    throw ProxyRequestError("content part of type \"image\" is missing `source`")
                }
                part = .image(try source.imageBlock())
            default:
                throw ProxyRequestError("unsupported content part type \"\(type)\"; supported: text, input_text, image_url, input_image, image")
            }
        }
    }

    /// `{"image_url": {"url": "…"}}` and the bare-string `{"image_url": "…"}`.
    private struct ImageURL: Decodable {
        let url: String

        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                url = s
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
        }
        private enum CodingKeys: String, CodingKey { case url }
    }

    private struct ImageSource: Decodable {
        let type: String?
        let media_type: String?
        let data: String?
        let url: String?

        func imageBlock() throws -> ImageBlock {
            switch type ?? "base64" {
            case "base64":
                guard let media_type, let data else {
                    throw ProxyRequestError("image `source` of type \"base64\" requires `media_type` and `data`")
                }
                return try ImageBlock(mediaType: media_type, base64: data)
            case "url":
                guard let url else {
                    throw ProxyRequestError("image `source` of type \"url\" requires `url`")
                }
                return try ImageBlock(url: url)
            default:
                throw ProxyRequestError("image `source.type` must be \"base64\" or \"url\" (got \"\(type ?? "")\")")
            }
        }
    }
}

// MARK: - Images

/// An image extracted from a multimodal content part, in the two forms the CLI
/// accepts. Inline data is validated at decode time (see `ChatMessage`); a URL is
/// passed through and fetched upstream, which reports its own failures.
struct ImageBlock: Equatable {
    enum Source: Equatable {
        case base64(mediaType: String, data: String)
        case url(String)
    }
    let source: Source

    static let supportedMediaTypes = ["image/gif", "image/jpeg", "image/png", "image/webp"]

    init(mediaType: String, base64: String) throws {
        let type = mediaType.lowercased().trimmingCharacters(in: .whitespaces)
        guard Self.supportedMediaTypes.contains(type) else {
            throw ProxyRequestError("image media type \"\(mediaType)\" is not supported; use one of \(Self.supportedMediaTypes.joined(separator: ", "))")
        }
        // Strict decoding, with line wrapping as the one tolerated deviation:
        // `.ignoreUnknownCharacters` would silently accept arbitrary junk as an
        // empty image, which is the exact failure this feature exists to remove.
        var payload = base64
        if Data(base64Encoded: payload) == nil {
            payload = payload.filter { !$0.isWhitespace }
        }
        guard let decoded = Data(base64Encoded: payload), !decoded.isEmpty else {
            throw ProxyRequestError("image data is not valid base64")
        }
        source = .base64(mediaType: type, data: payload)
    }

    /// Accepts a `data:` URL (decoded inline) or an `http(s)` URL (passed through).
    init(url: String) throws {
        if url.hasPrefix("data:") {
            guard let comma = url.firstIndex(of: ",") else {
                throw ProxyRequestError("malformed data URL: no \",\" separating the header from the payload")
            }
            let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
            guard header.hasSuffix(";base64") else {
                throw ProxyRequestError("data URLs must be base64-encoded (expected `data:<media type>;base64,<payload>`)")
            }
            self = try ImageBlock(mediaType: String(header.dropLast(7)),
                                  base64: String(url[url.index(after: comma)...]))
            return
        }
        guard url.hasPrefix("https://") || url.hasPrefix("http://") else {
            throw ProxyRequestError("image URL must be a `data:` URL or an http(s) URL")
        }
        source = .url(url)
    }
}

/// One piece of a message's content, in the order the client sent it. Order is
/// semantically load-bearing when text labels refer to adjacent images.
enum MessagePart: Equatable {
    case text(String)
    case image(ImageBlock)
}

// MARK: - Responses (Encodable)

struct ModelListResponse: Encodable {
    let object = "list"
    let data: [ModelEntry]
}

struct ModelEntry: Encodable {
    let id: String
    let object = "model"
    let created: Int
    let owned_by: String
}

struct ChatCompletionResponse: Encodable {
    let id: String
    let object = "chat.completion"
    let created: Int
    let model: String
    let choices: [Choice]

    struct Choice: Encodable {
        let index = 0
        let message: Message
        let finish_reason: String
    }

    struct Message: Encodable {
        let content: String?
        let tool_calls: [ToolCall]?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("assistant", forKey: .role)
            // Always include `content` (null when a tool call) — clients expect the key.
            if let content { try c.encode(content, forKey: .content) }
            else { try c.encodeNil(forKey: .content) }
            try c.encodeIfPresent(tool_calls, forKey: .tool_calls)
        }
        private enum CodingKeys: String, CodingKey { case role, content, tool_calls }
    }
}

struct ChatCompletionChunk: Encodable {
    let id: String
    let object = "chat.completion.chunk"
    let created: Int
    let model: String
    let choices: [Choice]

    struct Choice: Encodable {
        let index = 0
        let delta: Delta
        let finish_reason: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(index, forKey: .index)
            try c.encode(delta, forKey: .delta)
            // OpenAI emits the key on every chunk: null while streaming, then
            // "stop"/"tool_calls" on the terminal chunk. Keep both providers
            // on that exact shape instead of omitting the nil value.
            if let finish_reason { try c.encode(finish_reason, forKey: .finish_reason) }
            else { try c.encodeNil(forKey: .finish_reason) }
        }

        private enum CodingKeys: String, CodingKey { case index, delta, finish_reason }
    }

    struct Delta: Encodable {
        let role: String?
        let content: String?
        let tool_calls: [ToolCallDelta]?

        init(role: String? = nil, content: String? = nil, tool_calls: [ToolCallDelta]? = nil) {
            self.role = role
            self.content = content
            self.tool_calls = tool_calls
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(role, forKey: .role)
            try c.encodeIfPresent(content, forKey: .content)
            try c.encodeIfPresent(tool_calls, forKey: .tool_calls)
        }
        private enum CodingKeys: String, CodingKey { case role, content, tool_calls }
    }

    /// Streaming tool-call delta. We emit each call as one complete delta with an
    /// `index` — clients accumulate by index, and a single full delta is valid.
    struct ToolCallDelta: Encodable {
        let index: Int
        let id: String
        let type = "function"
        let function: Function
        struct Function: Encodable { let name: String; let arguments: String }
    }
}

// MARK: - Errors

struct OpenAIError: Encodable {
    struct Body: Encodable {
        let message: String
        let type: String
        let param: String?
        let code: String?
    }
    let error: Body
    init(_ message: String, type: String = "proxy_error", param: String? = nil, code: String? = nil) {
        self.error = Body(message: message, type: type, param: param, code: code)
    }
}

/// Thrown during request decoding/validation; surfaced to the client as HTTP 400.
struct ProxyRequestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum OpenAIIDs {
    static func chatID() -> String { "chatcmpl-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)) }
    static func toolCallID() -> String { "call_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)) }
    static var now: Int { Int(Date().timeIntervalSince1970) }
}
