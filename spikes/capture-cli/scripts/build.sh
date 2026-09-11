#!/bin/zsh
# Сборка capture-cli, обёртка в .app и подпись сертификатом Apple Development.
# TCC привязывает права к designated requirement подписи и bundle id: пересборка с тем же сертификатом
# сохраняет выданные права, ad-hoc подпись — нет.
#
#   scripts/build.sh                                   → .build/CaptureCLI.app (com.andreeyka.meetforme.spike.capture)
#   APP_NAME=CaptureCLIDeny BUNDLE_ID=com.andreeyka.meetforme.spike.capture.deny scripts/build.sh
set -euo pipefail
cd "${0:A:h}/.."

APP_NAME="${APP_NAME:-CaptureCLI}"
BUNDLE_ID="${BUNDLE_ID:-com.andreeyka.meetforme.spike.capture}"
IDENTITY="${IDENTITY:-Apple Development: andrey@skzd.ru (SKX9KNP9CA)}"

swift build -c release
APP=".build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/capture-cli "$APP/Contents/MacOS/capture-cli"
sed -e "s/__BUNDLE_ID__/${BUNDLE_ID}/" -e "s/__APP_NAME__/${APP_NAME}/" Bundle/Info.plist > "$APP/Contents/Info.plist"
codesign --force --options runtime --timestamp=none --entitlements Bundle/entitlements.plist --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^(Identifier|TeamIdentifier|Authority=Apple Development|CodeDirectory)"
codesign -d -r- "$APP" 2>&1 | grep designated
echo "$PWD/$APP"
