#!/usr/bin/env bash
#
# Live tool-calling check of the Chat endpoint against the REAL Claude backend.
#
#   ./Scripts/tool-call-test.sh                 # haiku, 10 runs per case, port 8802
#   ./Scripts/tool-call-test.sh sonnet 5 8850   # model, runs per case, port
#   ./Scripts/tool-call-test.sh gpt-5.6-luna 5  # gpt-* models run against Codex
#
# The request is Ral's real chat request (system prompt + 12 function tools,
# dumped from ral/src/main/chat into fixtures/ral-chat-tools.json). Each case is
# sent RUNS times; a case passes only if every run does what it should, because
# the bug this guards against was probabilistic (2 of 6 runs called the tool).
#
# Exits non-zero if any case fails.
set -uo pipefail
cd "$(dirname "$0")/.."

MODEL="${1:-haiku}"
RUNS="${2:-10}"
PORT="${3:-8802}"
ACCESS_KEY="llmp-toolcall"
if [[ "$MODEL" == gpt-* ]]; then
    SERVER_FLAG="--codex-server"; KEY_VAR="LLM_PROXY_ACCESS_KEY_CODEX"
else
    SERVER_FLAG="--chat-server"; KEY_VAR="LLM_PROXY_ACCESS_KEY_CLAUDE"
fi
LOG="${TMPDIR:-/tmp}/tool-call-test-server.log"

cleanup() { [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null; }
trap cleanup EXIT

echo "Building…"
swift build 2>&1 | tail -2
pkill -f -- "-server $PORT" 2>/dev/null; sleep 1
env "$KEY_VAR=$ACCESS_KEY" ./.build/debug/LLMProxy "$SERVER_FLAG" "$PORT" > "$LOG" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 20); do
    sleep 1
    curl -s --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null && break
done
curl -s --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null || { echo "server did not start (see $LOG)"; exit 1; }
echo "Server up on :$PORT — model $MODEL, $RUNS runs per case"

python3 - "$PORT" "$ACCESS_KEY" "$MODEL" "$RUNS" Scripts/fixtures/ral-chat-tools.json <<'PY'
import json, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor

port, key, model, runs, fixture_path = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
fixture = json.load(open(fixture_path))
URL = f"http://127.0.0.1:{port}/v1/chat/completions"

def body(messages, stream=False, **extra):
    return {"model": model, "stream": stream, "tools": fixture["tools"],
            "messages": [{"role": "system", "content": fixture["system"]}] + messages, **extra}

def post(payload):
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(), method="POST",
                                 headers={"content-type": "application/json", "authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=300) as r:
        raw = r.read().decode()
    if not payload["stream"]:
        msg = json.loads(raw)["choices"][0]["message"]
        return [c["function"]["name"] for c in msg.get("tool_calls") or []], msg.get("content") or ""
    calls, text = {}, ""
    for line in raw.splitlines():
        if not line.startswith("data: ") or line == "data: [DONE]":
            continue
        delta = json.loads(line[6:])["choices"][0]["delta"]
        text += delta.get("content") or ""
        for c in delta.get("tool_calls") or []:
            name = (c.get("function") or {}).get("name")
            if name:
                calls[c["index"]] = name
    return list(calls.values()), text

def user(text):
    return [{"role": "user", "content": text}]

def calls(name):
    return lambda names, text: (name in names, f"called {names}" if names else f"text: {text[:160]!r}")

def answers(must_contain=""):
    def check(names, text):
        if names:
            return False, f"called {names}"
        ok = bool(text.strip()) and must_contain.lower() in text.lower()
        return ok, f"text: {text[:160]!r}"
    return check

FOLLOW_UP = user("whats on my calendar today") + [
    {"role": "assistant", "content": None, "tool_calls": [{"id": "call_1", "type": "function",
     "function": {"name": "calendar_events", "arguments": json.dumps(
         {"from": "2026-10-03T00:00:00+05:30", "to": "2026-10-04T00:00:00+05:30"})}}]},
    {"role": "tool", "tool_call_id": "call_1",
     "content": "- Sat 3 Oct 2026, 17:00 – 17:45 · Dentist with Dr. Okafor (at Indiranagar)"},
]

CASES = [
    ("calendar today (the reported prompt)", body(user("whats on my calendar today")), calls("calendar_events")),
    ("calendar today, streamed",            body(user("whats on my calendar today"), stream=True), calls("calendar_events")),
    ("calendar tomorrow",                   body(user("What's on my calendar tomorrow?")), calls("calendar_events")),
    ("meetings today",                      body(user("do I have meetings today")), calls("calendar_events")),
    ("downloads folder",                    body(user("what's in my Downloads folder")), calls("list_directory")),
    ("notes search",                        body(user("find my notes about wifi")), calls("search_notes")),
    ("copy to clipboard",                   body(user("copy 'hello world' to my clipboard")), calls("copy_to_clipboard")),
    ("tool_choice required",                body(user("hello"), tool_choice="required"), lambda n, t: (bool(n), f"called {n}" if n else f"text: {t[:160]!r}")),
    ("tool_choice names a function",        body(user("what's on my calendar today?"), tool_choice={"type": "function", "function": {"name": "search_notes"}}), calls("search_notes")),
    ("follow-up uses the tool result",      body(FOLLOW_UP), answers("Okafor")),
    ("general question needs no tool",      body(user("What is the capital of Portugal?")), answers("Lisbon")),
    ("tool_choice none answers in text",    body(user("whats on my calendar today"), tool_choice="none"), answers()),
]

def run(case):
    name, payload, check = case
    try:
        return check(*post(payload))
    except Exception as e:
        return False, f"error: {e}"

failed = 0
with ThreadPoolExecutor(max_workers=4) as pool:
    for name, payload, check in CASES:
        results = list(pool.map(run, [(name, payload, check)] * runs))
        passed = sum(ok for ok, _ in results)
        mark = "PASS" if passed == runs else "FAIL"
        print(f"{mark}  {passed:>2}/{runs}  {name}")
        for ok, detail in results:
            if not ok:
                print(f"           ↳ {detail}")
        failed += passed != runs

print()
print("All cases passed." if failed == 0 else f"{failed} case(s) failed.")
sys.exit(1 if failed else 0)
PY
