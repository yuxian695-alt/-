#!/bin/bash
# 用 macOS 自带的韩语声音把讲稿一句一句读成 wav（00.wav、01.wav…），实测程序再按固定停顿拼起来，
# 这样每句话在什么时候说完是确切知道的。
set -euo pipefail
out="$1"
mkdir -p "$out"
say -v '?' | grep ko_KR || true
# 优先用韩语专用的 Yuna；没有就用多语言声音的韩语版本，例如 “Eddy (Korean (South Korea))”
voice=$(say -v '?' | grep -E '^Yuna[[:space:]]' | head -1 | sed -E 's/[[:space:]]+ko_KR.*//')
[ -n "$voice" ] || voice=$(say -v '?' | grep ko_KR | head -1 | sed -E 's/[[:space:]]+ko_KR.*//')
if [ -z "$voice" ]; then echo "没有韩语声音"; exit 3; fi
echo "用声音：$voice"
i=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  say -v "$voice" -r 180 -o "$out/$(printf %02d $i).wav" --file-format=WAVE --data-format=LEI16@16000 "$line"
  i=$((i+1))
done < "$(dirname "$0")/lecture_ko.txt"
ls -la "$out"
