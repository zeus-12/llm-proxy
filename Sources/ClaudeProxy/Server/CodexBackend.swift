import Foundation

/// Drives the supported Codex app-server protocol over stdio and exposes only
/// assistant-message deltas. Every API call gets an ephemeral thread rooted in
/// a unique scratch directory; the turn has no approvals and a custom permission
/// profile that grants model-initiated commands no filesystem or network access.
enum CodexBackend {
    private static let client = CodexAppServerClient()
    /// Plugins go wholesale: disabling a plugin's MCP server by name creates an
    /// entry with no transport, and Codex then refuses to load its config.
    static let disabledFeatureArguments = [
        "--disable", "shell_tool",
        "--disable", "unified_exec",
        "--disable", "shell_zsh_fork",
        "--disable", "plugins"
    ]

    static func prepare() throws { try client.prepare() }
    static func shutdown() { client.shutdown() }

    static func stream(model: String, messages: [ChatMessage],
                       tools: [Tool]? = nil, toolChoice: ToolChoice? = nil) throws -> ChatStreamResult {
        try client.stream(model: model, messages: messages, tools: tools, toolChoice: toolChoice)
    }

    /// Retained as a narrow fallback/reference implementation for parser tests.
    private static func streamCold(model: String, messages: [ChatMessage],
                       tools: [Tool]? = nil, toolChoice: ToolChoice? = nil) throws -> ChatStreamResult {
        guard let cli = ToolLocator.resolveCodex() else {
            throw BackendError.codexNotFound
        }

        let prompt = ClaudeBackend.buildPrompt(messages, tools: tools, toolChoice: toolChoice)
        let mcpOverrides = try disabledMCPArguments(cli: cli)
        let isolatedConfig = isolatedConfig()
        let scratch = try makeScratchDirectory()
        let input: [[String: Any]]
        do {
            input = try appServerInput(prompt.blocks, scratch: scratch)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli.codexPath)
        process.arguments = ["app-server", "--stdio"] + disabledFeatureArguments + mcpOverrides
        process.currentDirectoryURL = scratch
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = cli.path
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stderrLog = CodexOutputBuffer()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }

        let stdin = stdinPipe.fileHandleForWriting
        let stdout = stdoutPipe.fileHandleForReading
        let stderr = stderrPipe.fileHandleForReading
        stderr.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            else { stderrLog.append(chunk) }
        }

        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                defer {
                    stderr.readabilityHandler = nil
                    try? stdin.close()
                    if process.isRunning { process.terminate() }
                    try? FileManager.default.removeItem(at: scratch)
                }

                do {
                    try send([
                        "method": "initialize", "id": 0,
                        "params": [
                            "clientInfo": [
                                "name": "claude_proxy",
                                "title": "LLM Proxy",
                                "version": "0.3.0"
                            ]
                        ]
                    ], to: stdin)
                    try send(["method": "initialized", "params": [:]], to: stdin)
                    try send([
                        "method": "thread/start", "id": 1,
                        "params": [
                            "model": model,
                            "cwd": scratch.path,
                            "approvalPolicy": "never",
                            "ephemeral": true,
                            "baseInstructions": prompt.system,
                            "developerInstructions": "Act only as a chat backend. You may use hosted web search and browse public web pages. Never run shell or terminal commands, inspect host files, change files, use apps, MCP, skills, subagents, or any other built-in tool.",
                            "serviceName": "claude_proxy",
                            "config": isolatedConfig
                        ]
                    ], to: stdin)

                    var turnStarted = false
                    var acceptedItems = Set<String>()
                    var streamedItems = Set<String>()
                    var pendingError: String?

                    for try await line in stdout.bytes.lines {
                        try Task.checkCancellation()
                        guard let message = jsonObject(line) else { continue }

                        if (message["id"] as? Int) == 1 {
                            if let error = rpcError(message) {
                                throw BackendError.modelError(error)
                            }
                            guard !turnStarted,
                                  let result = message["result"] as? [String: Any],
                                  let thread = result["thread"] as? [String: Any],
                                  let threadID = thread["id"] as? String else { continue }
                            turnStarted = true
                            try send([
                                "method": "turn/start", "id": 2,
                                "params": [
                                    "threadId": threadID,
                                    "input": input,
                                    "model": model,
                                    "approvalPolicy": "never"
                                ]
                            ], to: stdin)
                            continue
                        }

                        if (message["id"] as? Int) == 2, let error = rpcError(message) {
                            throw BackendError.modelError(error)
                        }

                        guard let method = message["method"] as? String,
                              let params = message["params"] as? [String: Any] else { continue }

                        switch method {
                        case "item/started":
                            if let item = params["item"] as? [String: Any],
                               item["type"] as? String == "agentMessage",
                               item["phase"] as? String != "commentary",
                               let itemID = item["id"] as? String {
                                acceptedItems.insert(itemID)
                            }

                        case "item/agentMessage/delta":
                            guard let itemID = params["itemId"] as? String,
                                  acceptedItems.contains(itemID),
                                  let delta = params["delta"] as? String,
                                  !delta.isEmpty else { continue }
                            streamedItems.insert(itemID)
                            continuation.yield(delta)

                        case "item/completed":
                            guard let item = params["item"] as? [String: Any],
                                  item["type"] as? String == "agentMessage",
                                  item["phase"] as? String != "commentary",
                                  let itemID = item["id"] as? String else { continue }
                            acceptedItems.insert(itemID)
                            if !streamedItems.contains(itemID),
                               let text = item["text"] as? String, !text.isEmpty {
                                continuation.yield(text)
                            }

                        case "error":
                            pendingError = nestedMessage(params) ?? "Codex reported an error"

                        case "turn/completed":
                            guard let turn = params["turn"] as? [String: Any] else { continue }
                            if turn["status"] as? String == "completed" {
                                continuation.finish()
                            } else {
                                let message = nestedMessage(turn) ?? pendingError ?? "Codex turn failed"
                                continuation.finish(throwing: BackendError.modelError(message))
                            }
                            return

                        default:
                            break
                        }
                    }

                    let diagnostics = String(data: stderrLog.value, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let message: String
                    if let pendingError {
                        message = pendingError
                    } else if let diagnostics, !diagnostics.isEmpty {
                        message = diagnostics
                    } else {
                        message = "Codex app-server closed before completing the turn"
                    }
                    continuation.finish(throwing: BackendError.modelError(message))
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                stderr.readabilityHandler = nil
                try? stdin.close()
                if process.isRunning { process.terminate() }
            }
        }

        return ChatStreamResult(deltas: stream)
    }

    /// Exposed internally for the framework-free self-test.
    static func delta(fromLine line: String, acceptedItemIDs: Set<String>) -> String? {
        guard let message = jsonObject(line),
              message["method"] as? String == "item/agentMessage/delta",
              let params = message["params"] as? [String: Any],
              let itemID = params["itemId"] as? String,
              acceptedItemIDs.contains(itemID) else { return nil }
        return params["delta"] as? String
    }

    fileprivate static func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMProxy-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Enumerate configured MCP servers and build command-line overrides for the
    /// enabled ones. Command-line dotted overrides merge `enabled` into the
    /// existing server entry; the app-server per-thread config layer would
    /// replace the whole entry and erase its required transport fields.
    fileprivate static func disabledMCPArguments(cli: ToolLocator.ResolvedCodex) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli.codexPath)
        process.arguments = ["mcp", "list", "--json"] + disabledFeatureArguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = cli.path
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BackendError.modelError("Could not enumerate Codex MCP servers for isolation")
        }

        var arguments: [String] = []
        for entry in entries {
            guard entry["enabled"] as? Bool == true else { continue }
            guard let name = entry["name"] as? String, !name.isEmpty else { continue }
            guard name.utf8.allSatisfy({ byte in
                (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90)
                    || (byte >= 97 && byte <= 122) || byte == 45 || byte == 95
            }) else {
                throw BackendError.modelError("Cannot safely disable Codex MCP server named \"\(name)\"")
            }
            arguments += ["-c", "mcp_servers.\(name).enabled=false"]
        }
        return arguments
    }

    /// Per-thread isolation for non-MCP extension points. Unlike MCP server
    /// entries, each of these values is complete and safe to replace.
    /// Internal so the framework-free self-test can assert the security-critical
    /// profile rather than relying only on a live call accepting the config.
    static func isolatedConfig() -> [String: Any] {
        let hookEvents = [
            "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact",
            "PostCompact", "SessionStart", "SessionEnd", "SubagentStart",
            "SubagentStop", "UserPromptSubmit", "Stop"
        ]
        var hooks: [String: Any] = [:]
        for event in hookEvents { hooks[event] = [] }

        return [
            "default_permissions": "claude_proxy",
            "permissions": ["claude_proxy": [
                "description": "No local filesystem or command-network access for API traffic.",
                "filesystem": [:],
                "network": ["enabled": false]
            ]],
            "apps": ["_default": [
                "enabled": false,
                "destructive_enabled": false,
                "open_world_enabled": false
            ]],
            "agents": ["enabled": false],
            "hooks": hooks,
            // Hosted search/browse is the sole executable capability. Command
            // network stays off: web_search does not require shell networking.
            "web_search": "live",
            "allow_login_shell": false,
            "shell_environment_policy": ["inherit": "none"]
        ]
    }

    fileprivate static func appServerInput(_ blocks: [ClaudeBackend.PromptBlock],
                                       scratch: URL) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        var imageIndex = 0
        for block in blocks {
            switch block {
            case .text(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.append(["type": "text", "text": text])
            case .image(let image):
                switch image.source {
                case .url(let url):
                    result.append(["type": "image", "url": url])
                case .base64(let mediaType, let encoded):
                    guard let data = Data(base64Encoded: encoded) else {
                        throw ProxyRequestError("image data is not valid base64")
                    }
                    imageIndex += 1
                    let ext: String
                    switch mediaType {
                    case "image/jpeg": ext = "jpg"
                    case "image/gif": ext = "gif"
                    case "image/webp": ext = "webp"
                    default: ext = "png"
                    }
                    let file = scratch.appendingPathComponent("image-\(imageIndex).\(ext)")
                    try data.write(to: file, options: .atomic)
                    result.append(["type": "localImage", "path": file.path])
                }
            }
        }
        if result.isEmpty { result = [["type": "text", "text": " "]] }
        return result
    }

    fileprivate static func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    fileprivate static func rpcError(_ message: [String: Any]) -> String? {
        guard let error = message["error"] as? [String: Any] else { return nil }
        return error["message"] as? String ?? "Codex app-server request failed"
    }

    fileprivate static func nestedMessage(_ object: [String: Any]) -> String? {
        if let message = object["message"] as? String { return message }
        if let error = object["error"] as? [String: Any] {
            return error["message"] as? String
        }
        return nil
    }
}

/// One long-lived app-server shared by every Codex HTTP request. Requests still
/// get distinct ephemeral threads and scratch directories; only the transport
/// process is reused. JSON-RPC ids and thread ids multiplex concurrent turns.
private final class CodexAppServerClient: @unchecked Sendable {
    private final class Call {
        let id: UUID
        let model: String
        let system: String
        let input: [[String: Any]]
        let scratch: URL
        let continuation: AsyncThrowingStream<String, Error>.Continuation
        var threadID: String?
        var acceptedItems = Set<String>()
        var streamedItems = Set<String>()
        var pendingError: String?

        init(id: UUID, model: String, system: String,
             input: [[String: Any]], scratch: URL,
             continuation: AsyncThrowingStream<String, Error>.Continuation) {
            self.id = id; self.model = model; self.system = system
            self.input = input; self.scratch = scratch; self.continuation = continuation
        }
    }

    private let queue = DispatchQueue(label: "proxy.codex.app-server")
    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var generation = UUID()
    private var nextID = 10
    private var calls: [UUID: Call] = [:]
    private var threadRequests: [Int: UUID] = [:]
    private var turnRequests: [Int: UUID] = [:]
    private var threads: [String: UUID] = [:]

    func prepare() throws { try queue.sync { try ensureRunning() } }

    func stream(model: String, messages: [ChatMessage], tools: [Tool]?,
                toolChoice: ToolChoice?) throws -> ChatStreamResult {
        try prepare()
        let prompt = ClaudeBackend.buildPrompt(messages, tools: tools, toolChoice: toolChoice)
        let scratch = try CodexBackend.makeScratchDirectory()
        let input: [[String: Any]]
        do { input = try CodexBackend.appServerInput(prompt.blocks, scratch: scratch) }
        catch { try? FileManager.default.removeItem(at: scratch); throw error }

        let callID = UUID()
        let stream = AsyncThrowingStream<String, Error> { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    try self.ensureRunning()
                    let call = Call(id: callID, model: model, system: prompt.system, input: input,
                                    scratch: scratch, continuation: continuation)
                    self.calls[callID] = call
                    let requestID = self.allocateID()
                    self.threadRequests[requestID] = callID
                    try self.send([
                        "method": "thread/start", "id": requestID,
                        "params": [
                            "model": model, "cwd": scratch.path,
                            "approvalPolicy": "never", "ephemeral": true,
                            "baseInstructions": call.system,
                            "developerInstructions": "Act only as a chat backend. You may use hosted web search and browse public web pages. Never run shell or terminal commands, inspect host files, change files, use apps, MCP, skills, subagents, or any other built-in tool.",
                            "serviceName": "claude_proxy",
                            "config": CodexBackend.isolatedConfig()
                        ]
                    ])
                } catch {
                    try? FileManager.default.removeItem(at: scratch)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                guard let client = self else { return }
                client.queue.async { [weak client] in client?.cancel(callID) }
            }
        }
        return ChatStreamResult(deltas: stream)
    }

    func shutdown() {
        queue.sync {
            failAll(BackendError.modelError("Codex endpoint stopped"))
            let running = process
            process = nil
            stdin = nil
            if running?.isRunning == true { running?.terminate() }
        }
    }

    private func ensureRunning() throws {
        if process?.isRunning == true, stdin != nil { return }
        guard let cli = ToolLocator.resolveCodex() else { throw BackendError.codexNotFound }
        let mcpOverrides = try CodexBackend.disabledMCPArguments(cli: cli)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli.codexPath)
        process.arguments = ["app-server", "--stdio"] + CodexBackend.disabledFeatureArguments + mcpOverrides
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = cli.path
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let token = UUID(); generation = token
        stdoutBuffer.removeAll(keepingCapacity: true); stderrBuffer.removeAll(keepingCapacity: true)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.consume(data, generation: token) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.consumeError(data, generation: token) }
        }
        process.terminationHandler = { [weak self] process in
            self?.queue.async { self?.terminated(process, generation: token) }
        }
        try process.run()
        self.process = process; stdin = input.fileHandleForWriting
        try send(["method": "initialize", "id": 0,
                  "params": ["clientInfo": ["name": "llm_proxy", "title": "LLM Proxy", "version": "0.4.0"]]])
        try send(["method": "initialized", "params": [:]])
    }

    private func allocateID() -> Int { defer { nextID &+= 1 }; return nextID }
    private func send(_ object: [String: Any]) throws {
        guard let stdin else { throw BackendError.modelError("Codex app-server is not running") }
        try CodexBackend.send(object, to: stdin)
    }

    private func consume(_ data: Data, generation token: UUID) {
        guard token == generation, !data.isEmpty else { return }
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.prefix(upTo: newline)
            stdoutBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let requestID = message["id"] as? Int {
            if let callID = threadRequests.removeValue(forKey: requestID), let call = calls[callID] {
                if let error = CodexBackend.rpcError(message) { finish(call, error: BackendError.modelError(error)); return }
                guard let result = message["result"] as? [String: Any],
                      let thread = result["thread"] as? [String: Any],
                      let threadID = thread["id"] as? String else { return }
                call.threadID = threadID; threads[threadID] = callID
                let turnID = allocateID(); turnRequests[turnID] = callID
                do {
                    try send(["method": "turn/start", "id": turnID,
                              "params": ["threadId": threadID, "input": call.input,
                                         "model": call.model, "approvalPolicy": "never"]])
                } catch { finish(call, error: error) }
                return
            }
            if let callID = turnRequests[requestID], let error = CodexBackend.rpcError(message),
               let call = calls[callID] { finish(call, error: BackendError.modelError(error)) }
        }

        guard let method = message["method"] as? String,
              let params = message["params"] as? [String: Any],
              let threadID = params["threadId"] as? String,
              let callID = threads[threadID], let call = calls[callID] else { return }
        switch method {
        case "item/started":
            if let item = params["item"] as? [String: Any],
               let type = item["type"] as? String {
                let forbidden = ["commandExecution", "fileChange", "mcpToolCall",
                                 "dynamicToolCall", "collabToolCall"]
                if forbidden.contains(type) {
                    finish(call, error: BackendError.modelError("Codex attempted a disabled host tool: \(type)"))
                    return
                }
                if type == "agentMessage", item["phase"] as? String != "commentary",
                   let id = item["id"] as? String { call.acceptedItems.insert(id) }
            }
        case "item/agentMessage/delta":
            if let id = params["itemId"] as? String, call.acceptedItems.contains(id),
               let delta = params["delta"] as? String, !delta.isEmpty {
                call.streamedItems.insert(id); call.continuation.yield(delta)
            }
        case "item/completed":
            if let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
               item["phase"] as? String != "commentary", let id = item["id"] as? String,
               !call.streamedItems.contains(id), let text = item["text"] as? String, !text.isEmpty {
                call.continuation.yield(text)
            }
        case "error": call.pendingError = CodexBackend.nestedMessage(params) ?? "Codex reported an error"
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            if turn?["status"] as? String == "completed" { finish(call, error: nil) }
            else { finish(call, error: BackendError.modelError(turn.flatMap(CodexBackend.nestedMessage) ?? call.pendingError ?? "Codex turn failed")) }
        default: break
        }
    }

    private func finish(_ call: Call, error: Error?) {
        calls.removeValue(forKey: call.id)
        if let threadID = call.threadID { threads.removeValue(forKey: threadID) }
        threadRequests = threadRequests.filter { $0.value != call.id }
        turnRequests = turnRequests.filter { $0.value != call.id }
        try? FileManager.default.removeItem(at: call.scratch)
        if let error { call.continuation.finish(throwing: error) } else { call.continuation.finish() }
    }

    private func cancel(_ id: UUID) { if let call = calls[id] { finish(call, error: nil) } }
    private func consumeError(_ data: Data, generation token: UUID) {
        guard token == generation, !data.isEmpty else { return }
        stderrBuffer.append(data)
        if stderrBuffer.count > 65_536 { stderrBuffer.removeFirst(stderrBuffer.count - 65_536) }
    }
    private func terminated(_ terminated: Process, generation token: UUID) {
        guard token == generation, process === terminated else { return }
        process = nil; stdin = nil
        let diagnostics = String(data: stderrBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        failAll(BackendError.modelError(diagnostics?.isEmpty == false ? diagnostics! : "Codex app-server stopped"))
    }
    private func failAll(_ error: Error) { for call in Array(calls.values) { finish(call, error: error) } }
}

private final class CodexOutputBuffer: @unchecked Sendable {
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
