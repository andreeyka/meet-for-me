#!/bin/zsh
# R2: длинная запись с опорным сигналом. Без человека, если смена устройства не нужна.
# Плеер щёлкает чирпом раз в PERIOD с на встроенных динамиках (по UID — щелчки остаются на динамиках при смене
# устройств); tap на плеер + микрофон по умолчанию; второй tap без drift compensation для сравнения.
# Смена устройства ввода посреди записи делается человеком (подключить AirPods / выбрать другой вход) — CLI сам
# пересоберёт aggregate device и поставит маркеры discontinuity/deviceChanged.
#   BAND=high SECONDS=3660 scripts/r2-hour.sh
# Анализ: .build/release/capture-cli sync <dir> --period 2 --band high --csv sync.csv
set -euo pipefail
cd "${0:A:h}/.."
BAND="${BAND:-high}"
PERIOD="${PERIOD:-2}"
AMPLITUDE="${AMPLITUDE:-0.3}"
SECONDS_TOTAL="${SECONDS:-3660}"
mkdir -p .build/logs
.build/release/capture-cli play --device-uid BuiltInSpeakerDevice --period "$PERIOD" --band "$BAND" --amplitude "$AMPLITUDE" \
    > .build/logs/r2-player.json &
PLAYER_JOB=$!
sleep 1
PLAYER=$(python3 -c "import json;print(json.load(open('.build/logs/r2-player.json'))['pid'])")
scripts/run.sh record --pid "$PLAYER" --nodrift-tap --seconds "$SECONDS_TOTAL" --label "R2-${SECONDS_TOTAL}s-band-$BAND"
kill "$PLAYER_JOB" 2>/dev/null || true
