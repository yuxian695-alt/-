#!/bin/bash
# 用 macOS 自带的韩语声音（Yuna）把讲稿读出来：句子之间停 0.6 秒；倒数第二句很长、中间不停，用来测“老师一直讲不停”的情况。
set -euo pipefail
out="$1"
say -v '?' | grep ko_KR || true
# 优先用韩语专用的 Yuna；没有就用多语言声音的韩语版本，例如 “Eddy (Korean (South Korea))”
voice=$(say -v '?' | grep -E '^Yuna[[:space:]]' | head -1 | sed -E 's/[[:space:]]+ko_KR.*//')
[ -n "$voice" ] || voice=$(say -v '?' | grep ko_KR | head -1 | sed -E 's/[[:space:]]+ko_KR.*//')
if [ -z "$voice" ]; then echo "没有韩语声音"; say -v '?' | head -40; exit 3; fi
echo "用声音：$voice"
tmp=$(mktemp)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  printf '%s [[slnc 600]]\n' "$line" >> "$tmp"
done < "$(dirname "$0")/lecture_ko.txt"
say -v "$voice" -r 175 -f "$tmp" -o "$out" --file-format=WAVE --data-format=LEI16@16000
afinfo "$out" | head -8
