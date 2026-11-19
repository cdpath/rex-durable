#!/bin/sh
# Remove rex-durable: stop its service and delete its installed files.
#
#   ./uninstall.sh          keep your saves, in case you install it again
#   ./uninstall.sh --purge  delete the saves too
#
# Your Rex sessions and the programs in them are not touched.
set -eu

if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
  echo "uninstall.sh: HOME is not set to a folder" >&2
  exit 1
fi

purge=0
for arg in "$@"; do
  case "$arg" in
    --purge) purge=1 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "uninstall.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done

os=$(uname -s)
config="${XDG_CONFIG_HOME:-$HOME/.config}/rex"
pi_agent_dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
if [ "$os" = Darwin ]; then
  data="$HOME/Library/Application Support/rex-durable"
  state="$data"
  for label in io.rex-durable.watcher io.github.fazxes.rex-durable; do
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
  done
else
  data="${XDG_DATA_HOME:-$HOME/.local/share}/rex-durable"
  state="${XDG_STATE_HOME:-$HOME/.local/state}/rex-durable"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now rex-durable.service 2>/dev/null || true
    rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/rex-durable.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
fi

if command -v python3 >/dev/null 2>&1; then
  CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" FACTORY_DIR="$HOME/.factory" CURSOR_DIR="${CURSOR_CONFIG_DIR:-$HOME/.cursor}" python3 - <<'PY' 2>/dev/null || true
import json
import os
import shutil

for settings_path in [
    os.path.join(os.environ["CLAUDE_DIR"], "settings.json"),
    os.path.join(os.environ["FACTORY_DIR"], "settings.json"),
]:
    if not os.path.isfile(settings_path):
        continue
    try:
        with open(settings_path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        continue
    hooks = data.get("hooks") if isinstance(data, dict) else None
    session_start = hooks.get("SessionStart") if isinstance(hooks, dict) else None
    if not isinstance(session_start, list):
        continue
    cleaned = []
    changed = False
    for entry in session_start:
        if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
            cleaned.append(entry)
            continue
        kept = [
            h for h in entry["hooks"]
            if not (isinstance(h, dict) and "rex-durable-hook.sh" in str(h.get("command", "")))
        ]
        if len(kept) != len(entry["hooks"]):
            changed = True
        if kept:
            new_entry = dict(entry)
            new_entry["hooks"] = kept
            cleaned.append(new_entry)
    if changed:
        hooks["SessionStart"] = cleaned
        tmp = settings_path + ".rex-durable.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        shutil.copymode(settings_path, tmp)
        os.replace(tmp, settings_path)

cursor_hooks_path = os.path.join(os.environ["CURSOR_DIR"], "hooks.json")
if os.path.isfile(cursor_hooks_path):
    try:
        with open(cursor_hooks_path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = None
    hooks = data.get("hooks") if isinstance(data, dict) else None
    session_start = hooks.get("sessionStart") if isinstance(hooks, dict) else None
    if isinstance(session_start, list):
        cleaned = [
            entry for entry in session_start
            if not (isinstance(entry, dict) and "rex-durable-hook.sh" in str(entry.get("command", "")))
        ]
        if len(cleaned) != len(session_start):
            hooks["sessionStart"] = cleaned
            tmp = cursor_hooks_path + ".rex-durable.tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
                f.write("\n")
            shutil.copymode(cursor_hooks_path, tmp)
            os.replace(tmp, cursor_hooks_path)
PY
fi

rm -f "$data/durable.lua" "$data/rex-durable-hook.sh" "$config/rex_durable.lua" "$pi_agent_dir/extensions/rex-durable.ts"
rm -rf "$HOME/.agents/skills/rex-durable" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/rex-durable" "$HOME/.factory/skills/rex-durable" "${CURSOR_CONFIG_DIR:-$HOME/.cursor}/skills/rex-durable"

if [ "$purge" = 1 ]; then
  rm -rf "$data" "$state"
  echo "Removed rex-durable and its saves."
else
  echo "Removed rex-durable. Your saves are still in $state (delete them with --purge)."
fi
if [ -f "$config/init.lua" ] && grep -q 'rex_durable' "$config/init.lua"; then
  echo "Remove the require(\"rex_durable\") line from $config/init.lua, then run: rex config reload"
fi
