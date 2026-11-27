#!/bin/bash
# 把 iPad App 的全部源码放进一个临时的普通 Swift 包，按 iPadOS 编译一遍（不签名）。
# 这样不依赖 Swift Playgrounds 专用的 AppleProductTypes，也能查出所有编译错误。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
mkdir -p "$work/Sources/AppCheck"
cp "$root"/ClassInterpreter.swiftpm/Sources/AppModule/*.swift "$work/Sources/AppCheck/"
cat > "$work/Package.swift" <<'PKG'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "AppCheck",
    platforms: [.iOS("18.0")],
    products: [.library(name: "AppCheck", targets: ["AppCheck"])],
    targets: [.target(name: "AppCheck", path: "Sources/AppCheck")]
)
PKG
cd "$work"
set +e
xcodebuild build -scheme AppCheck -destination 'generic/platform=iOS' \
  -derivedDataPath "$work/dd" CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$work/build.log" | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" | sed "s|$work/Sources/AppCheck/||" | sort -u
status=${PIPESTATUS[0]}
set -e
echo "错误 $(grep -c 'error:' "$work/build.log" || true) 个，警告 $(grep -c 'warning:' "$work/build.log" || true) 个"
exit $status
