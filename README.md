# blindpaste

**English** | [简体中文](README.zh-CN.md)

Someone sends you a secret (a password, a one-time code). You don't want it to appear on your screen, but you need it on the clipboard so you can just `Cmd-V` it.

`blindpaste` replaces the ciphertext on your macOS clipboard with its plaintext, in place. The plaintext only travels through pipes into `pbcopy`; the screen shows nothing but its length and character class:

```
$ ./blindpaste
ok  b64 -> clipboard ready (6 chars, digits only)
    auto-clear in 90s (only if the clipboard is still unchanged)
```

That one line of metadata is what makes the design work. You can't see the content, so you need a way to confirm that decoding succeeded and that the length is what you expected — otherwise you'd blindly paste a broken result with no way to tell.

> [!WARNING]
> **Clipboard managers defeat this tool.** With Raycast, Alfred, Maccy, Paste or any other clipboard-history app running, the plaintext *will* be saved in its history, and you will see it the next time you browse it. If your clipboard manager can ignore specific apps, add your terminal; otherwise don't use blindpaste alongside it. See [Limitations](#limitations).

## Requirements

- **You (the receiver):** macOS. The system `/bin/bash` (3.2) is fine. Optional: [`age`](https://github.com/FiloSottile/age) for real encryption (`brew install age`).
- **The sender:** any bash or zsh, on macOS, Linux or WSL. Nothing to install for base64; `age` for the encrypted variant.

## The clipboard is only the second half

If the sender pastes the digits into WeChat or an email as plain text, they're rendered on your screen the moment you open the conversation, and no clipboard trick can undo that. **The plaintext has to be wrapped before it reaches your eyes** — what the sender sends must be an unreadable encoding or ciphertext.

So step one is sending the sender a command:

```sh
./blindpaste --sender
```

This prints the commands the sender should run. They have two properties: the secret is never written to the sender's shell history (it's read with `IFS= read -rs`), and they don't need `pbcopy` (the sender may be on Linux or WSL). There's no need to hide the ciphertext from the sender — they already know the plaintext — so it's printed straight to their terminal for them to copy and forward.

The sender sends you the resulting gibberish. You select and copy it, run `./blindpaste`, then `Cmd-V`.

## Two formats, different security

| Format | Sender needs | What it is |
| --- | --- | --- |
| base64 | nothing | **Obfuscation, not encryption.** Hides the secret from your eyes, not from the chat provider — to them, ciphertext and plaintext are equivalent |
| age | `age` installed | Real encryption. Safe even if the chat history leaks |

The script detects which one it received; you don't need to tell it.

**If the secret is a long-lived password rather than a one-time code that expires in minutes, use age.** base64 is only appropriate for "one-time code, and I just don't want to see it".

To enable age:

```sh
brew install age
./blindpaste --init          # creates .blindpaste.key in the repo root, mode 600
./blindpaste --sender        # now also prints the age command
```

`--sender` always prints the base64 command and adds the age command when a key exists. Whether *you* have a key and whether *the sender* has `age` installed are independent, and the script can't know the latter, so you decide which one to forward.

## Usage

```
./blindpaste [-t SECONDS]     decode the ciphertext on the clipboard, put the plaintext back
./blindpaste - [-t SECONDS]   read the ciphertext from stdin instead
./blindpaste --sender         print the commands to forward to the sender
./blindpaste --init           generate an age keypair
-t 0                          do not auto-clear the clipboard (default: clear after 90 s)
```

Exit codes: `0` success, `1` usage error (including `--init` when a key already exists), `2` unrecognized format, `3` missing dependency (no `age`, no readable key, or not on macOS), `4` decode failed, `5` empty input. **Every failure path leaves the clipboard untouched** and prints no byte of the decoded result.

## Auto-clear with a hash guard

By default the clipboard is cleared after 90 seconds, but right before clearing, the clipboard's hash is compared again: **if you copied something else in the meantime, nothing happens.** Otherwise this feature would turn into "deletes whatever you copied 90 seconds later".

The clearer is a background subshell that ignores SIGHUP, so closing the terminal doesn't kill it. The hash it compares against lives only in that process's memory, never in its command line: `ps` shows every process's arguments to all local users, and endpoint/audit software often logs them, and for a 6-digit code a hash is as good as the plaintext (all 10^6 candidates take under a second).

## Self-contained

Nothing to install. Run `./blindpaste` straight from the repo directory.

The tool never writes to `$HOME`, `/usr/local`, your shell config or any other system location. The age private key is also created in the repo root (`.blindpaste.key`), not in `~/.config`. `tests/run.sh` locks this in: the default key path must be inside the repo (also when the script is run through a symlink), it must be covered by `.gitignore`, and the code must not reference `$HOME` or `.local/bin`.

The price is that **a private key sits inside the repo**. `.gitignore` lists `.blindpaste.key` explicitly and the tests verify that with `git check-ignore`, but:

- Before pushing your copy of the repo anywhere, check it yourself.
- `git clean -fdx` (or `-fdX`) deletes ignored files — **including your key**. If it's gone, run `--init` again and forward the new `--sender` command. Ciphertext made for the old key can no longer be decrypted, which doesn't matter for one-time codes.
- If the repo is in a synced folder (iCloud Drive, Dropbox, …), the key is synced too.

To keep the key somewhere else, override it with an environment variable:

```sh
BLINDPASTE_KEY=~/somewhere/else.key ./blindpaste
```

If typing `./` every time gets old, add an alias or a symlink yourself (nothing touches your shell config for you):

```sh
alias blindpaste="$PWD/blindpaste"
# or
ln -s "$PWD/blindpaste" ~/bin/blindpaste
```

Symlinks are resolved, so the default key stays in the repo root either way.

## Tests

```sh
./tests/run.sh
```

No bats needed; macOS only. The tests read and write the real clipboard: text content is saved at the start and restored at the end (non-text content such as an image is not restored), so **don't run them in parallel**. When `age` isn't installed, the tests that need it are reported as skipped rather than silently passing. A run takes a few seconds because it waits for a real auto-clear to fire.

Design rationale: [docs/design.md](docs/design.md).

## Limitations

These three decide whether "it never shows up on my screen" actually holds. Read each one:

1. **`org.nspasteboard.ConcealedType` is not set.** That's the community convention telling clipboard managers to skip an entry, but neither `pbcopy` nor AppleScript can set it; it needs Swift or pyobjc. **With Raycast / Alfred / Maccy / Paste installed, the plaintext goes into their history, and browsing that history will show it to you.**
2. **Universal Clipboard (Handoff) syncs the clipboard to your iPhone / iPad.** To prevent that, turn off Handoff in System Settings. That's system configuration, not this tool's job.
3. **While the plaintext is on the clipboard, any app or process in your login session can read it.** That's inherent to the macOS clipboard. This tool shortens the exposure window; it can't eliminate it.

Also:

- Trailing whitespace in the plaintext is stripped (inherent to shell command substitution). That's the right behavior for numeric codes.
- The plaintext must be a single line of printable ASCII (bytes 0x20–0x7E). Non-ASCII secrets (CJK characters, accented letters, emoji) and multi-line secrets are rejected with exit code 4. That's the safety net described in the last item.
- Binary ciphertext containing NUL bytes isn't supported — shell variables can't hold NUL. This tool is for text passwords.
- If the machine shuts down or the background process is killed before the TTL expires, the clipboard isn't cleared.
- Format detection can't tell real base64 apart from a plain string of digits or letters whose length happens to be valid base64. The script's safety net is "the decoded result must be printable ASCII", which turns that case into exit code 4 instead of putting garbage bytes on the clipboard. The net isn't perfect: garbage that happens to be all printable ASCII slips through, but the character class in the metadata line then shows `has symbols`, which is enough to notice something is off.

## License

[MIT](LICENSE)
