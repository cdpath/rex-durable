-- Unit tests for durable.lua. They run in Rex's own Lua and only read/use temp state:
--
--   rex do test/unit.lua root="$PWD"     (from the repository root)
--
-- test/e2e.sh runs them for you.

REX_DURABLE_LIB = true
local here = rex.args.root or (debug.getinfo(1, "S").source:match("^@(.*)/test/[^/]*$")) or "."
local M = dofile(here .. "/durable.lua")
local HOME = os.getenv("HOME")

local passed, failed = 0, 0

local function show(v)
  if type(v) == "table" then return rex.json.encode(v) end
  return tostring(v)
end

local function check(name, got, want)
  if show(got) == show(want) then
    passed = passed + 1
  else
    failed = failed + 1
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
rex.exec({ "rm", "-rf", tmp_state })

-- Summary includes pi and agy
local sum_snap = { sessions = { { label = "work", windows = {
  { layout = { split = { direction = "horizontal", ratio = 0.5,
    before = { pane = { kind = "chat", app = "pi", id = pi_id } },
    after = { pane = { kind = "chat", app = "agy", id = agy_main } } } } },
} } } }
check("summary lists pi and agy", (M.summary(sum_snap)),
  "1 sessions, 1 tabs, 2 chats (1 pi, 1 agy), 0 other programs")

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

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then rex.stop(1) end
