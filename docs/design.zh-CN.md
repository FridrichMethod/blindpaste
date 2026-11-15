# blindpaste 设计文档

[English](design.md) | **简体中文**

本文记录 blindpaste 为什么是现在这个样子。用法见 [README](../README.zh-CN.md)。以代码（`blindpaste`）和测试（`tests/run.sh`）为准，本文与它们保持同步。

## 问题

别人要发我一串密码或一次性口令。我不想让它出现在我的屏幕上，但需要它进入 macOS 剪贴板，以便直接 `Cmd-V` 粘贴。

关键判断：**`pbcopy` 只是后半段，真正的约束在传输通道。** 只要对方把数字当普通文本发到微信或邮件里，它在我打开对话的那一刻就已经渲染到屏幕上了，任何剪贴板技巧都救不回来。因此明文必须在到达我眼睛之前就被包住 —— 对方发送的必须是不可读的编码或密文。

## 前提

- 发送方能在自己终端里跑一条命令（bash 或 zsh，macOS、Linux、WSL 均可）。这排除了依赖一次性密文网站的方案。
- 接收方在 macOS 上：`pbcopy`、`pbpaste`、`shasum` 和 BSD `base64`（解码用 `-D`）可用。脚本会检查 `pbcopy`/`pbpaste`，缺失时以退出码 3 退出。
- 接收方没有运行剪贴板管理器，或已让它忽略终端。见「明确不做」。

## 方案

一个 bash 脚本 `blindpaste`。把剪贴板里的密文原地替换为明文；明文全程只存在于管道和 shell 变量中，屏幕上只显示长度和字符类别这样的元信息。

### 双格式，自动嗅探

发送方能跑命令行不等于装了 `age`，所以脚本嗅探输入内容：

| 格式 | 判据 | 性质 |
| --- | --- | --- |
| `age` ASCII armor | 含 `BEGIN AGE ENCRYPTED FILE` | 真加密。聊天记录泄露也安全。长期首选 |
| base64 | 去掉空白后匹配 `^[A-Za-z0-9+/]+={0,2}$` | 仅遮蔽，非加密。零安装，第一天就能用 |
| 其它 | — | 报错退出，剪贴板保持原样 |

嗅探让发送方从 base64 升级到 age 时，接收端零改动。

base64 只是遮蔽而非加密，README 里写明了这一点：它满足「我不想看到」，但不满足「聊天服务商不该拿到」。要后者就必须装 `age`。

### 命令接口

| 命令 | 行为 |
| --- | --- |
| `blindpaste` | 主路径。读剪贴板 → 嗅探 → 解码 → 写回剪贴板 |
| `blindpaste -` | 同上，但密文从 stdin 读 |
| `blindpaste --sender` | 打印转发给对方的命令。**始终同时打印两条**：base64 版本，以及 age 版本（仅当已有密钥）。我按对方是否装了 `age` 自行取用 |
| `blindpaste --init` | 在脚本所在目录生成 age keypair（`.blindpaste.key`），`chmod 600`，打印公钥。可用 `BLINDPASTE_KEY` 覆盖路径 |
| `-t <秒>` | 覆盖自动清空 TTL，默认 90，`-t 0` 关闭 |

`--sender` 同时打印两条而非二选一：我这边有没有 age 密钥和对方那边有没有装 `age` 是两件独立的事，脚本无法知道后者，所以由我在转发时决定。

### 给发送方的命令

`--sender` 输出的命令有两个必需性质：**不把明文写进对方的 shell history**，且**不依赖 `pbcopy`**（对方可能在 Linux 或 WSL）。密文不需要对对方保密 —— 对方本来就知道明文 —— 所以直接打到对方终端里、由对方自己复制，比塞进对方的剪贴板更通用。

base64 版本：

```sh
printf 'secret: ' >&2; IFS= read -rs s; echo >&2; printf %s "$s" | base64 | tr -d '\n'; echo; unset s
```

age 版本：

```sh
printf 'secret: ' >&2; IFS= read -rs s; echo >&2; printf %s "$s" | age -a -r <我的公钥>; unset s
```

- `read -s` 不回显，对方屏幕上也看不到明文。`-r` 保留反斜杠；`IFS=` 保留首尾空格。
- `echo >&2` 结束提示行。`read -s` 会吞掉回车，没有这一句的话，密文会紧跟在 `secret: ` 后面、和它在同一行，对方从行首选中复制就会带上前缀，导致解码失败。
- `tr -d '\n'` 抹掉 GNU `base64` 对长输入的换行折叠和末尾换行，保证 base64 密文是可一次选中的单行。（age armor 本身就是多行块，这没问题。）

### 数据流

```
对方：IFS= read -rs ─┬─> base64 ──┐
                     └─> age -a ──┴─> 密文 ─> 任意聊天软件 ─> 我选中复制
                                                                  │
  ┌───────────────────────────────────────────────────────────────┘
  v
pbpaste ─> 嗅探 ─┬─> base64 -D ─┬─> $plain（仅内存）─┬─> pbcopy
                 └─> age -d ────┘                    ├─> 元信息 ─> stderr
                                                     └─> shasum ─> hash ─> 后台守卫（仅内存）
```

`$plain` 只经由管道流动。它绝不出现在 stdout、stderr、argv、任何文件或任何命令行参数中。它的 hash 也一样（见「自动清空」）。

### 成功输出

```
ok  b64 -> clipboard ready (6 chars, digits only)
    auto-clear in 90s (only if the clipboard is still unchanged)
```

这一行是整个设计成立的前提。我看不到内容，所以必须能确认解码成功且位数符合预期 —— 否则盲粘贴一个坏结果时我完全无法判断发生了什么。输出走 stderr，这样 `blindpaste` 可以出现在管道里而不污染 stdout。

元信息只包含：格式、字符长度（`${#plain}`）、字符类别。字符类别按以下优先级取**第一个**匹配项，互斥单值：含非字母数字字符 → `has symbols`；含字母 → `has letters`；否则 → `digits only`。不含明文的任何字节。

### 可打印 ASCII 安全网

`sniff` 无法区分真正的 base64 和一串恰好长度为 4 的倍数的纯数字，后者解码出的是垃圾。因此解码后，明文的每个字节都必须是可打印 ASCII（0x20–0x7E），否则以退出码 4 退出，剪贴板不动。

- 查的是「非可打印 ASCII」而不是「控制字符」：解码出的垃圾通常是 0x80–0xFF 的高位字节，那些不是控制字符。
- 按字节检查（`LC_ALL=C tr -d '\040-\176' | wc -c`）。基于 `grep` 的检查是按行的，会放过嵌在中间的换行；bash 模式匹配受 locale 影响；显式的八进制范围则不依赖 tr 对 `[:print:]` 的定义。
- 命令替换会悄无声息地丢掉 NUL 字节，所以 `main` 在捕获解码结果前先经过 `tr '\000' '\001'`。这样 NUL 会变成一个控制字符被本检查拒绝，而不是凭空消失、留下一个被篡改却能通过检查的密码。`pipefail` 保留了解码器的退出码。
- 结果：不支持非 ASCII 和多行的密码。拒绝换行本身也更安全：盲粘贴一段含换行的内容到终端，会提前回车提交。

### 自动清空，带 hash 守卫

写入明文后，`main` 调用 `schedule_clear`，在后台子 shell 里运行 `clear_if_unchanged`：

```sh
( trap '' HUP; clear_if_unchanged "$hash" "$ttl" ) </dev/null >/dev/null 2>&1 &
disown
```

`clear_if_unchanged` 的行为：`sleep $ttl`，然后重新计算当前剪贴板内容的 SHA-256 前 16 位十六进制，与传入的 hash 比对，**不一致则什么都不做**。这避免了「90 秒后把我后来复制的东西删掉」这个 bug。

守卫是「失败即不动」的。`clear_if_unchanged` 遇到空的或非十六进制的 hash 直接返回，因为 `shasum` 失败时两边都是空串，`"" = ""` 会把剪贴板上的任何东西清掉。`main` 在调度前也会检查 hash 是否为 16 个字符；不是的话，就关闭自动清空并给出警告（写剪贴板本身已经成功，所以退出码仍为 0）。

为什么是这个结构：

- **忽略 SIGHUP 是必需的。** 否则关闭终端时后台进程被杀，剪贴板会永远留着明文。`trap '' HUP` 就是 `nohup` 做的事，而被忽略的信号在子进程（`sleep`、`pbpaste`）里仍保持忽略。
- **用子 shell，而不是重新执行 `"$0"`。** 早期版本用的是 `nohup "$0" --__clear <hash> <ttl> &`，有两个问题：
  1. hash 出现在 argv 里。本机任何用户都能用 `ps` 读到 argv，终端安全 / 审计软件也常常记录它。对低熵口令而言，hash 和明文等价：面对一个无盐、截断到 64 位的 SHA-256，穷举全部 10^6 个 6 位数字口令远不到一秒。放在子 shell 里，hash 只存在于进程内存中。
  2. 依赖脚本的调用方式。用 `bash blindpaste` 调用时，`$0` 是不带斜杠的裸名字，`nohup` 会去 PATH 里找，找不到，错误又被 `/dev/null` 吞掉，于是剪贴板悄无声息地永远不会被清空。
- `main` 在 fork 之前 unset `$plain` 和 `$blob`，这样存活整个 TTL 的那个进程不会带着密码，哪怕你已经复制了别的东西。这只是尽力而为：bash 无法擦除已释放的内存。
- 清空逻辑是一个普通函数，测试通过 `BLINDPASTE_LIB=1` 以 `ttl=0` 直接调用它。

两处 hash 必须以相同方式计算：写入时对 shell 变量 `$plain` 求值，检查时对 `$(pbpaste)` 求值。两者都已被命令替换剥掉尾部换行，因此一致。

### 错误处理

所有失败路径都保持剪贴板原样，且不打印解码结果的任何字节（部分解码也可能泄露）。

| 退出码 | 条件 | 消息要点 |
| --- | --- | --- |
| 0 | 成功 | 元信息 |
| 1 | 用法错误 | 未知 flag、`-t` 缺参数或非整数、`--init` 时密钥已存在 |
| 2 | 嗅探失败 | 两种格式都不匹配，剪贴板未改动 |
| 3 | 缺依赖 | 不在 macOS 上（无 `pbcopy`/`pbpaste`）；是 age 密文但 `age` 未安装 → 提示 `brew install age`；私钥不可读 → 提示 `blindpaste --init` |
| 4 | 解码失败 | base64 损坏、age 私钥不匹配，或结果不是单行可打印 ASCII |
| 5 | 输入为空 | 剪贴板（或 stdin）为空 |

`age -d` 仅在成功时向 stdout 写明文，失败时非零退出。实现上用 `plain=$(... 2>/dev/null)` 并检查退出码，退出码非零时绝不使用 `$plain` 的内容。

`--init` 在密钥文件已存在时必须拒绝覆盖并非零退出。

### 密钥位置：自包含

仓库自包含：不安装到 `~/.local/bin` 或任何系统位置，直接从仓库目录跑 `./blindpaste`。推论是密钥必须留在仓库内（`.blindpaste.key`），因此：

- `.gitignore` 必须显式列出它，测试用 `git check-ignore` 验证。
- 脚本目录由 `BASH_SOURCE` 推导而非 `$0`，这样脚本在 `BLINDPASTE_LIB=1` 下被 source 时也能算对。
- 解析符号链接（用 `readlink` 循环，因为 macOS 的 bash 3.2 没有 `realpath`），这样 PATH 上的符号链接仍会让默认密钥指向仓库及其 `.gitignore`，而不是符号链接所在的目录。
- 除 `readlink` 外只用 builtin，因此在 PATH 很简陋时也能工作，「不在 macOS 上」的错误仍能正常报出。
- `init_key` 只在目录不存在时才 `mkdir` + `chmod 700`，因为默认目录就是仓库根目录，对已存在的目录 `chmod 700` 会改掉仓库自身的权限。

代价是仓库里躺着一个私钥。这是用自包含换来的，README 明确警告了相关风险（推送远端、`git clean -fdx`、同步目录）。用 `BLINDPASTE_KEY` 可以把密钥放到别处。

## 明确不做

- **`org.nspasteboard.ConcealedType` 标记。** 这是让剪贴板管理器跳过记录的社区约定，但 `pbcopy` 和 AppleScript 都设不了，需要 Swift 或 pyobjc。README 显眼地写明了：剪贴板管理器会让本工具失效。
- **通用剪贴板（Handoff）处理。** 剪贴板会同步到 iPhone/iPad。关闭 Handoff 是系统设置里的操作，不是代码职责。README 有提示。
- **`age -p` 口令模式。** 还需另开渠道传口令，比一次性交换公钥更麻烦。
- **二进制、非 ASCII 或多行的明文。** shell 变量无法承载 NUL，可打印 ASCII 安全网会拒绝以上所有情况（包括 NUL，见上文）。本工具面向文本密码。

## 已知限制

- 明文尾部的空白字符会被命令替换剥掉。对数字口令是正确行为，但不适用于「尾部空格有意义」的密码。
- 明文在剪贴板中期间，登录会话里的任何进程都能读取它。这是 macOS 剪贴板的固有性质，本工具只能缩短暴露窗口。
- 若在 TTL 到期前关机或杀掉后台进程，剪贴板不会被清空。

## 文件结构

```
blindpaste            # 主脚本，兼容 bash 3.2，纯 ASCII
tests/run.sh          # 自带测试器，零安装
README.md             # 用法 + 限制（英文）
README.zh-CN.md       # 用法 + 限制（中文）
docs/design.md        # 本文档（英文）
docs/design.zh-CN.md  # 本文档（中文）
LICENSE               # MIT
```

## 测试

不用 bats：默认没有安装，为一个约 200 行的脚本引入两个 Homebrew 依赖不划算。`tests/run.sh` 是自带的 shell 测试器。

脚本支持 `BLINDPASTE_LIB=1` 环境变量：设置时只定义函数、不执行 `main`，使测试能直接调用 `sniff`、`hash_of`、`clear_if_unchanged` 等函数，无需为测试暴露公开 flag。

覆盖点：

1. base64 往返：已知明文 → 编码 → `blindpaste` → 剪贴板内容逐字节等于原明文。stdin 模式也测。
2. age 往返：同上（`age` 未安装时跳过并明确报告为 skip，不静默通过）。
3. 嗅探：age armor、合法 base64、带空白的 base64、垃圾输入、空输入。
4. 垃圾输入不污染剪贴板：预置已知内容 → 喂垃圾 → 剪贴板未变且退出码为 2。
5. 安全网：被误判为 base64 的纯数字、非 ASCII 明文、多行明文、含 NUL 的明文都以退出码 4 退出，剪贴板不变。
6. hash 守卫，两个方向都测：(a) 剪贴板被改过 → `clear_if_unchanged <旧hash> 0` → 新内容未被删；(b) 剪贴板未改动 → `clear_if_unchanged <正确hash> 0` → 剪贴板已清空。只测 (a) 会让一个永不清空的实现也通过。另外测「失败即不动」：把 `shasum` 替换成必定失败时，守卫保留剪贴板，`main` 提示自动清空已关闭。
7. 自动清空端到端：后台清空真的会触发，`./blindpaste` 和 `bash blindpaste` 两种调用方式都测；它能扛住 SIGHUP；等待期间，任何进程的 argv 里都不出现明文的 hash（启动 1 秒后、exec 都已完成时用 `ps -ww` 采样）。`-t 08` 显示为 08s，不会被当成八进制。
8. 明文不泄露：捕获 stdout 与 stderr，断言其中不含明文。
9. 缺依赖：伪造 age 密文且在 `PATH` 中屏蔽 `age` → 退出码 3 且提示 age；没有 `pbcopy`/`pbpaste` → 退出码 3 且提示 macOS。
10. 发送方命令：始终包含 base64、不依赖 `pbcopy`、首尾空格和反斜杠能原样往返、提示行会结束、base64 输出为单行；age 命令也能往返。
11. 自包含：默认密钥在仓库内（经过多级符号链接也一样）、被 gitignore 覆盖、代码不引用 `$HOME` 或 `.local/bin`、代码文件是纯 ASCII。

测试会读写真实剪贴板。`tests/run.sh` 在开始时保存原剪贴板的文本内容、结束时恢复；除端到端自动清空测试外全程用 `-t 0`，以免后台清空进程干扰其它断言。测试不可并行运行。
