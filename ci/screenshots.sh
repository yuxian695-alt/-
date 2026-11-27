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
bid=app.xiaobawang.classinterpreter

# 先按平时的方式（不带示例数据）打开，确认首页检查跑完以后 App 还活着
xcrun simctl launch "$udid" "$bid"
sleep 20
if pgrep -f "ClassInterpreter.app/ClassInterpreter" >/dev/null; then echo "正常启动：20 秒后仍在运行"; else echo "正常启动：App 已退出"; fi
xcrun simctl io "$udid" screenshot "$out/normal.png"
for f in $(find ~/Library/Logs/DiagnosticReports -iname "*ClassInterpreter*" 2>/dev/null | head -3); do
  echo "== 崩溃报告 $f"; head -80 "$f"
done

for screen in home live detail; do
  xcrun simctl terminate "$udid" "$bid" >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" "$bid" -demo "$screen"
  sleep 12
  xcrun simctl io "$udid" screenshot "$out/$screen.png"
done
ls -la "$out"

# 截图也打进日志（压成 JPEG 的 base64），方便不能下载附件时取图
for f in "$out"/*.png; do
  n=$(basename "$f" .png)
  sips -s format jpeg -s formatOptions 80 -Z 1600 "$f" --out "/tmp/$n.jpg" >/dev/null
  echo "=====BEGIN $n.jpg"; base64 -i "/tmp/$n.jpg" | fold -w 76; echo "=====END $n.jpg"
done
