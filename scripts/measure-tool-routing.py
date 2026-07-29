#!/usr/bin/env python3
"""Re-run the 12-utterance routing set against a local Ollama brain.

    ./scripts/measure-tool-routing.py qwen3.5:4b

Needs a running Ollama and a schema dump. Get the schemas with:

    printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}\\n{"jsonrpc":"2.0","method":"notifications/initialized"}\\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\\n' \\
      | /Applications/SAGE.app/Contents/MacOS/sage-gui mcp > /tmp/mcp_tools.jsonl

**This script is the point.** The claim it replaces — "27 tools = 5-6/12,
14 tools = 12/12" — was quoted for weeks and could not be checked, because the
set that produced it was never written down. Whatever this measures, the next
person can re-measure. Do not quote a result from it without also saying which
model, which tool count, and when.

Note: measure one model at a time. Concurrent inference on the same host
distorts the per-turn latency, which is the axis the effect actually shows up on.

Also note: not every local model can do tool calling at all. `gemma3:12b` and
`llama3:latest` return HTTP 400 "does not support tools", which this harness
reports as twelve misses — a zero that means "never asked", not "asked and got
it wrong". Check the model supports tools before reading a 0/12 as a score.

Settles whether BrainPrompts.swift:193 ("27 tools = 5-6/12, 14 tools = 12/12",
measured on qwen3.5:4b) is reproducible, and whether the degradation it claims
is a small-model property — by sweeping model size with everything else held
fixed: same MCP schemas, same utterances, same temperature, same host.

Scores NAME ONLY. This measures routing, not argument quality; conflating the
two is how a 12/12 stops being reproducible.
"""
import json, sys, time, urllib.request

OLLAMA = "http://127.0.0.1:11434/api/chat"

# The 14 SAGE names in BrainPrompts.voiceToolAllowlist. web_search and the note
# tools are published locally rather than by SAGE, so they are out of scope for
# a 14-vs-27 comparison — which is the comparison the disputed claim makes.
ALLOWLIST = {
    "sage_recall", "sage_remember", "sage_forget", "sage_list", "sage_task",
    "sage_backlog", "sage_timeline", "sage_status", "sage_reflect",
    "sage_inbox", "sage_find_agent", "sage_pipe", "sage_pipe_result",
    "sage_federation",
}

# Nine positives, all served by tools present in BOTH catalogue sizes, so a
# miss is a routing failure and never "the model was never shown the tool".
# Three negatives, because the failure curation exists to fix is OVER-triggering
# and twelve tool-calling utterances score 12/12 on a model that calls a tool
# for "thanks bro that's all".
CASES = [
    ("What did we decide about the DMG signing thing?",              "sage_recall"),
    ("Remember that the Apple account for this is l33tdawg at hackinthebox dot org.", "sage_remember"),
    ("What's on my plate?",                                          "sage_backlog"),
    ("Add a task to measure time to first token on DeepSeek.",       "sage_task"),
    ("What have I been working on this week?",                       "sage_timeline"),
    ("Is anything waiting for me from the other agents?",            "sage_inbox"),
    ("Forget what I told you about the old relay address.",          "sage_forget"),
    ("Which agent is handling the Chrome work?",                     "sage_find_agent"),
    ("Is the SAGE node healthy?",                                    "sage_status"),
    ("Thanks bro, that's all.",                                      None),
    ("Can you say that again but shorter?",                          None),
    ("Good morning.",                                                None),
]

# The appliance's real voice system prompt is ~7.2 KB. A 109-character stand-in
# is not a smaller version of it — total context is what the model routes
# against, so a short prompt could easily hide an effect that only appears when
# a large prompt and a large catalogue are present together. Pass the real one
# via SYSTEM_PROMPT_FILE; the default is stated as an approximation, not a
# control.
import os
_default = ("You are Mynah, a voice assistant. Use a tool when one fits the "
            "request. If no tool fits, just reply normally.")
_path = os.environ.get("SYSTEM_PROMPT_FILE")
SYSTEM = open(_path).read() if _path else _default


def load_tools():
    tools = None
    for line in open("/tmp/mcp_tools.jsonl"):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("id") == 2:
            tools = d["result"]["tools"]
    if not tools:
        sys.exit("no tools/list response in /tmp/mcp_tools.jsonl")
    return [{"type": "function",
             "function": {"name": t["name"],
                          "description": t.get("description", ""),
                          "parameters": t.get("inputSchema", {"type": "object"})}}
            for t in tools]


def ask(model, tools, utterance, timeout=180):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "system", "content": SYSTEM},
                     {"role": "user", "content": utterance}],
        "tools": tools,
        "stream": False,
        "options": {"temperature": 0},
    }).encode()
    req = urllib.request.Request(OLLAMA, data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.load(r)
    elapsed = time.time() - t0
    calls = d.get("message", {}).get("tool_calls") or []
    name = calls[0]["function"]["name"] if calls else None
    return name, elapsed


def run(model, tools, label):
    correct, total_t, rows = 0, 0.0, []
    for utterance, expected in CASES:
        try:
            got, dt = ask(model, tools, utterance)
        except Exception as e:
            got, dt = f"ERROR:{type(e).__name__}", 0.0
        ok = (got == expected)
        correct += ok
        total_t += dt
        rows.append((ok, utterance[:44], expected or "(none)", got or "(none)", dt))
    print(f"\n=== {model} · {label} ({len(tools)} tools, "
          f"{len(json.dumps(tools))} bytes, system {len(SYSTEM)} chars) ===")
    for ok, u, exp, got, dt in rows:
        mark = "OK  " if ok else "MISS"
        print(f"  {mark} {u:46} want={exp:16} got={got:16} {dt:5.1f}s")
    print(f"  --> {correct}/12 correct, {total_t/12:.1f}s/turn avg")
    return correct, total_t / 12


if __name__ == "__main__":
    model = sys.argv[1]
    full = load_tools()
    curated = [t for t in full if t["function"]["name"] in ALLOWLIST]
    results = {}
    for label, tools in (("curated", curated), ("full", full)):
        results[label] = run(model, tools, label)
    c, ct = results["curated"]
    f, ft = results["full"]
    print(f"\nSUMMARY {model}: curated({len(curated)})={c}/12 @{ct:.1f}s  "
          f"full({len(full)})={f}/12 @{ft:.1f}s  delta={c-f:+d}")
