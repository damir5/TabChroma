#!/bin/bash
# tab-chroma: iTerm2 visual feedback plugin for Claude Code and Codex
# Changes tab color, badge, and title based on agent hook events

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARE_DIR="${TAB_CHROMA_SHARE:-$SCRIPT_DIR}"
DATA_DIR="${TAB_CHROMA_DATA:-$SCRIPT_DIR}"
HOOK_CMD="${TAB_CHROMA_HOOK_CMD:-$SCRIPT_DIR/tab-chroma.sh}"
CONFIG="$DATA_DIR/config.json"
STATE="$DATA_DIR/.state.json"
PAUSED="$DATA_DIR/.paused"
THEMES_DIR="$DATA_DIR/themes"
BUNDLED_THEMES_DIR="$SHARE_DIR/themes"
VERSION_FILE="$SHARE_DIR/VERSION"

if [[ -r "$VERSION_FILE" ]]; then
  read -r VERSION < "$VERSION_FILE"
else
  VERSION="unknown"
fi

# ─── Terminal Detection ────────────────────────────────────────────────────────

detect_terminal() {
  if [ "$TERM_PROGRAM" = "iTerm.app" ]; then
    echo "iterm2"
  elif [ "$TERM_PROGRAM" = "Apple_Terminal" ]; then
    echo "apple-terminal"
  elif [ -n "$KITTY_PID" ]; then
    echo "kitty"
  else
    echo "unsupported"
  fi
}

TERMINAL="$(detect_terminal)"

# ─── Terminal Device Resolution ────────────────────────────────────────────────
# Hook subprocesses spawned by Claude Code have no controlling terminal, so
# writing escape sequences to /dev/tty silently fails ("device not configured")
# and no colors/badges ever reach the terminal. Resolve the real pty by walking
# up the process tree to the nearest ancestor that owns one (e.g. the `claude`
# process), and fall back to /dev/tty for interactive CLI use, or /dev/null so
# writes become harmless no-ops when nothing is available.
resolve_output_device() {
  local pid="${PPID:-$$}" tty i=0
  while [ "$i" -lt 10 ]; do
    case "$pid" in ''|0|1|*[!0-9]*) break;; esac
    tty="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    case "$tty" in
      ttys*|pts/*|tty[0-9]*)
        [ -w "/dev/$tty" ] && { printf '/dev/%s' "$tty"; return 0; }
        ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    i=$((i + 1))
  done
  { [ -w /dev/tty ]; } 2>/dev/null && { printf '/dev/tty'; return 0; }
  printf '/dev/null'
}

TC_DEV="$(resolve_output_device)"

# ─── iTerm2 Output Functions ───────────────────────────────────────────────────

set_tab_color() {
  local r=$1 g=$2 b=$3
  { printf '\033]6;1;bg;red;brightness;%s\a\033]6;1;bg;green;brightness;%s\a\033]6;1;bg;blue;brightness;%s\a' \
    "$r" "$g" "$b" > "$TC_DEV"; } 2>/dev/null
}

reset_tab_color() {
  { printf '\033]6;1;bg;*;default\a' > "$TC_DEV"; } 2>/dev/null
}

set_badge_color() {
  local r=$1 g=$2 b=$3
  if [ "$TERMINAL" = "iterm2" ]; then
    local hex
    hex="$(printf '%02x%02x%02x' "$r" "$g" "$b")"
    { printf '\033]1337;SetColors=badge=%s\a' "$hex" > "$TC_DEV"; } 2>/dev/null
  fi
}

reset_badge_color() {
  if [ "$TERMINAL" = "iterm2" ]; then
    { printf '\033]1337;SetColors=badge=default\a' > "$TC_DEV"; } 2>/dev/null
  fi
}

set_tab_title() {
  local title="$1"
  if [ "$TERMINAL" = "iterm2" ] || [ "$TERMINAL" = "apple-terminal" ]; then
    { printf '\033]0;%s\007' "$title" > "$TC_DEV"; } 2>/dev/null
  fi
}

set_badge() {
  local text="$1"
  if [ "$TERMINAL" = "iterm2" ]; then
    if [ -z "$text" ]; then
      { printf '\033]1337;SetBadgeFormat=\a' > "$TC_DEV"; } 2>/dev/null
    else
      { printf '\033]1337;SetBadgeFormat=%s\a' "$(printf '%s' "$text" | base64)" > "$TC_DEV"; } 2>/dev/null
    fi
  fi
}

# ─── Config Helpers ───────────────────────────────────────────────────────────

get_active_theme() {
  python3 -c "import json; print(json.load(open('$CONFIG')).get('active_theme','default'))" 2>/dev/null
}

# ─── Ensure config exists ──────────────────────────────────────────────────────

ensure_config() {
  mkdir -p "$DATA_DIR"
  if [ ! -f "$CONFIG" ]; then
    cat > "$CONFIG" << 'EOF'
{
  "active_theme": "default",
  "enabled": true,
  "features": {
    "tab_color": true,
    "badge": false,
    "title": true
  },
  "states": {
    "session.start": true,
    "working": true,
    "done": true,
    "attention": true,
    "permission": true
  },
  "debounce_seconds": 2,
  "theme_rotation": [],
  "theme_rotation_mode": "off"
}
EOF
  fi
}

# ─── CLI Commands ──────────────────────────────────────────────────────────────

cmd_help() {
  cat << EOF
tab-chroma v$VERSION — iTerm2 visual feedback for Claude Code and Codex

USAGE:
  tab-chroma <command> [args]

CONTROLS:
  pause                 Disable color changes
  resume                Re-enable color changes
  toggle                Toggle pause state
  status                Show current config and state

THEMES:
  theme list            List installed themes
  theme use <name>      Switch active theme
  theme next            Cycle to next theme
  theme preview [name]  Preview all states (2s each)

FEATURES:
  badge on|off          Toggle iTerm2 badge
  title on|off          Toggle tab title updates
  color on|off          Toggle tab color changes

TESTING:
  test <state>          Manually trigger a state
                        States: working done attention permission session.start
  reset                 Reset tab to default color

INFO:
  help                  Show this help
  version               Show version

SETUP:
  install               Register Claude Code and Codex hooks
  uninstall             Remove hooks, completions, and data files
  update                Update tab-chroma to the latest version
EOF
}

cmd_status() {
  ensure_config
  local paused="false"
  [ -f "$PAUSED" ] && paused="true"

  python3 - << EOF
import json, os

config_path = "$CONFIG"
state_path = "$STATE"

try:
    config = json.load(open(config_path))
except Exception:
    config = {}

try:
    state = json.load(open(state_path)) if os.path.exists(state_path) else {}
except Exception:
    state = {}

print(f"tab-chroma v$VERSION")
print(f"")
print(f"paused:        $paused")
print(f"enabled:       {config.get('enabled', True)}")
print(f"active theme:  {config.get('active_theme', 'default')}")
print(f"last state:    {state.get('last_state', 'none')}")
print(f"")
print(f"features:")
features = config.get('features', {})
print(f"  tab_color:   {features.get('tab_color', True)}")
print(f"  badge:       {features.get('badge', True)}")
print(f"  title:       {features.get('title', True)}")
print(f"")
rotation_mode = config.get('theme_rotation_mode', 'off')
rotation = config.get('theme_rotation', [])
print(f"theme rotation: {rotation_mode}")
if rotation:
    print(f"  themes: {', '.join(rotation)}")
EOF
}

cmd_pause() {
  touch "$PAUSED"
  echo "tab-chroma paused"
}

cmd_resume() {
  rm -f "$PAUSED"
  echo "tab-chroma resumed"
}

cmd_toggle() {
  if [ -f "$PAUSED" ]; then
    cmd_resume
  else
    cmd_pause
  fi
}

cmd_theme_list() {
  ensure_config
  python3 - << EOF
import json, os

themes_dirs = ["$THEMES_DIR", "$BUNDLED_THEMES_DIR"]
config_path = "$CONFIG"

try:
    active = json.load(open(config_path)).get("active_theme", "default")
except Exception:
    active = "default"

print("installed themes:")
print("")
themes = {}
for themes_dir in reversed(themes_dirs):
    if not os.path.isdir(themes_dir):
        continue
    for name in os.listdir(themes_dir):
        theme_path = os.path.join(themes_dir, name, "theme.json")
        if os.path.isfile(theme_path):
            themes[name] = theme_path
for name, theme_path in sorted(themes.items()):
    try:
        t = json.load(open(theme_path))
    except Exception:
        continue
    display = t.get("display_name", name)
    desc = t.get("description", "")
    marker = "*" if name == active else " "
    print(f"  {marker} {name:<12} {display:<16} {desc}")
print("")
print("  (* = active)")
EOF
}

cmd_theme_use() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "usage: tab-chroma theme use <name>" >&2
    return 1
  fi
  if [ ! -f "$THEMES_DIR/$name/theme.json" ] && [ ! -f "$BUNDLED_THEMES_DIR/$name/theme.json" ]; then
    echo "theme not found: $name" >&2
    echo "run 'tab-chroma theme list' to see available themes" >&2
    return 1
  fi
  ensure_config
  python3 - << EOF
import json
config = json.load(open("$CONFIG"))
config["active_theme"] = "$name"
json.dump(config, open("$CONFIG", "w"), indent=2)
print(f"active theme set to: $name")
EOF
}

cmd_theme_next() {
  ensure_config
  python3 - << EOF
import json, os

themes_dirs = ["$THEMES_DIR", "$BUNDLED_THEMES_DIR"]
config_path = "$CONFIG"

themes = sorted({
    e for themes_dir in themes_dirs if os.path.isdir(themes_dir)
    for e in os.listdir(themes_dir)
    if os.path.isfile(os.path.join(themes_dir, e, "theme.json"))
})
config = json.load(open(config_path))
current = config.get("active_theme", "default")
if current in themes:
    idx = (themes.index(current) + 1) % len(themes)
else:
    idx = 0
next_theme = themes[idx]
config["active_theme"] = next_theme
json.dump(config, open(config_path, "w"), indent=2)
print(f"active theme set to: {next_theme}")
EOF
}

cmd_theme_preview() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    ensure_config
    name="$(get_active_theme)"
  fi
  local theme_file="$THEMES_DIR/$name/theme.json"
  [ -f "$theme_file" ] || theme_file="$BUNDLED_THEMES_DIR/$name/theme.json"
  if [ ! -f "$theme_file" ]; then
    echo "theme not found: $name" >&2
    return 1
  fi
  echo "previewing theme: $name (2s per state)"
  for state in "working" "done" "attention" "permission" "session.start"; do
    echo "  -> $state"
    _apply_theme_state "$theme_file" "$state"
    sleep 2
  done
  echo "preview complete"
}

_apply_theme_state() {
  local theme_file="$1" state_name="$2"
  eval "$(python3 - "$theme_file" "$state_name" << 'PYEOF'
import json, sys

theme_file = sys.argv[1]
state_name = sys.argv[2]

try:
    theme = json.load(open(theme_file))
except Exception:
    print('ACTION="skip"')
    sys.exit(0)

state = theme.get("states", {}).get(state_name, {})
if not state:
    print('ACTION="skip"')
    sys.exit(0)

action = state.get("action", "color")
r = state.get("r", 0)
g = state.get("g", 0)
b = state.get("b", 0)

if action == "reset":
    print('ACTION="reset"')
else:
    print('ACTION="color"')
    print(f'COLOR_R={r}')
    print(f'COLOR_G={g}')
    print(f'COLOR_B={b}')
PYEOF
  )"

  if [ "$ACTION" = "reset" ]; then
    reset_tab_color
    reset_badge_color
  elif [ "$ACTION" = "color" ]; then
    set_tab_color "$COLOR_R" "$COLOR_G" "$COLOR_B"
    set_badge_color "$COLOR_R" "$COLOR_G" "$COLOR_B"
  fi
}

cmd_test() {
  local state_name="$1"
  if [ -z "$state_name" ]; then
    echo "usage: tab-chroma test <state>" >&2
    echo "states: working done attention permission session.start" >&2
    return 1
  fi

  local valid_states="working done attention permission session.start"
  local valid=0
  for s in $valid_states; do
    [ "$s" = "$state_name" ] && valid=1
  done
  if [ $valid -eq 0 ]; then
    echo "unknown state: $state_name" >&2
    echo "valid states: $valid_states" >&2
    return 1
  fi

  ensure_config
  local theme_name
  theme_name="$(get_active_theme)"
  local theme_file="$THEMES_DIR/$theme_name/theme.json"
  [ -f "$theme_file" ] || theme_file="$BUNDLED_THEMES_DIR/$theme_name/theme.json"

  if [ ! -f "$theme_file" ]; then
    theme_file="$BUNDLED_THEMES_DIR/default/theme.json"
  fi

  echo "testing state: $state_name (theme: $theme_name)"
  _apply_theme_state "$theme_file" "$state_name"

  # Apply title and badge
  local project_name
  project_name="$(basename "$PWD")"
  eval "$(python3 - << EOF
import json
theme = json.load(open("$theme_file"))
state_cfg = theme.get("states", {}).get("$state_name", {})
label = state_cfg.get("label", "$state_name")
print(f'TITLE_TEXT="◉ $project_name: {label}"')
print(f'BADGE_TEXT="$project_name\\\\n{label}"')
EOF
  )"
  [ -n "$TITLE_TEXT" ] && set_tab_title "$TITLE_TEXT"
  if [ -n "$BADGE_TEXT" ]; then
    set_badge "$BADGE_TEXT"
    # Set badge color AFTER text — iTerm2 resets it when badge format changes
    [ "$ACTION" = "color" ] && set_badge_color "$COLOR_R" "$COLOR_G" "$COLOR_B"
  fi
}

cmd_reset() {
  reset_tab_color
  reset_badge_color
  set_badge ""
  echo "tab color reset"
}

cmd_install() {
  local claude_settings="$HOME/.claude/settings.json"
  local codex_settings="$HOME/.codex/hooks.json"
  local hook_cmd="$HOOK_CMD"
  local common_events="SessionStart UserPromptSubmit PreToolUse PostToolUse Stop PermissionRequest"

  ensure_config
  mkdir -p "$(dirname "$claude_settings")" "$(dirname "$codex_settings")"
  [ -f "$claude_settings" ] || echo '{}' > "$claude_settings"
  [ -f "$codex_settings" ] || echo '{}' > "$codex_settings"

  register_hooks() {
    local settings="$1"
    shift
    python3 - "$settings" "$hook_cmd" "$@" << 'PYEOF'
import json, re, sys

settings_path, hook_cmd = sys.argv[1], sys.argv[2]
events = sys.argv[3:]

with open(settings_path) as f:
    cfg = json.load(f)

cfg.setdefault("hooks", {})
changed = False

def is_legacy(command):
    if not isinstance(command, str) or command == hook_cmd:
        return False
    return (
        command.endswith("/.claude/hooks/tab-chroma/tab-chroma.sh")
        or re.search(r"/(?:Cellar|cellar)/.+/share/tab-chroma/tab-chroma\.sh$", command)
    )

for matchers in cfg["hooks"].values():
    for matcher in matchers:
        hooks = matcher.get("hooks", [])
        matcher["hooks"] = [h for h in hooks if not is_legacy(h.get("command"))]
        changed |= len(matcher["hooks"]) != len(hooks)

for event in events:
    matchers = cfg["hooks"].setdefault(event, [{"matcher": "", "hooks": []}])
    # Find the catch-all matcher
    catch_all = next((m for m in matchers if m.get("matcher") == ""), None)
    if catch_all is None:
        catch_all = {"matcher": "", "hooks": []}
        matchers.append(catch_all)
    hook_entry = {"type": "command", "command": hook_cmd}
    existing = [h for h in catch_all["hooks"] if h.get("command") == hook_cmd]
    if not existing:
        catch_all["hooks"].append(hook_entry)
        changed = True

with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2)

if changed:
    print(f"tab-chroma hooks registered in {settings_path}")
else:
    print("tab-chroma hooks already registered")
PYEOF
  }

  register_hooks "$claude_settings" $common_events Notification
  register_hooks "$codex_settings" $common_events
  echo "Codex: run /hooks to review and trust the new tab-chroma hooks"

  # Set up shell alias and completions
  local zshrc="$HOME/.zshrc"
  python3 - "$zshrc" "$hook_cmd" << 'PYEOF'
import pathlib, re, sys

path, hook_cmd = pathlib.Path(sys.argv[1]), sys.argv[2]
content = path.read_text() if path.exists() else ""
pattern = re.compile(r"^alias tab-chroma='([^']*)'$", re.MULTILINE)
matches = list(pattern.finditer(content))

def is_owned(command):
    return (
        command.endswith("/.claude/hooks/tab-chroma/tab-chroma.sh")
        or re.search(r"/(?:Cellar|cellar)/.+/share/tab-chroma/tab-chroma\.sh$", command)
    )

if any(is_owned(match.group(1)) for match in matches):
    content = pattern.sub(
        lambda match: f"alias tab-chroma='{hook_cmd}'" if is_owned(match.group(1)) else match.group(0),
        content,
    )
elif not matches:
    content += f"\n# tab-chroma\nalias tab-chroma='{hook_cmd}'\n"
path.write_text(content)
PYEOF

  # Add claude() wrapper so tab resets when exiting Claude Code (Ctrl+C etc.)
  # Claude Code has no SessionEnd hook, so a shell wrapper is the only way.
  local wrapper_marker="# tab-chroma: reset tab on claude exit"
  python3 - "$zshrc" << 'PYEOF'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
content = path.read_text()
old = '''# tab-chroma: reset tab on claude exit
claude() {
  command claude "$@"
  tab-chroma reset > /dev/null 2>&1
}'''
new = '''# tab-chroma: reset tab on claude exit
claude() {
  command claude "$@"
  local exit_status=$?
  tab-chroma reset > /dev/null 2>&1
  return "$exit_status"
}'''
path.write_text(content.replace(old, new))
PYEOF
  if ! grep -qF "$wrapper_marker" "$zshrc" 2>/dev/null; then
    {
      echo ""
      echo "$wrapper_marker"
      echo 'claude() {'
      echo '  command claude "$@"'
      echo '  local exit_status=$?'
      echo '  tab-chroma reset > /dev/null 2>&1'
      echo '  return "$exit_status"'
      echo '}'
    } >> "$zshrc"
    echo "claude() wrapper added to $zshrc (run: source ~/.zshrc)"
  fi

  local codex_wrapper_marker="# tab-chroma: reset tab on codex exit"
  if grep -qF "$codex_wrapper_marker" "$zshrc" 2>/dev/null; then
    :
  elif grep -Eq '^[[:space:]]*(function[[:space:]]+)?codex[[:space:]]*(\(\))?[[:space:]]*\{' "$zshrc" 2>/dev/null; then
    echo "existing codex() function left unchanged; add 'tab-chroma reset' to it manually"
  else
    {
      echo ""
      echo "$codex_wrapper_marker"
      echo 'codex() {'
      echo '  command codex "$@"'
      echo '  local exit_status=$?'
      echo '  tab-chroma reset > /dev/null 2>&1'
      echo '  return "$exit_status"'
      echo '}'
    } >> "$zshrc"
    echo "codex() wrapper added to $zshrc (run: source ~/.zshrc)"
  fi

  local comp_dir="$HOME/.bash_completion.d"
  local comp_src="$SHARE_DIR/completions/tab-chroma.bash"
  if [ -f "$comp_src" ]; then
    mkdir -p "$comp_dir"
    cp "$comp_src" "$comp_dir/tab-chroma"
    echo "completions installed to $comp_dir/tab-chroma"
  fi
}

cmd_uninstall() {
  local claude_settings="$HOME/.claude/settings.json"
  local codex_settings="$HOME/.codex/hooks.json"
  local install_dir="$DATA_DIR"
  local hook_cmd="$HOOK_CMD"

  read -r -p "Remove tab-chroma completely? This will remove all files and hooks. [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    return 0
  fi

  echo "Removing hooks from Claude Code and Codex settings..."
  python3 - "$hook_cmd" "$claude_settings" "$codex_settings" << 'PYEOF'
import json, os, re, sys
hook_cmd = sys.argv[1]

def is_owned(command):
    if not isinstance(command, str):
        return False
    return (
        command == hook_cmd
        or command.endswith("/.claude/hooks/tab-chroma/tab-chroma.sh")
        or re.search(r"/(?:Cellar|cellar)/.+/share/tab-chroma/tab-chroma\.sh$", command)
    )

for settings_path in sys.argv[2:]:
    if not os.path.exists(settings_path):
        print(f"  {settings_path} not found, skipping"); continue
    try:
        cfg = json.load(open(settings_path))
    except Exception as e:
        print(f"  error reading {settings_path}: {e}"); continue
    changed = False
    for entries in cfg.get("hooks", {}).values():
        for entry in entries:
            orig = list(entry.get("hooks", []))
            entry["hooks"] = [h for h in orig if not is_owned(h.get("command"))]
            changed |= len(entry["hooks"]) != len(orig)
    if changed:
        tmp = settings_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(cfg, f, indent=2); f.write("\n")
        os.replace(tmp, settings_path)
        print(f"  Removed tab-chroma hooks from {settings_path}.")
    else:
        print(f"  No tab-chroma hooks found in {settings_path}.")
PYEOF

  if [ "$TERM_PROGRAM" = "iTerm.app" ]; then
    printf '\033]6;1;bg;*;default\a' > "$TC_DEV"
    printf '\033]1337;SetBadgeFormat=\a' > "$TC_DEV"
    echo "Tab color reset and badge cleared."
  fi

  echo "Removing completions..."
  rm -f "$HOME/.bash_completion.d/tab-chroma"
  rm -f "$HOME/.config/fish/completions/tab-chroma.fish"

  echo "Removing shell entries from ~/.zshrc..."
  python3 - "$HOME/.zshrc" "$hook_cmd" << 'PYEOF'
import sys, re
zshrc, hook_cmd = sys.argv[1:]
try:
    with open(zshrc) as f:
        content = f.read()
except FileNotFoundError:
    sys.exit(0)
def is_owned(command):
    return (
        command == hook_cmd
        or command.endswith("/.claude/hooks/tab-chroma/tab-chroma.sh")
        or re.search(r"/(?:Cellar|cellar)/.+/share/tab-chroma/tab-chroma\.sh$", command)
    )

# Remove only aliases installed by tab-chroma; preserve custom aliases.
content = re.sub(
    r'(^|\n)(?:# tab-chroma\n)?alias tab-chroma=\'([^\']*)\'\n?',
    lambda match: match.group(1) if is_owned(match.group(2)) else match.group(0),
    content,
)
# Remove wrapper blocks added by cmd_install
content = re.sub(
    r'\n# tab-chroma: reset tab on claude exit\nclaude\(\) \{\n  command claude "\$@"\n  local exit_status=\$\?\n  tab-chroma reset > /dev/null 2>&1\n  return "\$exit_status"\n\}\n?',
    '', content
)
content = re.sub(
    r'\n# tab-chroma: reset tab on claude exit\nclaude\(\) \{\n  command claude "\$@"\n  tab-chroma reset > /dev/null 2>&1\n\}\n?',
    '', content
)
content = re.sub(
    r'\n# tab-chroma: reset tab on codex exit\ncodex\(\) \{\n  command codex "\$@"\n  local exit_status=\$\?\n  tab-chroma reset > /dev/null 2>&1\n  return "\$exit_status"\n\}\n?',
    '', content
)
with open(zshrc, 'w') as f:
    f.write(content)
print("  Removed tab-chroma entries from ~/.zshrc")
PYEOF

  echo ""
  if [ "$install_dir" = "$HOME/.claude/hooks/tab-chroma" ]; then
    echo "Removing $install_dir..."
    rm -rf "$install_dir"
  else
    echo "Refusing to remove unsafe data directory: $install_dir" >&2
  fi
  echo "Done. tab-chroma has been uninstalled."
}

cmd_update() {
  local repo="damir5/TabChroma"

  # Homebrew-managed install: defer to brew so its bookkeeping stays correct.
  if command -v brew >/dev/null 2>&1 && brew list tab-chroma >/dev/null 2>&1; then
    echo "tab-chroma is managed by Homebrew — updating via brew..."
    brew update >/dev/null 2>&1
    brew upgrade tab-chroma
    return $?
  fi

  # curl/git install: re-run the installer. It overwrites tab-chroma.sh,
  # themes, completions and VERSION but preserves config.json/.state.json,
  # and re-registers hooks idempotently. Changes take effect on the next
  # hook event — no need to restart Claude Code.
  if ! command -v curl >/dev/null 2>&1; then
    echo "error: curl is required to self-update" >&2
    echo "update manually: https://github.com/$repo" >&2
    return 1
  fi

  echo "Updating tab-chroma to the latest version from $repo..."
  curl -fsSL "https://raw.githubusercontent.com/$repo/main/install.sh" | bash
}

cmd_feature_toggle() {
  local feature="$1" value="$2"
  local key
  case "$feature" in
    badge) key="badge";;
    title) key="title";;
    color) key="tab_color";;
    *) echo "unknown feature: $feature" >&2; return 1;;
  esac
  if [ "$value" != "on" ] && [ "$value" != "off" ]; then
    echo "usage: tab-chroma $feature on|off" >&2
    return 1
  fi
  ensure_config
  local bool_val
  [ "$value" = "on" ] && bool_val="True" || bool_val="False"
  python3 - << EOF
import json
config = json.load(open("$CONFIG"))
config.setdefault("features", {})["$key"] = $bool_val
json.dump(config, open("$CONFIG", "w"), indent=2)
print(f"$feature: $value")
EOF

  # Immediately apply visual effect when disabling
  if [ "$value" = "off" ]; then
    case "$feature" in
      badge) set_badge ""; reset_badge_color;;
      color) reset_tab_color;;
    esac
  fi
  true
}

# ─── CLI Routing ───────────────────────────────────────────────────────────────

route_cli() {
  local cmd="$1"
  shift || true

  case "$cmd" in
    pause)   cmd_pause;;
    resume)  cmd_resume;;
    toggle)  cmd_toggle;;
    status)  cmd_status;;
    reset)   cmd_reset;;
    version) echo "tab-chroma v$VERSION";;
    help|--help|-h) cmd_help;;

    theme)
      local subcmd="${1:-list}"
      shift || true
      case "$subcmd" in
        list)    cmd_theme_list;;
        use)     cmd_theme_use "$@";;
        next)    cmd_theme_next;;
        preview) cmd_theme_preview "$@";;
        *)       echo "unknown theme subcommand: $subcmd" >&2; return 1;;
      esac
      ;;

    badge) cmd_feature_toggle "badge" "$@";;
    title) cmd_feature_toggle "title" "$@";;
    color) cmd_feature_toggle "color" "$@";;

    test) cmd_test "$@";;

    install)   cmd_install;;
    uninstall) cmd_uninstall;;
    update)    cmd_update;;

    *)
      echo "unknown command: $cmd" >&2
      echo "run 'tab-chroma help' for usage" >&2
      return 1
      ;;
  esac
}

# ─── Hook Event Processing ─────────────────────────────────────────────────────

process_hook() {
  # Only proceed for iTerm2 (or apple-terminal for title-only)
  if [ "$TERMINAL" = "unsupported" ] || [ "$TERMINAL" = "kitty" ]; then
    exit 0
  fi

  # Fast exit: drain stdin so hook runner doesn't block, then bail
  if [ -f "$PAUSED" ]; then
    cat > /dev/null
    exit 0
  fi

  ensure_config

  # Read stdin (hook JSON input)
  local INPUT
  INPUT="$(cat)"

  # Run consolidated Python block: parse input, check config, debounce, resolve theme
  eval "$(TAB_CHROMA_INPUT="$INPUT" \
  TAB_CHROMA_CONFIG="$CONFIG" \
  TAB_CHROMA_STATE="$STATE" \
  TAB_CHROMA_THEMES="$THEMES_DIR" \
  TAB_CHROMA_BUNDLED_THEMES="$BUNDLED_THEMES_DIR" \
  python3 - << 'PYEOF'
import sys, json, os, time

input_data = os.environ.get("TAB_CHROMA_INPUT", "")
config_path = os.environ.get("TAB_CHROMA_CONFIG", "")
state_path = os.environ.get("TAB_CHROMA_STATE", "")
themes_dir = os.environ.get("TAB_CHROMA_THEMES", "")
bundled_themes_dir = os.environ.get("TAB_CHROMA_BUNDLED_THEMES", "")

# --- Parse hook input ---
try:
    event_data = json.loads(input_data)
except Exception:
    print('ACTION="skip"')
    sys.exit(0)

event = event_data.get("hook_event_name", "")
cwd = event_data.get("cwd", "")
session_id = event_data.get("session_id", "")

notification_type = event_data.get("message", "").lower() if event == "Notification" else ""

# --- Map event -> state ---
state_map = {
    "SessionStart":      "session.start",
    "UserPromptSubmit":  "working",
    "PreToolUse":        "working",
    "Stop":              "done",
    "PostToolUse":       "working",
}

state_name = state_map.get(event, "")

if event == "Notification":
    if "permission" in notification_type or "approval" in notification_type:
        state_name = "permission"
    # generic completion notifications are ignored (Stop already handles "done")
elif event == "PermissionRequest":
    state_name = "permission"

if not state_name:
    print('ACTION="skip"')
    sys.exit(0)

# --- Load config ---
try:
    config = json.load(open(config_path))
except Exception:
    config = {}

if not config.get("enabled", True):
    print('ACTION="skip"')
    sys.exit(0)

# Check per-state enable
if not config.get("states", {}).get(state_name, True):
    print('ACTION="skip"')
    sys.exit(0)

# --- Load state ---
try:
    state = json.load(open(state_path)) if os.path.exists(state_path) else {}
except Exception:
    state = {}

# --- Debounce ---
now = time.time()
last_time = state.get("last_state_time", 0)
last_state = state.get("last_state", "")
debounce = config.get("debounce_seconds", 2)
urgent = state_name in ("attention", "permission")

if state_name == last_state and (now - last_time) < debounce and not urgent:
    print('ACTION="skip"')
    sys.exit(0)

# --- Resolve theme ---
rotation_mode = config.get("theme_rotation_mode", "off")
rotation = config.get("theme_rotation", [])
rotation_index = state.get("rotation_index", 0)

# Per-session theme pinning
session_themes = state.get("session_themes", {})

if rotation_mode != "off" and rotation:
    if rotation_mode == "random":
        import random
        theme_name = random.choice(rotation)
    elif rotation_mode == "round-robin":
        theme_name = rotation[rotation_index % len(rotation)]
        if state_name == "session.start":
            rotation_index = (rotation_index + 1) % len(rotation)
    else:
        theme_name = config.get("active_theme", "default")
else:
    theme_name = config.get("active_theme", "default")

# Pin theme to session
if session_id and state_name == "session.start":
    session_themes[session_id] = theme_name
elif session_id and session_id in session_themes:
    theme_name = session_themes[session_id]

# --- Load theme ---
theme_file = os.path.join(themes_dir, theme_name, "theme.json")
if not os.path.exists(theme_file):
    theme_file = os.path.join(bundled_themes_dir, theme_name, "theme.json")
if not os.path.exists(theme_file):
    theme_file = os.path.join(bundled_themes_dir, "default", "theme.json")

try:
    theme = json.load(open(theme_file))
except Exception:
    print('ACTION="skip"')
    sys.exit(0)

state_config = theme.get("states", {}).get(state_name, {})
if not state_config:
    print('ACTION="skip"')
    sys.exit(0)

action = state_config.get("action", "color")
r = state_config.get("r", 0)
g = state_config.get("g", 0)
b = state_config.get("b", 0)
label = state_config.get("label", state_name)

# --- Compute title and badge ---
project_name = os.path.basename(cwd) if cwd else ""

features = config.get("features", {})
do_color = features.get("tab_color", True)
do_title = features.get("title", True)
do_badge = features.get("badge", True)

title_text = ""
badge_text = ""
if do_title and project_name:
    title_text = f"◉ {project_name}: {state_name}"
if do_badge and project_name:
    badge_text = f"{project_name}\\n{label}"

# --- Output bash variables ---
if action == "reset":
    print('ACTION="reset"')
elif do_color:
    print('ACTION="color"')
    print(f'COLOR_R={r}')
    print(f'COLOR_G={g}')
    print(f'COLOR_B={b}')
else:
    print('ACTION="title_only"')

print(f'DO_TITLE="{str(do_title).lower()}"')
print(f'DO_BADGE="{str(do_badge).lower()}"')
print(f'TITLE_TEXT="{title_text}"')
print(f'BADGE_TEXT="{badge_text}"')
print(f'STATE_NAME="{state_name}"')

# --- Save state atomically ---
state["last_state"] = state_name
state["last_state_time"] = now
state["session_themes"] = session_themes
state["rotation_index"] = rotation_index

tmp_path = state_path + ".tmp"
with open(tmp_path, "w") as f:
    json.dump(state, f)
os.replace(tmp_path, state_path)

PYEOF
  )"

  # Apply visual changes
  case "$ACTION" in
    reset)
      reset_tab_color
      ;;
    color)
      if [ "$TERMINAL" = "iterm2" ]; then
        set_tab_color "$COLOR_R" "$COLOR_G" "$COLOR_B"
      fi
      ;;
    title_only|"")
      # color disabled, fall through to title/badge
      ;;
    skip)
      exit 0
      ;;
  esac

  if [ "$DO_TITLE" = "true" ] && [ -n "$TITLE_TEXT" ]; then
    set_tab_title "$TITLE_TEXT"
  fi

  if [ "$DO_BADGE" = "true" ]; then
    if [ "$ACTION" = "reset" ]; then
      set_badge ""
      reset_badge_color
    elif [ -n "$BADGE_TEXT" ]; then
      set_badge "$BADGE_TEXT"
      # Set badge color AFTER text — iTerm2 resets it when badge format changes
      if [ "$ACTION" = "color" ]; then
        set_badge_color "$COLOR_R" "$COLOR_G" "$COLOR_B"
      fi
    fi
  fi
  true
}

# ─── Entry Point ───────────────────────────────────────────────────────────────

if [ $# -gt 0 ]; then
  # CLI mode
  route_cli "$@"
elif [ -t 0 ]; then
  # Interactive terminal with no args — show help
  cmd_help
else
  # Hook mode — stdin has JSON from Claude Code
  process_hook
fi
