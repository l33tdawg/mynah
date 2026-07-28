#!/usr/bin/env bash
# Produces the two signed speech engines and their models for package-app.sh.
#
# Every source is revision-pinned and every opaque binary download has a
# SHA-256. This is a release-machine step; the owner never runs it and the
# resulting executables are staged before the app is codesigned/notarized.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASR_ROOT="${SAGE_VOICE_ASR_ROOT:-$ROOT/vendor/asr}"
SOURCE_ROOT="$ASR_ROOT/src"
BIN_ROOT="$ASR_ROOT/bin"
MODEL_ROOT="$ASR_ROOT/models"

WHISPER_CPP_VERSION="v1.9.1"
WHISPER_CPP_ARCHIVE_SHA="147267177eef7b22ec3d2476dd514d1b12e160e176230b740e3d1bd600118447"
ARGMAX_REVISION="dcf3a00f0ae4d5b57bc0aad92063b102b70d5fd1"
WHISPERKIT_REVISION="97a5bf9bbc74c7d9c12c755d04dea59e672e3808"
TOKENIZER_REVISION="06f233fe06e710322aca913c1bc4249a0d71fce1"
GGML_REVISION="c521a4b02f422512d734391fdf08bb08c0862f68"
GGML_SMALL_EN_SHA="c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
WHISPERKIT_MODEL="openai_whisper-large-v3-v20240930_626MB"

mkdir -p "$SOURCE_ROOT" "$BIN_ROOT" "$MODEL_ROOT"

verify_sha() {
  local file="$1" expected="$2"
  local actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    echo "SHA-256 mismatch for $file" >&2
    echo "expected $expected" >&2
    echo "actual   $actual" >&2
    exit 1
  }
}

ARGMAX_SOURCE="$SOURCE_ROOT/argmax-oss-swift"
if [[ ! -d "$ARGMAX_SOURCE/.git" ]]; then
  git clone https://github.com/argmaxinc/argmax-oss-swift.git "$ARGMAX_SOURCE"
fi
git -C "$ARGMAX_SOURCE" fetch --depth 1 origin "$ARGMAX_REVISION"
git -C "$ARGMAX_SOURCE" checkout --detach "$ARGMAX_REVISION"
(
  cd "$ARGMAX_SOURCE"
  BUILD_ALL=1 \
  SWIFTPM_HOME="$ROOT/.swiftpm-home" \
  CLANG_MODULE_CACHE_PATH="$ROOT/.clang-module-cache" \
    swift build -c release --product argmax-cli --arch arm64
)
cp "$ARGMAX_SOURCE/.build/arm64-apple-macosx/release/argmax-cli" "$BIN_ROOT/argmax-cli"

WHISPER_ARCHIVE="$SOURCE_ROOT/whisper.cpp-$WHISPER_CPP_VERSION.tar.gz"
if [[ ! -f "$WHISPER_ARCHIVE" ]]; then
  curl -L --fail --retry 3 \
    "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/$WHISPER_CPP_VERSION.tar.gz" \
    -o "$WHISPER_ARCHIVE"
fi
verify_sha "$WHISPER_ARCHIVE" "$WHISPER_CPP_ARCHIVE_SHA"
WHISPER_SOURCE="$SOURCE_ROOT/whisper.cpp"
if [[ ! -d "$WHISPER_SOURCE" ]]; then
  mkdir -p "$WHISPER_SOURCE"
  tar -xzf "$WHISPER_ARCHIVE" -C "$WHISPER_SOURCE" --strip-components 1
fi
cmake -S "$WHISPER_SOURCE" -B "$WHISPER_SOURCE/build" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_SDL2=OFF \
  -DGGML_METAL=ON
cmake --build "$WHISPER_SOURCE/build" --config Release --target whisper-cli \
  -j"$(sysctl -n hw.ncpu)"
cp "$WHISPER_SOURCE/build/bin/whisper-cli" "$BIN_ROOT/whisper-cli"

GGML_MODEL="$MODEL_ROOT/ggml-small.en.bin"
if [[ ! -f "$GGML_MODEL" ]]; then
  curl -L --fail --retry 3 \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/$GGML_REVISION/ggml-small.en.bin" \
    -o "$GGML_MODEL"
fi
verify_sha "$GGML_MODEL" "$GGML_SMALL_EN_SHA"

if ! python3 -c 'import huggingface_hub' >/dev/null 2>&1; then
  python3 -m pip install --user --quiet "huggingface_hub>=0.23"
fi
python3 - \
  "$MODEL_ROOT" "$WHISPERKIT_MODEL" "$WHISPERKIT_REVISION" "$TOKENIZER_REVISION" <<'PY'
import sys
from huggingface_hub import snapshot_download

root, model, model_revision, tokenizer_revision = sys.argv[1:]
target = f"{root}/{model}"
snapshot_download(
    repo_id="argmaxinc/whisperkit-coreml",
    revision=model_revision,
    local_dir=root,
    allow_patterns=[f"{model}/**"],
)
snapshot_download(
    repo_id="openai/whisper-large-v3",
    revision=tokenizer_revision,
    local_dir=target,
    allow_patterns=["tokenizer.json", "tokenizer_config.json"],
)
PY

for item in AudioEncoder.mlmodelc MelSpectrogram.mlmodelc TextDecoder.mlmodelc \
    config.json generation_config.json tokenizer.json tokenizer_config.json
do
  [[ -e "$MODEL_ROOT/$WHISPERKIT_MODEL/$item" ]] || {
    echo "WhisperKit model is incomplete; missing $item" >&2
    exit 1
  }
done

chmod +x "$BIN_ROOT/argmax-cli" "$BIN_ROOT/whisper-cli"
echo "$ASR_ROOT"
