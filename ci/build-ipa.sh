#!/bin/bash
# 编出没签名的 ipa：在电脑上用爱思助手（或 Sideloadly 等）用自己的 Apple ID 签名后装到 iPad。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
cd "$root/ci"
xcodegen generate --spec project.yml
set +e
xcodebuild build -project ClassInterpreterDemo.xcodeproj -scheme ClassInterpreter -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$root/ci/dd-ipa" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
status=${PIPESTATUS[0]}
set -e
[ "$status" = 0 ] || exit "$status"
app="$root/ci/dd-ipa/Build/Products/Release-iphoneos/ClassInterpreter.app"
plutil -p "$app/Info.plist" | grep -E "CFBundle(DisplayName|Identifier|ShortVersion|IconName)|Usage|UIBackgroundModes|audio|MinimumOS" || true
lipo -info "$app/ClassInterpreter"
out="$root/ipa"; rm -rf "$out"; mkdir -p "$out/Payload"
cp -R "$app" "$out/Payload/"
(cd "$out" && zip -qry ClassInterpreter.ipa Payload)
ls -la "$out/ClassInterpreter.ipa"
shasum -a 256 "$out/ClassInterpreter.ipa"
# 打进日志，方便不能下载附件时取出来
echo "=====BEGIN ClassInterpreter.ipa"; base64 -i "$out/ClassInterpreter.ipa" | fold -w 76; echo "=====END ClassInterpreter.ipa"
