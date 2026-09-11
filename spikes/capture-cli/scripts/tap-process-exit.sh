#!/bin/zsh
# Жизненный цикл tap при завершении и перезапуске тапнутого процесса. Без человека.
# Плеер запускается как CaptureCLIDeny.app (bundle id com.andreeyka.meetforme.spike.capture.deny), чтобы у процесса был bundle id.
#   MODE=pid       tap по object ID процесса (как на 14.2); плеер убивается на 15 с и перезапускается на 25 с
#   MODE=retap     --bundle-prefix + --retap: пересборка при появлении нового процесса
#   MODE=restore   --bundle-ids + --process-restore (macOS 26): без пересборки
set -euo pipefail
cd "${0:A:h}/.."
MODE="${MODE:-pid}"
BUNDLE=com.andreeyka.meetforme.spike.capture.deny
mkdir -p .build/logs

start_player() {
    open -n --stdout "$PWD/.build/logs/exit-player-$1.json" .build/CaptureCLIDeny.app --args play --device-uid BuiltInSpeakerDevice --period 2 --amplitude 0.2
    sleep 2
    pgrep -f "CaptureCLIDeny.app/Contents/MacOS/capture-cli play" | tail -1
}

PLAYER=$(start_player 1)
echo "player 1 pid=$PLAYER"
case "$MODE" in
    pid) ARGS=(--pid "$PLAYER") ;;
    retap) ARGS=(--bundle-prefix "$BUNDLE" --retap) ;;
    restore) ARGS=(--bundle-ids "$BUNDLE" --process-restore) ;;
esac
scripts/run.sh record "${ARGS[@]}" --seconds 45 --label "tap-process-exit-$MODE" >/dev/null 2>&1 &
RECORDER_JOB=$!
sleep 15
kill "$PLAYER"; echo "player 1 killed at $(date +%T)"
sleep 10
PLAYER2=$(start_player 2)
echo "player 2 pid=$PLAYER2 at $(date +%T)"
wait "$RECORDER_JOB"
kill "$PLAYER2" 2>/dev/null || true
DIR=$(ls -td "$HOME/Library/Application Support/com.andreeyka.meetforme.spike.capture/recordings"/*/ | head -1)
echo "dir=$DIR"
grep -E '"process_list_changed"|"tap_format_changed"|"rebuild_done"|"session_built"|"stats"|"aggregate_alive_changed"' "$DIR/events.log" \
    | python3 -c "
import json,sys
for l in sys.stdin:
    e=json.loads(l)
    keep={k:e[k] for k in ('event','tS','peakDBFS','callbacks','tappedGone','reason','gapsMs','atMs','removed','added') if k in e}
    if 'added' in keep: keep['added']=[(p['pid'],p['bundleID']) for p in keep['added']]
    if 'removed' in keep: keep['removed']=[(p['pid'],p['bundleID']) for p in keep['removed']]
    print(keep)"
.build/release/capture-cli levels "$DIR" --window 5 | tail -14
