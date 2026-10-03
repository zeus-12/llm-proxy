import Foundation
import Network

enum ToolStreamClassification: Equatable {
    case undecided
    case text
    case toolCandidate
}

/// Tool calls arrive as a JSON envelope, so only that small ambiguous prefix
/// must be held back. Ordinary prose can be forwarded as soon as its first
/// non-whitespace character proves it is not a tool envelope.
enum ToolStreamClassifier {
    static func classify(_ prefix: String) -> ToolStreamClassification {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return .undecided }
        return first == "{" || first == "`" ? .toolCandidate : .text
    }
}

/// Reads one HTTP request off a connection, routes it, writes the response, and
/// closes. One connection = one request (`Connection: close`).
final class HTTPConnection {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let backend: ChatBackend
    private var buffer = Data()
    /// Set once the request's `Origin` has been checked, and echoed back in the
    /// CORS headers. Nil means no header is sent, so a browser cannot read the
    /// response even if it managed to issue the request.
    private var echoedOrigin: String?
    /// Keeps this object alive for the duration of the connection. The
    /// NWConnection's callbacks capture `self` weakly, so without this strong
    /// self-reference the handler would deallocate the moment `accept()`
    /// returns. Cleared in `close()`.
    private var selfRetain: HTTPConnection?

    init(conn: NWConnection, queue: DispatchQueue, backend: ChatBackend) {
        self.conn = conn
        self.queue = queue
        self.backend = backend
    }

    func start() {
        selfRetain = self
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    // MARK: - Reading

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }

            if let request = HTTPRequest.parse(self.buffer) {
                self.route(request)
                return
            }
            if error != nil || isComplete {
                self.close()
                return
            }
            self.receive()
        }
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest) {
        // Checked ahead of everything, preflight included: refusing the preflight
        // is what stops the browser from ever sending the real request. API-key
        // protection is optional, so this — not the key — is what keeps a page
        // the user happens to have open from spending their subscription.
        let origin = OriginPolicy.decide(originHeader: request.headers["origin"])
        guard !origin.isDenied else {
            writeError(status: 403,
                       message: "This origin may not call the proxy. Clients that send no "
                              + "`Origin` header, such as curl and the OpenAI SDKs, are unaffected.",
                       type: "invalid_request_error")
            return
        }
        echoedOrigin = origin.echoedOrigin

        // CORS preflight so an allowlisted browser client works.
        if request.method == "OPTIONS" {
            writeRaw(status: 204, headers: corsHeaders, body: Data())
            return
        }

        // Liveness stays open so a client can check the endpoint is up before it
        // has been given a key; it exposes nothing but the model list.
        let isPublic = request.path == "/" || request.path == "/health"
        if !isPublic, !APIKey.authorizes(APIKey.presented(headers: request.headers), for: backend.keyScope) {
            writeError(status: 401,
                       message: "Invalid API key. Send it as "
                              + "`Authorization: Bearer <api-key>`.",
                       type: "invalid_request_error")
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/models"):
            handleModels()
        case ("POST", "/v1/chat/completions"):
            handleChat(request)
        case ("GET", "/"), ("GET", "/health"):
            writeJSON(status: 200, object: ["status": "ok", "provider": backend.rawValue,
                                            "models": backend.allowedIDs])
        default:
            writeError(status: 404, message: "Not found: \(request.method) \(request.path)")
        }
    }

    private func handleModels() {
        let response = ModelListResponse(data: backend.models.map {
            ModelEntry(id: $0.rawValue, created: OpenAIIDs.now, owned_by: $0.owner)
        })
        writeEncodable(status: 200, response)
    }

    private func handleChat(_ request: HTTPRequest) {
        guard let body = request.body else {
            writeError(status: 400, message: "Missing request body")
            return
        }
        let decoded: ChatCompletionRequest
        do {
            decoded = try JSONDecoder().decode(ChatCompletionRequest.self, from: body)
            try decoded.validate(allowedModels: backend.allowedIDs)
        } catch let e as ProxyRequestError {
            writeError(status: 400, message: e.message)
            return
        } catch let e as DecodingError {
            writeError(status: 400, message: "Invalid request body: \(Self.describe(e))")
            return
        } catch {
            writeError(status: 400, message: "Invalid request body: \(error.localizedDescription)")
            return
        }

        let wantsStream = decoded.stream ?? false
        // `validate()` has already guaranteed `model` is present and allowed.
        let model = decoded.model ?? ChatModel.sonnet.rawValue

        // Tool calling: a JSON-looking response must be inspected as a complete
        // envelope, but ordinary prose can still stream through immediately.
        let toolsActive = ClaudeBackend.functionsActive(tools: decoded.tools, toolChoice: decoded.tool_choice)

        guard let chatModel = ChatModel(rawValue: model), chatModel.backend == backend else {
            writeError(status: 400, message: "Unsupported model \(model)")
            return
        }

        let result: ChatStreamResult
        do {
            switch backend {
            case .claude:
                result = try ClaudeBackend.stream(model: chatModel.cliAlias,
                                                  messages: decoded.messages,
                                                  tools: decoded.tools,
                                                  toolChoice: decoded.tool_choice)
            case .codex:
                result = try CodexBackend.stream(model: chatModel.cliAlias,
                                                 messages: decoded.messages,
                                                 tools: decoded.tools,
                                                 toolChoice: decoded.tool_choice)
            }
        } catch {
            writeError(status: 502, message: error.localizedDescription)
            return
        }

        if toolsActive && wantsStream {
            streamToolAware(result, model: model)
        } else if toolsActive {
            collectToolAware(result, model: model)
        } else if wantsStream {
            streamChat(result, model: model)
        } else {
            collectChat(result, model: model)
        }
    }

    /// Non-streaming tool-aware responses still need the complete output before
    /// choosing between a message and an OpenAI-compatible tool call.
    private func collectToolAware(_ result: ChatStreamResult, model: String) {
        Task {
            var text = ""
            do {
                for try await delta in result.deltas { text += delta }
            } catch {
                // Nothing has been written yet, so a normal error response is fine
                // even if the client asked to stream.
                writeError(status: 502, message: error.localizedDescription)
                return
            }
            let calls = ClaudeBackend.parseToolCalls(text)
            let message: ChatCompletionResponse.Message
            let finish: String
            if let calls {
                message = .init(content: nil, tool_calls: calls)
                finish = "tool_calls"
            } else {
                message = .init(content: text, tool_calls: nil)
                finish = "stop"
            }
            let response = ChatCompletionResponse(
                id: OpenAIIDs.chatID(), created: OpenAIIDs.now, model: model,
                choices: [.init(message: message, finish_reason: finish)]
            )
            writeEncodable(status: 200, response)
        }
    }

    /// Streams prose immediately even when the client supplied tools. Only a
    /// JSON/fenced prefix remains buffered until it can be parsed as a tool call.
    private func streamToolAware(_ result: ChatStreamResult, model: String) {
        let id = OpenAIIDs.chatID()
        let created = OpenAIIDs.now
        writeRaw(status: 200, headers: sseHeaders, body: Data(), keepOpen: true)

        Task {
            sendChunk(id: id, created: created, model: model,
                      delta: .init(role: "assistant"), finish: nil)

            var buffered = ""
            var classification = ToolStreamClassification.undecided
            do {
                for try await delta in result.deltas {
                    if classification == .text {
                        sendChunk(id: id, created: created, model: model,
                                  delta: .init(content: delta), finish: nil)
                        continue
                    }

                    buffered += delta
                    classification = ToolStreamClassifier.classify(buffered)
                    if classification == .text {
                        sendChunk(id: id, created: created, model: model,
                                  delta: .init(content: buffered), finish: nil)
                        buffered = ""
                    }
                }

                if classification == .toolCandidate,
                   let calls = ClaudeBackend.parseToolCalls(buffered) {
                    let deltas = calls.enumerated().map { index, call in
                        ChatCompletionChunk.ToolCallDelta(
                            index: index, id: call.id,
                            function: .init(name: call.function.name,
                                            arguments: call.function.arguments)
                        )
                    }
                    sendChunk(id: id, created: created, model: model,
                              delta: .init(tool_calls: deltas), finish: nil)
                    sendChunk(id: id, created: created, model: model,
                              delta: .init(), finish: "tool_calls")
                } else {
                    if !buffered.isEmpty {
                        sendChunk(id: id, created: created, model: model,
                                  delta: .init(content: buffered), finish: nil)
                    }
                    sendChunk(id: id, created: created, model: model,
                              delta: .init(), finish: "stop")
                }
            } catch {
                let payload = OpenAIError(error.localizedDescription)
                if let data = try? JSONEncoder().encode(payload) {
                    sendSSE(Data("data: ".utf8) + data + Data("\n\n".utf8))
                }
            }
            conn.send(content: Data("data: [DONE]\n\n".utf8), completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
        }
    }

    // MARK: - Streaming (SSE)

    private func streamChat(_ result: ChatStreamResult, model: String) {
        let id = OpenAIIDs.chatID()
        let created = OpenAIIDs.now
        writeRaw(status: 200, headers: sseHeaders, body: Data(), keepOpen: true)

        Task {
            // First chunk announces the assistant role.
            sendChunk(id: id, created: created, model: model, role: "assistant", content: nil, finish: nil)
            do {
                for try await delta in result.deltas {
                    sendChunk(id: id, created: created, model: model, role: nil, content: delta, finish: nil)
                }
                sendChunk(id: id, created: created, model: model, role: nil, content: nil, finish: "stop")
            } catch {
                // Mid-stream failure: surface it as an SSE error event, then end.
                let payload = OpenAIError(error.localizedDescription)
                if let data = try? JSONEncoder().encode(payload) {
                    sendSSE(Data("data: ".utf8) + data + Data("\n\n".utf8))
                }
            }
            // Close only after the final bytes have actually flushed — calling
            // cancel() right after queueing a send races and drops the data.
            conn.send(content: Data("data: [DONE]\n\n".utf8), completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
        }
    }

    private func sendChunk(id: String, created: Int, model: String, role: String?, content: String?, finish: String?) {
        sendChunk(id: id, created: created, model: model,
                  delta: .init(role: role, content: content), finish: finish)
    }

    private func sendChunk(id: String, created: Int, model: String,
                           delta: ChatCompletionChunk.Delta, finish: String?) {
        let chunk = ChatCompletionChunk(
            id: id, created: created, model: model,
            choices: [.init(delta: delta, finish_reason: finish)]
        )
        guard let data = try? JSONEncoder().encode(chunk) else { return }
        sendSSE(Data("data: ".utf8) + data + Data("\n\n".utf8))
    }

    private func sendSSE(_ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Non-streaming

    private func collectChat(_ result: ChatStreamResult, model: String) {
        Task {
            var text = ""
            do {
                for try await delta in result.deltas { text += delta }
            } catch {
                writeError(status: 502, message: error.localizedDescription)
                return
            }
            let response = ChatCompletionResponse(
                id: OpenAIIDs.chatID(), created: OpenAIIDs.now, model: model,
                choices: [.init(message: .init(content: text, tool_calls: nil), finish_reason: "stop")]
            )
            writeEncodable(status: 200, response)
        }
    }

    /// Human-readable summary of a JSON decoding failure, including the key path,
    /// so clients get an actionable 400 instead of "Invalid request body".
    private static func describe(_ error: DecodingError) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let ctx):
            let p = path(ctx)
            return "missing required field `\(key.stringValue)`\(p.isEmpty ? "" : " at \(p)")"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            let p = path(ctx)
            return "\(ctx.debugDescription)\(p.isEmpty ? "" : " at \(p)")"
        case .dataCorrupted(let ctx):
            let p = path(ctx)
            return "\(ctx.debugDescription)\(p.isEmpty ? "" : " at \(p)")"
        @unknown default:
            return error.localizedDescription
        }
    }

    // MARK: - Writing helpers

    /// `Access-Control-Allow-Origin` is only ever the one allowlisted origin. A
    /// wildcard would let every page the user visits read this endpoint's
    /// responses, which the optional API key no longer prevents.
    private var corsHeaders: [String: String] {
        var headers = [
            "Vary": "Origin",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key"
        ]
        if let echoedOrigin { headers["Access-Control-Allow-Origin"] = echoedOrigin }
        return headers
    }

    private var sseHeaders: [String: String] {
        var h = corsHeaders
        h["Content-Type"] = "text/event-stream"
        h["Cache-Control"] = "no-cache"
        return h
    }

    private func writeEncodable<T: Encodable>(status: Int, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else {
            writeError(status: 500, message: "Failed to encode response")
            return
        }
        var headers = corsHeaders
        headers["Content-Type"] = "application/json"
        writeRaw(status: status, headers: headers, body: data)
    }

    private func writeJSON(status: Int, object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        var headers = corsHeaders
        headers["Content-Type"] = "application/json"
        writeRaw(status: status, headers: headers, body: data)
    }

    private func writeError(status: Int, message: String, type: String = "proxy_error") {
        writeEncodable(status: status, OpenAIError(message, type: type))
    }

    /// Write a full HTTP response. When `keepOpen` is true (SSE) we leave the
    /// connection open for subsequent `sendSSE` writes.
    private func writeRaw(status: Int, headers: [String: String], body: Data, keepOpen: Bool = false) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var headers = headers
        if !keepOpen {
            headers["Content-Length"] = String(body.count)
        }
        headers["Connection"] = "close"
        for (k, v) in headers {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(body)

        conn.send(content: data, completion: .contentProcessed { [weak self] _ in
            if !keepOpen { self?.close() }
        })
    }

    private func close() {
        conn.cancel()
        selfRetain = nil
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "OK"
        }
    }
}
