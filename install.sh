#!/bin/sh
# Install rex-durable: copy durable.lua, install Pi extension + Claude/Droid/Cursor
# SessionStart hooks + agent skill, load custom actions in ~/.config/rex/init.lua,
# and run the in-process event watcher as a login service.
#
#   ./install.sh                    install, or update an existing install
#   ./install.sh --add-to-config    also load custom actions from init.lua
#   ./install.sh --no-service       copy files only; run durable.lua yourself
#   ./install.sh --no-pi-extension  skip installing ~/.pi/agent/extensions/rex-durable.ts
#   ./install.sh --no-hooks         skip installing Claude/Droid/Cursor SessionStart hooks
#   ./install.sh --no-skill         skip installing ~/.agents/skills/rex-durable
#   REX=/path/to/rex ./install.sh   use this rex command
#
# Remove it with ./uninstall.sh.
set -eu

if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
  echo "install.sh: HOME is not set to a folder" >&2
  exit 1
fi

here=$(cd "$(dirname "$0")" && pwd)
os=$(uname -s)
add_to_config=0
service=1
pi_ext=1
install_hooks=1
install_skill=1
for arg in "$@"; do
  case "$arg" in
    --add-to-config) add_to_config=1 ;;
    --no-service) service=0 ;;
    --no-pi-extension) pi_ext=0 ;;
    --no-hooks) install_hooks=0 ;;
    --no-skill) install_skill=0 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
fail() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

case "$os" in
  Darwin)
    data="$HOME/Library/Application Support/rex-durable"
    state="$data"
    log="$HOME/Library/Logs/rex-durable.log"
    ;;
  Linux|FreeBSD)
    data="${XDG_DATA_HOME:-$HOME/.local/share}/rex-durable"
    state="${XDG_STATE_HOME:-$HOME/.local/state}/rex-durable"
    log=""
    ;;
  *) fail "unsupported system $os (rex-durable runs on macOS and Linux)" ;;
esac
config="${XDG_CONFIG_HOME:-$HOME/.config}/rex"
script="$data/durable.lua"
hook_script="$data/rex-durable-hook.sh"

find_rex() {
  if [ -n "${REX:-}" ]; then printf '%s\n' "$REX"; return 0; fi
  if [ "$os" = Darwin ]; then
    current="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
    if [ -x "$current" ]; then printf '%s\n' "$current"; return 0; fi
  fi
  if command -v rex >/dev/null 2>&1; then command -v rex; return 0; fi
  if [ "$os" = Darwin ]; then
    for candidate in /Applications/Rex*.app/Contents/Helpers/*/Contents/MacOS/rex \
                     "$HOME"/Applications/Rex*.app/Contents/Helpers/*/Contents/MacOS/rex \
                     /Applications/Rex*.app/Contents/Helpers/rex; do
      if [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
    done
  fi
  return 1
}
rex=$(find_rex) || fail "can't find the rex command. Open Rex once, or run REX=/path/to/rex ./install.sh"
say "Using rex: $rex"

check=$("$rex" --autostart=false do -e 'return (rex.exec and rex.every and rex.json and rex.on and rex.layout) and "ok" or "old"' 2>/dev/null || true)
case "$check" in
  *ok*) ;;
  *old*) fail "this Rex is too old for rex-durable; update Rex and try again" ;;
  *) say "Note: no Rex server is running, so the Rex version wasn't checked." ;;
esac

mkdir -p "$data" "$state/blocks"
cp "$here/durable.lua" "$script.new" && mv "$script.new" "$script"
say "Installed $script"

lua_string() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
sed_text() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }

if [ "$pi_ext" = 1 ]; then
  pi_agent_dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
  mkdir -p "$pi_agent_dir/extensions"
  ext_dst="$pi_agent_dir/extensions/rex-durable.ts"
  sed -e "s|@STATE_DIR@|$(sed_text "$(lua_string "$state")")|" \
      "$here/extensions/rex-durable.ts" >"$ext_dst.new" && mv "$ext_dst.new" "$ext_dst"
  say "Installed Pi extension (session tracking + OSC 7501 status) in $ext_dst"
fi

if [ "$install_hooks" = 1 ] && [ -f "$here/hooks/rex-durable-hook.sh" ]; then
  sed -e "s|@STATE_DIR@|$(sed_text "$state")|" \
      "$here/hooks/rex-durable-hook.sh" >"$hook_script.new"
  chmod +x "$hook_script.new"
  mv "$hook_script.new" "$hook_script"
  if command -v python3 >/dev/null 2>&1; then
    HOOK_SCRIPT="$hook_script" CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" FACTORY_DIR="$HOME/.factory" CURSOR_DIR="${CURSOR_CONFIG_DIR:-$HOME/.cursor}" python3 - <<'PY'
import json
import os
import shlex
import shutil
import sys

hook_script = os.environ["HOOK_SCRIPT"]
quoted_hook_script = shlex.quote(hook_script)
targets = [
    ("claude", os.path.join(os.environ["CLAUDE_DIR"], "settings.json")),
    ("droid", os.path.join(os.environ["FACTORY_DIR"], "settings.json")),
]

for app, settings_path in targets:
    parent = os.path.dirname(settings_path)
    if not os.path.isdir(parent):
        continue
    data = {}
    if os.path.isfile(settings_path):
        try:
            with open(settings_path, encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            continue
    if not isinstance(data, dict):
        continue
    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        continue
    session_start = hooks.setdefault("SessionStart", [])
    if not isinstance(session_start, list):
        continue

    cmd = f"sh {quoted_hook_script} {app}"
    cleaned = []
    for entry in session_start:
        if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
            cleaned.append(entry)
            continue
        kept = [
            h for h in entry["hooks"]
            if not (isinstance(h, dict) and "rex-durable-hook.sh" in str(h.get("command", "")))
        ]
        if kept:
            new_entry = dict(entry)
            new_entry["hooks"] = kept
            cleaned.append(new_entry)

    cleaned.append({
        "hooks": [
            {
                "type": "command",
                "command": cmd,
                "timeout": 5,
            }
        ]
    })
    hooks["SessionStart"] = cleaned

    tmp = settings_path + ".rex-durable.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    if os.path.isfile(settings_path):
        shutil.copymode(settings_path, tmp)
    os.replace(tmp, settings_path)
    print(f"Registered SessionStart hook for {app} in {settings_path}")

cursor_dir = os.environ.get("CURSOR_DIR", "")
if cursor_dir and os.path.isdir(cursor_dir):
    cursor_hooks_path = os.path.join(cursor_dir, "hooks.json")
    data = {}
    if os.path.isfile(cursor_hooks_path):
        try:
            with open(cursor_hooks_path, encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            data = None
    if not isinstance(data, dict):
        print(
            f"Warning: skipped {cursor_hooks_path} (invalid JSON or not a JSON object); fix it and re-run install.sh",
            file=sys.stderr,
        )
    else:
        data.setdefault("version", 1)
        hooks = data.setdefault("hooks", {})
        session_start = hooks.setdefault("sessionStart", []) if isinstance(hooks, dict) else None
        if not isinstance(session_start, list):
            print(
                f"Warning: skipped {cursor_hooks_path} (unexpected hooks.sessionStart format); fix it and re-run install.sh",
                file=sys.stderr,
            )
        else:
            cleaned = [
                entry for entry in session_start
                if not (isinstance(entry, dict) and "rex-durable-hook.sh" in str(entry.get("command", "")))
            ]
            cleaned.append({"command": f"sh {quoted_hook_script} cursor-agent"})
            hooks["sessionStart"] = cleaned
            tmp = cursor_hooks_path + ".rex-durable.tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
                f.write("\n")
            if os.path.isfile(cursor_hooks_path):
                shutil.copymode(cursor_hooks_path, tmp)
            os.replace(tmp, cursor_hooks_path)
            print(f"Registered sessionStart hook for cursor-agent in {cursor_hooks_path}")
PY
  fi
fi

if [ "$install_skill" = 1 ] && [ -f "$here/skills/rex-durable/SKILL.md" ]; then
  for skill_root in "$HOME/.agents/skills" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills" "$HOME/.factory/skills" "${CURSOR_CONFIG_DIR:-$HOME/.cursor}/skills"; do
    if [ -d "$(dirname "$skill_root")" ]; then
      mkdir -p "$skill_root/rex-durable"
      cp "$here/skills/rex-durable/SKILL.md" "$skill_root/rex-durable/SKILL.md.new"
      mv "$skill_root/rex-durable/SKILL.md.new" "$skill_root/rex-durable/SKILL.md"
    fi
  done
  say "Installed agent skill rex-durable"
fi

service_path="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.factory/bin:$HOME/.gemini/antigravity-cli/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
for tool in fx claude codex pi agy droid cursor-agent agent node bun; do
  where=$(command -v "$tool" 2>/dev/null || true)
  case "$where" in
    /*)
      dir=$(dirname "$where")
      case ":$service_path:" in
        *":$dir:"*) ;;
        *) service_path="$dir:$service_path" ;;
      esac
      ;;
  esac
done

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

if [ "$service" = 1 ]; then
  if [ "$os" = Darwin ]; then
    old_label=io.github.fazxes.rex-durable
    if [ -f "$HOME/Library/LaunchAgents/$old_label.plist" ]; then
      launchctl bootout "gui/$(id -u)/$old_label" 2>/dev/null || true
      rm -f "$HOME/Library/LaunchAgents/$old_label.plist"
    fi
    label=io.rex-durable.watcher
    plist="$HOME/Library/LaunchAgents/$label.plist"
    mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$log")"
    cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml "$rex")</string>
    <string>--autostart=false</string>
    <string>do</string>
    <string>$(xml "$script")</string>
    <string>--all</string>
    <string>mode=watch</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$(xml "$service_path")</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$(xml "$log")</string>
  <key>StandardErrorPath</key><string>$(xml "$log")</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    say "Started the login service $label (log: $log)"
  elif command -v systemctl >/dev/null 2>&1; then
    units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$units"
    cat >"$units/rex-durable.service" <<EOF
[Unit]
Description=rex-durable: keep coding agents and programs across Rex server restarts

[Service]
ExecStart="$rex" --autostart=false do "$script" --all mode=watch
Restart=always
RestartSec=5
Environment="PATH=$service_path"

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now rex-durable.service
    systemctl --user restart rex-durable.service
    say "Started the systemd user service rex-durable (log: journalctl --user -u rex-durable)"
  else
    say "No launchd or systemd here. Keep this running yourself, for example from your shell profile:"
    say "  \"$rex\" --autostart=false do \"$script\" --all mode=watch &"
  fi
fi

mkdir -p "$config"
sed -e "s|@REX@|$(sed_text "$(lua_string "$rex")")|" \
    -e "s|@SCRIPT@|$(sed_text "$(lua_string "$script")")|" \
    "$here/rex_durable.lua" >"$config/rex_durable.lua"
say "Installed custom actions in $config/rex_durable.lua"

init="$config/init.lua"
if [ -f "$init" ] && grep -q 'rex_durable' "$init"; then
  "$rex" --autostart=false config reload >/dev/null 2>&1 || true
elif [ "$add_to_config" = 1 ]; then
  printf '\n-- rex-durable: custom actions (durable_status, durable_save, durable_reopen, durable_repair, ...)\nrequire("rex_durable")\n' >>"$init"
  "$rex" --autostart=false config reload >/dev/null 2>&1 || true
  say "Added require(\"rex_durable\") to $init"
else
  say "To enable CLI & command palette actions, add this line to $init:"
  say "  require(\"rex_durable\")"
  say "(or run ./install.sh --add-to-config)"
fi

say ""
say "Done. rex-durable is watching your Rex sessions in real time."
say "Check status any time with:"
say "  rex do durable_status"
