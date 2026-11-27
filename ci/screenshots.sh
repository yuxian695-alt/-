#!/bin/bash
# 在 iPad 模拟器里用示例模式把 App 跑起来，截首页、上课、课后记录三张图。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/shots"
mkdir -p "$out"
brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
cd "$root/ci"
xcodegen generate --spec project.yml
read -r udid name < <(xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
c = [(rt, x) for rt, l in d.items() if "iOS" in rt for x in l if "iPad Pro 11" in x["name"]]
c = c or [(rt, x) for rt, l in d.items() if "iOS" in rt for x in l if "iPad" in x["name"]]
c.sort(key=lambda t: t[0])
rt, x = c[-1]
print(x["udid"], x["name"] + " / " + rt.split(".")[-1])')
echo "模拟器：$name ($udid)"
set +e
xcodebuild build -project ClassInterpreterDemo.xcodeproj -scheme ClassInterpreter \
  -destination "id=$udid" -derivedDataPath "$root/ci/dd" CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" | sort -u
status=${PIPESTATUS[0]}
set -e
[ "$status" = 0 ] || exit "$status"
app=$(find "$root/ci/dd/Build/Products" -name "ClassInterpreter.app" -maxdepth 2 | head -1)
xcrun simctl boot "$udid" || true
xcrun simctl bootstatus "$udid" -b
xcrun simctl ui "$udid" appearance dark || true
xcrun simctl status_bar "$udid" override --time "10:41" --batteryState charged --batteryLevel 100 --wifiBars 3 || true
xcrun simctl install "$udid" "$app"
for screen in home live detail; do
  xcrun simctl terminate "$udid" app.xiaobawang.classinterpreter >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" app.xiaobawang.classinterpreter -demo "$screen"
  sleep 12
  xcrun simctl io "$udid" screenshot "$out/$screen.png"
done
ls -la "$out"
