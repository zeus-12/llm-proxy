import Foundation

/// Drives `claude -p` headlessly and turns its `stream-json` output into a
/// stream of plain text deltas. This is the only place that touches the CLI.
///
/// Honesty notes baked into the design:
///  - We fully override the system prompt so the Claude Code agent persona is
///    replaced by a plain-assistant prompt. We cannot remove the ~12k tokens of
///    cached harness context, so every call has that input-token floor.
///  - The CLI is locked down to a plain text generator: no tools, no MCP
///    servers, no skills, no user settings, and a scratch working directory. A
///    chat proxy must never let a caller read files or run commands on the host.
enum ClaudeBackend {

    /// Everything that stops the CLI from acting on the host. `--tools ""` is the
    /// load-bearing one: it is a whitelist, so it also covers tools a deny-list
    /// would miss. `--disallowedTools` stays as a second layer over the built-ins.
    private static func isolationArguments(allowing tools: [String]) -> [String] {
        [
            "--tools", tools.joined(separator: ","),  // whitelist; empty means none
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,  // no MCP tools
            "--disable-slash-commands",                     // no skills; `/name` would load one
            "--safe-mode",                                  // no CLAUDE.md, hooks, plugins, agents
            "--no-session-persistence",                     // API traffic stays out of session history
            "--settings", permissionSettings(allowing: tools),
            "--disallowedTools"
        ] + disallowedTools
    }

    /// The only built-in tool the model may use. Fetching a public page is the one
    /// capability that acts on the network rather than on this machine.
    static let webFetch = "WebFetch"

    /// A caller's functions get no built-in tool beside them. Given one, the model
    /// invokes the caller's function natively, the CLI answers "No such tool
    /// available", and the model tells the user the function doesn't exist.
    static func allowedTools(callerHasFunctions: Bool) -> [String] {
        callerHasFunctions ? [] : [webFetch]
    }

    /// Hosts WebFetch must never reach. The endpoint is unauthenticated and
    /// loopback-bound, so without these a caller could use this machine to reach
    /// services that are only reachable *from* this machine.
    private static let blockedFetchHosts = [
        "localhost", "127.0.0.1", "0.0.0.0", "[::1]", "169.254.169.254"
    ]

    /// Read denial is what stops `@path` in message text becoming a file read: the
    /// CLI performs that expansion before the model runs, with no tool call, so
    /// tool settings alone never see it. All three globs are needed and mean
    /// different things — `//**` absolute, `~/**` home, `**` working directory —
    /// and any one alone leaves the other two readable.
    static func permissionSettings(allowing allow: [String]) -> String {
        let deny = ["Read(//**)", "Read(~/**)", "Read(**)"]
            + blockedFetchHosts.map { "WebFetch(domain:\($0))" }
        let rules: [String: Any] = ["permissions": ["allow": allow, "deny": deny]]
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"permissions":{"allow":[],"deny":["Read(//**)","Read(~/**)","Read(**)"]}}"#
        }
        return json
    }

    /// Tools we explicitly forbid. Belt-and-suspenders alongside `--tools`, which
    /// is the whitelist that actually governs.
    private static let disallowedTools = [
        "Bash", "Read", "Write", "Edit", "MultiEdit", "Glob", "Grep",
        "WebSearch", "Task", "TodoWrite", "NotebookEdit"
    ]

    /// The CLI resolves `@name` against its working directory, so it runs in an
    /// empty scratch directory rather than wherever the app was launched from.
    private static func workingDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LLMProxy-scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }


    private static let baseSystemPrompt = """
    You are a helpful AI assistant accessed through an API endpoint. Respond \
    directly to the user's messages. You can fetch public web pages when the user \
    gives you a URL. You have no other tools and no access to files, the \
    filesystem, or the user's computer. Do not mention the underlying coding \
    harness.
    """

    /// Used instead of `baseSystemPrompt` when the caller supplies functions. Says
    /// "directive", not "tool": that word made the model attempt native tool calls.
    private static let baseSystemPromptWithTools = """
    You are a helpful AI assistant accessed through an API endpoint. The \
    application calling you performs the actions listed under "Supported \
    directives" below: you request one by writing its JSON directive, the \
    application carries it out, and it sends the result back on a later turn. \
    Those directives are how you reach the user's data, files and devices, so use \
    them whenever a request needs what they cover. Writing a directive is plain \
    text generation. Do not mention the underlying coding harness.
    """

    /// One block of the user turn we hand to the CLI, in client order.
    enum PromptBlock: Equatable {
        case text(String)
        case image(ImageBlock)
    }

    /// Flatten OpenAI messages into (systemPrompt, userPrompt). OpenAI is
    /// stateless — the client resends full history every call — so we replay the
    /// conversation as a transcript in the prompt. The model sees all context;
    /// it is not relying on any server-side session. This is faithful, just not
    /// native multi-turn.
    ///
    /// When `tools` are provided, we inject a function-calling section into the
    /// system prompt instructing the model to emit tool calls as JSON text (the
    /// subscription CLI can't use the native tool protocol — see `parseToolCalls`).
    ///
    /// Images stay at the position the client put them, so text that refers to
    /// "the image above" still lines up. A request with no images produces one
    /// text block holding exactly the prompt string this used to return.
    static func buildPrompt(_ messages: [ChatMessage],
                            tools: [Tool]? = nil,
                            toolChoice: ToolChoice? = nil) -> (system: String, blocks: [PromptBlock]) {
        let systemParts = messages.filter { $0.role == "system" }.compactMap(\.content)
        let convo = messages.filter { $0.role != "system" }

        let toolSection = toolsSystemSection(tools: tools, toolChoice: toolChoice)
        let base = toolSection == nil ? baseSystemPrompt : baseSystemPromptWithTools
        var systemPieces = [base] + systemParts
        if let toolSection { systemPieces.append(toolSection) }
        let system = systemPieces.joined(separator: "\n\n")

        var blocks: [PromptBlock] = []
        if convo.count == 1, convo[0].role == "user", (tools?.isEmpty ?? true) {
            append(convo[0].parts, to: &blocks)
            if blocks.isEmpty { blocks = [.text("")] }
        } else {
            for (i, msg) in convo.enumerated() {
                if i > 0 { appendText("\n\n", to: &blocks) }
                appendTranscript(msg, to: &blocks)
            }
            if toolSection != nil, let forced = forcedDirective(toolChoice) {
                appendText("\n\nSystem: \(forced)", to: &blocks)
            }
            appendText("\n\nAssistant:", to: &blocks)
        }
        return (system, blocks)
    }

    /// Render one non-system message into the transcript, including replayed
    /// tool calls (assistant) and tool results (role "tool").
    private static func appendTranscript(_ msg: ChatMessage, to blocks: inout [PromptBlock]) {
        switch msg.role {
        case "assistant":
            if let calls = msg.toolCalls, !calls.isEmpty {
                let entries = calls.map { "{\"name\": \"\($0.function.name)\", \"arguments\": \($0.function.arguments)}" }
                appendText("Assistant: {\"tool_calls\": [\(entries.joined(separator: ", "))]}", to: &blocks)
                return
            }
            appendText("Assistant: ", to: &blocks)
        case "tool":
            appendText("Tool result (for tool_call_id \(msg.toolCallId ?? "")): ", to: &blocks)
        default:
            appendText("User: ", to: &blocks)
        }
        append(msg.parts, to: &blocks)
    }

    private static func append(_ parts: [MessagePart], to blocks: inout [PromptBlock]) {
        for part in parts {
            switch part {
            case .text(let t): appendText(t, to: &blocks)
            case .image(let image): blocks.append(.image(image))
            }
        }
    }

    /// Text accumulates into the trailing text block rather than starting a new
    /// one, so an image-free conversation collapses back to a single block.
    private static func appendText(_ text: String, to blocks: inout [PromptBlock]) {
        if case .text(let existing)? = blocks.last {
            blocks[blocks.count - 1] = .text(existing + text)
        } else {
            blocks.append(.text(text))
        }
    }

    /// Build the function-calling instructions injected into the system prompt.
    /// Returns nil when there are no tools or `tool_choice` is "none".
    private static func toolsSystemSection(tools: [Tool]?, toolChoice: ToolChoice?) -> String? {
        guard let tools, functionsActive(tools: tools, toolChoice: toolChoice) else { return nil }

        var offered = tools
        if case .function(let name) = toolChoice {
            offered = tools.filter { $0.function.name == name }
        }
        let list = offered.map { t -> String in
            let fn = t.function
            var line = "- \(fn.name)"
            if let d = fn.description, !d.isEmpty { line += ": \(d)" }
            if let p = fn.parameters { line += "\n  JSON Schema for arguments: \(p.jsonString)" }
            return line
        }.joined(separator: "\n")

        let obligation: String
        switch toolChoice {
        case .required:
            obligation = "You MUST emit at least one directive this turn, choosing the most relevant one even if the request does not obviously need it. Do not reply in plain text."
        case .function(let name):
            obligation = "You MUST emit the \"\(name)\" directive this turn. Do not reply in plain text."
        default:
            obligation = "If a directive can fulfil the request, emit its JSON rather than answering from your own knowledge. If no directive matches, reply in plain text."
        }

        return """
        When the user's request matches one of the directives below, output ONLY a \
        single JSON object and nothing else — no prose, no explanation, no markdown \
        code fences — in exactly this shape:
        {"tool_calls": [{"name": "<directive_name>", "arguments": { <arguments matching the directive's JSON Schema> }}]}
        Include multiple entries in the array to invoke several directives at once.

        The external system performs each action and returns the result on a later \
        turn as a line like "Tool result (for tool_call_id ...): ..." — use those \
        results to answer the user in plain text. NEVER claim you can't do something, \
        that a directive is "unavailable", or that an action "failed": you are only \
        writing the directive JSON, not performing it.

        Supported directives:
        \(list)

        \(obligation)
        """
    }

    private static func forcedDirective(_ toolChoice: ToolChoice?) -> String? {
        switch toolChoice {
        case .required: return "answer this turn with a directive JSON, not plain text."
        case .function(let name): return "answer this turn with the \"\(name)\" directive JSON, not plain text."
        default: return nil
        }
    }

    static func functionsActive(tools: [Tool]?, toolChoice: ToolChoice?) -> Bool {
        guard let tools, !tools.isEmpty else { return false }
        if case .none? = toolChoice { return false }
        return true
    }

    /// Parse the model's raw output into tool calls, or nil if it isn't a
    /// tool-call response (i.e. the model replied with plain text). Tolerant of
    /// markdown fences and surrounding whitespace; accepts the `tool_calls` array
    /// form, a single `tool_call` object, or a bare `{name, arguments}` object.
    /// Entries naming a function the caller didn't supply are dropped.
    static func parseToolCalls(_ raw: String, functionNames: Set<String>) -> [ToolCall]? {
        let candidate = extractJSONObject(from: raw)
        guard let data = candidate.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var entries: [[String: Any]] = []
        if let arr = obj["tool_calls"] as? [[String: Any]] {
            entries = arr
        } else if let single = obj["tool_call"] as? [String: Any] {
            entries = [single]
        } else if obj["name"] is String {
            entries = [obj]
        } else {
            return nil
        }

        let calls: [ToolCall] = entries.compactMap { entry in
            guard let name = entry["name"] as? String, functionNames.contains(name) else { return nil }
            let argsString: String
            if let s = entry["arguments"] as? String {
                argsString = s
            } else if let anyArgs = entry["arguments"],
                      let d = try? JSONSerialization.data(withJSONObject: anyArgs),
                      let s = String(data: d, encoding: .utf8) {
                argsString = s
            } else {
                argsString = "{}"
            }
            return ToolCall(id: OpenAIIDs.toolCallID(), name: name, arguments: argsString)
        }
        return calls.isEmpty ? nil : calls
    }

    /// Strip markdown fences and, if the output has surrounding prose, isolate the
    /// outermost `{ ... }` so a stray sentence doesn't defeat JSON parsing.
    private static func extractJSONObject(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            // Drop the opening fence line (```json / ```) and the closing fence.
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if let fence = s.range(of: "```", options: .backwards) {
                s = String(s[..<fence.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.hasPrefix("{") && s.hasSuffix("}") { return s }
        if let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}"), open < close {
            return String(s[open...close])
        }
        return s
    }

    /// Launch the CLI and stream text deltas. Throws if `claude` can't be found
    /// or the process fails before producing output.
    static func stream(model: String, messages: [ChatMessage],
                       tools: [Tool]? = nil, toolChoice: ToolChoice? = nil) throws -> ChatStreamResult {
        guard let cli = ToolLocator.resolve() else {
            throw BackendError.claudeNotFound
        }
        let (system, blocks) = buildPrompt(messages, tools: tools, toolChoice: toolChoice)
        let stdinPayload = try stdinFrames(blocks)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli.claudePath)
        process.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--model", model,
            "--system-prompt", system
        ] + isolationArguments(allowing: allowedTools(
            callerHasFunctions: functionsActive(tools: tools, toolChoice: toolChoice)))

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = cli.path             // so claude can find node
        // Stops the CLI building a file attachment out of an `@path` in message
        // text at all, rather than letting one be built and then refused.
        env["CLAUDE_CODE_DISABLE_ATTACHMENTS"] = "1"
        process.environment = env
        process.currentDirectoryURL = workingDirectory()

        // Set before run() so an immediate exit cannot be missed.
        let exit = ProcessExit()
        process.terminationHandler = { exit.finish($0.terminationStatus) }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stderrLog = OutputBuffer()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        try process.run()

        // Drain stderr for the life of the process. Reading it only after exit
        // deadlocks the turn: once the child fills the 64 KB pipe buffer it blocks
        // on write, stops producing stdout, and we wait forever on output that
        // will never come.
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrLog.append(chunk)
        }

        // Off the caller's thread: a multi-megabyte image payload will not fit in
        // the pipe buffer, so writing inline blocks until the child drains stdin
        // while the child can be blocked writing stdout that nobody is reading.
        // A failed write leaves the child with a short turn, which it reports
        // itself on stdout.
        let stdin = stdinPipe.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdin.write(contentsOf: stdinPayload)
            try? stdin.close()
        }

        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    var sawText = false
                    var resultText: String?
                    for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                        if let text = Self.textDelta(fromLine: line) {
                            sawText = true
                            continuation.yield(text)
                        }
                        if let text = Self.successResult(fromLine: line) {
                            resultText = text
                        }
                        if let errMessage = Self.errorResult(fromLine: line) {
                            continuation.finish(throwing: BackendError.modelError(errMessage))
                            process.terminate()
                            return
                        }
                    }
                    let status = await exit.value()
                    // The CLI answers some turns itself, with a synthetic message
                    // and no deltas. Report what it said rather than an empty
                    // completion that reads as a successful blank answer.
                    if !sawText, status == 0, let resultText, !resultText.isEmpty {
                        continuation.yield(resultText)
                        continuation.finish()
                        return
                    }
                    if !sawText && status != 0 {
                        let msg = String(data: stderrLog.value, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        continuation.finish(throwing: BackendError.modelError(
                            msg.isEmpty ? "claude exited with status \(status)" : msg))
                        return
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                stderrHandle.readabilityHandler = nil
                if process.isRunning { process.terminate() }
            }
        }

        return ChatStreamResult(deltas: stream)
    }

    /// The two stdin lines for one turn: the Agent SDK's initialize handshake,
    /// then the user message. The handshake is what the SDK sends; images are
    /// delivered with or without it on CLI 2.1.220, so it is parity rather than a
    /// load-bearing step.
    static func stdinFrames(_ blocks: [PromptBlock]) throws -> Data {
        var content: [[String: Any]] = blocks.compactMap { block in
            switch block {
            case .text(let text):
                // The API rejects a blank text block, and a blank one carries
                // nothing anyway.
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return ["type": "text", "text": text]
            case .image(let image):
                switch image.source {
                case .base64(let mediaType, let data):
                    return ["type": "image",
                            "source": ["type": "base64", "media_type": mediaType, "data": data]]
                case .url(let url):
                    return ["type": "image", "source": ["type": "url", "url": url]]
                }
            }
        }
        // An empty turn is the CLI's error to report, not ours to invent.
        if content.isEmpty { content = [["type": "text", "text": ""]] }


        let userFrame: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
            "parent_tool_use_id": NSNull()
        ]

        var data = Data(#"{"request_id":"init","type":"control_request","request":{"subtype":"initialize"}}"#.utf8)
        data.append(0x0A)
        data.append(try JSONSerialization.data(withJSONObject: userFrame))
        data.append(0x0A)
        return data
    }

    /// Extract a text delta from one stream-json line, if present.
    private static func textDelta(fromLine line: String) -> String? {
        guard let obj = jsonObject(line),
              obj["type"] as? String == "stream_event",
              let event = obj["event"] as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String else {
            return nil
        }
        return text
    }

    /// The text of a successful terminal `result` line.
    private static func successResult(fromLine line: String) -> String? {
        guard let obj = jsonObject(line),
              obj["type"] as? String == "result",
              obj["is_error"] as? Bool != true else {
            return nil
        }
        return obj["result"] as? String
    }

    /// Detect a terminal error reported in a `result` line.
    private static func errorResult(fromLine line: String) -> String? {
        guard let obj = jsonObject(line),
              obj["type"] as? String == "result",
              (obj["is_error"] as? Bool == true) else {
            return nil
        }
        return (obj["result"] as? String) ?? "claude reported an error"
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Awaits a child process's exit status without blocking a thread.
///
/// `Process.waitUntilExit()` cannot be used here: it blocks, and called from a
/// Swift concurrency task it occupies a cooperative-pool thread. It was also
/// observed hanging permanently on an already-reaped child — roughly one request
/// in twenty never returned, leaving the caller waiting on a response forever.
private final class ProcessExit: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?

    func finish(_ value: Int32) {
        lock.lock()
        guard status == nil else { lock.unlock(); return }
        status = value
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func value() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

/// Accumulates a child process's output from the pipe's read queue.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

enum BackendError: LocalizedError {
    case claudeNotFound
    case codexNotFound
    case modelError(String)

    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "Could not find the `claude` CLI on your login PATH. Make sure Claude Code is installed and logged in."
        case .codexNotFound:
            return "Could not find the `codex` CLI. Install Codex or the ChatGPT desktop app, then sign in."
        case .modelError(let m):
            return m
        }
    }
}
