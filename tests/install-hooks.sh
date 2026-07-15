#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
HOME="$TMP_ROOT/existing-wrapper"
export HOME

mkdir -p "$HOME/.claude" "$HOME/.codex"
printf '%s\n' '{"keep":"claude"}' > "$HOME/.claude/settings.json"
printf '%s\n' '{"keep":"codex"}' > "$HOME/.codex/hooks.json"
printf '%s\n' 'codex() { command codex --existing "$@"; }' > "$HOME/.zshrc"

TERM_PROGRAM=unsupported bash "$ROOT/tab-chroma.sh" install >/dev/null
TERM_PROGRAM=unsupported bash "$ROOT/tab-chroma.sh" install >/dev/null

python3 - "$HOME" "$ROOT/tab-chroma.sh" <<'PY'
import json, pathlib, sys

home, command = pathlib.Path(sys.argv[1]), sys.argv[2]
claude = json.loads((home / ".claude/settings.json").read_text())
codex = json.loads((home / ".codex/hooks.json").read_text())
common = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "PermissionRequest"}

assert claude["keep"] == "claude" and codex["keep"] == "codex"
assert common <= claude["hooks"].keys() and "Notification" in claude["hooks"]
assert common == codex["hooks"].keys()
for config in (claude, codex):
    for groups in config["hooks"].values():
        commands = [hook["command"] for group in groups for hook in group["hooks"]]
        assert commands.count(command) == 1

zshrc = (home / ".zshrc").read_text()
assert zshrc.count("codex() {") == 1
assert "# tab-chroma: reset tab on codex exit" not in zshrc
PY

HOME="$TMP_ROOT/generated-wrapper"
export HOME
INSTALL_DIR="$HOME/.claude/hooks/tab-chroma"
mkdir -p "$INSTALL_DIR" "$TMP_ROOT/bin"
cp "$ROOT/tab-chroma.sh" "$INSTALL_DIR/tab-chroma.sh"
chmod +x "$INSTALL_DIR/tab-chroma.sh"
printf '%s\n' '#!/bin/sh' 'exit 23' > "$TMP_ROOT/bin/codex"
chmod +x "$TMP_ROOT/bin/codex"

TERM_PROGRAM=unsupported bash "$INSTALL_DIR/tab-chroma.sh" install >/dev/null

set +e
PATH="$TMP_ROOT/bin:$PATH" zsh -c 'source "$HOME/.zshrc"; codex'
codex_status=$?
set -e
[ "$codex_status" -eq 23 ]

python3 - "$HOME" <<'PY'
import json, pathlib, sys

home = pathlib.Path(sys.argv[1])
for path in (home / ".claude/settings.json", home / ".codex/hooks.json"):
    config = json.loads(path.read_text())
    config["keep"] = path.parent.name
    config["hooks"]["SessionStart"][0]["hooks"].append(
        {"type": "command", "command": "/tmp/unrelated-hook"}
    )
    path.write_text(json.dumps(config))
PY
printf '%s\n' "alias tab-chroma='/custom/tab-chroma'" >> "$HOME/.zshrc"

printf 'y\n' | TERM_PROGRAM=unsupported bash "$INSTALL_DIR/tab-chroma.sh" uninstall >/dev/null

python3 - "$HOME" <<'PY'
import json, pathlib, sys

home = pathlib.Path(sys.argv[1])
for path in (home / ".claude/settings.json", home / ".codex/hooks.json"):
    config = json.loads(path.read_text())
    assert config["keep"] == path.parent.name
    commands = [
        hook["command"]
        for groups in config["hooks"].values()
        for group in groups
        for hook in group["hooks"]
    ]
    assert "/tmp/unrelated-hook" in commands
    assert not any("tab-chroma" in command for command in commands)

zshrc = (home / ".zshrc").read_text()
assert "alias tab-chroma='/custom/tab-chroma'" in zshrc
assert ".claude/hooks/tab-chroma/tab-chroma.sh" not in zshrc
assert "# tab-chroma: reset tab on claude exit" not in zshrc
assert "# tab-chroma: reset tab on codex exit" not in zshrc
assert not (home / ".claude/hooks/tab-chroma").exists()
PY

# Homebrew upgrades replace versioned assets while hooks keep calling one stable wrapper.
HOME="$TMP_ROOT/brew-home"
export HOME
BREW_ROOT="$TMP_ROOT/brew"
DATA_DIR="$HOME/.claude/hooks/tab-chroma"
STABLE_CMD="$BREW_ROOT/bin/tab-chroma"
mkdir -p "$BREW_ROOT/bin" "$BREW_ROOT/cellar/v1" "$BREW_ROOT/cellar/v2"
for version in v1 v2; do
  share="$BREW_ROOT/cellar/$version/share/tab-chroma"
  mkdir -p "$share"
  cp "$ROOT/tab-chroma.sh" "$share/tab-chroma.sh"
  cp -R "$ROOT/themes" "$share/themes"
  cp -R "$ROOT/completions" "$share/completions"
  printf '%s\n' "${version#v}" > "$share/VERSION"
done
cp -R "$ROOT/themes/ocean" "$BREW_ROOT/cellar/v2/share/tab-chroma/themes/v2only"
ln -s "$BREW_ROOT/cellar/v1/share/tab-chroma" "$BREW_ROOT/current"
printf '%s\n' \
  '#!/bin/bash' \
  "export TAB_CHROMA_SHARE=\"$BREW_ROOT/current\"" \
  "export TAB_CHROMA_DATA=\"\$HOME/.claude/hooks/tab-chroma\"" \
  "export TAB_CHROMA_HOOK_CMD=\"$STABLE_CMD\"" \
  'exec "$TAB_CHROMA_SHARE/tab-chroma.sh" "$@"' > "$STABLE_CMD"
chmod +x "$STABLE_CMD"

mkdir -p "$HOME/.claude" "$HOME/.codex"
python3 - "$HOME" "$BREW_ROOT/cellar/v1/share/tab-chroma/tab-chroma.sh" <<'PY'
import json, pathlib, sys

home, legacy = pathlib.Path(sys.argv[1]), sys.argv[2]
config = {
    "hooks": {
        "SessionStart": [{
            "matcher": "",
            "hooks": [
                {"type": "command", "command": legacy},
                {"type": "command", "command": "/tmp/unrelated-hook"},
            ],
        }]
    }
}
for path in (home / ".claude/settings.json", home / ".codex/hooks.json"):
    path.write_text(json.dumps(config))
PY
printf '%s\n' \
  '# tab-chroma' \
  "alias tab-chroma='$BREW_ROOT/cellar/v1/share/tab-chroma/tab-chroma.sh'" \
  '# tab-chroma: reset tab on claude exit' \
  'claude() {' \
  '  command claude "$@"' \
  '  tab-chroma reset > /dev/null 2>&1' \
  '}' > "$HOME/.zshrc"

TERM_PROGRAM=unsupported "$STABLE_CMD" install >/dev/null
python3 - "$HOME" "$STABLE_CMD" <<'PY'
import json, pathlib, sys

home, stable = pathlib.Path(sys.argv[1]), sys.argv[2]
for path in (home / ".claude/settings.json", home / ".codex/hooks.json"):
    config = json.loads(path.read_text())
    commands = [
        hook["command"]
        for groups in config["hooks"].values()
        for group in groups
        for hook in group["hooks"]
    ]
    assert stable in commands
    assert "/tmp/unrelated-hook" in commands
    assert not any("/cellar/v1/share/tab-chroma/tab-chroma.sh" in command for command in commands)
zshrc = (home / ".zshrc").read_text()
assert f"alias tab-chroma='{stable}'" in zshrc
assert "/cellar/v1/share/tab-chroma/tab-chroma.sh" not in zshrc
assert "local exit_status=$?" in zshrc
assert 'return "$exit_status"' in zshrc
PY
mkdir -p "$DATA_DIR/themes/custom"
cp "$ROOT/themes/ocean/theme.json" "$DATA_DIR/themes/custom/theme.json"
touch "$DATA_DIR/.paused"
python3 - "$DATA_DIR/config.json" "$DATA_DIR/.state.json" <<'PY'
import json, pathlib, sys

config, state = map(pathlib.Path, sys.argv[1:])
data = json.loads(config.read_text())
data["active_theme"] = "custom"
data["preserved"] = True
config.write_text(json.dumps(data))
state.write_text(json.dumps({"preserved": True}))
PY

rm "$BREW_ROOT/current"
ln -s "$BREW_ROOT/cellar/v2/share/tab-chroma" "$BREW_ROOT/current"

[ "$(TERM_PROGRAM=unsupported "$STABLE_CMD" version)" = "tab-chroma v2" ]
theme_list="$(TERM_PROGRAM=unsupported "$STABLE_CMD" theme list)"
case "$theme_list" in *custom*v2only*) ;; *) exit 1;; esac
python3 - "$HOME" "$STABLE_CMD" "$DATA_DIR" <<'PY'
import json, pathlib, sys

home, command, data_dir = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
for path in (home / ".claude/settings.json", home / ".codex/hooks.json"):
    config = json.loads(path.read_text())
    commands = [
        hook["command"]
        for groups in config["hooks"].values()
        for group in groups
        for hook in group["hooks"]
    ]
    assert command in commands
    assert "/tmp/unrelated-hook" in commands
    assert not any("/cellar/v1/share/tab-chroma/tab-chroma.sh" in item for item in commands)
config = json.loads((data_dir / "config.json").read_text())
state = json.loads((data_dir / ".state.json").read_text())
assert config["active_theme"] == "custom" and config["preserved"] is True
assert state["preserved"] is True
assert (data_dir / ".paused").exists()
PY

printf 'y\n' | TERM_PROGRAM=unsupported "$STABLE_CMD" uninstall >/dev/null
[ -d "$BREW_ROOT/cellar/v1/share/tab-chroma" ]
[ -d "$BREW_ROOT/cellar/v2/share/tab-chroma" ]
[ ! -e "$DATA_DIR" ]
python3 - "$HOME" <<'PY'
import json, pathlib, sys

home = pathlib.Path(sys.argv[1])
for path in (home / ".claude/settings.json", home / ".codex/hooks.json"):
    config = json.loads(path.read_text())
    commands = [
        hook["command"]
        for groups in config["hooks"].values()
        for group in groups
        for hook in group["hooks"]
    ]
    assert commands == ["/tmp/unrelated-hook"]
PY

# Unsafe TAB_CHROMA_DATA values never become rm -rf targets.
HOME="$TMP_ROOT/unsafe-data-home"
export HOME
mkdir -p "$HOME/.claude" "$HOME/.codex"
touch "$HOME/must-survive"
printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"unsafe-hook"}]}]}}' > "$HOME/.claude/settings.json"
printf '%s\n' '{}' > "$HOME/.codex/hooks.json"
printf '%s\n' "alias tab-chroma='/custom/tab-chroma'" > "$HOME/.zshrc"
unsafe_output="$(printf 'y\n' | TAB_CHROMA_DATA="$HOME" TAB_CHROMA_HOOK_CMD="unsafe-hook" TERM_PROGRAM=unsupported bash "$ROOT/tab-chroma.sh" uninstall 2>&1)"
[ -f "$HOME/must-survive" ]
case "$unsafe_output" in *"Refusing to remove unsafe data directory: $HOME"*) ;; *) exit 1;; esac
python3 - "$HOME" <<'PY'
import json, pathlib, sys

home = pathlib.Path(sys.argv[1])
settings = json.loads((home / ".claude/settings.json").read_text())
commands = [
    hook["command"]
    for groups in settings["hooks"].values()
    for group in groups
    for hook in group["hooks"]
]
assert commands == []
assert "alias tab-chroma='/custom/tab-chroma'" in (home / ".zshrc").read_text()
PY

# Standalone uninstall removes exact owned hooks, not substring lookalikes.
HOME="$TMP_ROOT/standalone-uninstall"
export HOME
mkdir -p "$HOME/.claude/hooks/tab-chroma" "$HOME/.codex"
python3 - "$HOME" <<'PY'
import json, pathlib, sys

home = pathlib.Path(sys.argv[1])
owned = str(home / ".claude/hooks/tab-chroma/tab-chroma.sh")
lookalike = f"/tmp/prefix{owned}/suffix"
config = {"hooks": {"SessionStart": [{"matcher": "", "hooks": [
    {"type": "command", "command": owned},
    {"type": "command", "command": lookalike},
]}]}}
(home / ".claude/settings.json").write_text(json.dumps(config))
PY
TERM_PROGRAM=unsupported bash "$ROOT/uninstall.sh" --yes >/dev/null
python3 - "$HOME" <<'PY'
import json, pathlib, sys

home = pathlib.Path(sys.argv[1])
settings = json.loads((home / ".claude/settings.json").read_text())
commands = [
    hook["command"]
    for groups in settings["hooks"].values()
    for group in groups
    for hook in group["hooks"]
]
assert len(commands) == 1 and commands[0].startswith("/tmp/prefix")
PY

echo "install hooks check passed"
