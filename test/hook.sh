#!/bin/bash
# Test of hooks/rex-durable-hook.sh without Rex. A stand-in "droid" (or "claude")
# process runs the hook as its child, the way the real program does, with the
# SessionStart payload on stdin. The test reads back the record the hook leaves
# for durable.lua.
#
#   test/hook.sh
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
T=$(cd "$(mktemp -d /tmp/rex-durable-hook.XXXXXX)" && pwd -P)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
passed=0
failed=0

ok() { passed=$((passed + 1)); echo "  ok    $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL  $1"; }
expect() {
  local what=$1; shift
  if "$@"; then ok "$what"; else bad "$what"; fi
}

cat >"$T/launcher.c" <<'EOF'
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc < 2) return 2;
  pid_t child = fork();
  if (child == 0) {
    execl("/bin/sh", "sh", "-c", argv[1], (char *)0);
    _exit(127);
  }
  int status;
  waitpid(child, &status, 0);
  return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
EOF
cc -O0 -o "$T/bin/droid" "$T/launcher.c"
cp "$T/bin/droid" "$T/bin/claude"
sed "s|@STATE_DIR@|$T/state|" "$here/hooks/rex-durable-hook.sh" >"$T/hook.sh"

ROOT=aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa
WORKER=bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb
NEXT=cccccccc-3333-4333-8333-cccccccccccc
BLOCK=block:01a1ee00-0000-7000-8000-000000000001
RECORD="$T/state/blocks/block_01a1ee00-0000-7000-8000-000000000001.json"

payload() { # session-id [extra json members, each starting with a comma]
  printf '{"session_id":"%s","transcript_path":"/tmp/p/%s.jsonl","cwd":"/tmp/p","hook_event_name":"SessionStart"%s}' \
    "$1" "$1" "${2:-}"
}
fire() { # app payload [block id; empty means outside Rex]
  local app=$1 json=$2 block=${3-$BLOCK}
  printf '%s' "$json" |
    env -u REX_BLOCK -u REX_DURABLE_STATE_DIR ${block:+REX_BLOCK=$block} \
      "$T/bin/$app" "sh '$T/hook.sh' $app" || true
}
field() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$RECORD" "$1" 2>/dev/null || true; }

echo "SessionStart hook"
fire droid "$(payload "$ROOT" ',"source":"startup"')"
expect "droid session is recorded for its block" test "$(field id)" = "$ROOT"
expect "the record names the program" test "$(field app)" = droid
expect "the record names the transcript file" test "$(field session_file)" = "/tmp/p/$ROOT.jsonl"
expect "the record names the process that runs the session" sh -c "test -n '$(field pid)'"

fire droid "$(payload "$WORKER" ',"source":"startup","calling_session_id":"'"$ROOT"'"')"
expect "a Task subagent's session leaves the main session recorded" test "$(field id)" = "$ROOT"

fire droid "$(payload "$ROOT" ',"source":"compact"')"
expect "a compaction keeps the same session recorded" test "$(field id)" = "$ROOT"

fire droid "$(payload "$NEXT" ',"source":"clear","previous_session_id":"'"$ROOT"'"')"
expect "/new replaces the recorded session" test "$(field id)" = "$NEXT"

rm -rf "$T/state/blocks"
fire droid "$(payload "$ROOT" ',"source":"startup"')" ""
expect "outside Rex nothing is recorded" test ! -e "$T/state/blocks"

fire claude "$(payload "$ROOT" ',"source":"startup"')"
expect "claude session is recorded for its block" test "$(field id)" = "$ROOT"
expect "the record names claude" test "$(field app)" = claude

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
