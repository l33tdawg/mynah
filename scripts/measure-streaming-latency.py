#!/usr/bin/env python3
"""Measure time-to-first-token against total turn time on a local Ollama brain.

    ./scripts/measure-streaming-latency.py qwen3.5:4b

Needs a running Ollama and, to be worth reading, the real system prompt:

    SYSTEM_PROMPT_FILE=/tmp/mynah-voice-system-prompt.txt \\
      ./scripts/measure-streaming-latency.py qwen3.5:4b

**Why this exists.** `OllamaClient` sends `"stream": false`, so the appliance
waits for an entire generation and then shows all of it at once. The question
"would streaming help, and by how much" was about to be answered by turning the
knob and asking whether it felt better. It is answerable instead: the gap
between first token and last token is exactly the silence streaming removes,
and it can be measured without changing a line of Swift.

Reports, per utterance:

    ttft   seconds until the first content token arrives
    total  seconds until generation ends
    gap    total - ttft, which is the silence streaming would fill

A large gap means streaming is worth the plumbing. A gap near zero means the
time is all prefill and streaming would change nothing the owner can see, which
is a real possible answer and the reason to measure before building.

Do not quote a result without saying which model, which prompt, and when.

**Close the app AND stop the daemon first.** Concurrent inference on the same
host does not merely add noise, it invalidates the run. First attempt,
2026-07-31, with the GUI closed but `local.sage.voicebridge` still answering
Signal: ttft 262-484s against turns observed at 10-30s live, rising
monotonically across five utterances. The Ollama log showed two alternating
prompt sizes, this script's and the daemon's, on a server with one slot. Those
numbers are void and are recorded here only so nobody repeats the setup:

    launchctl bootout gui/$UID/local.sage.voicebridge   # and bootstrap it after

One thing that run did establish, because it is not a timing claim: two of the
five utterances returned ZERO content chunks. qwen3.5 is a thinking model and
put the whole answer in its reasoning field, so a client streaming `content`
shows the owner nothing at all until reasoning ends. Whether streaming helps
therefore depends on streaming *thinking*, which is a different feature from
the one "just turn on stream:true" describes.
"""
import json, os, pathlib, sys, time, urllib.request

OLLAMA = "http://127.0.0.1:11434/api/chat"

_default = ("You are Mynah, a voice assistant. Use a tool when one fits the "
            "request. If no tool fits, just reply normally.")
_path = os.environ.get("SYSTEM_PROMPT_FILE")
SYSTEM = open(_path).read() if _path else _default

# Deliberately tool-free and answerable, because this measures generation
# latency, not routing. A turn that calls a tool spends its time somewhere else
# entirely and would confound the one number this script exists to produce.
UTTERANCES = [
    "what is on my plate today",
    "give me three ideas for dinner tonight",
    "explain in a few sentences why the sky is blue",
    "summarise what we talked about earlier",
    "are you still there",
]


def measure(model, utterance, timeout=180):
    """One streamed turn. Returns (ttft, total, tokens)."""
    body = json.dumps({
        "model": model,
        "messages": [{"role": "system", "content": SYSTEM},
                     {"role": "user", "content": utterance}],
        "stream": True,
        "options": {"temperature": 0},
    }).encode()
    req = urllib.request.Request(OLLAMA, data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    ttft = None
    tokens = 0
    with urllib.request.urlopen(req, timeout=timeout) as r:
        for raw in r:
            raw = raw.strip()
            if not raw:
                continue
            chunk = json.loads(raw)
            piece = chunk.get("message", {}).get("content", "")
            if piece:
                tokens += 1
                if ttft is None:
                    ttft = time.time() - t0
            if chunk.get("done"):
                break
    total = time.time() - t0
    return (ttft if ttft is not None else total), total, tokens


if __name__ == "__main__":
    model = sys.argv[1]
    print(f"=== {model} · system {len(SYSTEM)} chars ===")
    gaps = []
    for utterance in UTTERANCES:
        try:
            ttft, total, tokens = measure(model, utterance)
        except Exception as e:
            print(f"  ERROR {type(e).__name__} on {utterance!r}")
            continue
        gap = total - ttft
        gaps.append((ttft, total, gap))
        print(f"  {utterance[:44]:46} ttft={ttft:5.1f}s  total={total:5.1f}s  "
              f"gap={gap:5.1f}s  ({tokens} chunks)")
    if gaps:
        n = len(gaps)
        print(f"\n  --> mean ttft {sum(g[0] for g in gaps)/n:.1f}s, "
              f"mean total {sum(g[1] for g in gaps)/n:.1f}s, "
              f"mean gap {sum(g[2] for g in gaps)/n:.1f}s")
        print("      The gap is the silence streaming removes. "
              "Small gap = streaming buys the owner nothing.")
