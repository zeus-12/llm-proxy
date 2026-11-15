import Foundation

/// The single source of truth for the API reference. `APIReferencePane` renders
/// these structures, and the "Copy docs" buttons serialize the *same* structures
/// to Markdown — so the on-screen reference and the copied text can never drift.
///
/// The copied Markdown is meant to be pasted straight into an LLM, so it spells
/// out the things a coding agent otherwise guesses wrong: that the base URL is a
/// base URL and not a request path, which fields are honoured, and which are
/// accepted but ignored.
enum APIDocs {

    struct Entry {
        let title: String
        let detail: String
        let code: String
    }

    /// A worked example. Kept as title + body rather than pre-formatted Markdown
    /// so each renderer can pick the heading level that matches its nesting —
    /// the standalone and combined documents nest sections differently.
    struct Example {
        let title: String
        let body: String
    }

    struct Section {
        let title: String
        let systemImage: String
        /// Prose that opens the copied document. Not shown in the UI, which has
        /// its own section header.
        let summary: String
        let entries: [Entry]
        let examples: [Example]
    }

    // MARK: - Chat

    private static let claudeOptionEntries = [
        Entry(title: "Reasoning effort",
              detail: "Optional `reasoning_effort`. `low`, `medium` and `high` set Claude Code's effort. `none` and `minimal` also drop the thinking parameter, which turns thinking off on models before the 5.5 family; the 5.5 models cannot turn thinking off, so they think briefly at low effort. Leave it out for Claude Code's default (medium).",
              code: "{ \"reasoning_effort\": \"none\" }"),
        Entry(title: "Keep warm",
              detail: "Optional `keep_warm`. Keeps one started Claude Code process (about 230 MB) waiting for the next keep_warm request with the same model, effort and tools, which saves about half a second before the first token. The waiting process exits after five idle minutes.",
              code: "{ \"keep_warm\": true }"),
    ]

    static func chat(backend: ChatBackend, baseURL: String, keyRequired: Bool) -> Section {
        let providerModels = backend.models
        let models = backend.allowedIDs.joined(separator: ", ")
        let defaultModel = providerModels.first?.rawValue ?? ""
        let runtime = backend == .claude ? "the local Claude Code CLI" : "one warm `codex app-server` process (not `codex exec`)"
        let webDetail = backend == .claude
            ? "Claude can fetch public URLs through its single guarded WebFetch tool. Loopback, localhost and cloud-metadata addresses are refused."
            : "Codex can use hosted web search and browse public pages. Shell tools, command networking, MCP, apps, agents and file changes are disabled."
        let isolation = backend == .claude
            ? "A scratch working directory is used; MCP, skills, user settings and file tools are disabled."
            : "Every request gets an ephemeral thread and scratch directory with approvals off and no model-initiated filesystem or command-network access."
        // Every key-dependent string is derived from the live setting: a
        // reference that told you to send `unused` while the endpoint demanded a
        // key would be worse than no reference at all.
        let authHeader = "-H \"Authorization: Bearer <api-key>\" \\\n  "
        let curlAuth = keyRequired ? authHeader : ""
        let sdkKey = keyRequired ? "<api-key>" : "unused"
        return Section(
            title: "\(backend.title) chat",
            systemImage: backend.icon,
            summary: """
            OpenAI-compatible chat backed by your \(backend.subtitle). It uses \
            \(runtime). Set your client's base URL to `\(baseURL)`, or send a \
            request to `POST \(baseURL)/chat/completions`.

            \(keyRequired
              ? "This endpoint requires an API key. Send it as `Authorization: Bearer <api-key>` or `x-api-key`. This is a proxy key, not your provider login."
              : "This endpoint requires no API key. Turn on Require API key in Settings to change that.")
            """,
            entries: [
                Entry(title: "Base URL",
                      detail: "Paste this into any OpenAI-compatible client.",
                      code: baseURL),
                Entry(title: "Request",
                      detail: "Send messages in OpenAI Chat Completions format.",
                      code: "POST \(baseURL)/chat/completions"),
                Entry(title: "Models",
                      detail: backend == .claude
                        ? "These aliases always mean the newest model of each family. Any other Claude model ID, such as `claude-haiku-4-5`, is passed to the CLI as is; an unknown ID returns 404 `model_not_found`."
                        : "These are the listed models. Any other model ID your Codex account offers is passed to Codex as is; an unknown ID returns 404 `model_not_found`.",
                      code: models),
                Entry(title: "Streaming",
                      detail: "Set `stream` to true for SSE chunks ending with `[DONE]`.",
                      code: "{ \"stream\": true }"),
                Entry(title: "Images",
                      detail: "Send `image_url` content parts. Data URLs and public HTTP URLs work.",
                      code: "{ \"type\": \"image_url\", \"image_url\": { \"url\": \"data:image/png;base64,…\" } }"),
                Entry(title: "Function tools",
                      detail: "The proxy returns tool calls to your client. It never runs them.",
                      code: "{ \"tools\": [...], \"tool_choice\": \"auto\" }"),
                Entry(title: "Model access",
                      detail: "\(webDetail) \(isolation)",
                      code: "web only; no host commands or file access"),
                Entry(title: "API key",
                      detail: keyRequired
                        ? "Required. Copy it from \(backend.title) Settings."
                        : "Not required. Requests without one are accepted.",
                      code: keyRequired ? "Authorization: Bearer <api-key>" : "no key needed"),
                Entry(title: "Other routes",
                      detail: "Model list and liveness. `/health` needs no API key.",
                      code: "GET \(baseURL)/models  ·  GET \(rootURL(from: baseURL))/health"),
                Entry(title: "Ignored fields",
                      detail: "Accepted for compatibility and then discarded — the CLI backend exposes no controls for them. Do not rely on them having any effect.",
                      code: "temperature, top_p, max_tokens, n, stop, penalties, seed"),
                Entry(title: "Browser clients",
                      detail: "Requests carrying an `Origin` header are refused with a 403 unless that origin is allowlisted, so a web page cannot spend your subscription. Clients that send no `Origin` are unaffected.",
                      code: "curl · OpenAI SDKs · native apps"),
            ] + (backend == .claude ? claudeOptionEntries : []),
            examples: [
                Example(title: "curl", body: """
                ```bash
                curl \(baseURL)/chat/completions \\
                  -H "Content-Type: application/json" \\
                  \(curlAuth)-d '{
                    "model": "\(defaultModel)",
                    "messages": [{"role": "user", "content": "Hello!"}]
                  }'
                ```
                """),
                Example(title: "curl (streaming)", body: """
                ```bash
                curl -N \(baseURL)/chat/completions \\
                  -H "Content-Type: application/json" \\
                  \(curlAuth)-d '{
                    "model": "\(defaultModel)",
                    "stream": true,
                    "messages": [{"role": "user", "content": "Count to five."}]
                  }'
                ```
                """),
                Example(title: "curl (image)", body: """
                ```bash
                curl \(baseURL)/chat/completions \\
                  -H "Content-Type: application/json" \\
                  \(curlAuth)-d '{
                    "model": "\(defaultModel)",
                    "messages": [{"role": "user", "content": [
                      {"type": "text", "text": "What is in this image?"},
                      {"type": "image_url", "image_url": {"url": "data:image/png;base64,'"$(base64 -i shape.png)"'"}}
                    ]}]
                  }'
                ```
                """),
                Example(title: "Python (openai SDK)", body: """
                ```python
                from openai import OpenAI

                client = OpenAI(base_url="\(baseURL)", api_key="\(sdkKey)")

                response = client.chat.completions.create(
                    model="\(defaultModel)",
                    messages=[{"role": "user", "content": "Hello!"}],
                )
                print(response.choices[0].message.content)
                ```
                """),
                Example(title: "TypeScript (openai SDK)", body: """
                ```ts
                import OpenAI from "openai";

                const client = new OpenAI({
                  baseURL: "\(baseURL)",
                  apiKey: "\(sdkKey)",
                });

                const response = await client.chat.completions.create({
                  model: "\(defaultModel)",
                  messages: [{ role: "user", content: "Hello!" }],
                });
                console.log(response.choices[0].message.content);
                ```
                """),
                Example(title: "Errors", body: """
                Errors use OpenAI's shape: `{ "error": { "message": ..., "type": ... } }`.

                - `403`: the request carried an `Origin` header that is not \
                allowlisted. Browser pages are refused; curl and the SDKs send no \
                `Origin` and are unaffected.
                - `401`: API-key protection is enabled and the key is missing \
                or wrong. Copy it from \(backend.title) Settings and send it as \
                `Authorization: Bearer <api-key>`.
                - `400`: `model` missing or not in (\(models)); `messages` empty; a \
                message has an unknown `role`; a `role: "tool"` message is missing \
                `tool_call_id`; an image has an unsupported media type, invalid \
                base64, or a URL scheme other than `data:`/`http(s)`.
                - `404`: wrong path. Remember `\(baseURL)` is a base URL; the \
                request path is `\(baseURL)/chat/completions`.
                - `502`: the \(backend.title) runtime could not be found, was not \
                signed in, or failed to run.
                """),
            ]
        )
    }

    // MARK: - Voice

    static func voice(endpointURL: String, keyRequired: Bool) -> Section {
        // Third-party clients are configured with an http(s) base URL and append
        // `/listen` themselves, so show them that form rather than the ws:// one.
        let baseURL = endpointURL
            .replacingOccurrences(of: "ws://", with: "http://") + "/v1"

        return Section(
            title: "Voice",
            systemImage: "waveform",
            summary: """
            A local speech-to-text WebSocket backed by Claude. Deepgram clients \
            use `/v1/listen`. TypeWhisper uses the legacy `/` route.

            \(keyRequired
              ? "This endpoint requires an API key. Send it as `Authorization: Token <api-key>`, as `?token=<api-key>`, or as the `token, <api-key>` subprotocol — browser clients cannot set headers, which is why the last two exist."
              : "This endpoint requires no API key. Turn on Require API key in Settings to change that.")

            Connections carrying an `Origin` header are refused unless that \
            origin is allowlisted. WebSockets get no CORS preflight, so this is \
            what keeps a web page from opening a socket here.
            """,
            entries: [
                Entry(title: "Deepgram base URL",
                      detail: "Use this in clients that append `/listen`.",
                      code: baseURL),
                Entry(title: "WebSocket route",
                      detail: "Pass the audio format in the query string.",
                      code: "\(endpointURL)/v1/listen?encoding=linear16&sample_rate=16000&channels=1"),
                Entry(title: "Audio",
                      detail: "Send signed 16-bit PCM in binary frames. Multi-channel audio is mixed to mono.",
                      code: "binary Int16 PCM"),
                Entry(title: "Controls",
                      detail: "Finalize the current segment or close the stream.",
                      code: "{ \"type\": \"CloseStream\" | \"Finalize\" | \"KeepAlive\" }"),
                Entry(title: "Events",
                      detail: "Receive interim and final transcripts, then metadata.",
                      code: "{ \"type\": \"Results\" | \"UtteranceEnd\" | \"Metadata\" | \"Error\" }"),
                Entry(title: "Legacy protocol",
                      detail: "Send 16 kHz mono PCM to `/`. Send `{\"type\":\"end\"}` to finish.",
                      code: endpointURL),
                Entry(title: "Limits",
                      detail: "No word timing, measured confidence, diarization, or batch mode. Segment times are approximate.",
                      code: "stream audio at about real time"),
                Entry(title: "API key",
                      detail: keyRequired
                        ? "Required. Copy it from Voice Settings."
                        : "Not required. Connections without one are accepted.",
                      code: keyRequired
                        ? "Authorization: Token <api-key>  or  ?token=<api-key>"
                        : "no key needed"),
                Entry(title: "Browser clients",
                      detail: "A connection whose `Origin` is not allowlisted is refused with a 403 before the upgrade. Native clients send no `Origin` and are unaffected.",
                      code: "TypeWhisper · native Deepgram clients"),
            ],
            examples: [
                Example(title: "Limitations", body: """
                Claude returns transcript text and segment boundaries.

                - No word-level timing or diarization.
                - Segment timestamps are approximate.
                - `confidence` is a compatibility placeholder, not a measurement.
                - There is no batch endpoint. Stream audio at about real time.
                """),
                Example(title: "curl (handshake check)", body: """
                ```bash
                curl -i -N \\
                  -H "Connection: Upgrade" \\
                  -H "Upgrade: websocket" \\
                  -H "Sec-WebSocket-Version: 13" \\
                  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \\
                  "\(baseURL)/listen?encoding=linear16&sample_rate=16000"
                ```

                A `101 Switching Protocols` response means the endpoint is live.
                """),
                Example(title: "Python (Deepgram protocol)", body: """
                ```python
                import json, websockets

                url = "\(endpointURL)/v1/listen?encoding=linear16&sample_rate=16000&channels=1"

                async with websockets.connect(url) as ws:
                    # Stream interleaved Int16 PCM as binary frames, in real time.
                    for chunk in pcm_chunks:
                        await ws.send(chunk)

                    await ws.send(json.dumps({"type": "CloseStream"}))

                    async for message in ws:
                        event = json.loads(message)
                        if event["type"] == "Results":
                            alt = event["channel"]["alternatives"][0]
                            print(event["is_final"], alt["transcript"])
                        elif event["type"] == "Metadata":
                            break
                ```
                """),
                Example(title: "Python (legacy protocol)", body: """
                ```python
                import json, websockets

                async with websockets.connect("\(endpointURL)") as ws:
                    # Stream Int16 PCM @ 16 kHz mono as binary frames.
                    for chunk in pcm_chunks:
                        await ws.send(chunk)

                    await ws.send(json.dumps({"type": "end"}))

                    async for message in ws:
                        event = json.loads(message)
                        if event["type"] == "final":
                            print(event)
                            break
                ```
                """),
                Example(title: "Errors", body: """
                Deepgram-protocol failures arrive as an `Error` message and the \
                socket closes:

                - When API-key protection is enabled, a missing or wrong API key \
                is refused with a 401 before the socket opens, not as an `Error` \
                message.
                - Missing `encoding`, or an `encoding` other than `linear16`.
                - Missing or invalid `sample_rate`, or `channels` outside 1 to 8.
                - An unknown path. Use `/v1/listen` or `/listen` for the Deepgram \
                protocol, or `/` for the legacy one.
                - The Claude OAuth token could not be read or has expired. Run \
                Claude Code once to refresh it.
                """),
            ]
        )
    }

    // MARK: - Markdown

    /// Serialize one section as standalone Markdown.
    static func markdown(for section: Section) -> String {
        """
        # LLM Proxy: \(section.title) API

        \(section.summary)

        ## Reference

        \(body(of: section, headingLevel: 3))
        """
    }

    /// Serialize several sections as one document, for the "copy everything" case.
    static func markdown(for sections: [Section]) -> String {
        let body = sections.map { section in
            """
            ## \(section.title)

            \(section.summary)

            ### Reference

            \(self.body(of: section, headingLevel: 4))
            """
        }.joined(separator: "\n\n---\n\n")

        return """
        # LLM Proxy API reference

        LLM Proxy runs local servers on this machine. Chat exposes Claude Code \
        and Codex models through an OpenAI-compatible API; Voice exposes Claude \
        speech-to-text through WebSocket APIs. Both are loopback-only \
        (`127.0.0.1`). Optional API-key protection can be enabled separately for \
        each endpoint.

        \(body)
        """
    }

    /// A section's entries and examples, with entry/example headings rendered at
    /// `headingLevel` and the "Examples" divider one level above it.
    private static func body(of section: Section, headingLevel: Int) -> String {
        let hash = String(repeating: "#", count: headingLevel)
        let parentHash = String(repeating: "#", count: headingLevel - 1)

        let entries = section.entries.map { entry in
            "\(hash) \(entry.title)\n\n\(entry.detail)\n\n```\n\(entry.code)\n```"
        }.joined(separator: "\n\n")

        let examples = section.examples.map { example in
            "\(hash) \(example.title)\n\n\(example.body)"
        }.joined(separator: "\n\n")

        return "\(entries)\n\n\(parentHash) Examples\n\n\(examples)"
    }

    /// `http://127.0.0.1:8787/v1` → `http://127.0.0.1:8787`. `/health` lives at
    /// the server root, not under `/v1`.
    private static func rootURL(from baseURL: String) -> String {
        guard baseURL.hasSuffix("/v1") else { return baseURL }
        return String(baseURL.dropLast(3))
    }
}
