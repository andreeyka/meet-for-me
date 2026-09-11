#!/bin/zsh
# Запуск через LaunchServices (`open`), а не из shell напрямую: тогда «ответственный процесс» для TCC —
# сам CaptureCLI.app, и промпт и запись в Privacy & Security относятся к его bundle id, а не к терминалу.
#
#   scripts/run.sh record --pid 123 --seconds 30
#   APP_NAME=CaptureCLIDeny scripts/run.sh tcc
# stdout/stderr процесса — в $LOG_DIR/<время>-<команда>.{out,err}; скрипт ждёт завершения (-W).
set -euo pipefail
cd "${0:A:h}/.."

APP_NAME="${APP_NAME:-CaptureCLI}"
LOG_DIR="${LOG_DIR:-$PWD/.build/logs}"
mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)-${1:-help}"
echo "stdout: $LOG_DIR/$STAMP.out" >&2
echo "stderr: $LOG_DIR/$STAMP.err" >&2
open -n -W --stdout "$LOG_DIR/$STAMP.out" --stderr "$LOG_DIR/$STAMP.err" ".build/${APP_NAME}.app" --args "$@"
cat "$LOG_DIR/$STAMP.out"
