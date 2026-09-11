#!/bin/zsh
# R6: эхо без наушников, сырой микрофон против voice processing. Нужен человек у Mac.
# Сценарий от старта (время плеера): речь «собеседника» 5–40 с (человек молчит), человек читает текст ~45–80 с,
# речь снова 85–120 с и человек читает поверх (двойной разговор). Запись 125 с.
#   MODE=raw scripts/r6-echo.sh speech.aiff   — aggregate: tap на плеер + микрофон как есть
#   MODE=vp  scripts/r6-echo.sh speech.aiff   — то же + AVAudioEngine VP в том же процессе, включён до сборки aggregate,
#                                               ducking .min (иначе чужой звук тише на 30 дБ); выход VP в diag-mic-vp.caf
set -euo pipefail
cd "${0:A:h}/.."
SPEECH="${1:?путь к файлу речи}"
MODE="${MODE:-raw}"
mkdir -p .build/logs
.build/release/capture-cli play --device-uid BuiltInSpeakerDevice --file "$SPEECH" --schedule 5,85 --amplitude 1.0 \
    > .build/logs/r6-echo-player.json &
sleep 1
PLAYER=$(python3 -c "import json;print(json.load(open('.build/logs/r6-echo-player.json'))['pid'])")
EXTRA=()
[[ "$MODE" == vp ]] && EXTRA=(--vp --vp-delay -1 --vp-ducking min)
scripts/run.sh record --pid "$PLAYER" --seconds 124 --label "R6-echo-$MODE" "${EXTRA[@]}"
