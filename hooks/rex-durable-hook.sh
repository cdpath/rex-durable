#!/bin/sh
# Installed by rex-durable into <data_dir>/rex-durable-hook.sh
# SessionStart hook for Claude Code (~/.claude/settings.json), Factory Droid
# (~/.factory/settings.json), and Cursor Agent (~/.cursor/hooks.json). Records
# { block_id, pid, app, id, session_file } when running inside a Rex terminal
# block (REX_BLOCK).
set -eu

[ -n "${REX_BLOCK:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

app="${1:-}"
[ -n "$app" ] || exit 0

# python3 reads its program from stdin below, so take the hook payload first.
payload=$(cat || true)

REX_DURABLE_HOOK_APP="$app" REX_DURABLE_HOOK_PAYLOAD="$payload" \
  REX_DURABLE_CONFIGURED_STATE="@STATE_DIR@" python3 - <<'PY' 2>/dev/null || true
import json
import os
import subprocess
import sys
import time

block_id = os.environ.get("REX_BLOCK", "")
app = os.environ.get("REX_DURABLE_HOOK_APP", "")
if not block_id or not app:
    raise SystemExit(0)

try:
    raw = os.environ.get("REX_DURABLE_HOOK_PAYLOAD", "")
    payload = json.loads(raw) if raw.strip() else {}
except Exception:
    raise SystemExit(0)

if not isinstance(payload, dict):
    raise SystemExit(0)

event_name = payload.get("hook_event_name") or payload.get("hookEventName")
if event_name is not None and event_name not in ("SessionStart", "sessionStart"):
    raise SystemExit(0)

if any(
    payload.get(k)
    for k in (
        "agent_id",
        "agentId",
        "calling_session_id",
        "callingSessionId",
        "parent_session_id",
        "parentSessionId",
        "is_subagent",
        "isSubagent",
        "is_background_agent",
    )
):
    raise SystemExit(0)

session_id = next(
    (
        payload.get(k)
        for k in ("session_id", "sessionId", "conversation_id", "conversationId")
        if isinstance(payload.get(k), str) and payload.get(k)
    ),
    None,
)
if not session_id:
    raise SystemExit(0)

transcript_path = payload.get("transcript_path") or payload.get("transcriptPath")
session_file = (
    transcript_path
    if isinstance(transcript_path, str) and transcript_path.startswith("/")
    else None
)

cwd = payload.get("cwd")
if not isinstance(cwd, str) or not cwd:
    roots = payload.get("workspace_roots")
    cwd = next((r for r in roots if isinstance(r, str) and r), None) if isinstance(roots, list) else None
if not cwd:
    cwd = os.getcwd()

owner_pid = None
cur = os.getppid()
for _ in range(6):
    if cur <= 1:
        break
    try:
        out = subprocess.check_output(
            ["ps", "-o", "ppid=,comm=", "-p", str(cur)], text=True
        ).strip()
    except Exception:
        break
    if not out:
        break
    parts = out.split(None, 1)
    ppid = int(parts[0])
    comm = os.path.basename(parts[1].strip()) if len(parts) > 1 else ""
    if (
        comm == app
        or (app == "claude" and (comm.startswith("node") or "claude" in comm))
        or (app == "droid" and "droid" in comm)
        or (
            app == "cursor-agent"
            and (comm in ("cursor-agent", "agent") or comm.startswith("node") or "cursor-agent" in comm)
        )
    ):
        owner_pid = cur
        break
    cur = ppid

if not owner_pid:
    raise SystemExit(0)

state_dir = os.environ.get("REX_DURABLE_STATE_DIR") or os.environ.get(
    "REX_DURABLE_CONFIGURED_STATE", ""
)
if not state_dir or state_dir.startswith("@"):
    home = os.path.expanduser("~")
    if sys.platform == "darwin":
        state_dir = os.path.join(home, "Library", "Application Support", "rex-durable")
    else:
        xdg = os.environ.get("XDG_STATE_HOME") or os.path.join(home, ".local", "state")
        state_dir = os.path.join(xdg, "rex-durable")

blocks_dir = os.path.join(state_dir, "blocks")
os.makedirs(blocks_dir, exist_ok=True)
safe_name = (
    "".join(c if (c.isalnum() or c in "._-") else "_" for c in block_id) + ".json"
)
target = os.path.join(blocks_dir, safe_name)
tmp = f"{target}.{os.getpid()}.tmp"

record = {
    "block_id": block_id,
    "session_id": os.environ.get("REX_SESSION") or None,
    "app": app,
    "pid": owner_pid,
    "id": session_id,
    "session_file": session_file,
    "cwd": cwd,
    "updated_at": int(time.time()),
}
record = {k: v for k, v in record.items() if v is not None}

with open(tmp, "w", encoding="utf-8") as f:
    json.dump(record, f, indent=2)
    f.write("\n")
os.replace(tmp, target)
PY
