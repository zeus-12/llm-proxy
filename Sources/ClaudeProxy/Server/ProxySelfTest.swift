import Foundation

/// Framework-free unit checks for request decoding and prompt building, runnable
/// with `swift run LLMProxy --selftest`. Same rationale as `VoiceSelfTest`:
/// `swift test` needs full Xcode, which the build machine doesn't have.
enum ProxySelfTest {

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// 1×1 transparent PNG.
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    static func run() -> Bool {
        var failures = 0
        func check(_ label: String, _ condition: Bool) {
            if condition { print("  ✓ \(label)") }
            else { print("  ✗ \(label)"); failures += 1 }
        }

        func decode(_ json: String) throws -> ChatCompletionRequest {
            try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        }
        /// The client-facing 400 message, or nil if the request decoded.
        func rejection(_ json: String) -> String? {
            do {
                let request = try decode(json)
                try request.validate()
                return nil
            } catch let e as ProxyRequestError {
                return e.message
            } catch {
                return "\(error)"
            }
        }
        func blocks(_ json: String) -> [ClaudeBackend.PromptBlock] {
            guard let request = try? decode(json) else { return [] }
            return ClaudeBackend.buildPrompt(request.messages).blocks
        }
        func image(_ block: ClaudeBackend.PromptBlock) -> ImageBlock? {
            if case .image(let i) = block { return i } else { return nil }
        }
        func envelope(_ parts: String) -> String {
            #"{"model":"sonnet","messages":[{"role":"user","content":[\#(parts)]}]}"#
        }
        let textPart = #"{"type":"text","text":"hi"}"#
        let openAIImage = #"{"type":"image_url","image_url":{"url":"data:image/png;base64,\#(pngBase64)"}}"#

        print("ProxySelfTest — content parts")

        // Every spelling of an image part decodes to the same block.
        do {
            let expected = try? ImageBlock(mediaType: "image/png", base64: pngBase64)
            let spellings = [
                "OpenAI image_url object": openAIImage,
                "OpenAI image_url bare string": #"{"type":"image_url","image_url":"data:image/png;base64,\#(pngBase64)"}"#,
                "Anthropic image/source": #"{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(pngBase64)"}}"#,
                "Responses input_image": #"{"type":"input_image","image_url":"data:image/png;base64,\#(pngBase64)"}"#,
            ]
            for (name, part) in spellings {
                let b = blocks(envelope(part))
                check(name, b.count == 1 && image(b[0]) == expected)
            }
        }

        // Interleaved parts keep their order — image N must stay with label N.
        do {
            let b = blocks(envelope([
                #"{"type":"text","text":"[Image 1 of 2]"}"#, openAIImage,
                #"{"type":"text","text":"[Image 2 of 2]"}"#, openAIImage,
            ].joined(separator: ",")))
            check("interleaved order preserved",
                  b.count == 4 && b[0] == .text("[Image 1 of 2]") && image(b[1]) != nil
                               && b[2] == .text("[Image 2 of 2]") && image(b[3]) != nil)
        }

        // Text-only requests still collapse to exactly one block.
        do {
            let single = blocks(#"{"model":"sonnet","messages":[{"role":"user","content":"Hello!"}]}"#)
            check("plain string → one text block", single == [.text("Hello!")])

            let parts = blocks(envelope(#"{"type":"text","text":"a"},{"type":"text","text":"b"}"#))
            check("adjacent text parts merge", parts == [.text("ab")])

            let multi = blocks("""
            {"model":"sonnet","messages":[
              {"role":"system","content":"sys"},
              {"role":"user","content":"one"},
              {"role":"assistant","content":"two"},
              {"role":"user","content":"three"}]}
            """)
            check("multi-turn transcript unchanged",
                  multi == [.text("User: one\n\nAssistant: two\n\nUser: three\n\nAssistant:")])
        }

        // Images survive a multi-turn transcript, in place.
        do {
            let b = blocks("""
            {"model":"sonnet","messages":[
              {"role":"user","content":[\(textPart),\(openAIImage)]},
              {"role":"assistant","content":"ok"}]}
            """)
            check("image kept inside transcript",
                  b.count == 3 && b[0] == .text("User: hi") && image(b[1]) != nil
                               && b[2] == .text("\n\nAssistant: ok\n\nAssistant:"))
        }

        print("ProxySelfTest — rejections")

        // An image we cannot forward is a 400, never a silent drop.
        check("unsupported media type",
              rejection(envelope(#"{"type":"image_url","image_url":{"url":"data:image/tiff;base64,\#(pngBase64)"}}"#))?
                .contains("image/tiff") == true)
        check("invalid base64",
              rejection(envelope(#"{"type":"image_url","image_url":{"url":"data:image/png;base64,!!!!"}}"#))?
                .contains("valid base64") == true)
        check("data URL without base64 marker",
              rejection(envelope(#"{"type":"image_url","image_url":{"url":"data:image/png,abc"}}"#))?
                .contains("base64-encoded") == true)
        check("non-http scheme",
              rejection(envelope(#"{"type":"image_url","image_url":{"url":"file:///etc/passwd"}}"#))?
                .contains("http(s)") == true)
        check("image part missing image_url",
              rejection(envelope(#"{"type":"image_url"}"#))?.contains("missing `image_url`") == true)
        check("unknown part type",
              rejection(envelope(#"{"type":"input_audio","input_audio":{}}"#))?
                .contains("input_audio") == true)
        check("text-only request still accepted",
              rejection(envelope(textPart)) == nil)
        check("http URL accepted",
              rejection(envelope(#"{"type":"image_url","image_url":{"url":"https://example.com/x.png"}}"#)) == nil)

        print("ProxySelfTest — stdin frames")

        // The CLI reads one JSON object per line; images ride in the user frame.
        do {
            let png = try? ImageBlock(mediaType: "image/png", base64: pngBase64)
            let data = try? ClaudeBackend.stdinFrames([.text("look"), .image(png!)])
            let lines = String(data: data ?? Data(), encoding: .utf8)?
                .split(separator: "\n", omittingEmptySubsequences: false) ?? []
            check("two frames, trailing newline", lines.count == 3 && lines[2].isEmpty)

            let first = lines.first.flatMap { jsonObject(String($0)) }
            check("frame 1 is the initialize handshake",
                  first?["type"] as? String == "control_request")

            let user = lines.count > 1 ? jsonObject(String(lines[1])) : nil
            let content = ((user?["message"] as? [String: Any])?["content"]) as? [[String: Any]] ?? []
            check("frame 2 is the user turn", user?["type"] as? String == "user")
            check("blocks keep order in the frame",
                  content.count == 2 && content[0]["type"] as? String == "text"
                                     && content[1]["type"] as? String == "image")
            let source = content.count > 1 ? content[1]["source"] as? [String: Any] : nil
            check("image source is base64 + media type",
                  source?["type"] as? String == "base64"
                  && source?["media_type"] as? String == "image/png"
                  && source?["data"] as? String == pngBase64)

            // Blank text blocks would be rejected upstream.
            let blank = try? ClaudeBackend.stdinFrames([.text("  \n "), .image(png!)])
            let blankUser = String(data: blank ?? Data(), encoding: .utf8)?
                .split(separator: "\n").dropFirst().first.flatMap { jsonObject(String($0)) }
            let blankContent = ((blankUser?["message"] as? [String: Any])?["content"]) as? [[String: Any]] ?? []
            check("blank text block dropped",
                  blankContent.count == 1 && blankContent[0]["type"] as? String == "image")
        }

        print("ProxySelfTest — browser origin policy")

        do {
            let allowed: Set<String> = ["http://localhost:3000"]
            func decide(_ origin: String?) -> OriginPolicy.Decision {
                OriginPolicy.decide(originHeader: origin, allowed: allowed)
            }
            check("no Origin is allowed", decide(nil) == .allowedWithoutOrigin)
            check("blank Origin is allowed", decide("   ") == .allowedWithoutOrigin)
            check("unlisted origin denied", decide("https://evil.example") == .denied)
            check("listed origin allowed",
                  decide("http://localhost:3000") == .allowed("http://localhost:3000"))
            check("port mismatch denied", decide("http://localhost:3001") == .denied)
            check("scheme mismatch denied", decide("https://localhost:3000") == .denied)
            check("null origin denied", decide("null") == .denied)
            check("null origin denied even if allowlisted",
                  OriginPolicy.decide(originHeader: "null", allowed: ["null"]) == .denied)
            check("nothing ships allowlisted", OriginPolicy.allowed.isEmpty)
            check("every browser origin denied by default",
                  OriginPolicy.decide(originHeader: "http://localhost:3000").isDenied)
            check("denied origin echoes no header", decide("https://evil.example").echoedOrigin == nil)
            check("allowed origin is echoed back",
                  decide("http://localhost:3000").echoedOrigin == "http://localhost:3000")
            check("no-Origin request echoes no header", decide(nil).echoedOrigin == nil)
        }

        print("ProxySelfTest — API key")

        do {
            check("bearer header",
                  APIKey.presented(headers: ["authorization": "Bearer cp-abc"]) == "cp-abc")
            check("token header",
                  APIKey.presented(headers: ["authorization": "Token cp-abc"]) == "cp-abc")
            check("bare authorization value",
                  APIKey.presented(headers: ["authorization": "cp-abc"]) == "cp-abc")
            check("x-api-key header",
                  APIKey.presented(headers: ["x-api-key": "cp-abc"]) == "cp-abc")
            check("websocket subprotocol",
                  APIKey.presented(headers: ["sec-websocket-protocol": "token, cp-abc"]) == "cp-abc")
            check("query token",
                  APIKey.presented(headers: [:], query: ["token": "cp-abc"]) == "cp-abc")
            check("no credential", APIKey.presented(headers: [:]) == nil)
            check("unknown scheme ignored",
                  APIKey.presented(headers: ["authorization": "Basic cp-abc"]) == nil)

            check("correct key accepted", APIKey.accepts("cp-abc", required: "cp-abc"))
            check("wrong key rejected", !APIKey.accepts("cp-xyz", required: "cp-abc"))
            check("missing key rejected", !APIKey.accepts(nil, required: "cp-abc"))
            check("prefix of key rejected", !APIKey.accepts("cp-ab", required: "cp-abc"))
            check("empty requirement rejects", !APIKey.accepts(nil, required: ""))
            check("API key protection is optional",
                  APIKey.authorizes(nil, protectionEnabled: false, required: nil))
            check("enabled protection needs a configured API key",
                  !APIKey.authorizes(nil, protectionEnabled: true, required: nil))
            check("enabled protection accepts the matching API key",
                  APIKey.authorizes("cp-abc", protectionEnabled: true, required: "cp-abc"))
            check("environment API key enables protection",
                  APIKey.protectionEnabled(environmentKey: "cp-abc", preference: false))
            check("blank environment API key does not enable protection",
                  !APIKey.protectionEnabled(environmentKey: "  \n", preference: false))
            check("saved preference enables protection without an environment API key",
                  APIKey.protectionEnabled(environmentKey: nil, preference: true))

            check("environment key locks the requirement toggle",
                  APIKey.isEnvironmentManaged(.claude) == (ProcessInfo.processInfo
                    .environment[APIKey.environmentName(for: .claude)]?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false))

            let generated = APIKey.generate()
            check("generated key is prefixed", generated.hasPrefix("llmp-"))
            check("generated key is long enough", generated.count >= 32)
            check("generated keys differ", APIKey.generate() != APIKey.generate())

            check("scopes are distinct", Set(APIKeyScope.allCases.map(\.rawValue)).count == 3)
        }

        print("ProxySelfTest — secure defaults")

        check("Claude endpoint starts disabled", !ChatEndpoint().autoStart)
        check("Codex endpoint starts disabled", !ChatEndpoint(port: ChatBackend.codex.defaultPort).autoStart)
        check("Codex uses its uncommon default port", ChatBackend.codex.defaultPort == 17878)
        check("Voice endpoint starts disabled", !VoiceEndpoint().autoStart)

        let startupController = MainActor.assumeIsolated {
            APIKeyController(
                loadState: { _ in .disabled }
            )
        }
        check("API keys start unconfigured", MainActor.assumeIsolated {
            APIKeyScope.allCases.allSatisfy { startupController.state($0) == .disabled }
        })

        print("ProxySelfTest — tool-aware streaming")

        check("plain text streams immediately",
              ToolStreamClassifier.classify("Hello") == .text)
        check("leading whitespace waits for a decision",
              ToolStreamClassifier.classify("  \n") == .undecided)
        check("JSON tool envelope stays buffered",
              ToolStreamClassifier.classify(#" {"tool_calls":[]}"#) == .toolCandidate)
        check("fenced tool envelope stays buffered",
              ToolStreamClassifier.classify("```json\n{") == .toolCandidate)

        print("ProxySelfTest — provider routing")

        do {
            check("Claude aliases route to Claude",
                  ChatModel.sonnet.backend == .claude && ChatModel.opus.backend == .claude)
            check("GPT aliases route to Codex",
                  ChatModel.gpt56.backend == .codex && ChatModel.gpt56Terra.backend == .codex)
            check("model owners match providers",
                  ChatModel.haiku.owner == "anthropic" && ChatModel.gpt56Luna.owner == "openai")
            check("all advertised ids round-trip",
                  ChatModel.allowedIDs.allSatisfy { ChatModel(rawValue: $0) != nil })
            check("provider model lists do not overlap",
                  Set(ChatBackend.claude.allowedIDs).isDisjoint(with: Set(ChatBackend.codex.allowedIDs)))
            let codexRequest = try? JSONDecoder().decode(ChatCompletionRequest.self, from:
                Data(#"{"model":"sonnet","messages":[{"role":"user","content":"hi"}]}"#.utf8))
            let rejectsClaude: Bool
            do {
                try codexRequest?.validate(allowedModels: ChatBackend.codex.allowedIDs)
                rejectsClaude = false
            } catch { rejectsClaude = true }
            check("Codex endpoint rejects Claude models", rejectsClaude)

            let delta = #"{"method":"item/agentMessage/delta","params":{"itemId":"answer","delta":"hello","threadId":"t","turnId":"u"}}"#
            check("Codex final delta accepted",
                  CodexBackend.delta(fromLine: delta, acceptedItemIDs: ["answer"]) == "hello")
            check("Codex unknown delta ignored",
                  CodexBackend.delta(fromLine: delta, acceptedItemIDs: []) == nil)

            let config = CodexBackend.isolatedConfig()
            let profileName = config["default_permissions"] as? String
            let profiles = config["permissions"] as? [String: Any]
            let profile = profiles?[profileName ?? ""] as? [String: Any]
            let filesystem = profile?["filesystem"] as? [String: Any]
            let network = profile?["network"] as? [String: Any]
            check("Codex permission profile selected", profileName == "claude_proxy")
            check("Codex filesystem grants are empty", filesystem?.isEmpty == true)
            check("Codex command network disabled", network?["enabled"] as? Bool == false)
            check("Codex agents disabled",
                  (config["agents"] as? [String: Any])?["enabled"] as? Bool == false)
            check("Codex hosted web search enabled", config["web_search"] as? String == "live")
            check("Codex shell implementations disabled",
                  Set(CodexBackend.disabledFeatureArguments).isSuperset(of: ["shell_tool", "unified_exec"]))
        }

        print("ProxySelfTest — shared OpenAI wire format")

        // Claude and Codex both terminate at ChatStreamResult; these are the
        // single shared encoders used after that boundary. Assert the actual
        // JSON keys/types so neither provider can silently drift in wire shape.
        do {
            let textResponse = ChatCompletionResponse(
                id: "chatcmpl-test", created: 1, model: "model-test",
                choices: [.init(message: .init(content: "hello", tool_calls: nil),
                                finish_reason: "stop")]
            )
            let textData = try? JSONEncoder().encode(textResponse)
            let text = textData.flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }
            let textChoice = (text?["choices"] as? [[String: Any]])?.first
            let textMessage = textChoice?["message"] as? [String: Any]
            check("completion envelope",
                  text?["object"] as? String == "chat.completion"
                  && text?["id"] as? String == "chatcmpl-test"
                  && text?["created"] as? Int == 1
                  && text?["model"] as? String == "model-test")
            check("completion assistant message",
                  textChoice?["index"] as? Int == 0
                  && textChoice?["finish_reason"] as? String == "stop"
                  && textMessage?["role"] as? String == "assistant"
                  && textMessage?["content"] as? String == "hello")

            let call = ToolCall(id: "call_test", name: "lookup",
                                arguments: #"{"query":"x"}"#)
            let toolResponse = ChatCompletionResponse(
                id: "chatcmpl-tool", created: 2, model: "model-test",
                choices: [.init(message: .init(content: nil, tool_calls: [call]),
                                finish_reason: "tool_calls")]
            )
            let toolData = try? JSONEncoder().encode(toolResponse)
            let tool = toolData.flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }
            let toolChoice = (tool?["choices"] as? [[String: Any]])?.first
            let toolMessage = toolChoice?["message"] as? [String: Any]
            let toolCall = (toolMessage?["tool_calls"] as? [[String: Any]])?.first
            let function = toolCall?["function"] as? [String: Any]
            check("tool-call response shape",
                  toolChoice?["finish_reason"] as? String == "tool_calls"
                  && toolMessage?["content"] is NSNull
                  && toolCall?["id"] as? String == "call_test"
                  && toolCall?["type"] as? String == "function"
                  && function?["name"] as? String == "lookup"
                  && function?["arguments"] as? String == #"{"query":"x"}"#)

            let chunk = ChatCompletionChunk(
                id: "chatcmpl-stream", created: 3, model: "model-test",
                choices: [.init(delta: .init(role: "assistant", content: "hi"),
                                finish_reason: nil)]
            )
            let chunkData = try? JSONEncoder().encode(chunk)
            let streamed = chunkData.flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }
            let streamChoice = (streamed?["choices"] as? [[String: Any]])?.first
            let deltaObject = streamChoice?["delta"] as? [String: Any]
            check("stream chunk shape",
                  streamed?["object"] as? String == "chat.completion.chunk"
                  && streamChoice?["index"] as? Int == 0
                  && deltaObject?["role"] as? String == "assistant"
                  && deltaObject?["content"] as? String == "hi"
                  && streamChoice?["finish_reason"] is NSNull)

            let errorData = try? JSONEncoder().encode(OpenAIError("bad", type: "proxy_error"))
            let errorObject = errorData.flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }?["error"] as? [String: Any]
            check("error envelope",
                  errorObject?["message"] as? String == "bad"
                  && errorObject?["type"] as? String == "proxy_error")
        }

        print("ProxySelfTest — permission configuration")

        // The live suite proves these hold against the real CLI; these catch a
        // rule being dropped or mistyped without waiting on a network run.
        do {
            let settings = ClaudeBackend.permissionSettings(allowing: ClaudeBackend.allowedTools(callerHasFunctions: false))
            let parsed = jsonObject(settings)?["permissions"] as? [String: Any]
            let deny = parsed?["deny"] as? [String] ?? []
            let allow = parsed?["allow"] as? [String] ?? []

            check("settings are valid JSON", parsed != nil)
            // All three globs are needed: //** absolute, ~/** home, ** cwd.
            check("denies absolute reads", deny.contains("Read(//**)"))
            check("denies home reads", deny.contains("Read(~/**)"))
            check("denies relative reads", deny.contains("Read(**)"))
            check("denies loopback fetch", deny.contains("WebFetch(domain:127.0.0.1)"))
            check("denies localhost fetch", deny.contains("WebFetch(domain:localhost)"))
            check("denies link-local fetch", deny.contains("WebFetch(domain:169.254.169.254)"))
            check("allows WebFetch", allow == ["WebFetch"])
            check("WebFetch is the only tool", ClaudeBackend.allowedTools(callerHasFunctions: false) == ["WebFetch"])
            check("no built-in tool beside caller functions", ClaudeBackend.allowedTools(callerHasFunctions: true).isEmpty)

            let withFunctions = jsonObject(ClaudeBackend.permissionSettings(allowing: []))?["permissions"] as? [String: Any]
            check("caller functions allow nothing", (withFunctions?["allow"] as? [String]) == [])
            check("caller functions keep read denial", (withFunctions?["deny"] as? [String] ?? []).contains("Read(//**)"))

            let calendar = Tool(type: "function", function: .init(name: "calendar_events", description: nil, parameters: nil, strict: nil))
            check("functions active with tools", ClaudeBackend.functionsActive(tools: [calendar], toolChoice: nil))
            check("functions inactive under tool_choice none", !ClaudeBackend.functionsActive(tools: [calendar], toolChoice: ToolChoice.none))
            check("functions inactive without tools", !ClaudeBackend.functionsActive(tools: [], toolChoice: .required))
        }

        print("ProxySelfTest — tool_choice shapes the directive prompt")

        do {
            let tools = ["calendar_events", "search_notes"].map {
                Tool(type: "function", function: .init(name: $0, description: nil, parameters: nil, strict: nil))
            }
            let user = (try? JSONDecoder().decode([ChatMessage].self,
                                                  from: Data(#"[{"role":"user","content":"hello"}]"#.utf8))) ?? []
            let auto = ClaudeBackend.buildPrompt(user, tools: tools).system
            let required = ClaudeBackend.buildPrompt(user, tools: tools, toolChoice: .required).system
            let named = ClaudeBackend.buildPrompt(user, tools: tools, toolChoice: .function(name: "search_notes")).system

            check("auto lists every function", auto.contains("- calendar_events") && auto.contains("- search_notes"))
            check("auto allows a plain-text reply", auto.contains("reply in plain text."))
            check("required forbids a plain-text reply", !required.contains("If no directive matches"))
            check("required obligation comes last", required.hasSuffix("Do not reply in plain text."))
            check("named function is the only one listed", named.contains("- search_notes") && !named.contains("- calendar_events"))
            check("tools prompt never says it has no tools", !auto.contains("no tools"))
        }

        print("ProxySelfTest — message text is forwarded verbatim")

        // File reads are denied at the CLI's permission layer, so message text
        // needs no rewriting. These guard against a rewrite creeping back in.
        do {
            for text in ["read @/etc/hosts now", "@~/.ssh/id_rsa", "mail bob@example.com",
                         "@../../etc/hosts", "cc @vishnu please", "/usr is a directory",
                         "/caveman hello"] {
                let framed = try? ClaudeBackend.stdinFrames([.text(text)])
                let userLine = String(data: framed ?? Data(), encoding: .utf8)?
                    .split(separator: "\n").dropFirst().first
                let content = ((userLine.flatMap { jsonObject(String($0)) }?["message"]
                                as? [String: Any])?["content"]) as? [[String: Any]] ?? []
                check("verbatim: \(text)", content.first?["text"] as? String == text)
            }
        }

        print(failures == 0 ? "PASS — all checks passed" : "FAIL — \(failures) check(s) failed")
        return failures == 0
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
