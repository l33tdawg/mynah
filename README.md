# SAGE Voice Bridge

Voice-operated **agent manager** for a SAGE federation. Runs on an always-on
Mac; you reach it by voice message from anywhere and it acts across every SAGE
node you've connected.

    voice note -> ASR (local) -> agent loop over SAGE MCP tools -> reply

## Status

Phase 1, in progress.

- [x] ASR core lifted from QuietType, builds standalone, verified on-device
- [ ] Ollama brain (qwen3.5:4b) + SAGE MCP tool loop
- [ ] Signal transport (signal-cli JSON-RPC)
- [ ] TTS (TTSKit, replacing Kokoro)
- [ ] App bundle (SAGE + Ollama + models, like QuietType bundles SAGE)

## Layout

- `Sources/SageVoiceCore` — ASR + correction/personalization layer
- `Sources/sage-voiced` — daemon (currently a transcribe smoke harness)

## Measured on the target hardware (Mac mini M2, 16GB)

| | |
|---|---|
| ASR | WhisperKit large-v3 on ANE, ~1.1s per short clip (~4.8x realtime) |
| Brain | qwen3.5:4b — 4.1s avg, 91% routing at 22 tools |
| Cold start | ~87s first model load, ~6s warm |

Audio never leaves the machine: the transcriber refuses non-loopback endpoints.
