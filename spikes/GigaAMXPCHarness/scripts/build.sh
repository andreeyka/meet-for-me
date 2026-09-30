#!/bin/zsh
# Стенд Z6 (MEE-504): сервис `TranscriptionEngine.xpc` собирается тем же project.yml, что и
# приложение (xcodegen + xcodebuild, Release, подпись ad-hoc, hardened runtime из project.yml),
# и кладётся в `Contents/XPCServices/` бандла стенда; бандл подписывается ad-hoc с hardened runtime.
#
#   spikes/GigaAMXPCHarness/scripts/build.sh
#     → spikes/GigaAMXPCHarness/.build/GigaAMXPCHarness.app
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
HARNESS="${0:A:h:h}"
REPO="${HARNESS:h:h}"

# DerivedData — внутри репозитория (в .gitignore): под /tmp SwiftPM не распаковывает XCFramework
# onnxruntime-libs («symlink 'Resources' points … outside», /tmp ↔ /private/tmp).
( cd "$REPO"
  xcodegen generate --spec project.yml
  xcodebuild build -project MeetForMe.xcodeproj -scheme MeetForMe -configuration Release \
    -destination 'platform=macOS' -derivedDataPath DerivedData \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= -quiet )
XPC="$REPO/DerivedData/Build/Products/Release/MeetForMe.app/Contents/XPCServices/TranscriptionEngine.xpc"

cd "$HARNESS"
swift build -c release --product GigaAMXPCHarness
APP=".build/GigaAMXPCHarness.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/XPCServices"
cp .build/release/GigaAMXPCHarness "$APP/Contents/MacOS/GigaAMXPCHarness"
cp Bundle/Info.plist "$APP/Contents/Info.plist"
ditto "$XPC" "$APP/Contents/XPCServices/TranscriptionEngine.xpc"
codesign --force --options runtime --timestamp=none --sign - "$APP"
codesign --verify --strict "$APP"
codesign --verify --strict "$APP/Contents/XPCServices/TranscriptionEngine.xpc"
codesign -dv "$APP/Contents/XPCServices/TranscriptionEngine.xpc" 2>&1 | grep -E "^(Identifier|CodeDirectory|Signature)"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|CodeDirectory|Signature)"
echo "$PWD/$APP"
