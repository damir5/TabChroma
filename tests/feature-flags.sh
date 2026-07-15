#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

cp -R "$ROOT/themes" "$TMP_ROOT/themes"

capture_test() {
  local output="$1" fifo="$TMP_ROOT/output.fifo" reader
  rm -f "$fifo"
  mkfifo "$fifo"
  cat "$fifo" > "$output" &
  reader=$!
  exec 3> "$fifo"
  TAB_CHROMA_DATA="$TMP_ROOT" \
  TAB_CHROMA_SHARE="$ROOT" \
  TAB_CHROMA_OUTPUT_DEVICE="$fifo" \
  TERM_PROGRAM=iTerm.app \
    bash "$ROOT/tab-chroma.sh" test working >/dev/null
  exec 3>&-
  wait "$reader"
}

printf '%s\n' '{"active_theme":"default","features":{"tab_color":true,"badge":false,"title":false}}' > "$TMP_ROOT/config.json"
capture_test "$TMP_ROOT/disabled-output"

python3 - "$TMP_ROOT/disabled-output" <<'PY'
import pathlib, sys

output = pathlib.Path(sys.argv[1]).read_bytes()
assert output == (
    b"\x1b]6;1;bg;red;brightness;0\x07"
    b"\x1b]6;1;bg;green;brightness;100\x07"
    b"\x1b]6;1;bg;blue;brightness;200\x07"
    b"\x1b]0;\x07"
    b"\x1b]1337;SetBadgeFormat=\x07"
    b"\x1b]1337;SetColors=badge=default\x07"
)
PY

printf '%s\n' '{"active_theme":"default","features":{"tab_color":true,"badge":true,"title":true}}' > "$TMP_ROOT/config.json"
capture_test "$TMP_ROOT/enabled-output"

python3 - "$TMP_ROOT/enabled-output" <<'PY'
import pathlib, re, sys

output = pathlib.Path(sys.argv[1]).read_bytes()
assert output.count(b"SetColors=badge=0064c8") == 2
assert re.search(rb"\x1b\]0;[^\x07]+\x07", output)
assert re.search(rb"SetBadgeFormat=[^\x07]+\x07", output)
PY

TAB_CHROMA_DATA="$TMP_ROOT" \
TAB_CHROMA_SHARE="$ROOT" \
TAB_CHROMA_OUTPUT_DEVICE="$TMP_ROOT/output" \
TERM_PROGRAM=iTerm.app \
  bash "$ROOT/tab-chroma.sh" title off >/dev/null

python3 - "$TMP_ROOT/output" <<'PY'
import pathlib, sys

assert pathlib.Path(sys.argv[1]).read_bytes() == b"\x1b]0;\x07"
PY

echo "feature flags check passed"
