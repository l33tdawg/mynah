"""Speaks for the appliance, locally.

macOS ships two classes of voice and only one of them is any good. The compact
voices `say` falls back on are the robotic ones; the Premium and Enhanced voices
are a separate download with no command-line path — no MobileAsset tooling on
this machine, and `/System/Library/Speech/Voices` empty. On an appliance that is
meant to run headless, "open System Settings and click Manage Voices" is not an
answer.

Kokoro is. 82M parameters, Apache 2.0, and measured on this Mac mini at a
real-time factor of about 0.29 — roughly three and a half times faster than
speech. That is the whole reason it is viable here: Qwen3-TTS sounds excellent
and takes nine seconds a sentence, which is a dead line rather than a voice.

Deliberately not edge-tts, which the phone bridge next door uses. That is
Microsoft's cloud service: it costs a network round trip on every sentence, and
it sends the owner's private conversation to a third party — on the one product
whose argument is that their words stay on their machine.

Serves the shape KokoroHTTPSynthesizer already speaks, so nothing on the Swift
side had to be invented for it.
"""

import io
import logging
import os
import time
import wave

import numpy as np
from scipy.signal import resample_poly
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel
from kokoro_onnx import Kokoro

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_VOICE = os.environ.get("KOKORO_VOICE", "am_michael")

# What the caller's phone expects. Opus runs at 48 kHz and Kokoro emits 24, so
# something has to convert — and this is the right place for it. The server owns
# the audio format; doing it in the appliance would put a resampler in the audio
# path, where a subtle error is inaudible in testing and awful on a real call.
OUTPUT_RATE = int(os.environ.get("KOKORO_RATE", "48000"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("kokoro")

app = FastAPI()

# Loaded once, at import, and held. The model takes about three quarters of a
# second to load; paying that per request would double the latency of every
# sentence and be the single largest cost in a spoken reply.
log.info("loading kokoro")
_started = time.time()
_kokoro = Kokoro(
    os.path.join(HERE, "kokoro-v1.0.onnx"),
    os.path.join(HERE, "voices-v1.0.bin"),
)
log.info("kokoro ready in %.2fs", time.time() - _started)


class SpeechRequest(BaseModel):
    text: str
    voice: str | None = None
    speed: float = 1.0


@app.get("/")
def health():
    """What the Swift client probes before it commits to this backend.

    It falls back to `say` when this is unreachable, so the check has to be
    honest and cheap: no synthesis, just proof the process is up with the model
    resident.
    """
    return {"ok": True, "voices": len(_kokoro.get_voices()), "default": DEFAULT_VOICE}


@app.get("/voices")
def voices():
    return {"voices": sorted(_kokoro.get_voices())}


@app.post("/api/speech")
def speak(request: SpeechRequest):
    text = request.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="no text")

    voice = request.voice or DEFAULT_VOICE
    if voice not in _kokoro.get_voices():
        # Named rather than substituted. A voice that silently becomes a
        # different voice is a bug the owner hears and cannot explain.
        raise HTTPException(status_code=400, detail=f"unknown voice {voice}")

    started = time.time()
    try:
        samples, rate = _kokoro.create(text, voice=voice, speed=request.speed, lang="en-us")
    except Exception as error:  # noqa: BLE001 - surfaced to the caller as 500
        log.exception("synthesis failed")
        raise HTTPException(status_code=500, detail=str(error)) from error

    if rate != OUTPUT_RATE:
        # Polyphase rather than interpolation. 24 to 48 kHz is an exact doubling,
        # and resample_poly filters the images properly instead of leaving them
        # to fold back as the metallic edge that makes synthesis sound cheap —
        # which is the specific thing this whole exercise is meant to remove.
        from math import gcd
        divisor = gcd(OUTPUT_RATE, rate)
        samples = resample_poly(samples, OUTPUT_RATE // divisor, rate // divisor)
        rate = OUTPUT_RATE

    # Float to signed 16-bit, which is what the WAV contract promises and what
    # Opus takes. Clipped before scaling: Kokoro occasionally overshoots 1.0 on
    # plosives, and wrapping there is an audible click rather than a loud sample.
    clipped = np.clip(samples, -1.0, 1.0)
    pcm = (clipped * 32767.0).astype("<i2")

    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(pcm.tobytes())

    audio_seconds = len(samples) / rate
    took = time.time() - started
    log.info(
        "%s: %.2fs for %.2fs of audio (rtf %.2f) %r",
        voice, took, audio_seconds, took / max(audio_seconds, 0.01), text[:60],
    )
    return Response(content=buffer.getvalue(), media_type="audio/wav")
