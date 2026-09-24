#!/bin/zsh
# Сборка CaptureManualHarness, обёртка в .app и подпись — тот же приём, что у
# spikes/capture-cli/scripts/build.sh (TCC привязывает права к designated requirement подписи
# и bundle id: пересборка тем же сертификатом сохраняет выданные права, ad-hoc — нет).
#
#   Packages/Mac/Sources/CaptureManualHarness/scripts/build.sh
#     → Packages/Mac/.build/CaptureManualHarness.app (com.andreeyka.meetforme.spike.capture.harness)
set -euo pipefail
cd "${0:A:h}/../../.."   # -> Packages/Mac

IDENTITY="${IDENTITY:-Apple Development: andrey@skzd.ru (SKX9KNP9CA)}"
HARNESS_DIR="Sources/CaptureManualHarness"

swift build -c release --product CaptureManualHarness
APP=".build/CaptureManualHarness.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CaptureManualHarness "$APP/Contents/MacOS/CaptureManualHarness"
cp "$HARNESS_DIR/Bundle/Info.plist" "$APP/Contents/Info.plist"
codesign --force --options runtime --timestamp=none \
  --entitlements "$HARNESS_DIR/Bundle/entitlements.plist" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^(Identifier|TeamIdentifier|Authority=Apple Development|CodeDirectory)"
echo "$PWD/$APP"
