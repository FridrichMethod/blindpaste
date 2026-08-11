#!/usr/bin/env bash
# blindpaste 测试器。会读写真实剪贴板，开始时保存、结束时恢复。不可并行运行。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BP=./blindpaste

pass=0; fail=0; skip=0
ORIG=$(pbpaste)
trap 'printf %s "$ORIG" | pbcopy' EXIT

ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
sk() { skip=$((skip+1)); printf '  skip %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — got [$2] want [$3]"; fi; }

SNIFF() { BLINDPASTE_LIB=1 bash -c '. ./blindpaste; sniff "$1"' _ "$1"; }

printf '\n-- sniff --\n'
check 'sniff age armor' "$(SNIFF '-----BEGIN AGE ENCRYPTED FILE-----')" age
check 'sniff base64'    "$(SNIFF 'MTIzNDU2')" b64
check 'sniff 带空白的 base64' "$(SNIFF 'MTIz
NDU2')" b64
check 'sniff 垃圾'      "$(SNIFF 'hello world!!')" none
check 'sniff 空'        "$(SNIFF '')" none

printf '\n-- base64 主路径 --\n'
SECRET=903142
printf %s "$SECRET" | base64 | tr -d '\n' | pbcopy
out=$("$BP" -t 0 2>&1); rc=$?
check 'b64 退出码' "$rc" 0
check 'b64 剪贴板' "$(pbpaste)" "$SECRET"
check 'b64 元信息' "$(printf %s "$out" | grep -c '6 字符，全数字')" 1
if printf %s "$out" | grep -q "$SECRET"; then no 'b64 明文未泄露'; else ok 'b64 明文未泄露'; fi

printf %s 'SENTINEL2' | pbcopy
printf %s "$SECRET" | base64 | "$BP" - -t 0 >/dev/null 2>&1
check 'stdin 模式' "$(pbpaste)" "$SECRET"

printf '\n-- 错误路径 --\n'
printf %s 'SENTINEL-KEEP-ME' | pbcopy
"$BP" -t 0 >/dev/null 2>&1
check '垃圾输入退出码' "$?" 2
check '垃圾输入不动剪贴板' "$(pbpaste)" 'SENTINEL-KEEP-ME'

printf '' | pbcopy
"$BP" -t 0 >/dev/null 2>&1
check '空输入退出码' "$?" 5

printf %s '12345678' | pbcopy
"$BP" -t 0 >/dev/null 2>&1
check '纯数字误判为 b64 时退出码' "$?" 4
check '纯数字误判时不动剪贴板' "$(pbpaste)" '12345678'

"$BP" --bogus >/dev/null 2>&1
check '未知 flag 退出码' "$?" 1
"$BP" -t abc >/dev/null 2>&1
check '-t 非整数退出码' "$?" 1

printf '\n-- hash 守卫 --\n'
H=$(BLINDPASTE_LIB=1 bash -c '. ./blindpaste; hash_of "$1"' _ 'target-content')

printf %s 'something-else' | pbcopy
"$BP" --__clear "$H" 0 >/dev/null 2>&1
check '守卫保住被改过的剪贴板' "$(pbpaste)" 'something-else'

printf %s 'target-content' | pbcopy
"$BP" --__clear "$H" 0 >/dev/null 2>&1
check '守卫清空未改动的剪贴板' "$(pbpaste)" ''

printf '\n-- age 路径 --\n'
if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
  TD=$(mktemp -d); K="$TD/k.txt"
  BLINDPASTE_KEY="$K" "$BP" --init >/dev/null 2>&1
  check '--init 退出码' "$?" 0
  check '--init 密钥权限' "$(stat -f '%Lp' "$K" 2>/dev/null)" 600
  PUB=$(grep -o 'age1[a-z0-9]*' "$K" 2>/dev/null | head -1)
  printf %s "$SECRET" | age -a -r "$PUB" | pbcopy
  BLINDPASTE_KEY="$K" "$BP" -t 0 >/dev/null 2>&1
  check 'age 往返' "$(pbpaste)" "$SECRET"
  BLINDPASTE_KEY="$K" "$BP" --init >/dev/null 2>&1
  check '--init 不覆盖已有密钥' "$?" 1
  check '--sender 含 age 公钥' "$(BLINDPASTE_KEY="$K" "$BP" --sender | grep -c "$PUB")" 1
  rm -rf "$TD"
else
  sk 'age 往返（age 未安装，跑 brew install age 后重测）'
  sk '--init（age 未安装）'
  sk '--sender 的 age 版本（age 未安装）'
fi

printf -- '-----BEGIN AGE ENCRYPTED FILE-----\nabc\n-----END AGE ENCRYPTED FILE-----\n' | pbcopy
PATH=/usr/bin:/bin "$BP" -t 0 >/dev/null 2>&1
check 'age 密文但缺 age 时退出码' "$?" 3

check '--sender 总含 base64 版本' "$("$BP" --sender | grep -c 'base64')" 2
# 只看非注释行：注释里提到 pbcopy 是说明文字，命令本身才不能依赖它
check '--sender 不依赖 pbcopy' "$("$BP" --sender | grep -v '^#' | grep -c 'pbcopy')" 0

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
