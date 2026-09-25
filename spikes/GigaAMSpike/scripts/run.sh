#!/bin/zsh
# Запуск напрямую — не через `open`/LaunchServices: тому нужна TCC-привязка к bundle id
# (см. Packages/Mac/Sources/CaptureManualHarness/scripts/run.sh), а у этого спайка нет ни одной
# защищённой возможности, привязывать нечего.
#
#   scripts/run.sh --model models/gigaam-v3-e2e-ctc/gigaam_v3_e2e_ctc_int8.onnx \
#     --tokens models/gigaam-v3-e2e-ctc/gigaam_v3_e2e_ctc_tokens.txt \
#     --wav /path/to/16k-mono.wav
set -euo pipefail
cd "${0:A:h}/.."   # -> spikes/GigaAMSpike

BIN=".build/release/GigaAMSpikeHarness"
if [[ ! -x "$BIN" ]]; then
  echo "не собрано — сначала scripts/build.sh" >&2
  exit 1
fi
exec "$BIN" run "$@"
