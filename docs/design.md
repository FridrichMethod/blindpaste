# blindpaste design

**English** | [简体中文](design.zh-CN.md)

This document records why blindpaste works the way it does. For usage, see the [README](../README.md). The code (`blindpaste`) and its tests (`tests/run.sh`) are the source of truth; this document is kept in sync with them.

## Problem

Someone needs to send me a secret (a password or a one-time code). I don't want it to appear on my screen, but I need it on the macOS clipboard so I can `Cmd-V` it.

The key observation: **`pbcopy` is only the second half; the real constraint is the transport channel.** If the sender types the digits into WeChat or an email as plain text, they're rendered on my screen the moment I open the conversation, and no clipboard trick can undo that. So the plaintext must be wrapped before it reaches my eyes — what the sender sends must be an unreadable encoding or ciphertext.

## Assumptions

- The sender can run one command in their own terminal (bash or zsh, on macOS, Linux or WSL). This rules out approaches built on one-time-secret websites.
- The receiver is on macOS: `pbcopy`, `pbpaste`, `shasum` and BSD `base64` (which decodes with `-D`) are available. The script checks for `pbcopy`/`pbpaste` and exits with code 3 if they're missing.
- The receiver has no clipboard manager running, or has told it to ignore the terminal. See "Out of scope".

## Approach

A single bash script, `blindpaste`. It replaces the ciphertext on the clipboard with its plaintext, in place. The plaintext only ever exists in pipes and shell variables; the screen shows only metadata such as length and character class.

### Two formats, detected automatically

Being able to run a command doesn't mean the sender has `age` installed, so the script sniffs its input:

| Format | Detected by | What it is |
| --- | --- | --- |
| `age` ASCII armor | contains `BEGIN AGE ENCRYPTED FILE` | Real encryption. Safe even if the chat history leaks. The long-term choice |
| base64 | matches `^[A-Za-z0-9+/]+={0,2}$` after removing whitespace | Obfuscation, not encryption. Zero install, usable on day one |
| anything else | — | Error exit; the clipboard is left untouched |

Sniffing means the receiver needs no change when a sender moves from base64 to age.

base64 is obfuscation, not encryption, and the README says so: it satisfies "I don't want to see it", but not "the chat provider must not get it". The latter requires `age`.

### Command interface

| Command | Behavior |
| --- | --- |
| `blindpaste` | Main path: read clipboard → sniff → decode → write the clipboard back |
| `blindpaste -` | Same, but the ciphertext is read from stdin |
| `blindpaste --sender` | Print the commands to forward to the sender. **Always prints both**: the base64 command, plus the age command if a key exists. I pick one depending on whether the sender has `age` |
| `blindpaste --init` | Generate an age keypair at `.blindpaste.key` next to the script, `chmod 600`, print the public key. `BLINDPASTE_KEY` overrides the path |
| `-t <seconds>` | Override the auto-clear TTL. Default 90; `-t 0` disables it |

`--sender` prints both rather than choosing: whether I have an age key and whether the sender has `age` installed are independent, and the script can't know the latter, so I decide when forwarding.

### Commands for the sender

The commands printed by `--sender` have two required properties: **the secret is never written to the sender's shell history**, and **they don't need `pbcopy`** (the sender may be on Linux or WSL). The ciphertext doesn't need to be hidden from the sender — they already know the plaintext — so printing it in their terminal for them to copy is more portable than putting it on their clipboard.

base64:

```sh
printf 'secret: ' >&2; IFS= read -rs s; echo >&2; printf %s "$s" | base64 | tr -d '\n'; echo; unset s
```

age:

```sh
printf 'secret: ' >&2; IFS= read -rs s; echo >&2; printf %s "$s" | age -a -r <my public key>; unset s
```

- `read -s` doesn't echo, so the secret doesn't appear on the sender's screen either. `-r` keeps backslashes; `IFS=` keeps leading and trailing spaces.
- `echo >&2` ends the prompt line. `read -s` swallows the Enter key, so without it the ciphertext would be printed right after `secret: ` on the same line, and a sender who copies from the start of the line would send a prefix that breaks decoding.
- `tr -d '\n'` removes the line wrapping that GNU `base64` applies to long input, plus the trailing newline, so the base64 ciphertext is a single line that can be selected in one go. (age armor is a multi-line block by nature; that's fine.)

### Data flow

```
sender: IFS= read -rs ─┬─> base64 ──┐
                       └─> age -a ──┴─> ciphertext ─> any chat app ─> I select & copy
                                                                         │
  ┌──────────────────────────────────────────────────────────────────────┘
  v
pbpaste ─> sniff ─┬─> base64 -D ─┬─> $plain (memory only) ─┬─> pbcopy
                  └─> age -d ────┘                         ├─> metadata ─> stderr
                                                           └─> shasum ─> hash ─> background guard (memory only)
```

`$plain` only flows through pipes. It never appears on stdout or stderr, in argv, in any file, or in any command-line argument. Neither does its hash (see "Auto-clear").

### Success output

```
ok  b64 -> clipboard ready (6 chars, digits only)
    auto-clear in 90s (only if the clipboard is still unchanged)
```

This line is the premise the whole design rests on. I can't see the content, so I must be able to confirm that decoding succeeded and the length is what I expected — otherwise I'd have no idea what happened after blindly pasting a broken result. It goes to stderr so that `blindpaste` can sit in a pipeline without polluting stdout.

The metadata contains only: the format, the length (`${#plain}`), and a character class. The class is the **first** match, in this order, as a single value: contains a non-alphanumeric character → `has symbols`; contains a letter → `has letters`; otherwise → `digits only`. It contains no byte of the plaintext.

### Printable-ASCII safety net

`sniff` can't tell real base64 from, say, a string of digits whose length happens to be a multiple of 4; decoding the latter yields garbage. So after decoding, every byte of the plaintext must be printable ASCII (0x20–0x7E); otherwise the script exits with code 4 and leaves the clipboard alone.

- The check is "not printable ASCII", not "control character": garbage from decoding is usually high bytes (0x80–0xFF), which are not control characters.
- The check is byte-level (`LC_ALL=C tr -d '[:print:]' | wc -c`). A `grep`-based check is line-oriented and would let an embedded newline through; a bash pattern depends on the locale.
- Consequence: non-ASCII and multi-line secrets are not supported. Rejecting newlines is also the safer behavior: a blind paste containing a newline into a terminal would submit early.

### Auto-clear, with a hash guard

After writing the plaintext, `main` calls `schedule_clear`, which runs `clear_if_unchanged` in a background subshell:

```sh
( trap '' HUP; clear_if_unchanged "$hash" "$ttl" ) </dev/null >/dev/null 2>&1 &
disown
```

`clear_if_unchanged` does `sleep $ttl`, recomputes the first 16 hex digits of the SHA-256 of the current clipboard, compares them with the hash it was given, and **does nothing if they differ**. That avoids the bug of "deletes whatever I copied 90 seconds later".

Why this shape:

- **Ignoring SIGHUP is required.** Without it, closing the terminal kills the background process and the plaintext stays on the clipboard forever. `trap '' HUP` is what `nohup` does, and an ignored signal stays ignored in child processes (`sleep`, `pbpaste`).
- **A subshell, not a re-exec of `"$0"`.** An earlier version ran `nohup "$0" --__clear <hash> <ttl> &`. That had two problems:
  1. The hash was in argv. Any local user can read argv with `ps`, and endpoint/audit software often logs it. For a low-entropy secret, a hash is as good as the plaintext: all 10^6 six-digit codes can be tried in well under a second against a 64-bit, unsalted SHA-256 prefix. In a subshell the hash only lives in process memory.
  2. It depended on how the script was invoked. With `bash blindpaste`, `$0` is a bare name; `nohup` looks it up on PATH, doesn't find it, and the error disappears into `/dev/null`, so the clipboard is silently never cleared.
- The clear logic is a plain function, so the tests call it directly (via `BLINDPASTE_LIB=1`) with `ttl=0`.

The two hashes must be computed the same way: when writing, from the shell variable `$plain`; when checking, from `$(pbpaste)`. Command substitution has stripped trailing newlines from both, so they match.

### Error handling

Every failure path leaves the clipboard untouched and prints no byte of the decoded result (even a partial decode could leak something).

| Exit code | Condition | Message gist |
| --- | --- | --- |
| 0 | Success | Metadata |
| 1 | Usage error | Unknown flag, `-t` missing or not an integer, `--init` when the key already exists |
| 2 | Sniffing failed | Neither format matches; clipboard unchanged |
| 3 | Missing dependency | Not on macOS (no `pbcopy`/`pbpaste`); age ciphertext but no `age` → `brew install age`; no readable private key → `blindpaste --init` |
| 4 | Decode failed | Corrupt base64, wrong age key, or the result isn't single-line printable ASCII |
| 5 | Empty input | The clipboard (or stdin) is empty |

`age -d` writes plaintext to stdout only on success and exits non-zero on failure. The implementation uses `plain=$(... 2>/dev/null)` and checks the exit code; when it's non-zero, the contents of `$plain` are never used.

`--init` must refuse to overwrite an existing key file and exit non-zero.

### Key location: self-contained

The repo is self-contained: nothing is installed into `~/.local/bin` or any system location; `./blindpaste` runs straight from the repo directory. The corollary is that the key must live inside the repo (`.blindpaste.key`), so:

- `.gitignore` must list it explicitly, and the tests check that with `git check-ignore`.
- The script directory is derived from `BASH_SOURCE`, not `$0`, so it's also right when the script is sourced with `BLINDPASTE_LIB=1`.
- Symlinks are resolved (with a `readlink` loop, since macOS bash 3.2 has no `realpath`), so a symlink on PATH still points the default key at the repo and its `.gitignore`, not at the directory holding the symlink.
- Resolution uses only builtins apart from `readlink`, so it works even with a bare PATH and the "not on macOS" error can still be reported.
- `init_key` only runs `mkdir` + `chmod 700` when the directory doesn't exist yet, because the default directory is the repo root, and `chmod 700` on an existing directory would change the permissions of the repo itself.

The price is that a private key sits inside the repo. That's the trade for being self-contained, and the README warns about it explicitly (pushing, `git clean -fdx`, synced folders). `BLINDPASTE_KEY` moves the key elsewhere.

## Out of scope

- **The `org.nspasteboard.ConcealedType` marker.** This is the community convention that makes clipboard managers skip an entry, but neither `pbcopy` nor AppleScript can set it; it needs Swift or pyobjc. The README states prominently that a clipboard manager defeats the tool.
- **Universal Clipboard (Handoff).** The clipboard syncs to iPhone/iPad. Turning off Handoff is a System Settings change, not code's job. The README mentions it.
- **`age -p` passphrase mode.** It needs a second channel for the passphrase, which is more hassle than a one-time public key exchange.
- **Binary or NUL-containing ciphertext, non-ASCII or multi-line plaintext.** Shell variables can't hold NUL, and the printable-ASCII safety net rejects the rest. The tool targets text passwords.

## Known limitations

- Trailing whitespace in the plaintext is stripped by command substitution. Right for numeric codes, wrong for secrets where trailing spaces matter.
- While the plaintext is on the clipboard, any process in the login session can read it. That's inherent to the macOS clipboard; the tool can only shorten the exposure window.
- If the machine shuts down or the background process is killed before the TTL expires, the clipboard isn't cleared.

## Layout

```
blindpaste            # the script, bash 3.2 compatible, ASCII only
tests/run.sh          # self-contained test runner, no installs
README.md             # usage and limitations (English)
README.zh-CN.md       # usage and limitations (Chinese)
docs/design.md        # this document (English)
docs/design.zh-CN.md  # this document (Chinese)
LICENSE               # MIT
```

## Testing

No bats: it's not installed by default, and pulling in two Homebrew dependencies for a ~200-line script isn't worth it. `tests/run.sh` is a self-contained shell test runner.

When `BLINDPASTE_LIB=1` is set, the script only defines its functions and doesn't run `main`, so the tests can call `sniff`, `hash_of`, `clear_if_unchanged` and friends directly without exposing them as public flags.

Coverage:

1. base64 round trip: known plaintext → encode → `blindpaste` → the clipboard equals the original byte for byte. Also via stdin.
2. age round trip: same (skipped and reported as skip when `age` isn't installed, never a silent pass).
3. Sniffing: age armor, valid base64, base64 with whitespace, garbage, empty.
4. Garbage doesn't pollute the clipboard: preset known content → feed garbage → clipboard unchanged and exit code 2.
5. The safety net: digits mis-sniffed as base64, non-ASCII plaintext and multi-line plaintext all exit 4 with the clipboard unchanged.
6. The hash guard, in both directions: (a) clipboard changed → `clear_if_unchanged <old hash> 0` → the new content survives; (b) clipboard unchanged → `clear_if_unchanged <correct hash> 0` → the clipboard is cleared. Testing only (a) would let an implementation that never clears pass.
7. Auto-clear end to end: the background clearer really fires, both for `./blindpaste` and for `bash blindpaste`, and the hash of the secret appears in no process's argv while it waits.
8. No plaintext leak: capture stdout and stderr and assert that the plaintext isn't in them.
9. Missing dependencies: fake age ciphertext with `age` hidden from `PATH` → exit 3 with the age message; no `pbcopy`/`pbpaste` → exit 3 with the macOS message.
10. Sender commands: always include base64, never use `pbcopy`, round-trip leading/trailing spaces and backslashes, end the prompt line, produce one line of base64; the age command round-trips too.
11. Self-contained: the default key is in the repo (also through a chain of symlinks), it's gitignored, the code doesn't reference `$HOME` or `.local/bin`, and the code files are pure ASCII.

The tests read and write the real clipboard. `tests/run.sh` saves the original text content at the start and restores it at the end, and uses `-t 0` everywhere except the end-to-end auto-clear tests, so that no background clearer interferes with other assertions. The tests must not run in parallel.
