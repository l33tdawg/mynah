# SAGE Voice Bridge

Voice-operated **agent manager** for a SAGE federation. Runs on an always-on
Mac; you reach it by voice message from anywhere and it acts across every SAGE
node you've connected.

    voice note -> ASR (local) -> agent loop over SAGE MCP tools -> reply

Not a voice assistant. The verbs are *send this to the MacBook agent*, *what's
on the mini's plate*, *remind Amy's desktop agent about the inbox*.

## Status

Phase 1. The subsystems exist and are tested; the daemon that wires them
together does not yet.

- [x] ASR core lifted from QuietType, builds standalone, verified on-device
- [x] Brain: `BrainBackend` protocol — local Ollama and cloud providers as peers
- [x] SAGE MCP client + agent tool loop, verified against a live node
- [x] First-run environment probe + install-time provider picker
- [x] SAGE vendored into the app bundle (build-time, verified)
- [x] Speech synthesis (Kokoro over loopback HTTP)
- [~] Signal transport — written, **never run against a real signal-cli daemon**
- [ ] The daemon: Signal -> ASR -> brain -> TTS -> Signal, end to end
- [ ] `package-app.sh` — copy SAGE into `Resources` and codesign the bundle
- [ ] Google OAuth client + consent-screen verification

## Layout

    Sources/SageVoiceCore
      ├── (top level)   ASR + correction/personalisation, lifted from QuietType
      ├── Brain/        BrainBackend protocol, Ollama/Anthropic/OpenAI-compat,
      │                 MCP client, agent tool loop
      ├── Setup/        environment probe, provider picker, SAGE provisioning
      ├── Speech/       synthesis protocol, Kokoro backend, WAV codec
      └── Transport/    signal-cli JSON-RPC client + sender allowlist
    Sources/sage-voiced  smoke harness (transcribe / brain / setup / verify-sage)
    scripts/             build-time SAGE vendoring

## Choosing a brain

The model is an install-time choice, not a compile-time one. `EnvironmentProbe`
detects what this Mac can actually offer and `BrainSetupPlanner` ranks it —
zero-friction first, fully-local always offered when the hardware allows.

An ambient API key ranks *below* an already-signed-in CLI on purpose:
recommending a metered path over a flat-rate subscription the owner already
pays for is a quiet way to spend their money.

`OpenAICompatBackend` covers OpenAI, DeepSeek, Kimi, Groq, Gemini and LM Studio
as configuration rather than code. Gemini matters most — its OpenAI-compatible
endpoint takes the same wire format whether authenticated by API key or by an
OAuth token, which is what makes sign-in-with-Google cheap to add.

    sage-voiced setup                    # what this Mac can offer, ranked
    sage-voiced brain "what's on the mini's plate?"

## Measured

On the target hardware — Mac mini M2, 16GB, macOS 26.5:

| | |
|---|---|
| ASR | WhisperKit large-v3 on ANE, ~1.1s per short clip (~4.8x realtime) |
| ASR cold start | ~87s first model load, ~6s warm |
| Brain, single call | qwen3.5:4b, 4.1s avg, 92% tool-selection accuracy |
| **Brain, real turn** | **18–29s end to end; 77s worst case on a large `sage_recall`** |
| Tool routing | 12/12 on the curated 14-tool set; 5–6/12 on all 27 |

Two of these correct earlier claims and are worth stating plainly:

**4.1s is a single model call, not a voice turn.** A turn is 2+ model calls plus
tool execution. The first tuning lever is `maxToolResultCharacters`.

**Tool-surface size does degrade routing badly.** An earlier measurement said it
didn't; that test used distractor tools with thin `{arg: string}` schemas. Against
SAGE's real 27 schemas the curated subset scores twice as well, which is why
`ToolLoop` fails *closed* when its allowlist matches nothing rather than widening
to the full catalogue.

## Privacy

Audio never leaves the machine: ASR is local and the transcriber refuses
non-loopback endpoints, including via redirect.

Whether *text* leaves depends on the brain you pick, and the setup screen says
so per option rather than making you infer it. Fully-local is offered whenever
the hardware supports it.

## Build

    swift build && swift test
    scripts/vendor-sage.sh          # vendors SAGE.app for bundling

Zero external dependencies — Foundation and CryptoKit only. macOS 13+,
Apple Silicon (WhisperKit runs on the Neural Engine).

## Not yet verified

Stated because "builds and has tests" is not the same as "works":

- The cloud backends have never touched their real APIs. Wire encoding is
  tested against captured payloads and against a live OpenAI-compatible server;
  auth headers and per-provider error translation are not.
- `SignalClient` has never talked to a real signal-cli daemon.
- No real `sage_pipe` send between two agents.
- TTSKit vs Kokoro is unresolved; Kokoro is what currently ships.
