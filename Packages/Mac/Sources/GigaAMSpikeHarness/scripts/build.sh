#!/bin/zsh
# Сборка GigaAMSpikeHarness — простой исполняемый файл, без .app-обёртки и codesign: спайку
# не нужна ни одна TCC-защищённая возможность (не читает микрофон, не трогает календарь) —
# в отличие от CaptureManualHarness/CalendarEventKitManualHarness, которым обёртка и подпись
# нужны именно ради TCC (см. их же scripts/build.sh).
#
#   Packages/Mac/Sources/GigaAMSpikeHarness/scripts/build.sh
#     -> Packages/Mac/.build/release/GigaAMSpikeHarness
set -euo pipefail
cd "${0:A:h}/../../.."   # -> Packages/Mac

swift build -c release --product GigaAMSpikeHarness
echo "$PWD/.build/release/GigaAMSpikeHarness"
