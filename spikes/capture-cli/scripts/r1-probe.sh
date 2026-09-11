#!/bin/zsh
# R1: какой процесс браузера издаёт звук звонка и ловит ли его группировка. Нужен идущий звонок в браузере.
# Каждая проба — запись SECONDS с, tap на выбранную группу (system) + tap «всё, кроме группы и себя» (rest).
# Если rest громче тишины, пока звонок звучит, — группа звук не ловит.
#   scripts/r1-probe.sh chrome-audio-helper --pid 50773
#   scripts/r1-probe.sh chrome-main --pid 39603
#   scripts/r1-probe.sh chrome-prefix --bundle-prefix com.google.Chrome
set -euo pipefail
cd "${0:A:h}/.."
NAME="${1:?имя пробы}"; shift
SECONDS_PER_PROBE="${SECONDS_PER_PROBE:-25}"
scripts/run.sh record "$@" --rest-tap --seconds "$SECONDS_PER_PROBE" --label "R1-$NAME" >/dev/null 2>&1
DIR=$(ls -td "$HOME/Library/Application Support/com.andreeyka.meetforme.spike.capture/recordings"/*/ | head -1)
echo "== $NAME ($*) → $DIR"
python3 - "$DIR/events.log" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    event = json.loads(line)
    if event["event"] == "session_built":
        print("  процессы в tap:", [(p["pid"], p["bundleID"], p["exe"], "out=%d" % p["out"]) for p in event["processes"]])
    if event["event"] == "tap_created" and event["kind"] == "system":
        print("  описание tap в HAL:", event.get("descriptionFromHAL"))
PY
.build/release/capture-cli levels "$DIR" --window 5 | tail -4
