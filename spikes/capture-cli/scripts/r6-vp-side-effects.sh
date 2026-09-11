#!/bin/zsh
# R6, побочные эффекты voice processing в ДРУГОМ процессе (как Chrome/Zoom во время созвона). Без человека.
# Речь «собеседника» звучит трижды (3–38, 43–78, 83–118 с от старта плеера); на второй раз другой процесс
# держит AVAudioEngine с VP. Запись сырая (tap на плеер + микрофон). Смотреть: уровень system по фазам (ducking),
# события mic_stream_config_changed / aggregate_stream_config_changed / rebuild_done в events.log.
#
#   scripts/r6-vp-side-effects.sh /path/to/speech.aiff            # ducking по умолчанию
#   DUCK=min scripts/r6-vp-side-effects.sh /path/to/speech.aiff   # AVAudioVoiceProcessingOtherAudioDuckingConfiguration .min
set -euo pipefail
cd "${0:A:h}/.."
SPEECH="${1:?путь к файлу речи}"
DUCK="${DUCK:-default}"
mkdir -p .build/logs
.build/release/capture-cli play --device-uid BuiltInSpeakerDevice --file "$SPEECH" --schedule 3,43,83 --amplitude 1.0 \
    > .build/logs/r6-player.json &
sleep 1
PLAYER=$(python3 -c "import json;print(json.load(open('.build/logs/r6-player.json'))['pid'])")
scripts/run.sh record --pid "$PLAYER" --seconds 125 --label "R6-vp-side-effects-ducking-$DUCK" &
RECORDER=$!
sleep 40
scripts/run.sh vp-hold --seconds 40 --vp-ducking "$DUCK"
wait "$RECORDER"
