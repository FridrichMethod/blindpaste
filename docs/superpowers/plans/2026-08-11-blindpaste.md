# blindpaste Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一个 bash 脚本，把剪贴板里的密文原地替换为明文，明文全程不经过屏幕。

**Architecture:** 单文件 bash 脚本 `blindpaste`，内部是一组纯函数（`sniff` / `decode` / `describe` / `hash_of` / `clear_if_unchanged`）加一个 `main` 分发器。`BLINDPASTE_LIB=1` 时只定义函数不执行 `main`，使测试能直接调用纯函数。定时清空由脚本 `nohup` 调用自身的内部子命令 `--__clear` 实现，而非内联 `bash -c` 字符串。

**Tech Stack:** bash、BSD `base64`（解码用 `-D`）、`pbcopy` / `pbpaste`、`shasum -a 256`、可选 `age` / `age-keygen`。测试用自带 `tests/run.sh`，零第三方依赖。

Spec：`docs/superpowers/specs/2026-08-10-blindpaste-design.md`

## Global Constraints

- 明文 `$plain` 绝不出现在 stdout、argv、文件或任何命令行参数中。只允许经由管道进 `pbcopy`，以及经由 `shasum` 变成 hash。
- 所有失败路径必须保持剪贴板原样，且不打印解码结果的任何字节。
- 元信息输出走 **stderr**，stdout 保持干净。
- 本机 `base64` 是 BSD 风格：解码必须用 `-D`，不能用 `-d`。
- `age` 与 `bats` 均未安装。`age` 相关测试在缺失时必须明确报 skip，不可静默通过。
- 退出码：0 成功、1 用法错误、2 嗅探失败、3 缺依赖、4 解码失败、5 输入为空。
- 提交信息用 `<type>: <description>` 格式，不加任何 AI 署名。

## File Structure

| 文件 | 职责 |
| --- | --- |
| `blindpaste` | 全部逻辑。约 130 行。单文件是因为各单元都只有 3-10 行，拆成模块会让 shell 的 `source` 路径解析成为新的复杂度来源，而收益为零 |
| `tests/run.sh` | 自带测试器。保存并恢复真实剪贴板，全程 `-t 0` |
| `README.md` | 用法、两种格式的安全性差别、限制章节 |

`--__clear` 与 `main` 共处一个文件是有意的：清空逻辑必须和写入逻辑用同一个 `hash_of`，跨文件会引入两份实现漂移的风险。

---

### Task 1: 测试器骨架 + `sniff`

**Files:**
- Create: `tests/run.sh`
- Create: `blindpaste`

**Interfaces:**
- Produces: `sniff <blob>` → 向 stdout 打印 `age` | `b64` | `none`，恒返回 0。`hash_of <string>` → 打印 SHA-256 前 16 位十六进制。脚本在 `BLINDPASTE_LIB=1` 时不执行 `main`。

- [ ] **Step 1: 写失败的测试**

`tests/run.sh`（本任务只含 sniff 段，后续任务往同一文件追加）：

```bash
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

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: 运行，确认失败**

```bash
chmod +x tests/run.sh && ./tests/run.sh
```

Expected: 全部 FAIL，因为 `./blindpaste` 还不存在（`. ./blindpaste` 报 No such file）。

- [ ] **Step 3: 写最小实现**

`blindpaste`：

```bash
#!/usr/bin/env bash
# blindpaste — 把剪贴板里的密文原地解码为明文，明文不经过屏幕。
set -uo pipefail

BP_KEY="${BLINDPASTE_KEY:-$HOME/.config/age/blindpaste.key}"
BP_DEFAULT_TTL=90

die() { printf 'blindpaste: %s\n' "$1" >&2; exit "${2:-1}"; }

# sniff <blob> -> age | b64 | none
sniff() {
  local blob=$1 compact
  case $blob in
    *'BEGIN AGE ENCRYPTED FILE'*) printf age; return 0 ;;
  esac
  compact=$(printf %s "$blob" | tr -d '[:space:]')
  if [ -n "$compact" ] && printf %s "$compact" | grep -qE '^[A-Za-z0-9+/]+={0,2}$'; then
    printf b64
  else
    printf none
  fi
}

# hash_of <string> -> SHA-256 前 16 位
hash_of() { printf %s "$1" | shasum -a 256 | cut -c1-16; }

if [ "${BLINDPASTE_LIB:-}" != 1 ]; then
  main "$@"
fi
```

- [ ] **Step 4: 运行，确认通过**

```bash
chmod +x blindpaste && ./tests/run.sh
```

Expected: 5 passed, 0 failed。`main` 未定义不影响 `BLINDPASTE_LIB=1` 路径。

- [ ] **Step 5: 提交**

```bash
git add blindpaste tests/run.sh
git commit -m 'feat: add blindpaste sniff and test harness'
```

---

### Task 2: base64 解码主路径

**Files:**
- Modify: `blindpaste`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `sniff`、`hash_of`
- Produces: `decode <mode> <blob>` → 明文到 stdout；失败非零；私钥不可读时返回 3。`describe <plain>` → 如 `6 字符，全数字`。`main "$@"` 支持 `-t <秒>` 与 `-` (stdin)。

- [ ] **Step 1: 写失败的测试**

追加到 `tests/run.sh`，放在末尾汇总行**之前**：

```bash
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
```

- [ ] **Step 2: 运行，确认失败**

```bash
./tests/run.sh
```

Expected: 新增 5 项 FAIL，`main: command not found`。

- [ ] **Step 3: 写最小实现**

在 `blindpaste` 的 `hash_of` 之后插入：

```bash
# describe <plain> -> "6 字符，全数字"
describe() {
  local p=$1 kind
  case $p in
    *[!A-Za-z0-9]*) kind='含符号' ;;
    *[A-Za-z]*)     kind='含字母' ;;
    *)              kind='全数字' ;;
  esac
  printf '%d 字符，%s' "${#p}" "$kind"
}

# decode <mode> <blob> -> 明文到 stdout；3=私钥不可读
decode() {
  local mode=$1 blob=$2
  case $mode in
    b64) printf %s "$blob" | tr -d '[:space:]' | base64 -D 2>/dev/null ;;
    age) [ -r "$BP_KEY" ] || return 3
         printf %s "$blob" | age -d -i "$BP_KEY" 2>/dev/null ;;
    *)   return 4 ;;
  esac
}
```

在 library guard **之前**插入 `main`：

```bash
main() {
  local ttl=$BP_DEFAULT_TTL src=clipboard blob mode plain rc

  while [ $# -gt 0 ]; do
    case $1 in
      -t) [ $# -ge 2 ] || die '-t 需要一个参数'
          case $2 in ''|*[!0-9]*) die "-t 需要非负整数：$2" ;; esac
          ttl=$2; shift 2 ;;
      -)  src=stdin; shift ;;
      *)  die "未知参数：$1" ;;
    esac
  done

  if [ "$src" = stdin ]; then blob=$(cat); else blob=$(pbpaste); fi
  [ -n "$blob" ] || die '输入为空' 5

  mode=$(sniff "$blob")
  [ "$mode" != none ] || die '无法识别格式：既不是 age armor 也不是 base64。剪贴板未改动' 2

  plain=$(decode "$mode" "$blob"); rc=$?
  case $rc in
    0) ;;
    3) die "找不到可读的私钥：$BP_KEY。先跑 blindpaste --init" 3 ;;
    *) die "解码失败（$mode）。剪贴板未改动" 4 ;;
  esac
  [ -n "$plain" ] || die '解码结果为空。剪贴板未改动' 4
  case $plain in
    *[[:cntrl:]]*) die '解码结果含控制字符，多半不是给我的密文。剪贴板未改动' 4 ;;
  esac

  printf %s "$plain" | pbcopy
  printf '✓ %s  →  剪贴板已就绪（%s）\n' "$mode" "$(describe "$plain")" >&2
}
```

控制字符检查是必需的安全网：`sniff` 无法区分 base64 密文和一串恰好长度为 4 倍数的纯数字，后者解码出的是垃圾字节。这一检查把那种情况变成干净的退出码 4，而不是往剪贴板里塞垃圾。

- [ ] **Step 4: 运行，确认通过**

```bash
./tests/run.sh
```

Expected: 10 passed, 0 failed。

- [ ] **Step 5: 提交**

```bash
git add blindpaste tests/run.sh
git commit -m 'feat: add base64 decode path with metadata output'
```

---

### Task 3: 错误路径

**Files:**
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: Task 2 的 `main`。本任务不改实现，只证明 Task 2 已满足错误处理契约。若有测试失败，修实现。

- [ ] **Step 1: 写失败的测试**

追加到汇总行之前：

```bash
printf '\n-- 错误路径 --\n'
printf %s 'SENTINEL-KEEP-ME' | pbcopy
"$BP" -t 0 >/dev/null 2>&1
check '垃圾输入退出码' "$?" 2
check '垃圾输入不动剪贴板' "$(pbpaste)" 'SENTINEL-KEEP-ME'

printf '' | pbcopy
"$BP" -t 0 >/dev/null 2>&1
check '空输入退出码' "$?" 5

printf %s 'KEEP-ME-TOO' | pbcopy
printf %s '12345678' | pbcopy
"$BP" -t 0 >/dev/null 2>&1
check '纯数字误判为 b64 时退出码' "$?" 4
check '纯数字误判时不动剪贴板' "$(pbpaste)" '12345678'

"$BP" --bogus >/dev/null 2>&1
check '未知 flag 退出码' "$?" 1
"$BP" -t abc >/dev/null 2>&1
check '-t 非整数退出码' "$?" 1
```

`12345678` 是合法 base64，解码为 3 个不可打印字节，因此必须走控制字符检查并退出 4。这条测试锁住那个安全网。

- [ ] **Step 2: 运行**

```bash
./tests/run.sh
```

Expected: 全通过（Task 2 的实现已覆盖这些路径）。若 `纯数字误判` 一项失败，说明控制字符检查漏了，回 Task 2 Step 3 补。

- [ ] **Step 3: 提交**

```bash
git add tests/run.sh
git commit -m 'test: cover blindpaste error paths and exit codes'
```

---

### Task 4: `--__clear` hash 守卫与自动清空

**Files:**
- Modify: `blindpaste`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `hash_of`
- Produces: `clear_if_unchanged <hash> <ttl>`；内部子命令 `blindpaste --__clear <hash> <ttl>`。`main` 在 `ttl > 0` 时后台启动它。

- [ ] **Step 1: 写失败的测试**

```bash
printf '\n-- hash 守卫 --\n'
H=$(BLINDPASTE_LIB=1 bash -c '. ./blindpaste; hash_of "$1"' _ 'target-content')

printf %s 'something-else' | pbcopy
"$BP" --__clear "$H" 0 >/dev/null 2>&1
check '守卫保住被改过的剪贴板' "$(pbpaste)" 'something-else'

printf %s 'target-content' | pbcopy
"$BP" --__clear "$H" 0 >/dev/null 2>&1
check '守卫清空未改动的剪贴板' "$(pbpaste)" ''
```

两个方向都必须测：只测第一个方向的话，一个永不清空的实现也能通过。

- [ ] **Step 2: 运行，确认失败**

Expected: `守卫清空未改动的剪贴板` FAIL（`--__clear` 会被当成未知参数，退出 1，剪贴板不变）。

- [ ] **Step 3: 写最小实现**

在 `describe` 之后插入：

```bash
# clear_if_unchanged <hash> <ttl>：ttl 秒后，仅当剪贴板仍是我们写入的内容时清空它
clear_if_unchanged() {
  local want=$1 ttl=$2
  [ "$ttl" -gt 0 ] && sleep "$ttl"
  if [ "$(hash_of "$(pbpaste)")" = "$want" ]; then
    printf '' | pbcopy
  fi
  return 0
}
```

在 `main` 的 `while` 循环**之前**插入子命令分发：

```bash
  case ${1:-} in
    --__clear) [ $# -eq 3 ] || die '--__clear <hash> <ttl>'
               clear_if_unchanged "$2" "$3"; return 0 ;;
  esac
```

在 `main` 末尾的元信息输出**之后**追加：

```bash
  if [ "$ttl" -gt 0 ]; then
    nohup "$0" --__clear "$(hash_of "$plain")" "$ttl" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    printf '  %d 秒后自动清空（仅在剪贴板未被改动时）\n' "$ttl" >&2
  fi
```

`nohup` 是必需的：否则关闭终端时 SIGHUP 杀掉后台进程，剪贴板会永远留着明文。传出去的是 hash 不是明文，且 hash 是纯十六进制，无注入风险。

- [ ] **Step 4: 运行，确认通过**

```bash
./tests/run.sh
```

Expected: 全通过。

- [ ] **Step 5: 提交**

```bash
git add blindpaste tests/run.sh
git commit -m 'feat: add hash-guarded clipboard auto-clear'
```

---

### Task 5: age 路径、`--init`、`--sender`

**Files:**
- Modify: `blindpaste`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `decode`、`BP_KEY`
- Produces: `init_key`、`sender_cmds`、`usage`；子命令 `--init` / `--sender` / `-h`。

- [ ] **Step 1: 写失败的测试**

```bash
printf '\n-- age 路径 --\n'
if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
  TD=$(mktemp -d); K="$TD/k.txt"
  BLINDPASTE_KEY="$K" "$BP" --init >/dev/null 2>&1
  check '--init 退出码' "$?" 0
  check '--init 密钥权限' "$(stat -f '%Lp' "$K")" 600
  PUB=$(grep -o 'age1[a-z0-9]*' "$K" | head -1)
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
fi

printf -- '-----BEGIN AGE ENCRYPTED FILE-----\nabc\n-----END AGE ENCRYPTED FILE-----\n' | pbcopy
PATH=/usr/bin:/bin "$BP" -t 0 >/dev/null 2>&1
check 'age 密文但缺 age 时退出码' "$?" 3

check '--sender 总含 base64 版本' "$("$BP" --sender | grep -c 'base64')" 2
check '--sender 不依赖 pbcopy' "$("$BP" --sender | grep -c 'pbcopy')" 0
```

`PATH=/usr/bin:/bin` 里有 `pbpaste`、`pbcopy`、`shasum`，没有 `/opt/homebrew/bin`，因此 `age` 必然缺失。

- [ ] **Step 2: 运行，确认失败**

Expected: `--sender` 与缺依赖两项 FAIL。

- [ ] **Step 3: 写最小实现**

```bash
usage() {
  cat <<'EOF'
用法：
  blindpaste [-t 秒]     读剪贴板里的密文，解码后写回剪贴板
  blindpaste - [-t 秒]   密文从 stdin 读
  blindpaste --sender    打印转发给对方的命令
  blindpaste --init      生成 age keypair
  -t 0                   不自动清空剪贴板（默认 90 秒后清空）
EOF
}

init_key() {
  command -v age-keygen >/dev/null 2>&1 || die '未安装 age。先跑 brew install age' 3
  [ -e "$BP_KEY" ] && die "密钥已存在：$BP_KEY（不覆盖）" 1
  mkdir -p "$(dirname "$BP_KEY")" || die "无法创建 $(dirname "$BP_KEY")"
  chmod 700 "$(dirname "$BP_KEY")"
  ( umask 077; age-keygen -o "$BP_KEY" >/dev/null 2>&1 ) || die 'age-keygen 失败' 3
  chmod 600 "$BP_KEY"
  printf '密钥已生成：%s\n公钥（用 blindpaste --sender 拿给对方的命令）：\n' "$BP_KEY" >&2
  grep -o 'age1[a-z0-9]*' "$BP_KEY" | head -1
}

sender_cmds() {
  cat <<'EOF'
# 转发给对方。两条都不会把明文写进对方的 shell history，也不依赖 pbcopy。

# base64（对方无需装任何东西；只遮蔽，不加密）：
printf 'secret: ' >&2; read -rs s; printf %s "$s" | base64 | tr -d '\n'; echo; unset s
EOF
  if [ -r "$BP_KEY" ]; then
    local pub; pub=$(grep -o 'age1[a-z0-9]*' "$BP_KEY" | head -1)
    printf '\n# age（对方需 brew install age；真加密，推荐）：\n'
    printf "printf 'secret: ' >&2; read -rs s; printf %%s \"\$s\" | age -a -r %s; unset s\n" "$pub"
  else
    printf '\n# age 版本不可用：还没生成密钥。先跑 blindpaste --init\n'
  fi
}
```

在 `main` 的子命令分发里补三个分支，并在 age 模式解码前加缺依赖检查：

```bash
    --init)    init_key; return $? ;;
    --sender)  sender_cmds; return 0 ;;
    -h|--help) usage; return 0 ;;
```

```bash
  if [ "$mode" = age ] && ! command -v age >/dev/null 2>&1; then
    die '这是 age 密文，但未安装 age。先跑 brew install age' 3
  fi
```

`--sender` 始终打印 base64 版本、并在有密钥时追加 age 版本：我这边有没有密钥和对方那边有没有装 `age` 是两件独立的事，脚本无法知道后者。

- [ ] **Step 4: 运行，确认通过**

```bash
./tests/run.sh
```

Expected: 全通过；`age` 未安装时有 2 项 skip 并明确报告。

- [ ] **Step 5: 提交**

```bash
git add blindpaste tests/run.sh
git commit -m 'feat: add age decrypt path, key init, and sender commands'
```

---

### Task 6: README 与安装

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: 全部已实现行为。

- [ ] **Step 1: 写 README**

必须覆盖：用法；base64 只遮蔽不加密 / age 才是真加密这一区别；以及 spec 的「明确不做」与「已知限制」两节的全部内容 —— 特别是这三条，因为它们决定「不被我看到」是否真的成立：

1. 没有设 `org.nspasteboard.ConcealedType`。装了 Raycast / Alfred / Maccy / Paste 之后，明文会进剪贴板管理器历史，届时必须补这个标记。
2. 通用剪贴板（Handoff）会把剪贴板同步到 iPhone / iPad。要挡住得在系统设置里关 Handoff。
3. 明文在剪贴板里的这段时间，同机任何进程都能读它。本工具只能缩短窗口，不能消除。

以及：明文尾部空白会被剥掉；不支持含 NUL 的二进制密文；TTL 到期前关机则剪贴板不会被清空。

- [ ] **Step 2: 装到 PATH 并做一次真实演练**

```bash
mkdir -p ~/.local/bin && ln -sf "$PWD/blindpaste" ~/.local/bin/blindpaste
printf %s 424242 | base64 | pbcopy
~/.local/bin/blindpaste -t 0
```

Expected: stderr 显示 `✓ b64  →  剪贴板已就绪（6 字符，全数字）`，且 `pbpaste` 为 `424242`。用符号链接而非拷贝，这样仓库里的改动立即生效。

- [ ] **Step 3: 提交**

```bash
git add README.md
git commit -m 'docs: add blindpaste README with security limitations'
```

---

## Self-Review

**Spec coverage：** 双格式嗅探 → T1/T2/T5；命令接口 → T2（`-t`/`-`）、T4（`--__clear`）、T5（`--init`/`--sender`/`-h`）；给发送方的命令 → T5；数据流与元信息 → T2；自动清空与 hash 守卫 → T4；错误处理全部 6 个退出码 → T2/T3/T5；文件结构 → T1/T6；测试 7 个覆盖点 → T1（嗅探三分支）、T2（base64 往返、明文不泄露）、T3（垃圾不污染剪贴板）、T4（守卫双向）、T5（age 往返、缺依赖）；明确不做与已知限制 → T6。无遗漏。

**Placeholder 扫描：** 无 TBD / TODO，无「加上适当的错误处理」这类空话，每个代码步骤都是可直接粘贴运行的完整代码。

**类型一致性：** `sniff` 返回值 `age`/`b64`/`none` 在 T1 定义，T2 的 `decode` 与 `main`、T5 的缺依赖检查用的是同一组字面量。`hash_of` 在 T1 定义，T4 的 `clear_if_unchanged` 与 `main` 后台调用共用。`BP_KEY` 在 T1 定义，T2 的 `decode`、T5 的 `init_key`/`sender_cmds` 一致引用，测试用 `BLINDPASTE_KEY` 环境变量覆盖它。`clear_if_unchanged` 全程同名。
