#!/bin/bash
# tab-chroma uninstaller

INSTALL_DIR="$HOME/.claude/hooks/tab-chroma"
SETTINGS_FILE="$HOME/.claude/settings.json"
CODEX_SETTINGS_FILE="$HOME/.codex/hooks.json"

echo "tab-chroma uninstaller"
echo ""

# Allow --yes / -y to skip confirmation (used by `tab-chroma uninstall`)
if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]]; then
  confirm="y"
else
  read -r -p "Remove tab-chroma completely? This will remove all files and hooks. [y/N] " confirm
fi

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ─── 1. Remove hooks from Claude Code and Codex settings ──────────────────────

echo "Removing Claude Code and Codex hooks..."

python3 - "$SETTINGS_FILE" "$CODEX_SETTINGS_FILE" "$INSTALL_DIR" << 'PYEOF'
import json, os, re, sys

install_dir = sys.argv[3]

def is_owned(command):
    if not isinstance(command, str):
        return False
    return (
        command == os.path.join(install_dir, "tab-chroma.sh")
        or command in ("/opt/homebrew/bin/tab-chroma", "/usr/local/bin/tab-chroma")
        or re.search(r"/(?:Cellar|cellar)/.+/share/tab-chroma/tab-chroma\.sh$", command)
    )

for settings_path in sys.argv[1:3]:
    if not os.path.exists(settings_path):
        print(f"  {settings_path} not found, skipping")
        continue
    try:
        settings = json.load(open(settings_path))
    except Exception as e:
        print(f"  error reading {settings_path}: {e}")
        continue
    changed = False
    for entries in settings.get("hooks", {}).values():
        for entry in entries:
            original = list(entry.get("hooks", []))
            entry["hooks"] = [h for h in original if not is_owned(h.get("command"))]
            changed |= len(entry["hooks"]) != len(original)
    if changed:
        tmp_path = settings_path + ".tmp"
        with open(tmp_path, "w") as f:
            json.dump(settings, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, settings_path)
        print(f"  Removed tab-chroma hooks from {settings_path}.")
    else:
        print(f"  No tab-chroma hooks found in {settings_path}.")
PYEOF

# ─── 2. Reset tab color and clear badge ───────────────────────────────────────

if [ "$TERM_PROGRAM" = "iTerm.app" ]; then
  printf '\033]6;1;bg;*;default\a' > /dev/tty
  printf '\033]1337;SetBadgeFormat=\a' > /dev/tty
  echo "Tab color reset and badge cleared."
fi

# ─── 3. Remove completions ────────────────────────────────────────────────────

echo "Removing completions..."

BASH_COMPLETION="$HOME/.bash_completion.d/tab-chroma"
if [ -f "$BASH_COMPLETION" ]; then
  rm -f "$BASH_COMPLETION"
  echo "  removed $BASH_COMPLETION"
fi

FISH_COMPLETION="$HOME/.config/fish/completions/tab-chroma.fish"
if [ -f "$FISH_COMPLETION" ]; then
  rm -f "$FISH_COMPLETION"
  echo "  removed $FISH_COMPLETION"
fi

# ─── 4. Note about alias ──────────────────────────────────────────────────────

echo ""
echo "Note: if you added 'alias tab-chroma=...' to .zshrc/.bashrc, remove it manually."

# ─── 5. Remove install directory ──────────────────────────────────────────────

echo ""
echo "Removing $INSTALL_DIR..."
rm -rf "$INSTALL_DIR"
echo "Done. tab-chroma has been uninstalled."
