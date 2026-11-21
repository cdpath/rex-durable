-- Unit tests for durable.lua. They run in Rex's own Lua and only read/use temp state:
--
--   rex do test/unit.lua root="$PWD"     (from the repository root)
--
-- test/e2e.sh runs them for you.

REX_DURABLE_LIB = true
local here = rex.args.root or (debug.getinfo(1, "S").source:match("^@(.*)/test/[^/]*$")) or "."
local M = dofile(here .. "/durable.lua")
local HOME = os.getenv("HOME")

local stats = { passed = 0, failed = 0 }

local function show(v)
  if type(v) == "table" then return rex.json.encode(v) end
  return tostring(v)
end

local function check(name, got, want)
  if show(got) == show(want) then
    stats.passed = stats.passed + 1
  else
    stats.failed = stats.failed + 1
    print("FAIL " .. name .. "\n  got:  " .. show(got) .. "\n  want: " .. show(want))
  end
end

local function new_fx(_, option) return option ~= "--sessions-v2" end
local function old_fx() return true end

-- A chat that runs subagents holds their locks too: save the main chat.
local function reader(path)
  if path:find("/SUB1/", 1, true) then return '{"kind":"session_created","id":"SUB1","role":"child","parent":"MAIN1"}' end
  if path:find("/SUB2/", 1, true) then return '{"kind":"session_created","id":"SUB2","role":"child","parent":"SUB1"}' end
  return '{"kind":"session_created","role":"root"}'
end
local v2 = HOME .. "/.fx/sessions/v2/"
check("main chat wins over its subagent",
  { M.fx_session({ v2 .. "SUB1/lock", v2 .. "MAIN1/lock" }, nil, reader) }, { "MAIN1", "v2" })
check("only subagent locks: follow the owners to the main chat",
  { M.fx_session({ v2 .. "SUB2/lock" }, nil, reader) }, { "MAIN1", "v2" })
check("no log: a main chat", { M.fx_session({ v2 .. "PLAIN/lock" }, nil, function() return nil end) }, { "PLAIN", "v2" })

-- Antigravity CLI (agy) session detection & subagent disambiguation
local agy_main = "92a03d59-a6ae-4417-9c3c-4dd05e31bfa9"
local agy_sub = "11111111-2222-4333-8444-555555555555"
local agy_base = HOME .. "/.gemini/antigravity-cli/"
check("agy single brain dir",
  { M.agy_session({ "/usr/lib/dyld", agy_base .. "brain/" .. agy_main }, HOME) },
  { agy_main, agy_base .. "brain/" .. agy_main })
check("agy single conversations db-shm",
  { M.agy_session({ agy_base .. "conversations/" .. agy_main .. ".db-shm" }, HOME) },
  { agy_main, agy_base .. "brain/" .. agy_main })
check("agy other profile ignored",
  M.agy_session({ "/tmp/other-home/.gemini/antigravity-cli/brain/" .. agy_main }, HOME), nil)
local function agy_reader(path)
  if path:find(agy_main, 1, true) then
    return '{"tool_calls":[{"name":"invoke_subagent"}],"content":"conversationId: ' .. agy_sub .. '"}'
  end
  return '{"step_index":0,"content":"subagent task"}'
end
check("agy main chat wins over subagent even when subagent listed first",
  { M.agy_session({ agy_base .. "brain/" .. agy_sub, agy_base .. "brain/" .. agy_main }, HOME, agy_reader) },
  { agy_main, agy_base .. "brain/" .. agy_main })

-- Pi slug & session detection
check("pi slug normal path", M.pi_slug("/Users/alice/Developer/work/my-app"),
  "--Users-alice-Developer-work-my-app--")
check("pi slug keeps dots, underscores, tildes, spaces",
  M.pi_slug("/Users/me/.herdr/my_proj/iCloud~obsidian/my docs/"),
  "--Users-me-.herdr-my_proj-iCloud~obsidian-my docs--")
local pi_id = "01a1ed70-0f42-7352-8e29-dca044c16b6d"
local pi_file = HOME .. "/.pi/agent/sessions/--Users-me-proj--/2026-11-18T06-55-06-562Z_" .. pi_id .. ".jsonl"
check("pi open session file", { M.pi_session({ pi_file }, HOME) }, { pi_id, pi_file })

-- Factory Droid slug & session detection
local droid_id = "eeeeeeee-5555-4555-8555-eeeeeeeeeeee"
local droid_file = HOME .. "/.factory/sessions/-Users-alice-Developer-rex-durable/" .. droid_id .. ".jsonl"
local droid_settings = HOME .. "/.factory/sessions/-Users-alice-Developer-rex-durable/" .. droid_id .. ".settings.json"
check("droid slug normal path", M.droid_slug("/Users/alice/Developer/rex-durable"),
  "-Users-alice-Developer-rex-durable")
check("droid slug keeps dots, underscores, spaces",
  M.droid_slug("/Users/alice/.herdr/my_proj/my docs/"),
  "-Users-alice-.herdr-my_proj-my docs")
check("droid open jsonl file", { M.droid_session({ droid_file }, HOME) }, { droid_id, droid_file })
check("droid open settings.json maps to jsonl",
  { M.droid_session({ droid_settings }, HOME) }, { droid_id, droid_file })
check("droid session started by a Task is a subagent's",
  M.droid_is_subagent({ type = "session_start", id = "w", callingSessionId = droid_id }), true)
check("droid session with no calling session is a main session",
  M.droid_is_subagent({ type = "session_start", id = droid_id }), false)
check("droid empty calling session is a main session", M.droid_is_subagent({ callingSessionId = "" }), false)
check("droid unreadable header is not taken for a subagent's", M.droid_is_subagent(nil), false)

check("md5 known vector", M.md5("hello"), "5d41402abc4b2a76b9719d911017c592")
check("md5 empty string", M.md5(""), "d41d8cd98f00b204e9800998ecf8427e")
local cur_id = "ffffffff-6666-4666-8666-ffffffffffff"
local cur_id2 = "12121212-6666-4666-8666-121212121212"
local cur_hash = M.md5("/Users/alice/proj")
local cur_base = HOME .. "/.cursor/chats/" .. cur_hash .. "/"
check("cursor-agent open store.db-wal maps to store.db",
  { M.cursor_agent_session({ cur_base .. cur_id .. "/store.db-wal" }, HOME) },
  { cur_id, cur_base .. cur_id .. "/store.db" })
check("cursor-agent other profile ignored",
  M.cursor_agent_session({ "/tmp/other/.cursor/chats/" .. cur_hash .. "/" .. cur_id .. "/store.db" }, HOME), nil)
local function cur_meta_reader(path)
  if path:find(cur_id, 1, true) then
    return '{"hasConversation":true,"updatedAtMs":2000}'
  end
  if path:find(cur_id2, 1, true) then
    return '{"hasConversation":false,"updatedAtMs":9000}'
  end
end
check("cursor-agent prefers hasConversation over newer empty chat",
  { M.cursor_agent_session({ cur_base .. cur_id2 .. "/store.db", cur_base .. cur_id .. "/store.db" }, HOME, cur_meta_reader) },
  { cur_id, cur_base .. cur_id .. "/store.db" })
local function cur_newer_reader(path)
  if path:find(cur_id, 1, true) then
    return '{"hasConversation":true,"updatedAtMs":1000}'
  end
  if path:find(cur_id2, 1, true) then
    return '{"hasConversation":true,"updatedAtMs":5000}'
  end
end
check("cursor-agent prefers highest updatedAtMs among active chats",
  { M.cursor_agent_session({ cur_base .. cur_id .. "/store.db", cur_base .. cur_id2 .. "/store.db" }, HOME, cur_newer_reader) },
  { cur_id2, cur_base .. cur_id2 .. "/store.db" })

-- Many tabs closed at once
local function snap_with(tabs, chats)
  local windows = {}
  for i = 1, tabs do
    windows[i] = { layout = { pane = { kind = i <= chats and "chat" or "shell", app = "fx", id = "C" .. i } } }
  end
  return { sessions = { { label = "s", windows = windows } } }
end
check("big drop: most tabs gone", M.big_drop(snap_with(10, 8), snap_with(2, 1)), true)
check("no drop: one tab closed", M.big_drop(snap_with(10, 8), snap_with(9, 7)), false)
check("no drop: only two tabs gone", M.big_drop(snap_with(3, 3), snap_with(1, 1)), false)
check("big drop: chats stopped, tabs stayed", M.big_drop(snap_with(10, 8), snap_with(10, 2)), true)

-- Repair: what is missing compared with a save
local saved_r = { sessions = {
  { session_id = "s1", label = "work", windows = {
    { layout = { pane = { block_id = "k1", kind = "chat", app = "fx", id = "A" } } },
    { layout = { pane = { block_id = "k2", kind = "shell", cwd = "/w" } } },
    { layout = { pane = { block_id = "k3", kind = "chat", app = "fx", id = "B" } } },
  } },
  { session_id = "gone", label = "old", windows = {
    { layout = { pane = { block_id = "k9", kind = "shell", cwd = "/w" } } },
  } },
} }
local live_r = { sessions = { { session_id = "s1", label = "work", windows = {
  { layout = { pane = { block_id = "k1", kind = "chat", app = "fx", id = "A" } } },
} } } }
local function actions(open)
  local out = {}
  for _, a in ipairs(M.plan_repair(saved_r, live_r, open)) do
    out[#out + 1] = a.kind == "session" and ("session " .. a.saved.label) or (a.label .. " tab " .. a.index)
  end
  return out
end
check("repair adds missing tabs and sessions", actions({}), { "work tab 2", "work tab 3", "session old" })
check("repair skips a tab whose chat is open elsewhere", actions({ ["fx:B"] = true }), { "work tab 2", "session old" })
saved_r.sessions[1].windows[2].window_id = "window:saved-2"
table.insert(live_r.sessions[1].windows, { window_id = "window:new-2",
  layout = { pane = { block_id = "k2-new", kind = "shell", cwd = "/w" } } })
local again = {}
for _, a in ipairs(M.plan_repair(saved_r, live_r, {}, { ["window:saved-2"] = "window:new-2" })) do
  again[#again + 1] = a.kind == "session" and ("session " .. a.saved.label) or (a.label .. " tab " .. a.index)
end
check("repair doesn't add a tab it already put back", again, { "work tab 3", "session old" })

-- ps and lsof output
check("etime seconds", M.parse_etime("05:07"), 307)
check("etime hours", M.parse_etime("1:02:03"), 3723)
check("etime days", M.parse_etime("2-01:00:00"), 2 * 86400 + 3600)
local ps = M.parse_ps("  101 01:00 /usr/bin/fx --resume abc\n  202 2-00:00:01 zsh\n")
check("ps args", ps[101].args, "/usr/bin/fx --resume abc")
check("ps age", ps[202].age, 2 * 86400 + 1)
local files = M.parse_lsof("p101\nfcwd\nn/tmp\np202\nn/a b/c.jsonl\n")
check("lsof files", files, { [101] = { "/tmp" }, [202] = { "/a b/c.jsonl" } })

-- Which conversation a chat is on
check("fx v2 lock", { M.fx_session({ "/x", HOME .. "/.fx/sessions/v2/Xy7_q-Z/lock" }) }, { "Xy7_q-Z", "v2" })
check("fx v1 lock", { M.fx_session({ HOME .. "/.fx/sessions/AbC123/session.lock" }) }, { "AbC123", "v1" })
check("fx other profile", M.fx_session({ "/tmp/aig-fx-home/.fx/sessions/v2/X/lock" }), nil)
local rollout = HOME .. "/.codex/sessions/2026/11/13/rollout-2026-11-13T10-00-00-aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb.jsonl"
check("codex rollout", (M.codex_session({ rollout })), "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb")
check("claude slug", M.claude_slug("/Users/me/my.proj"), "-Users-me-my-proj")
local claude_file = HOME .. "/.claude/projects/-Users-me/cccccccc-4444-4555-8666-dddddddddddd.jsonl"
check("claude file", (M.claude_session({ claude_file })), "cccccccc-4444-4555-8666-dddddddddddd")
local uuid = "cccccccc-4444-4555-8666-dddddddddddd"
check("claude --resume", M.argv_session("claude", { "claude", "--resume", uuid }), uuid)
check("claude --resume=", M.argv_session("claude", { "claude", "--resume=" .. uuid }), uuid)
check("codex resume", M.argv_session("codex", { "codex", "resume", uuid }), uuid)
check("codex resume with flags before id", M.argv_session("codex", { "codex", "resume", "-m", "gpt-5", uuid }), uuid)
check("codex --last", M.argv_session("codex", { "codex", "resume", "--last" }), nil)
check("droid --resume", M.argv_session("droid", { "droid", "--resume", droid_id }), droid_id)
check("droid -r", M.argv_session("droid", { "droid", "-r", droid_id }), droid_id)
check("droid resume subcommand with flags", M.argv_session("droid", { "droid", "resume", "--auto", "high", droid_id }), droid_id)
check("droid interactive resume without id", M.argv_session("droid", { "droid", "resume" }), nil)
check("agy --conversation", M.argv_session("agy", { "agy", "--conversation", agy_main }), agy_main)
check("agy --conversation=", M.argv_session("agy", { "agy", "--conversation=" .. agy_main }), agy_main)
check("agy --switch", M.argv_session("agy", { "agy", "--switch", agy_main }), agy_main)
check("pi --session id", M.argv_session("pi", { "pi", "--session", pi_id }), pi_id)
check("pi --session-id", M.argv_session("pi", { "pi", "--session-id", pi_id }), pi_id)
check("pi --session path", { M.argv_session("pi", { "pi", "--session=" .. pi_file }) }, { pi_id, pi_file })
check("cursor-agent --resume", M.argv_session("cursor-agent", { "cursor-agent", "--resume", cur_id }), cur_id)
check("cursor-agent --resume=", M.argv_session("cursor-agent", { "agent", "--resume=" .. cur_id }), cur_id)
check("cursor-agent resume subcommand with flags",
  M.argv_session("cursor-agent", { "agent", "resume", "--model", "opus", cur_id }), cur_id)
check("cursor-agent resume after wrapper args",
  M.argv_session("cursor-agent", { "agent", "--use-system-ca", "/opt/cursor-agent/versions/1/index.js", "--resume", cur_id }), cur_id)
check("cursor-agent -w does not swallow resume UUID",
  M.argv_session("cursor-agent", { "agent", "resume", "-w", cur_id }), cur_id)
check("cursor-agent --workspace UUID is not mistaken for resume",
  M.argv_session("cursor-agent", { "agent", "--workspace", cur_id }), nil)
check("claude via node", M.is_app("claude", "node", { "node", "/usr/local/bin/claude" }), true)
check("pi via node", M.is_app("pi", "node", { "node", "/Users/me/.bun/bin/pi" }), true)
check("pi via bun package", M.is_app("pi", "bun", { "bun", "/opt/pi-coding-agent/dist/cli.js" }), true)
check("pi via Rex terminal.process script field",
  M.is_app("pi", { name = "node", script = "/opt/pi-coding-agent/dist/cli.js" }, {}), true)
check("pi via Rex terminal.process invoked_path field",
  M.is_app("pi", { name = "node", invoked_path = "/Users/alice/.bun/bin/pi" }, {}), true)
check("pi via Rex terminal.process argv0 field",
  M.is_app("pi", { name = "node", argv0 = "pi" }, {}), true)
check("pi binary", M.is_app("pi", "pi", { "pi" }), true)
check("agy binary", M.is_app("agy", "agy", { "/Users/me/.local/bin/agy" }), true)
check("codex binary", M.is_app("codex", "codex", { "/opt/homebrew/bin/codex" }), true)
check("cursor-agent binary", M.is_app("cursor-agent", "cursor-agent", { "/Users/me/.local/bin/cursor-agent" }), true)
check("cursor-agent agent wrapper with --use-system-ca and index.js",
  M.is_app("cursor-agent", { name = "agent", argv0 = "agent" },
    { "agent", "--use-system-ca", "/Users/me/.local/share/cursor-agent/versions/2026.05/index.js", "--model", "opus" }), true)
check("cursor-agent node path under cursor-agent",
  M.is_app("cursor-agent", { name = "node", path = "/Users/me/.local/share/cursor-agent/versions/2026.05/node" }, { "agent" }), true)
check("unrelated agent binary is not cursor-agent",
  M.is_app("cursor-agent", { name = "agent" }, { "agent", "--port", "8080" }), false)
check("not claude", M.is_app("claude", "node", { "node", "server.js" }), false)

-- Commands that reopen a chat
local function cmd(pane, accepts) return M.join(M.resume_argv(pane, accepts or new_fx)) end
check("fx keeps real options, drops relaunch internals",
  cmd({ app = "fx", id = "ID1", store = "v2",
        argv = { "fx", "resume", "OLD", "--upgrade-relaunch", "abc123", "--model", "m1", "--fast" } }),
  "fx --model m1 --fast --resume ID1")
check("fx drops --sessions-v2 when unsupported",
  cmd({ app = "fx", id = "ID2", store = "v2", argv = { "fx", "--sessions-v2", "--resume", "ID2" } }),
  "fx --resume ID2")
check("older fx keeps --sessions-v2",
  cmd({ app = "fx", id = "ID3", store = "v2", argv = { "fx" } }, old_fx),
  "fx --sessions-v2 --resume ID3")
check("fx missing dev build falls back to fx",
  cmd({ app = "fx", id = "ID4", argv = { "/nonexistent/zig-out/bin/fx" } }), "fx --resume ID4")
check("fx option=value",
  cmd({ app = "fx", id = "ID5", argv = { "fx", "--effort=high", "-r", "OLD" } }), "fx --effort=high --resume ID5")
check("claude keeps permission mode",
  cmd({ app = "claude", id = uuid,
        argv = { "node", "/usr/local/bin/claude", "--permission-mode", "plan", "--verbose" } }),
  "claude --permission-mode plan --resume " .. uuid)
check("codex resume with model",
  cmd({ app = "codex", id = uuid, argv = { "codex", "-m", "gpt-5", "--full-auto" } }),
  "codex resume -m gpt-5 " .. uuid)
check("codex --yolo kept on resume",
  cmd({ app = "codex", id = uuid, argv = { "codex", "--yolo" } }),
  "codex resume --yolo " .. uuid)
check("pi resume keeps model and thinking, drops old --continue",
  cmd({ app = "pi", id = pi_id, session_file = pi_file,
        argv = { "pi", "-c", "--model", "zhipu/glm-5.3", "--thinking", "max", "--verbose" } }),
  "pi --model zhipu/glm-5.3 --thinking max --verbose --session " .. pi_id)
check("pi custom session file outside ~/.pi/agent/sessions uses path",
  cmd({ app = "pi", id = pi_id, session_file = "/tmp/custom/session_" .. pi_id .. ".jsonl",
        argv = { "pi" } }),
  "pi --session /tmp/custom/session_" .. pi_id .. ".jsonl")
check("agy resume keeps model, effort, mode, sandbox",
  cmd({ app = "agy", id = agy_main,
        argv = { "agy", "-c", "--model", "gemini-4", "--effort", "high", "--mode", "auto", "--sandbox" } }),
  "agy --model gemini-4 --effort high --mode auto --sandbox --conversation " .. agy_main)
check("droid resume keeps --auto and --use-spec, drops bare resume subcmd",
  cmd({ app = "droid", id = droid_id,
        argv = { "droid", "resume", "--auto", "high", "--use-spec" } }),
  "droid --auto high --use-spec --resume " .. droid_id)
check("cursor-agent preserves agent alias and kept options, strips secrets",
  cmd({ app = "cursor-agent", id = cur_id,
        argv = { "agent", "--model", "opus", "--yolo", "--api-key", "secret123",
                 "-H", "Authorization: Bearer tok", "--header=X-Token: abc" } }),
  "agent --model opus --yolo --resume " .. cur_id)
check("cursor-agent missing path preserves basename alias",
  cmd({ app = "cursor-agent", id = cur_id,
        argv = { "/nonexistent/bin/agent", "--plan" } }),
  "agent --plan --resume " .. cur_id)
check("cursor-agent -w with value and without value",
  cmd({ app = "cursor-agent", id = cur_id,
        argv = { "cursor-agent", "-w", "feat-x", "--worktree", "--yolo" } }),
  "cursor-agent -w feat-x --worktree --yolo --resume " .. cur_id)
check("cursor-agent --worktree=val and bare --worktree before resume",
  cmd({ app = "cursor-agent", id = cur_id,
        argv = { "agent", "--worktree=feat-y", "--worktree", "resume", cur_id } }),
  "agent --worktree=feat-y --worktree --resume " .. cur_id)
check("quote spaces", M.join({ "cd", "/a b/it's" }), "cd '/a b/it'\\''s'")

-- Block record from Pi extension (verified by PID, recovers flags hidden by process.title)
local tmp_state = "/tmp/rex-durable-unit-" .. tostring(os.time())
rex.exec({ "mkdir", "-p", tmp_state .. "/blocks" })
local blk = "block:01a1ec5d-test"
local f = assert(io.open(M.block_file(blk, tmp_state), "wb"))
f:write(rex.json.encode({
  block_id = blk, app = "pi", pid = 90000010, id = pi_id, session_file = pi_file,
  argv = { "pi", "--model", "sonnet:high", "--thinking", "max" }, ephemeral = false,
}))
f:close()
local pi_proc = {
  foreground = { pid = 90000010, name = "pi", cwd = "/w" },
  ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" } },
}
local pi_desc = M.describe(pi_proc, {
  ps = { [90000010] = { age = 20, args = "pi" } }, files = {}, now = os.time(), state_dir = tmp_state,
}, blk)
check("pi block record recovers id and CLI flags when ps args only shows pi",
  { pi_desc.kind, pi_desc.app, pi_desc.id, cmd(pi_desc) },
  { "chat", "pi", pi_id, "pi --model sonnet:high --thinking max --session " .. pi_id })
local stale_desc = M.describe({
  foreground = { pid = 90000011, name = "pi", cwd = "/w" },
  ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" } },
}, { ps = { [90000011] = { age = 5, args = "pi" } }, files = {}, now = os.time(), state_dir = tmp_state }, blk)
check("stale block record with mismatched PID is ignored", stale_desc.id, nil)

local cur_blk = "block:01a1ec5d-cursor"
local cf = assert(io.open(M.block_file(cur_blk, tmp_state), "wb"))
cf:write(rex.json.encode({
  block_id = cur_blk, app = "cursor-agent", pid = 90000020, id = cur_id,
  session_file = cur_base .. cur_id .. "/store.db",
}))
cf:close()
local cur_alias_desc = M.describe({
  foreground = { pid = 90000020, name = "agent", cwd = "/w" },
  ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" } },
}, {
  ps = { [90000020] = { age = 10, args = "agent --model opus --api-key sk-secret" } },
  files = {}, now = os.time(), state_dir = tmp_state,
}, cur_blk)
check("agent corroborated by block record strips --api-key and resumes as agent",
  { cur_alias_desc.kind, cur_alias_desc.app, cur_alias_desc.id, cur_alias_desc.argv, cmd(cur_alias_desc) },
  { "chat", "cursor-agent", cur_id, { "agent", "--model", "opus" }, "agent --model opus --resume " .. cur_id })

local cur_wrap_desc = M.describe({
  foreground = { pid = 90000021, name = "agent", cwd = "/w" },
  ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" } },
}, {
  ps = { [90000021] = { age = 10, args = "agent --use-system-ca /opt/cursor-agent/versions/1/index.js --api-key=secret -H Authorization:Bearer --header=X-Auth:tok --workspace /tmp/worker" } },
  files = { [90000021] = { cur_base .. cur_id .. "/store.db" } }, now = os.time(),
})
check("cursor-agent wrapper strips internal args and secrets while --workspace /tmp/worker stays a chat",
  { cur_wrap_desc.kind, cur_wrap_desc.app, cur_wrap_desc.id, cur_wrap_desc.argv },
  { "chat", "cursor-agent", cur_id, { "agent", "--workspace", "/tmp/worker" } })

local cur_print_desc = M.describe({
  foreground = { pid = 90000022, name = "cursor-agent", cwd = "/w" },
  ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" } },
}, {
  ps = { [90000022] = { age = 10, args = "cursor-agent -p hello" } },
  files = {}, now = os.time(),
})
check("cursor-agent -p is treated as non-chat program",
  { cur_print_desc.kind, cur_print_desc.argv }, { "program", { "cursor-agent", "-p", "hello" } })

local cur_worker_desc = M.describe({
  foreground = { pid = 90000023, name = "cursor-agent", cwd = "/w" },
  ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" } },
}, {
  ps = { [90000023] = { age = 10, args = "cursor-agent worker" } },
  files = {}, now = os.time(),
})
check("cursor-agent worker subcommand is treated as non-chat program",
  { cur_worker_desc.kind, cur_worker_desc.argv }, { "program", { "cursor-agent", "worker" } })

local other_agent_desc = M.describe({
  foreground = { pid = 90000024, name = "agent", cwd = "/w" },
  ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" } },
}, {
  ps = { [90000024] = { age = 10, args = "agent --port 8080" } },
  files = {}, now = os.time(),
})
check("unrelated agent binary without corroboration is saved as program",
  { other_agent_desc.kind, other_agent_desc.argv }, { "program", { "agent", "--port", "8080" } })

rex.exec({ "rm", "-rf", tmp_state })

local sum_snap = { sessions = { { label = "work", windows = {
  { layout = { split = { direction = "horizontal", ratio = 0.5,
    before = { pane = { kind = "chat", app = "pi", id = pi_id } },
    after = { pane = { kind = "chat", app = "agy", id = agy_main } } } } },
  { layout = { pane = { kind = "chat", app = "cursor-agent", id = cur_id } } },
} } } }
check("summary lists pi, agy, and cursor-agent", (M.summary(sum_snap)),
  "1 sessions, 2 tabs, 3 chats (1 pi, 1 agy, 1 cursor-agent), 0 other programs")

-- What a tab runs (process IDs above any real pid_max, so /proc never answers)
local proc = {
  foreground = { pid = 90000003, name = "fx", cwd = "/w" },
  ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" }, { pid = 90000001, name = "login" } },
}
local info = {
  ps = { [90000003] = { age = 10, args = "fx --resume ID9" } },
  files = { [90000003] = { HOME .. "/.fx/sessions/v2/ID9/lock" } },
  now = os.time(),
}
local pane = M.describe(proc, info)
check("describe fx chat", { pane.kind, pane.app, pane.id, pane.cwd }, { "chat", "fx", "ID9", "/w" })
local agy_pane = M.describe(
  { foreground = { pid = 90000008, name = "agy", cwd = "/w" },
    ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" } } },
  { ps = { [90000008] = { age = 15, args = "agy --effort high" } },
    files = { [90000008] = { agy_base .. "brain/" .. agy_main } }, now = os.time() })
check("describe agy chat", { agy_pane.kind, agy_pane.app, agy_pane.id, cmd(agy_pane) },
  { "chat", "agy", agy_main, "agy --effort high --conversation " .. agy_main })
pane = M.describe({ foreground = { pid = 90000002, name = "-zsh", cwd = "/w" } }, { ps = {}, files = {}, now = 0 })
check("describe shell", { pane.kind, pane.cwd }, { "shell", "/w" })
pane = M.describe({ foreground = { pid = 90000005, name = "sleep", cwd = "/w" },
                    ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" } } },
                  { ps = { [90000005] = { age = 1, args = "sleep 4242" } }, files = {}, now = 0 })
check("describe program", { pane.kind, pane.argv }, { "program", { "sleep", "4242" } })
pane = M.describe({ foreground = { pid = 90000007, name = "bash", cwd = "/w" },
                    ancestors = { { pid = 90000006, name = "claude", cwd = "/w" }, { pid = 90000002, name = "zsh" } } },
                  { ps = { [90000006] = { age = 1, args = "claude --resume " .. uuid }, [90000007] = { age = 1, args = "bash -c ls" } },
                    files = {}, now = 0 })
check("describe claude running a tool", { pane.kind, pane.app, pane.id }, { "chat", "claude", uuid })

-- Blank sessions
local function shell_session(cwd)
  return { windows = { { layout = { pane = { kind = "shell", cwd = cwd } } } } }
end
check("default session", M.is_default_session(shell_session(HOME)), true)
check("not default elsewhere", M.is_default_session(shell_session("/w")), false)
check("blank server", M.is_blank({ sessions = { shell_session(HOME) } }), true)

-- Matching saved tabs to the tabs Rex restored
local function leaf(p) return { pane = p } end
local saved = { sessions = {
  { session_id = "s1", label = "work", windows = {
    { layout = { split = { direction = "horizontal", ratio = 0.5,
      before = leaf({ block_id = "b1", kind = "chat", app = "fx", id = "A", store = "v2", argv = { "fx" }, cwd = "/w" }),
      after = leaf({ block_id = "b2", kind = "program", argv = { "sleep", "4242" }, cwd = "/w" }) } } },
    { layout = leaf({ block_id = "b3", kind = "chat", app = "fx", id = "B", store = "v2", argv = { "fx" }, cwd = "/w" }) },
    { layout = leaf({ block_id = "b4", kind = "chat", app = "fx", id = "C", store = "v2", argv = { "fx" }, cwd = "/w" }) },
    { layout = leaf({ block_id = "b5", kind = "chat", app = "agy", id = agy_main, argv = { "agy" }, cwd = "/other" }) },
  } },
  { session_id = "gone", label = "renamed-elsewhere", windows = {
    { layout = leaf({ block_id = "x1", kind = "chat", app = "pi", id = pi_id, argv = { "pi" }, cwd = "/w" }) },
  } },
} }
local live = { sessions = {
  { session_id = "s1", label = "work", windows = {
    { layout = { split = { direction = "horizontal", ratio = 0.5,
      before = leaf({ block_id = "b1", kind = "shell", cwd = "/w" }),
      after = leaf({ block_id = "b2", kind = "shell", cwd = "/w" }) } } },
    { layout = leaf({ block_id = "b3", kind = "program", argv = { "vim" }, cwd = "/w" }) },
    { layout = leaf({ block_id = "b4", kind = "shell", cwd = "/w" }) },
    { layout = leaf({ block_id = "b5", kind = "shell", cwd = "/w" }) },
  } },
  { session_id = "new-id", label = "renamed-elsewhere", windows = {
    { layout = leaf({ block_id = "y1", kind = "shell", cwd = "/w" }) },
  } },
} }
local opts = { dir_exists = function() return true end }
local function plan(open, extra)
  for k, v in pairs(extra or {}) do opts[k] = v end
  local writes, notes = M.plan_reopen(saved, live, open or {}, opts)
  local out = {}
  for _, w in ipairs(writes) do out[#out + 1] = w.block_id .. "=" .. w.data end
  return out, notes
end
local real_exec = rex.exec
rex.exec = function(argv, o)
  if argv[2] == "--help" then return { ok = true, code = 0, stdout = "-r, --resume [last|<id>]", stderr = "" } end
  return real_exec(argv, o)
end
local writes, notes = plan({ ["fx:C"] = true })
check("reopen plan", writes, {
  "b1=fx --resume A\n",
  "b2=sleep 4242",
  "b5=cd /other && agy --conversation " .. agy_main .. "\n",
  "y1=pi --session " .. pi_id .. "\n",
})
check("reopen notes", notes, {
  "work tab 2: the tab is busy, left alone",
  "work tab 3: fx chat C is already open",
})
writes = plan({}, { programs = false })
check("programs=false only reopens chats", #writes, 4)
live.sessions[1].windows[1].layout.split.before.pane = { block_id = "b1", kind = "chat", app = "fx", id = "A" }
writes = plan({}, { programs = true })
check("a chat already in its tab is left alone", writes[1], "b2=sleep 4242")
live.sessions[1].windows[1].layout.split.after.pane = { block_id = "b2", kind = "program", argv = { "sleep", "4242" } }
writes, notes = plan({})
check("a program still running in its tab is left alone quietly",
  { writes[1], notes }, { "b4=fx --resume C\n", { "work tab 2: the tab is busy, left alone" } })
rex.exec = real_exec

-- Closed-tab diffing, pruning, and tab order restoration
local function make_snap(instance, sessions)
  return { server = { instance_id = instance }, sessions = sessions }
end
local function win(wid, pane_or_layout, label)
  local layout = pane_or_layout.split and pane_or_layout or { pane = pane_or_layout }
  return { window_id = wid, label = label, layout = layout }
end

local base_snap = make_snap("inst-1", {
  { session_id = "s1", label = "work", windows = {
    win("w1", { block_id = "b1", kind = "chat", app = "fx", id = "FX1", cwd = "/w" }),
    win("w2", { block_id = "b2", kind = "chat", app = "claude", id = uuid, cwd = "/w" }, "claude-tab"),
    win("w3", { block_id = "b3", kind = "chat", app = "pi", id = pi_id, cwd = "/w" }),
  } },
  { session_id = "s2", label = "side", windows = {
    win("w4", { block_id = "b4", kind = "chat", app = "agy", id = agy_main, cwd = "/w" }),
  } },
})

local one_tab_closed = make_snap("inst-1", {
  { session_id = "s1", label = "work", windows = {
    win("w1", { block_id = "b1", kind = "chat", app = "fx", id = "FX1", cwd = "/w" }),
    win("w3", { block_id = "b3", kind = "chat", app = "pi", id = pi_id, cwd = "/w" }),
  } },
  { session_id = "s2", label = "side", windows = {
    win("w4", { block_id = "b4", kind = "chat", app = "agy", id = agy_main, cwd = "/w" }),
  } },
})
local d_one = M.diff_closed(base_snap, one_tab_closed, 1000)
check("diff_closed: single closed tab records window, index, order, and chat id",
  { #d_one, d_one[1].kind, d_one[1].session_id, d_one[1].window_id, d_one[1].window_index,
    d_one[1].window_order, d_one[1].window.layout.pane.id },
  { 1, "window", "s1", "w2", 2, { "w1", "w2", "w3" }, uuid })

local whole_session_closed = make_snap("inst-1", {
  { session_id = "s1", label = "work", windows = {
    win("w1", { block_id = "b1", kind = "chat", app = "fx", id = "FX1", cwd = "/w" }),
    win("w2", { block_id = "b2", kind = "chat", app = "claude", id = uuid, cwd = "/w" }, "claude-tab"),
    win("w3", { block_id = "b3", kind = "chat", app = "pi", id = pi_id, cwd = "/w" }),
  } },
})
local d_sess = M.diff_closed(base_snap, whole_session_closed, 1000)
check("diff_closed: closing entire session records kind=session with its windows",
  { #d_sess, d_sess[1].kind, d_sess[1].session_id, d_sess[1].session_label, #d_sess[1].session.windows,
    d_sess[1].session.windows[1].layout.pane.id },
  { 1, "session", "s2", "side", 1, agy_main })

local restarted = make_snap("inst-2", {
  { session_id = "s1", label = "work", windows = {
    win("w1", { block_id = "b1", kind = "chat", app = "fx", id = "FX1", cwd = "/w" }),
  } },
})
check("diff_closed: different server instance records nothing", #M.diff_closed(base_snap, restarted, 1000), 0)
check("diff_closed: nil before records nothing", #M.diff_closed(nil, one_tab_closed, 1000), 0)

local all_gone = make_snap("inst-1", {})
check("diff_closed: all tabs disappearing at once records nothing (server exit guard)",
  #M.diff_closed(base_snap, all_gone, 1000), 0)

local big_before = make_snap("inst-1", {
  { session_id = "s1", label = "work", windows = {
    win("w1", { block_id = "b1", kind = "chat", app = "fx", id = "C1", cwd = "/w" }),
    win("w2", { block_id = "b2", kind = "chat", app = "fx", id = "C2", cwd = "/w" }),
    win("w3", { block_id = "b3", kind = "chat", app = "fx", id = "C3", cwd = "/w" }),
    win("w4", { block_id = "b4", kind = "chat", app = "fx", id = "C4", cwd = "/w" }),
    win("w5", { block_id = "b5", kind = "chat", app = "fx", id = "C5", cwd = "/w" }),
  } },
})
local big_after = make_snap("inst-1", {
  { session_id = "s1", label = "work", windows = {
    win("w1", { block_id = "b1", kind = "chat", app = "fx", id = "C1", cwd = "/w" }),
  } },
})
local d_big = M.diff_closed(big_before, big_after, 1000)
check("diff_closed: big_drop still pushes all closed tabs",
  { M.big_drop(big_before, big_after), #d_big, d_big[1].window_id, d_big[4].window_id },
  { true, 4, "w2", "w5" })

local multi_closed = make_snap("inst-1", {
  { session_id = "s1", label = "work", windows = {
    win("w3", { block_id = "b3", kind = "chat", app = "pi", id = pi_id, cwd = "/w" }),
  } },
  { session_id = "s2", label = "side", windows = {
    win("w4", { block_id = "b4", kind = "chat", app = "agy", id = agy_main, cwd = "/w" }),
  } },
})
local d_multi = M.diff_closed(base_snap, multi_closed, 1000)
check("diff_closed: simultaneous close records all vanished tabs in order",
  { #d_multi, d_multi[1].window_id, d_multi[2].window_id }, { 2, "w1", "w2" })

check("insert_window_order: restores middle tab to original slot",
  M.insert_window_order({ "w1", "w3", "w2_new" }, "w2_new", { "w1", "w2", "w3" }, "w2", 2),
  { "w1", "w2_new", "w3" })
check("insert_window_order: restores two simultaneously closed leading tabs in order",
  M.insert_window_order({ "w2_new", "w3", "w1_new" }, "w1_new", { "w1", "w2", "w3" }, "w1", 1),
  { "w1_new", "w2_new", "w3" })
check("insert_window_order: respects prepended new tab when restoring middle tab",
  M.insert_window_order({ "w0", "w1", "w3", "w2_new" }, "w2_new", { "w1", "w2", "w3" }, "w2", 2),
  { "w0", "w1", "w2_new", "w3" })

local stack = {}
for i = 1, 25 do
  stack[i] = { kind = "window", window_id = "w" .. i, closed_ts = 100000 + i }
end
stack[1].closed_ts = 100 -- expired (> 24h before 100100)
local pruned = M.prune_closed_tabs(stack, 100100, 20, 86400)
check("prune_closed_tabs: caps to 20 newest and drops expired entries",
  { #pruned, pruned[1].window_id, pruned[20].window_id }, { 20, "w6", "w25" })
local all_old = { { kind = "window", window_id = "old", closed_ts = 1000 } }
check("prune_closed_tabs: drops entries older than 24h", #M.prune_closed_tabs(all_old, 1000 + 86401, 20, 86400), 0)

local moved_pane = make_snap("inst-1", {
  { session_id = "s1", label = "work", windows = {
    win("w1", { split = { direction = "horizontal", ratio = 0.5,
      before = leaf({ block_id = "b1", kind = "chat", app = "fx", id = "FX1", cwd = "/w" }),
      after = leaf({ block_id = "b2", kind = "chat", app = "claude", id = uuid, cwd = "/w" }) } }),
    win("w3", { block_id = "b3", kind = "chat", app = "pi", id = pi_id, cwd = "/w" }),
  } },
  { session_id = "s2", label = "side", windows = {
    win("w4", { block_id = "b4", kind = "chat", app = "agy", id = agy_main, cwd = "/w" }),
  } },
})
check("diff_closed: moving a tab's pane into another tab is not recorded as closed",
  #M.diff_closed(base_snap, moved_pane, 1000), 0)

local lock_dir = "/tmp/rex-durable-lock-unit-" .. tostring(os.time())
rex.exec({ "mkdir", "-p", lock_dir })
local stack_file = lock_dir .. "/closed_tabs.json"
M.append_closed_tabs({
  { kind = "window", window_id = "w1", closed_ts = 1000 },
  { kind = "window", window_id = "w2", closed_ts = 1001 },
}, 1002, stack_file)
local popped1, rem1 = M.pop_closed_tab(1002, stack_file)
check("pop_closed_tab: removes top entry immediately", { popped1.window_id, rem1 }, { "w2", 1 })
-- Simulate watcher appending a newly closed tab while restore is in flight, then restore failing
M.append_closed_tabs({ { kind = "window", window_id = "w3", closed_ts = 1003 } }, 1003, stack_file)
local count_after_push = M.push_closed_tab(popped1, 1004, stack_file)
check("push_closed_tab: restores failed entry without clobbering concurrent appends", count_after_push, 3)
local p_top = M.pop_closed_tab(1004, stack_file)
local p_mid = M.pop_closed_tab(1004, stack_file)
local p_bot = M.pop_closed_tab(1004, stack_file)
local p_empty, rem_empty = M.pop_closed_tab(1004, stack_file)
check("pop_closed_tab: sequential pops drain stack cleanly",
  { p_top.window_id, p_mid.window_id, p_bot.window_id, p_empty, rem_empty },
  { "w2", "w3", "w1", nil, 0 })

-- Lock timeout errors instead of proceeding unlocked, and leaves existing stack untouched
M.append_closed_tabs({ { kind = "window", window_id = "w_locked", closed_ts = os.time() } }, os.time(), stack_file)
rex.exec({ "mkdir", stack_file .. ".lock" })
local ts_f = assert(io.open(stack_file .. ".lock/ts", "wb"))
ts_f:write(tostring(os.time()))
ts_f:close()
local lock_ok, lock_err = pcall(M.pop_closed_tab, os.time(), stack_file, 0)
check("pop_closed_tab: errors when lock cannot be acquired in time",
  { lock_ok, tostring(lock_err):find("timed out waiting for closed_tabs lock", 1, true) ~= nil },
  { false, true })
rex.exec({ "rm", "-rf", stack_file .. ".lock" })
local after_unlock = M.pop_closed_tab(os.time(), stack_file, 0)
check("pop_closed_tab: stack intact after failed lock attempt", after_unlock.window_id, "w_locked")
rex.exec({ "rm", "-rf", lock_dir })

-- refresh_closed: a chat saved as "conversation unknown" is resolved again when its tab closes
local function unknown_pane(bid, cwd)
  return { kind = "program", argv = { "codex" }, block_id = bid, cwd = cwd,
           note = "conversation unknown", pending_app = "codex", started_at = 100 }
end
local function closed_win(p) return { kind = "window", window = { layout = { pane = p } } } end
local function live_snap(panes)
  local layout
  for _, p in ipairs(panes) do
    layout = layout and { split = { before = layout, after = { pane = p } } } or { pane = p }
  end
  return { sessions = { { windows = layout and { { layout = layout } } or {} } } }
end
local asked = {}
local function late(p) asked[#asked + 1] = p; return "CODEX1", "/f/rollout-CODEX1.jsonl" end

local rc = M.refresh_closed({ closed_win(unknown_pane("b1", "/w")) }, live_snap({}), late)
local rp = rc[1].window.layout.pane
check("refresh_closed: upgrades unknown codex pane to a resumable chat",
  { rp.kind, rp.app, rp.id, rp.session_file, rp.note, rp.pending_app, asked[1].started_at },
  { "chat", "codex", "CODEX1", "/f/rollout-CODEX1.jsonl", nil, nil, 100 })
check("refresh_closed: upgraded pane resumes with codex resume <id>", M.resume_argv(rp), { "codex", "resume", "CODEX1" })

rc = M.refresh_closed({ closed_win(unknown_pane("b1", "/w")) },
  live_snap({ unknown_pane("b2", "/w") }), late)
check("refresh_closed: skips when another unknown codex is still live in the same folder",
  rc[1].window.layout.pane.kind, "program")

rc = M.refresh_closed({ closed_win(unknown_pane("b1", "/w")) },
  live_snap({ { kind = "chat", app = "codex", id = "CODEX1", cwd = "/w" } }), late)
check("refresh_closed: never claims a session a live pane already owns",
  rc[1].window.layout.pane.kind, "program")

rc = M.refresh_closed({ closed_win(unknown_pane("b1", "/w")), closed_win(unknown_pane("b3", "/w")) },
  live_snap({}), late)
check("refresh_closed: skips two closed unknown panes sharing app and folder",
  { rc[1].window.layout.pane.kind, rc[2].window.layout.pane.kind }, { "program", "program" })

rc = M.refresh_closed({ closed_win(unknown_pane("b1", "/w")) }, live_snap({}), function() return nil end)
check("refresh_closed: leaves pane unchanged when no session file exists yet",
  { rc[1].window.layout.pane.kind, rc[1].window.layout.pane.pending_app }, { "program", "codex" })

rc = M.refresh_closed({ { kind = "session", session = { windows = { { layout = { pane = unknown_pane("b1", "/w") } } } } } },
  live_snap({}), late)
check("refresh_closed: also upgrades panes inside a closed session",
  rc[1].session.windows[1].layout.pane.id, "CODEX1")

check("is_background_holder: codex app-server daemon holds rollouts for exited chats",
  { M.is_background_holder("/Users/me/.codex/packages/app-server-daemon/releases/0.171.0/bin/codex app-server --listen unix:// --managed-daemon"),
    M.is_background_holder("codex resume 01a1fc80-fd6e-75d2-95da-a87ee582a601"),
    M.is_background_holder("codex"), M.is_background_holder(nil) },
  { true, false, false, false })

print(string.format("%d passed, %d failed", stats.passed, stats.failed))
if stats.failed > 0 then rex.stop(1) end
