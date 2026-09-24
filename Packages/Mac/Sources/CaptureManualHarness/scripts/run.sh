#!/bin/zsh
# Запуск через LaunchServices (`open`), а не из shell напрямую: тогда «ответственный процесс» для
# TCC — сам CaptureManualHarness.app, и промпт/запись в Privacy & Security относятся к его bundle id,
# а не к терминалу. Тот же приём, что у spikes/capture-cli/scripts/run.sh.
#
#   scripts/run.sh start --directory /tmp/mee-317-m1 --input none \
#     --group-app-key com.apple.Music --group-pid "$(pgrep -x Music)"   # см. README.md, М1
#   scripts/run.sh start --directory /tmp/mee-317-m2 --input default    # см. README.md, М2 —
#     БЕЗ --group-app-key: с ним start() уходит в systemUnavailable раньше микрофона
# stdout/stderr — в $LOG_DIR/<время>.{out,err}; скрипт ждёт завершения (-W).
set -euo pipefail
cd "${0:A:h}/../../.."   # -> Packages/Mac

LOG_DIR="${LOG_DIR:-$PWD/.build/logs}"
mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
echo "stdout: $LOG_DIR/$STAMP.out" >&2
echo "stderr: $LOG_DIR/$STAMP.err" >&2
open -n -W --stdout "$LOG_DIR/$STAMP.out" --stderr "$LOG_DIR/$STAMP.err" \
  .build/CaptureManualHarness.app --args "$@"
cat "$LOG_DIR/$STAMP.out"
