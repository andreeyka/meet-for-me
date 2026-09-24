#!/bin/zsh
# Запуск через LaunchServices (`open`), а не из shell напрямую: тогда «ответственный процесс» для
# TCC — сам CalendarEventKitManualHarness.app, и промпт/право на Календари относятся к его bundle
# id, а не к терминалу. Тот же приём, что у CaptureManualHarness/scripts/run.sh и
# spikes/capture-cli/scripts/run.sh.
#
#   scripts/run.sh m1 --days-back 7 --days-forward 14      # см. README.md, М1
#   scripts/run.sh m2 --wait-seconds 20                     # см. README.md, М2
# stdout/stderr — в $LOG_DIR/<время>.{out,err}; скрипт ждёт завершения (-W). Смотреть .err
# обязательно для М2: EventKit может не бросить типизированную ошибку, а завершить процесс
# необработанным исключением (main.swift, комментарий у runM2) — тогда исход виден только там.
set -euo pipefail
cd "${0:A:h}/../../.."   # -> Packages/Mac

LOG_DIR="${LOG_DIR:-$PWD/.build/logs}"
mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)-${1:-help}"
echo "stdout: $LOG_DIR/$STAMP.out" >&2
echo "stderr: $LOG_DIR/$STAMP.err" >&2
open -n -W --stdout "$LOG_DIR/$STAMP.out" --stderr "$LOG_DIR/$STAMP.err" \
  .build/CalendarEventKitManualHarness.app --args "$@"
cat "$LOG_DIR/$STAMP.out"
