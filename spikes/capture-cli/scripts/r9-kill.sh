#!/bin/zsh
# R9: kill -9 посреди записи. Без человека.
#   WRITER=raw|apple  FLUSH_MS=200  KILL_AFTER=30  scripts/r9-kill.sh
# Печатает verify каталога записи (что читается, сколько потеряно), afinfo, и остались ли private aggregate devices.
set -euo pipefail
cd "${0:A:h}/.."
WRITER="${WRITER:-raw}"
FLUSH_MS="${FLUSH_MS:-200}"
KILL_AFTER="${KILL_AFTER:-30}"
SUPPORT="$HOME/Library/Application Support/com.andreeyka.meetforme.spike.capture/recordings"
mkdir -p .build/logs

.build/release/capture-cli play --device-uid BuiltInSpeakerDevice --period 2 --amplitude 0.2 > .build/logs/r9-player.json &
PLAYER_JOB=$!
sleep 1
PLAYER=$(python3 -c "import json;print(json.load(open('.build/logs/r9-player.json'))['pid'])")

BEFORE=$(ls -1 "$SUPPORT" 2>/dev/null | sort)
scripts/run.sh record --pid "$PLAYER" --seconds 600 --writer "$WRITER" --flush-ms "$FLUSH_MS" \
    --label "R9-kill9-writer-$WRITER-flush-$FLUSH_MS" >/dev/null 2>&1 &
sleep "$KILL_AFTER"
RECORDER=$(pgrep -f "CaptureCLI.app/Contents/MacOS/capture-cli record" | head -1)
KILLED_AT_MS=$(python3 -c 'import time; print(int(time.time()*1000))')
kill -9 "$RECORDER"
echo "kill -9 pid=$RECORDER at_ms=$KILLED_AT_MS writer=$WRITER flush_ms=$FLUSH_MS"
sleep 2
AFTER=$(ls -1 "$SUPPORT" | sort)
DIR="$SUPPORT/$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") | head -1)"
echo "dir=$DIR"
.build/release/capture-cli verify "$DIR" --killed-at-ms "$KILLED_AT_MS"
for f in "$DIR"/*.caf; do echo "--- afinfo $(basename "$f")"; afinfo "$f" 2>&1 | grep -E "estimated duration|audio packets|audio bytes|Data format|error|failed" || true; done
echo "--- aggregate devices после kill -9:"
.build/release/capture-cli devices | grep -c "meetforme-spike" || true
kill "$PLAYER_JOB" 2>/dev/null || true
