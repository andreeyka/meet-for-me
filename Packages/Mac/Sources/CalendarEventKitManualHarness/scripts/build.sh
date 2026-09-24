#!/bin/zsh
# Сборка CalendarEventKitManualHarness, обёртка в .app и подпись — тот же приём, что у
# CaptureManualHarness/scripts/build.sh и spikes/capture-cli/scripts/build.sh (TCC привязывает
# права к designated requirement подписи и bundle id: пересборка тем же сертификатом сохраняет
# выданные права, ad-hoc — нет).
#
#   Packages/Mac/Sources/CalendarEventKitManualHarness/scripts/build.sh
#     → Packages/Mac/.build/CalendarEventKitManualHarness.app
#       (com.andreeyka.meetforme.spike.calendar-eventkit.harness)
set -euo pipefail
cd "${0:A:h}/../../.."   # -> Packages/Mac

IDENTITY="${IDENTITY:-Apple Development: andrey@skzd.ru (SKX9KNP9CA)}"
HARNESS_DIR="Sources/CalendarEventKitManualHarness"

swift build -c release --product CalendarEventKitManualHarness
APP=".build/CalendarEventKitManualHarness.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CalendarEventKitManualHarness "$APP/Contents/MacOS/CalendarEventKitManualHarness"
cp "$HARNESS_DIR/Bundle/Info.plist" "$APP/Contents/Info.plist"
codesign --force --options runtime --timestamp=none \
  --entitlements "$HARNESS_DIR/Bundle/entitlements.plist" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^(Identifier|TeamIdentifier|Authority=Apple Development|CodeDirectory)"
echo "$PWD/$APP"
