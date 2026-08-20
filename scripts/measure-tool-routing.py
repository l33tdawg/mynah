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
import json, pathlib, sys, time, urllib.request

OLLAMA = "http://127.0.0.1:11434/api/chat"

# The SAGE names in BrainPrompts.voiceToolAllowlist. web_search and the note
# tools are published locally rather than by SAGE, so they are out of scope
# here — but they are NOT out of scope for the ceiling, see COMPOSED_EXTRAS.
#
# **This set had drifted, and the drift is exactly what the comment it replaces
# said would end the numbers' meaning.** Checked against Swift on 19 Aug 2026:
# it still measured `sage_list`, `sage_reflect`, `sage_find_agent`, `sage_pipe`
# and `sage_pipe_result` — five names the appliance does not offer, two of them
# (`sage_pipe`, `sage_pipe_result`) removed *because the model misused them*,
# `sage_pipe_result` having written into another agent's inbox when the owner
# asked for an update. It was missing `sage_directory`, `sage_message_send`,
# `sage_message_reply` and `sage_message_history`, all four of which ship.
#
# So every score this produced described a catalogue nobody runs. Corrected to
# the fifteen that ship. If you change `BrainPrompts.voiceToolAllowlist`, change
# this in the same commit — `VoiceRoutingUtterances` pins the utterances, and
# nothing pins this, which is how it drifted for months.
ALLOWLIST = {
    "sage_recall", "sage_remember", "sage_forget", "sage_task",
    "sage_backlog", "sage_timeline", "sage_status", "sage_inbox",
    "sage_directory", "sage_federation", "sage_corroborate", "sage_link",
    "sage_message_send", "sage_message_reply", "sage_message_history",
}

# What the composed catalogue carries besides SAGE: four note tools and
# web_search. The ceiling in `BrainCapabilities.maxRoutableTools` counts the
# COMPOSED total, not the SAGE slice, so a sweep that reports only the SAGE
# count is answering a different question from the one the ceiling asks. Every
# size below is therefore printed both ways.
COMPOSED_EXTRAS = 5

# The order distractors are added in for the sweep.
#
# `sage_message_status` first because it is the one actually being proposed —
# so the second row of the sweep IS the catalogue a hosted brain is offered
# today, rather than an abstraction near it. The rest follow in sorted order so
# that a rerun measures the same catalogues in the same sequence.
FIRST_DISTRACTOR = "sage_message_status"

# Nine positives, all served by tools present in BOTH catalogue sizes, so a
# miss is a routing failure and never "the model was never shown the tool".
# Three negatives, because the failure curation exists to fix is OVER-triggering
# and twelve tool-calling utterances score 12/12 on a model that calls a tool
# for "thanks bro that's all".
# The set lives in ONE file, read by this script and by the Swift fixture test.
# Two copies under a comment saying they agree is how `deepseek-chat` survived
# in this repo for weeks; the same mistake here would silently decouple the
# numbers from the set they were measured against, which is the entire failure
# this harness exists to end.
_FIXTURE = (pathlib.Path(__file__).resolve().parent.parent
            / "Tests/Fixtures/voice-routing-utterances.json")
CASES = [(c["utterance"], c["expected"])
         for c in json.loads(_FIXTURE.read_text())["cases"]]

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


# Sentences appended to SAGE's own descriptions before routing, when
# MYNAH_TOOL_HINTS=1. SAGE writes for a capable agent; the owner speaks like a
# person, and three of the twelve utterances miss at EVERY catalogue size below
# the cliff because of the gap between those two — a failure curation cannot
# reach, since it is the same at 15 tools and at 22.
#
# Kept in a fixture rather than inline so the wording that wins here is the
# wording Swift ships, checked by a test. Same arrangement as the utterances,
# and for the same reason: two copies under a comment claiming they agree is how
# this script's tool list silently stopped describing the appliance.
_HINTS = (pathlib.Path(__file__).resolve().parent.parent
          / "Tests/Fixtures/spoken-tool-hints.json")


def apply_hints(tools):
    if os.environ.get("MYNAH_TOOL_HINTS") != "1":
        return tools
    hints = json.loads(_HINTS.read_text())["hints"]
    out = []
    for t in tools:
        t = {"type": t["type"], "function": dict(t["function"])}
        hint = hints.get(t["function"]["name"])
        if hint:
            t["function"]["description"] = (
                t["function"]["description"].rstrip() + " " + hint
            )
        out.append(t)
    return out


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


def sweep_sizes(full, curated):
    """Catalogues of growing size, holding WHICH tools matter constant.

    The two-point curated-vs-full comparison this replaces answers "is a big
    catalogue worse than a small one". It cannot answer "how much bigger may
    this one get", which is the question a ceiling actually asks — and the
    question somebody has to answer before moving one.

    Every catalogue here contains all fifteen shipped names, so the nine
    positives are always routable and a miss is always a routing failure rather
    than a tool the model was never shown. Only the number of distractors
    changes.
    """
    names = {t["function"]["name"] for t in curated}
    rest = [t for t in full if t["function"]["name"] not in names]
    rest.sort(key=lambda t: (t["function"]["name"] != FIRST_DISTRACTOR,
                             t["function"]["name"]))
    out = [("ships today", curated)]
    for extra in (1, 2, 4, 7, 12):
        if extra > len(rest):
            break
        out.append((f"+{extra}", curated + rest[:extra]))
    out.append(("everything SAGE publishes", full))
    return out


if __name__ == "__main__":
    model = sys.argv[1]
    full = apply_hints(load_tools())
    curated = [t for t in full if t["function"]["name"] in ALLOWLIST]
    if os.environ.get("MYNAH_TOOL_HINTS") == "1":
        print("note: spoken hints applied from Tests/Fixtures/spoken-tool-hints.json")

    missing = ALLOWLIST - {t["function"]["name"] for t in full}
    if missing:
        print(f"warning: this node does not publish {sorted(missing)} — "
              "the curated row is smaller than what ships", file=sys.stderr)

    rows = []
    for label, tools in sweep_sizes(full, curated):
        correct, per_turn = run(model, tools, label)
        rows.append((label, len(tools), correct, per_turn))

    print(f"\nSUMMARY {model}")
    print(f"  {'catalogue':28} {'sage':>4} {'composed':>8} {'score':>7} {'s/turn':>7}")
    for label, n, correct, per_turn in rows:
        print(f"  {label:28} {n:>4} {n + COMPOSED_EXTRAS:>8} {correct:>4}/12 {per_turn:>6.1f}")
    print("\n  'composed' is what BrainCapabilities.maxRoutableTools bounds: the")
    print(f"  SAGE slice plus {COMPOSED_EXTRAS} tools this repository publishes itself.")
    print("  Quote a number from here with the model, the date and the count, or")
    print("  it becomes the unfalsifiable claim this script was written to end.")
