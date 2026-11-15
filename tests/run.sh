#!/usr/bin/env bash
# Test runner for blindpaste. No bats needed. macOS only.
#
# It reads and writes the REAL clipboard: text content is saved at the start
# and restored on exit. Do not run it in parallel with itself.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd -P)
BP=./blindpaste

pass=0; fail=0; skip=0
ORIG=$(pbpaste)
trap 'printf %s "$ORIG" | pbcopy' EXIT

ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
sk() { skip=$((skip+1)); printf '  skip %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 -- got [$2] want [$3]"; fi; }

# LIB <function> [args...] -- call one of blindpaste's functions directly.
LIB() { BLINDPASTE_LIB=1 bash -c '. ./blindpaste; "$@"' _ "$@"; }

printf '\n-- sniff --\n'
check 'sniff: age armor'           "$(LIB sniff '-----BEGIN AGE ENCRYPTED FILE-----')" age
check 'sniff: base64'              "$(LIB sniff 'MTIzNDU2')" b64
check 'sniff: base64 with newline' "$(LIB sniff 'MTIz
NDU2')" b64
check 'sniff: garbage'             "$(LIB sniff 'hello world!!')" none
check 'sniff: empty'               "$(LIB sniff '')" none

printf '\n-- base64 main path --\n'
SECRET=903142
printf %s "$SECRET" | base64 | tr -d '\n' | pbcopy
out=$("$BP" -t 0 2>&1); rc=$?
check 'b64: exit code' "$rc" 0
check 'b64: clipboard holds the plaintext' "$(pbpaste)" "$SECRET"
check 'b64: metadata line' "$(printf %s "$out" | grep -c '6 chars, digits only')" 1
if printf %s "$out" | grep -q "$SECRET"; then no 'b64: plaintext not printed'; else ok 'b64: plaintext not printed'; fi

printf %s 'SENTINEL2' | pbcopy
printf %s "$SECRET" | base64 | "$BP" - -t 0 >/dev/null 2>&1
check 'stdin mode' "$(pbpaste)" "$SECRET"

printf '\n-- error paths --\n'
printf %s 'SENTINEL-KEEP-ME' | pbcopy
"$BP" -t 0 >/dev/null 2>&1
check 'garbage input: exit code' "$?" 2
check 'garbage input: clipboard unchanged' "$(pbpaste)" 'SENTINEL-KEEP-ME'

printf '' | pbcopy
"$BP" -t 0 >/dev/null 2>&1
check 'empty input: exit code' "$?" 5

# 12345678 is valid base64 and decodes to high bytes, so it must be caught by
# the printable-ASCII safety net.
printf %s '12345678' | pbcopy
"$BP" -t 0 >/dev/null 2>&1
check 'digits mis-sniffed as b64: exit code' "$?" 4
check 'digits mis-sniffed as b64: clipboard unchanged' "$(pbpaste)" '12345678'

# Non-ASCII plaintext ("cafe" with an accented e, as UTF-8) is rejected.
CT=$(printf 'caf\303\251' | base64 | tr -d '\n')
printf %s "$CT" | pbcopy
"$BP" -t 0 >/dev/null 2>&1
check 'non-ASCII plaintext: exit code' "$?" 4
check 'non-ASCII plaintext: clipboard unchanged' "$(pbpaste)" "$CT"

# An embedded newline must not slip through (grep is line-based).
printf 'abc\ndef' | base64 | tr -d '\n' | pbcopy
"$BP" -t 0 >/dev/null 2>&1
check 'multi-line plaintext: exit code' "$?" 4

"$BP" --bogus >/dev/null 2>&1
check 'unknown flag: exit code' "$?" 1
"$BP" -t abc >/dev/null 2>&1
check '-t non-integer: exit code' "$?" 1

# Without pbcopy/pbpaste (i.e. not macOS) it must say so and exit 3.
out=$(PATH=/nonexistent "$BASH" "$BP" -t 0 2>&1); rc=$?
check 'no pbcopy/pbpaste: exit code' "$rc" 3
check 'no pbcopy/pbpaste: message' "$(printf %s "$out" | grep -c 'only runs on macOS')" 1

printf '\n-- auto-clear --\n'
H=$(LIB hash_of 'target-content')

printf %s 'something-else' | pbcopy
LIB clear_if_unchanged "$H" 0
check 'guard keeps a clipboard that changed' "$(pbpaste)" 'something-else'

printf %s 'target-content' | pbcopy
LIB clear_if_unchanged "$H" 0
check 'guard clears an unchanged clipboard' "$(pbpaste)" ''

# End to end: the background clearer must really fire, must not depend on how
# the script was invoked, and must never put the hash in any process's argv
# (a hash of a 6-digit code can be brute-forced in well under a second).
HS=$(LIB hash_of "$SECRET")
printf %s "$SECRET" | base64 | tr -d '\n' | pbcopy
"$BP" -t 1 >/dev/null 2>&1
PS=$(ps -A -o command= 2>/dev/null)
if [ -z "$PS" ]; then
  sk 'hash not in any argv (ps unavailable)'
elif printf %s "$PS" | grep -q "$HS"; then
  no 'hash not in any argv'
else
  ok 'hash not in any argv'
fi
sleep 3
check 'auto-clear fires (./blindpaste)' "$(pbpaste)" ''

printf %s "$SECRET" | base64 | tr -d '\n' | pbcopy
bash blindpaste -t 1 >/dev/null 2>&1
sleep 3
check 'auto-clear fires (bash blindpaste)' "$(pbpaste)" ''

printf '\n-- sender commands --\n'
SND=$("$BP" --sender)
B64CMD=$(printf '%s\n' "$SND" | grep -v '^#' | grep '| base64')
check '--sender always has a base64 command' "$(printf '%s\n' "$B64CMD" | grep -c .)" 1
# Only non-comment lines: the comments mention pbcopy as explanation.
check '--sender commands do not use pbcopy' "$(printf '%s\n' "$SND" | grep -v '^#' | grep -c 'pbcopy')" 0
TD=$(mktemp -d)
printf '  p\\q  \n' | bash -c "$B64CMD" >"$TD/out" 2>"$TD/err"
check 'base64 sender command keeps spaces and backslashes' "$(base64 -D <"$TD/out")" '  p\q  '
check 'sender prompt ends its line' "$(tail -c 1 "$TD/err" | od -An -c | tr -d ' ')" '\n'
check 'sender ciphertext is one line' "$(grep -c . "$TD/out")" 1
rm -rf "$TD"

printf '\n-- age path --\n'
if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
  TD=$(mktemp -d); K="$TD/k.txt"
  BLINDPASTE_KEY="$K" "$BP" --init >/dev/null 2>&1
  check '--init: exit code' "$?" 0
  check '--init: key mode 600' "$(stat -f '%Lp' "$K" 2>/dev/null)" 600
  PUB=$(grep -o 'age1[a-z0-9]*' "$K" 2>/dev/null | head -1)
  printf %s "$SECRET" | age -a -r "$PUB" | pbcopy
  BLINDPASTE_KEY="$K" "$BP" -t 0 >/dev/null 2>&1
  check 'age round trip' "$(pbpaste)" "$SECRET"
  BLINDPASTE_KEY="$K" "$BP" --init >/dev/null 2>&1
  check '--init does not overwrite an existing key' "$?" 1
  SND=$(BLINDPASTE_KEY="$K" "$BP" --sender)
  check '--sender includes the age public key' "$(printf '%s\n' "$SND" | grep -c "$PUB")" 1
  AGECMD=$(printf '%s\n' "$SND" | grep -v '^#' | grep 'age -a -r')
  CT=$(printf '  a b  \n' | bash -c "$AGECMD" 2>/dev/null)
  check 'age sender command round trip keeps spaces' "$(printf '%s\n' "$CT" | age -d -i "$K" 2>/dev/null)" '  a b  '
  # The default key is in the repo root; chmod 700 on an existing directory
  # would change the permissions of the repo itself.
  TD2=$(mktemp -d); chmod 755 "$TD2"
  BLINDPASTE_KEY="$TD2/k.txt" "$BP" --init >/dev/null 2>&1
  check '--init leaves an existing directory mode alone' "$(stat -f '%Lp' "$TD2")" 755
  rm -rf "$TD" "$TD2"
else
  sk 'age round trip (age not installed; brew install age, then rerun)'
  sk '--init (age not installed)'
  sk '--sender age command (age not installed)'
fi

# /usr/bin:/bin has pbcopy, pbpaste and shasum on macOS, but not a
# Homebrew-installed age.
printf -- '-----BEGIN AGE ENCRYPTED FILE-----\nabc\n-----END AGE ENCRYPTED FILE-----\n' | pbcopy
out=$(PATH=/usr/bin:/bin "$BP" -t 0 2>&1); rc=$?
check 'age ciphertext without age: exit code' "$rc" 3
check 'age ciphertext without age: message' "$(printf %s "$out" | grep -c 'age is not installed')" 1

printf '\n-- self-contained --\n'
# BLINDPASTE_KEY= (empty) means "use the default", whatever the caller's env.
DEFKEY=$(BLINDPASTE_KEY= BLINDPASTE_LIB=1 bash -c '. ./blindpaste; printf %s "$BP_KEY"')
check 'default key path is the repo root' "$DEFKEY" "$ROOT/.blindpaste.key"
if git check-ignore -q .blindpaste.key; then ok 'default key is gitignored'; else no 'default key is not gitignored'; fi
# A relative symlink to an absolute symlink: both kinds must be resolved.
TD=$(mktemp -d); ln -s "$ROOT/blindpaste" "$TD/a"; ln -s a "$TD/b"
LINKKEY=$(BLINDPASTE_KEY= BLINDPASTE_LIB=1 bash -c '. "$1"; printf %s "$BP_KEY"' _ "$TD/b")
check 'default key path via a symlink is still the repo root' "$LINKKEY" "$ROOT/.blindpaste.key"
rm -rf "$TD"
# Code lines only: the comments mention $HOME as explanation.
NOCOMMENT=$(grep -v '^[[:space:]]*#' blindpaste)
check 'code does not reference $HOME'      "$(printf %s "$NOCOMMENT" | grep -c 'HOME')" 0
check 'code does not reference .local/bin' "$(printf %s "$NOCOMMENT" | grep -c '.local/bin')" 0
for f in blindpaste tests/run.sh .gitignore; do
  check "$f is pure ASCII" "$(LC_ALL=C grep -c '[^[:print:][:space:]]' "$f")" 0
done

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
