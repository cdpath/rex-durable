--[[
rex-durable: keep the agent sessions and programs in your Rex tabs across
server restarts and reboots.

Built with Rex native best practices:
  * Single in-process `rex do --all` watcher subscribing to `terminal.process_changed`,
    `terminal.program_status_changed`, and `session_view_changed` with burst debouncing.
  * Uses `session.attach_all` (avoiding `client_connected` spam in `session.list_clients`),
    `com.superlogical.terminal.process` (`script`, `invoked_path`, `argv0`),
    `com.superlogical.terminal.modes` (`screen ~= "alternate"` guard), and `rex.layout.*`.
  * Preserves window focus (`w.focused_block_id`), zoomed panes (`w.zoomed_block_id`),
    and custom block labels (`b.label`).
  * First-class `rex.action` definitions (`durable_status`, `durable_save`,
    `durable_reopen`, `durable_repair`, `durable_undo_close`, `durable_checkpoint`,
    `durable_rebuild`) with typed schemas and structured JSON results (`json=true`).

Supported coding agents (auto-resumed on their exact conversation):
  * Antigravity CLI (`agy --conversation <id>`)
  * Pi coding agent (`pi --session <id>`)
  * Factory Droid (`droid --resume <id>`)
  * Cursor Agent (`cursor-agent --resume <id>` / `agent --resume <id>`)
  * Claude Code (`claude --resume <id>`)
  * Codex (`codex resume <id>`)
  * fx (`fx --resume <id>`)

MIT License — based on https://github.com/fazxes/rex-durable, redesigned for
idiomatic Rex APIs with Pi, Antigravity CLI, Factory Droid, and Cursor Agent support.
]]

local M = {}
M.VERSION = "0.6.0"

local TERMINAL = "com.superlogical.terminal"
local SHELL_FLAVOR = "com.superlogical.terminal.shell"
local SAVE_EVERY = 30         -- periodic safety poll in seconds while watching
local DEBOUNCE_WAIT = 2       -- trailing debounce seconds after event bursts
local MAX_DEBOUNCE_WAIT = 8   -- max seconds to defer save during continuous events
local KEEP_SNAPSHOTS = 10     -- saves kept, one per server instance
local MAX_AGE_DAYS = 30       -- older saves are never restored on their own
local TYPE_DELAY = 0.35       -- seconds between reopened programs
local SETTLE_TRIES = 10       -- tries while restored tabs finish starting their shells
local SETTLE_WAIT = 3         -- seconds between those tries
local HISTORY_EVERY = 600     -- seconds between copies kept in history/
local HISTORY_KEEP = 144      -- copies kept: 24 hours
local DROP_MIN = 3            -- a big drop loses at least this many tabs or chats...
local DROP_KEEP = 0.6         -- ...and keeps at most this fraction of them
local AUTO_PREFIX = "auto-before-drop-"
local AUTO_KEEP = 10          -- automatic checkpoints kept
local CLOSED_TABS_MAX = 20    -- recently closed tabs/sessions kept for undo
local CLOSED_TABS_MAX_AGE = 86400 -- 24 hours in seconds

local SHELLS = {
  bash = true, csh = true, dash = true, elvish = true, fish = true, ksh = true,
  nu = true, sh = true, tcsh = true, xonsh = true, zsh = true,
}

M.APPS = { "fx", "claude", "codex", "pi", "agy", "droid", "cursor-agent" }

-- Options each chat program keeps when it reopens. Anything else on the
-- original command line, such as an internal relaunch flag or old resume ID,
-- is dropped.
M.CHATS = {
  fx = {
    values = { ["--model"] = true, ["--effort"] = true, ["--provider"] = true,
               ["--add-dir"] = true, ["--context-limit"] = true },
    switches = { ["--fast"] = true, ["--no-fast"] = true, ["--ultrafast"] = true,
                 ["--no-ultrafast"] = true, ["--no-additional-dirs"] = true,
                 ["--sessions-v2"] = true },
  },
  claude = {
    values = { ["--model"] = true, ["--permission-mode"] = true, ["--add-dir"] = true,
               ["--settings"] = true, ["--agent"] = true },
    switches = { ["--dangerously-skip-permissions"] = true },
  },
  codex = {
    values = { ["-m"] = true, ["--model"] = true, ["-p"] = true, ["--profile"] = true,
               ["-s"] = true, ["--sandbox"] = true, ["-a"] = true,
               ["--ask-for-approval"] = true, ["--add-dir"] = true, ["-c"] = true,
               ["--config"] = true },
    switches = { ["--dangerously-bypass-approvals-and-sandbox"] = true,
                 ["--yolo"] = true, ["--search"] = true, ["--oss"] = true },
  },
  pi = {
    values = { ["--provider"] = true, ["--model"] = true, ["--models"] = true,
               ["--thinking"] = true, ["--mode"] = true, ["--session-dir"] = true,
               ["--tools"] = true, ["-t"] = true, ["--exclude-tools"] = true, ["-xt"] = true,
               ["--extension"] = true, ["-e"] = true, ["--skill"] = true,
               ["--prompt-template"] = true, ["--theme"] = true, ["--use-theme"] = true,
               ["--tui-mode"] = true, ["--system-prompt"] = true,
               ["--append-system-prompt"] = true },
    switches = { ["--no-tools"] = true, ["-nt"] = true, ["--no-builtin-tools"] = true,
                 ["-nbt"] = true, ["--no-extensions"] = true, ["-ne"] = true,
                 ["--no-mcp"] = true, ["--no-skills"] = true, ["-ns"] = true,
                 ["--no-prompt-templates"] = true, ["-np"] = true, ["--no-themes"] = true,
                 ["--no-context-files"] = true, ["-nc"] = true, ["--verbose"] = true,
                 ["--approve"] = true, ["-a"] = true, ["--no-approve"] = true,
                 ["-na"] = true, ["--offline"] = true },
  },
  agy = {
    values = { ["--model"] = true, ["--effort"] = true, ["--mode"] = true, ["--agent"] = true,
               ["--add-dir"] = true, ["--project"] = true, ["--settings"] = true,
               ["--log-file"] = true },
    switches = { ["--dangerously-skip-permissions"] = true, ["--sandbox"] = true,
                 ["--remote-agent"] = true, ["--remote-control"] = true },
  },
  droid = {
    values = { ["--settings"] = true, ["--append-system-prompt"] = true,
               ["--append-system-prompt-file"] = true, ["--cwd"] = true,
               ["-w"] = true, ["--worktree"] = true, ["--auto"] = true },
    switches = { ["--use-spec"] = true, ["--disable-builtin-skills"] = true },
  },
  ["cursor-agent"] = {
    aliases = { agent = true },
    values = {
      ["--model"] = true, ["--mode"] = true, ["--sandbox"] = true,
      ["--workspace"] = true, ["--add-dir"] = true, ["--plugin-dir"] = true,
      ["--worktree-base"] = true, ["-e"] = true, ["--endpoint"] = true,
    },
    optional_values = {
      ["-w"] = true, ["--worktree"] = true,
    },
    switches = {
      ["--plan"] = true, ["-f"] = true, ["--force"] = true, ["--yolo"] = true,
      ["--auto-review"] = true, ["--approve-mcps"] = true, ["--trust"] = true,
      ["--skip-worktree-setup"] = true,
    },
    non_chat_flags = {
      ["-p"] = true, ["--print"] = true, ["--output-format"] = true,
      ["--stream-partial-output"] = true, ["--list-models"] = true,
      ["--help"] = true, ["-h"] = true, ["--version"] = true, ["-v"] = true,
    },
    non_chat_subcommands = {
      login = true, logout = true, mcp = true, plugin = true, worker = true,
      status = true, whoami = true, models = true, team = true, bedrock = true,
      about = true, update = true, ["create-chat"] = true, ls = true, help = true,
    },
    secret_values = {
      ["--api-key"] = true, ["-H"] = true, ["--header"] = true,
    },
  },
}

local UUID = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

local args = rex.args or {}
local HOME = os.getenv("HOME") or ""
local JSON_MODE = args.json == true

---------------------------------------------------------------------------
-- Small helpers

local function stamp() return os.date("%Y-%m-%d %H:%M:%S") end
local function now_iso() return os.date("!%Y-%m-%dT%H:%M:%SZ") end

local function log(message)
  if JSON_MODE then return end
  print(stamp() .. " " .. tostring(message))
  io.flush()
end

local function emit_text(message)
  if JSON_MODE then return end
  print(message)
  io.flush()
end

local function basename(path)
  return tostring(path or ""):match("([^/]+)/*$") or ""
end

local function list(t) return type(t) == "table" and t or {} end

function M.quote(word)
  word = tostring(word)
  if word ~= "" and word:match("^[%w@%%+=:,%./_%-]+$") then return word end
  local escaped = word:gsub("'", "'\\''")
  return "'" .. escaped .. "'"
end

function M.join(argv)
  local out = {}
  for i, word in ipairs(argv) do out[i] = M.quote(word) end
  return table.concat(out, " ")
end

local function run(argv, opts)
  return rex.exec(argv, opts)  -- nil only when the program could not start
end

local function stdout_of(argv, opts)
  local r = run(argv, opts)
  return r and r.stdout or ""
end

local function lines(text)
  local out = {}
  for line in (text or ""):gmatch("[^\n]+") do out[#out + 1] = line end
  return out
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function write_file(path, data)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return os.rename(tmp, path)
end

local function read_json(path)
  local text = read_file(path)
  if not text then return nil end
  local ok, decoded = pcall(rex.json.decode, text)
  return ok and decoded or nil
end

local function write_json(path, value)
  return write_file(path, rex.json.encode(value, { indent = true }) .. "\n")
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local function dir_exists(path)
  local r = run({ "test", "-d", path })
  return r ~= nil and r.ok
end

local function list_dir(dir, suffix)
  local out = {}
  local r = run({ "ls", "-1", dir })
  if not (r and r.ok) then return out end
  for _, name in ipairs(lines(r.stdout)) do
    if not suffix or name:sub(-#suffix) == suffix then out[#out + 1] = dir .. "/" .. name end
  end
  return out
end

local OS = stdout_of({ "uname", "-s" }):gsub("%s+$", "")
local IS_MAC = OS == "Darwin"
M.OS = OS

local STATE_DIR = args.state_dir
  or os.getenv("REX_DURABLE_STATE_DIR")
  or (IS_MAC and (HOME .. "/Library/Application Support/rex-durable"))
  or ((os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-durable")
local SNAP_DIR = STATE_DIR .. "/snapshots"
local CHECKPOINT_DIR = STATE_DIR .. "/checkpoints"
local HISTORY_DIR = STATE_DIR .. "/history"
local BLOCKS_DIR = STATE_DIR .. "/blocks"
local STATE_FILE = STATE_DIR .. "/state.json"
local CLOSED_TABS_FILE = STATE_DIR .. "/closed_tabs.json"
M.STATE_DIR = STATE_DIR
M.CLOSED_TABS_FILE = CLOSED_TABS_FILE

local function notify(message)
  if args.notify == false then return end
  if IS_MAC then
    run({ "osascript", "-e", "on run argv",
          "-e", "display notification (item 1 of argv) with title \"Rex\"",
          "-e", "end run", message })
  else
    run({ "notify-send", "Rex", message })
  end
end

-- Track sessions we explicitly attached to on non-`--all` CLI runs so we can
-- detach cleanly before exiting; under `rex do --all`, `session.view` works
-- directly without `session.attach` and adds zero entries to `session.list_clients`.
local attached_sessions = {}
local is_all_scope = false

local function ensure_session(session_id)
  if is_all_scope or not session_id or attached_sessions[session_id] then return end
  local ok = rex.session.attach{ session_id = session_id }
  if ok then attached_sessions[session_id] = true end
end

local function detach_attached_sessions()
  for sid in pairs(attached_sessions) do
    rex.session.detach{ session_id = sid }
    attached_sessions[sid] = nil
  end
end

local function session_view(session_id)
  local view, err = rex.session.view{ session_id = session_id }
  if view then return view end
  local att, aerr = rex.session.attach{ session_id = session_id }
  if att and att.view then
    attached_sessions[session_id] = true
    return att.view
  end
  return nil, err or aerr
end

---------------------------------------------------------------------------
-- Processes: what is running in a tab, its command line, and its open files

-- ps prints elapsed time as [[dd-]hh:]mm:ss.
function M.parse_etime(text)
  text = text or ""
  local days, rest = text:match("^(%d+)%-(.+)$")
  if not days then days, rest = "0", text end
  local seconds = 0
  for n in rest:gmatch("%d+") do seconds = seconds * 60 + tonumber(n) end
  return tonumber(days) * 86400 + seconds
end

function M.parse_ps(text)
  local out = {}
  for _, line in ipairs(lines(text)) do
    local pid, etime, command = line:match("^%s*(%d+)%s+(%S+)%s*(.*)$")
    if pid then out[tonumber(pid)] = { age = M.parse_etime(etime), args = command } end
  end
  return out
end

local function processes(pids)
  if #pids == 0 then return {} end
  return M.parse_ps(stdout_of({ "ps", "-o", "pid=,etime=,args=", "-p", table.concat(pids, ",") }))
end

-- lsof -F output: "p<pid>" starts a process, "n<path>" names one of its files.
function M.parse_lsof(text)
  local out, pid = {}, nil
  for _, line in ipairs(lines(text)) do
    local kind, rest = line:sub(1, 1), line:sub(2)
    if kind == "p" then
      pid = tonumber(rest)
      out[pid] = out[pid] or {}
    elseif kind == "n" and pid then
      table.insert(out[pid], rest)
    end
  end
  return out
end

local function open_files(pids)
  if #pids == 0 then return {} end
  local r = run({ "lsof", "-nP", "-w", "-Fpn", "-p", table.concat(pids, ",") })
  if r then return M.parse_lsof(r.stdout) end
  -- No lsof (common on minimal Linux): read /proc/<pid>/fd instead.
  local argv = { "sh", "-c",
    'for p in "$@"; do for f in /proc/$p/fd/*; do ' ..
    'l=$(readlink "$f" 2>/dev/null) && printf "p%s\\nn%s\\n" "$p" "$l"; done; done', "sh" }
  for _, pid in ipairs(pids) do argv[#argv + 1] = tostring(pid) end
  return M.parse_lsof(stdout_of(argv))
end

-- Which of these paths some process has open right now.
local function held_files(paths)
  local held = {}
  if #paths == 0 then return held end
  local argv = { "lsof", "-nP", "-w", "-Fn", "--" }
  for _, p in ipairs(paths) do argv[#argv + 1] = p end
  local r = run(argv)
  if r then
    for _, line in ipairs(lines(r.stdout)) do
      if line:sub(1, 1) == "n" then held[line:sub(2)] = true end
    end
    return held
  end
  if IS_MAC then return held end
  argv = { "find", "/proc", "-mindepth", "3", "-maxdepth", "3", "-path", "/proc/[0-9]*/fd/*",
           "-type", "l", "(" }
  for i, p in ipairs(paths) do
    if i > 1 then argv[#argv + 1] = "-o" end
    argv[#argv + 1] = "-lname"
    argv[#argv + 1] = p
  end
  for _, word in ipairs({ ")", "-printf", "%l\\n" }) do argv[#argv + 1] = word end
  for _, line in ipairs(lines(stdout_of(argv))) do held[line] = true end
  return held
end

local function mtimes(paths)
  local out = {}
  if #paths == 0 then return out end
  local argv = IS_MAC and { "stat", "-f", "%m %N" } or { "stat", "-c", "%Y %n" }
  for _, p in ipairs(paths) do argv[#argv + 1] = p end
  for _, line in ipairs(lines(stdout_of(argv))) do
    local t, path = line:match("^(%d+) (.+)$")
    if t then out[path] = tonumber(t) end
  end
  return out
end

local function split_words(text)
  local out = {}
  for word in (text or ""):gmatch("%S+") do out[#out + 1] = word end
  return out
end

local function argv_of(pid, ps)
  if not IS_MAC then
    local raw = read_file("/proc/" .. pid .. "/cmdline")
    if raw and #raw > 0 then
      local out, from = {}, 1
      while from <= #raw do
        local nul = raw:find("\0", from, true) or (#raw + 1)
        out[#out + 1] = raw:sub(from, nul - 1)
        from = nul + 1
      end
      if #out > 0 then return out end
    end
  end
  return split_words(ps and ps.args)
end

-- The tab's process chain, closest to the screen first, without login.
function M.chain_of(proc)
  local out, seen, candidates = {}, {}, {}
  if type(proc) ~= "table" then return out end
  if proc.foreground then candidates[#candidates + 1] = proc.foreground end
  for _, p in ipairs(list(proc.ancestors)) do candidates[#candidates + 1] = p end
  for _, p in ipairs(candidates) do
    if p.pid and not seen[p.pid] and p.name ~= "login" then
      seen[p.pid] = true
      out[#out + 1] = p
    end
  end
  return out
end

local function is_shell(p)
  local candidate = p.name or p.argv0 or ""
  return SHELLS[basename(candidate:gsub("^%-", ""))] == true
end

---------------------------------------------------------------------------
-- Chats: which conversation a running fx, Claude Code, Codex, Pi, or agy is on

local function under(path, dir)
  return path:sub(1, #dir) == dir and path:sub(#dir + 1) or nil
end

local function first_line(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  return line
end

local function pi_sessions_root(home)
  if not home then
    local env_dir = os.getenv("PI_CODING_AGENT_SESSION_DIR")
    if env_dir and env_dir ~= "" then return env_dir end
    local agent_dir = os.getenv("PI_CODING_AGENT_DIR")
    if agent_dir and agent_dir ~= "" then return agent_dir .. "/sessions" end
  end
  return (home or HOME) .. "/.pi/agent/sessions"
end

function M.safe_block_name(block_id)
  return tostring(block_id or ""):gsub("[^A-Za-z0-9._%-]", "_") .. ".json"
end

function M.block_file(block_id, state_dir)
  return (state_dir or STATE_DIR) .. "/blocks/" .. M.safe_block_name(block_id)
end

-- Read a live extension/hook record for a Rex block, verified by PID so a
-- stale file left by an earlier process is never mistaken for the current one.
function M.block_record(block_id, pid, app, state_dir)
  if not block_id or not pid then return nil end
  local rec = read_json(M.block_file(block_id, state_dir))
  if type(rec) ~= "table" then return nil end
  if rec.app ~= app or tonumber(rec.pid) ~= tonumber(pid) then return nil end
  return rec
end

function M.fx_parent(id, home, reader)
  local line = (reader or first_line)((home or HOME) .. "/.fx/sessions/v2/" .. id .. "/log.jsonl")
  local ok, record = pcall(function() return line and rex.json.decode(line) end)
  if ok and type(record) == "table" and record.role == "child" and type(record.parent) == "string"
    and record.parent ~= "" then
    return record.parent
  end
end

function M.fx_session(files, home, reader)
  local found = {}
  for _, f in ipairs(list(files)) do
    local rest = under(f, (home or HOME) .. "/.fx/sessions/")
    if rest then
      local id = rest:match("^v2/([%w_%-]+)/lock$")
      if id then found[#found + 1] = { id, "v2" } end
      id = rest:match("^([%w_%-]+)/session%.lock$")
      if id then found[#found + 1] = { id, "v1" } end
    end
  end
  if #found == 0 then return nil end
  for _, chat in ipairs(found) do
    if chat[2] ~= "v2" or not M.fx_parent(chat[1], home, reader) then return chat[1], chat[2] end
  end
  local id = found[1][1]
  for _ = 1, 5 do
    local parent = M.fx_parent(id, home, reader)
    if not parent then break end
    id = parent
  end
  return id, "v2"
end

function M.codex_session(files, home)
  for _, f in ipairs(list(files)) do
    if under(f, (home or HOME) .. "/.codex/sessions/") then
      local id = f:match("rollout%-.*%-(" .. UUID .. ")%.jsonl$")
      if id then return id, f end
    end
  end
end

function M.claude_slug(cwd) return (tostring(cwd or ""):gsub("[^%w]", "-")) end

function M.claude_session(files, home)
  for _, f in ipairs(list(files)) do
    if under(f, (home or HOME) .. "/.claude/projects/") then
      local id = f:match("/(" .. UUID .. ")%.jsonl$")
      if id then return id, f end
    end
  end
end

function M.pi_slug(cwd)
  local s = tostring(cwd or ""):gsub("^[/\\]+", ""):gsub("[/\\]+$", ""):gsub("[/\\:]", "-")
  return "--" .. s .. "--"
end

function M.pi_session(files, home)
  local base = pi_sessions_root(home) .. "/"
  for _, f in ipairs(list(files)) do
    if under(f, base) then
      local id = f:match("_(" .. UUID .. ")%.jsonl$") or f:match("/(" .. UUID .. ")%.jsonl$")
      if id then return id, f end
    end
  end
end

-- Factory Droid writes ~/.factory/sessions/<cwd with / \ : as ->/<id>.jsonl
-- (plus <id>.settings.json).
function M.droid_slug(cwd)
  return (tostring(cwd or ""):gsub("[/\\]+$", ""):gsub("[/\\:]", "-"))
end

-- A Task subagent's session sits beside its parent's in the same folder and
-- names the parent in callingSessionId. Only the parent belongs to a tab.
function M.droid_is_subagent(header)
  return type(header) == "table" and type(header.callingSessionId) == "string"
    and header.callingSessionId ~= ""
end

function M.droid_session(files, home)
  local base = (home or HOME) .. "/.factory/sessions/"
  for _, f in ipairs(list(files)) do
    if under(f, base) then
      local id = f:match("/(" .. UUID .. ")%.jsonl$")
        or f:match("/(" .. UUID .. ")%.settings%.json$")
      if id then
        local jsonl = f:gsub("%.settings%.json$", ".jsonl")
        return id, jsonl
      end
    end
  end
end

-- Antigravity CLI (agy) holds ~/.gemini/antigravity-cli/conversations/<id>.db*
-- and ~/.gemini/antigravity-cli/brain/<id> open while the conversation runs.
-- Subagent conversations are filtered out via parent transcript.jsonl references.
function M.agy_session(files, home, reader)
  local base = (home or HOME) .. "/.gemini/antigravity-cli/"
  local ids, seen = {}, {}
  local function add(id)
    if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
  end
  for _, f in ipairs(list(files)) do
    local rest = under(f, base)
    if rest then
      add(rest:match("^conversations/(" .. UUID .. ")%.db"))
      add(rest:match("^brain/(" .. UUID .. ")$") or rest:match("^brain/(" .. UUID .. ")/"))
    end
  end
  if #ids == 0 then return nil end
  if #ids == 1 then return ids[1], base .. "brain/" .. ids[1] end
  local read_all = reader or read_file
  local transcripts = {}
  for _, id in ipairs(ids) do
    transcripts[id] = read_all(base .. "brain/" .. id .. "/.system_generated/logs/transcript.jsonl") or ""
  end
  local roots = {}
  for _, candidate in ipairs(ids) do
    local is_child = false
    for _, other in ipairs(ids) do
      if other ~= candidate and transcripts[other]:find(candidate, 1, true) then
        is_child = true
        break
      end
    end
    if not is_child then roots[#roots + 1] = candidate end
  end
  local chosen = roots[1] or ids[1]
  return chosen, base .. "brain/" .. chosen
end

local function normalize_cwd(dir)
  if type(dir) ~= "string" or dir == "" then return nil end
  local stripped = dir:gsub("/+$", "")
  return stripped == "" and "/" or stripped
end

local md5_cache = {}
function M.md5(text)
  text = tostring(text or "")
  if md5_cache[text] ~= nil then return md5_cache[text] or nil end
  local out = stdout_of({
    "sh", "-c",
    'if command -v md5 >/dev/null 2>&1; then printf "%s" "$1" | md5 -q; ' ..
    'elif command -v md5sum >/dev/null 2>&1; then printf "%s" "$1" | md5sum | awk \'{print $1}\'; ' ..
    'elif command -v openssl >/dev/null 2>&1; then printf "%s" "$1" | openssl md5 -r | awk \'{print $1}\'; ' ..
    'fi',
    "sh", text,
  })
  local hex = out:lower():match("(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)")
  md5_cache[text] = hex or false
  return hex
end

local function cursor_meta(path, reader)
  local text = (reader or read_file)(path)
  if not text then return nil end
  local ok, decoded = pcall(rex.json.decode, text)
  return ok and type(decoded) == "table" and decoded or nil
end

function M.cursor_agent_session(files, home, reader)
  local base = (home or HOME) .. "/.cursor/chats/"
  local found, seen = {}, {}
  for _, f in ipairs(list(files)) do
    local rest = under(f, base)
    if rest then
      local hash, id = rest:match("^([^/]+)/(" .. UUID .. ")/")
      if hash and id and not seen[id] then
        seen[id] = true
        found[#found + 1] = { hash = hash, id = id }
      end
    end
  end
  if #found == 0 then return nil end
  if #found == 1 then
    return found[1].id, base .. found[1].hash .. "/" .. found[1].id .. "/store.db"
  end
  local best, best_has_conv, best_updated
  for _, item in ipairs(found) do
    local meta = cursor_meta(base .. item.hash .. "/" .. item.id .. "/meta.json", reader)
    local has_conv = not (meta and meta.hasConversation == false)
    local updated = (meta and tonumber(meta.updatedAtMs)) or -1
    if not best
      or (has_conv and not best_has_conv)
      or (has_conv == best_has_conv and updated > best_updated) then
      best, best_has_conv, best_updated = item, has_conv, updated
    end
  end
  return best.id, base .. best.hash .. "/" .. best.id .. "/store.db"
end

local function is_app_executable(app, exe)
  if type(exe) ~= "string" or exe == "" then return false end
  local base = basename(exe)
  if base == app then return true end
  local spec = M.CHATS[app]
  return spec ~= nil and spec.aliases ~= nil and spec.aliases[base] == true
end

local function has_app_alias(app, proc_or_name, argv)
  local spec = M.CHATS[app]
  if not (spec and spec.aliases) then return false end
  local p = type(proc_or_name) == "table" and proc_or_name or { name = proc_or_name }
  for _, field in ipairs({ "name", "argv0", "invoked_path", "path" }) do
    if p[field] and spec.aliases[basename(p[field])] then return true end
  end
  argv = list(argv)
  return argv[1] ~= nil and spec.aliases[basename(argv[1])] == true
end

local function matches_script_path(app, script)
  if type(script) ~= "string" or script == "" then return false end
  return basename(script) == app
    or script:sub(1, #app + 1) == app .. "/"
    or script:find("/" .. app .. "/", 1, true) ~= nil
    or (app == "claude" and script:find("claude-code", 1, true) ~= nil)
    or (app == "pi" and script:find("pi-coding-agent", 1, true) ~= nil)
end

local function cursor_args_start(argv)
  local i = 2
  while i <= #argv and (argv[i] == "--use-system-ca" or matches_script_path("cursor-agent", argv[i])) do
    i = i + 1
  end
  return i
end

local function optional_value_arg(arg)
  return type(arg) == "string"
    and arg ~= ""
    and arg ~= "--"
    and arg ~= "resume"
    and arg:sub(1, 1) ~= "-"
    and not arg:match("^" .. UUID .. "$")
end

local function sanitize_cursor_argv(argv)
  argv = list(argv)
  if #argv == 0 then return {} end
  local secrets = (M.CHATS["cursor-agent"] and M.CHATS["cursor-agent"].secret_values) or {}
  local out = { argv[1] }
  local i = is_app_executable("cursor-agent", argv[1]) and cursor_args_start(argv) or 2
  local passthrough = false
  while i <= #argv do
    local a = argv[i]
    if not passthrough then
      if a == "--" then
        passthrough = true
        out[#out + 1] = a
        i = i + 1
      else
        local name = a:match("^(%-%-?[%w%-]+)=") or a
        if secrets[name] then
          i = i + (a == name and 2 or 1)
        else
          out[#out + 1] = a
          i = i + 1
        end
      end
    else
      out[#out + 1] = a
      i = i + 1
    end
  end
  return out
end

local function is_non_chat_cursor_argv(argv)
  local spec = M.CHATS["cursor-agent"]
  local non_chat_flags = spec.non_chat_flags or {}
  local non_chat_subcommands = spec.non_chat_subcommands or {}
  local values = spec.values or {}
  local secret_values = spec.secret_values or {}
  local optional_values = spec.optional_values or {}
  local i = cursor_args_start(argv)
  local saw_positional = false
  while i <= #argv do
    local a = argv[i]
    if a == "--" then break end
    local name = a:match("^(%-%-?[%w%-]+)=") or a
    if non_chat_flags[name] then return true end
    if values[name] or secret_values[name] then
      i = i + (a == name and 2 or 1)
    elseif optional_values[name] then
      if a == name and optional_value_arg(argv[i + 1]) then
        i = i + 2
      else
        i = i + 1
      end
    elseif a:sub(1, 1) == "-" then
      i = i + 1
    else
      if not saw_positional then
        saw_positional = true
        if non_chat_subcommands[a] then return true end
      end
      i = i + 1
    end
  end
  return false
end

local function has_cursor_open_file(files)
  for _, f in ipairs(list(files)) do
    if type(f) == "string" and f:find("/cursor-agent/", 1, true) then return true end
  end
  return false
end

local function parse_pi_session_arg(arg)
  if type(arg) ~= "string" or arg == "" then return nil end
  if arg:match("^" .. UUID .. "$") then return arg, nil end
  local id = arg:match("_(" .. UUID .. ")%.jsonl$") or arg:match("/(" .. UUID .. ")%.jsonl$")
  if id then return id, arg end
  if arg:sub(-6) == ".jsonl" then return basename(arg):gsub("%.jsonl$", ""), arg end
end

function M.argv_session(app, argv)
  argv = list(argv)
  if app == "cursor-agent" then
    local spec = M.CHATS["cursor-agent"]
    local values = spec.values or {}
    local secret_values = spec.secret_values or {}
    local optional_values = spec.optional_values or {}
    local i = cursor_args_start(argv)
    local saw_resume = false
    while i <= #argv do
      local a = argv[i]
      if a == "--" then break end
      local b = argv[i + 1]
      local name = a:match("^(%-%-?[%w%-]+)=") or a
      if a == "--resume" and b and b:match("^" .. UUID .. "$") then
        return b
      end
      local eq = a:match("^%-%-resume=(" .. UUID .. ")$")
      if eq then return eq end
      if a == "resume" and not saw_resume then
        saw_resume = true
        if b and b:match("^" .. UUID .. "$") then return b end
        i = i + 1
      elseif saw_resume and a:match("^" .. UUID .. "$") then
        return a
      elseif values[name] or secret_values[name] then
        i = i + (a == name and 2 or 1)
      elseif optional_values[name] then
        if a == name and optional_value_arg(b) then
          i = i + 2
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    end
    return nil
  end
  local saw_resume_subcmd = false
  for i = 1, #argv do
    local a = argv[i]
    local b = argv[i + 1]
    if a == "--" then break end
    if (app == "codex" or app == "droid") and a == "resume" then
      saw_resume_subcmd = true
      if b and b:match("^" .. UUID .. "$") then return b end
    elseif saw_resume_subcmd and a:match("^" .. UUID .. "$") then
      return a
    elseif (app == "claude" or app == "droid")
      and (a == "--resume" or a == "-r" or a == "--session-id")
      and b and b:match("^" .. UUID .. "$") then
      return b
    elseif app == "agy" and (a == "--conversation" or a == "--switch")
      and b and b:match("^" .. UUID .. "$") then
      return b
    elseif app == "pi" and b then
      if a == "--session-id" and b:match("^" .. UUID .. "$") then return b end
      if a == "--session" then
        local id, file = parse_pi_session_arg(b)
        if id then return id, file end
      end
    end
  end
  for _, a in ipairs(argv) do
    if a == "--" then break end
    if app == "claude" or app == "droid" then
      local id = a:match("^%-%-resume=(" .. UUID .. ")$")
        or a:match("^%-r=(" .. UUID .. ")$")
        or a:match("^%-%-session%-id=(" .. UUID .. ")$")
      if id then return id end
    elseif app == "agy" then
      local id = a:match("^%-%-conversation=(" .. UUID .. ")$")
        or a:match("^%-%-switch=(" .. UUID .. ")$")
      if id then return id end
    elseif app == "pi" then
      local id = a:match("^%-%-session%-id=(" .. UUID .. ")$")
      if id then return id end
      local arg = a:match("^%-%-session=(.+)$")
      if arg then
        local pid, file = parse_pi_session_arg(arg)
        if pid then return pid, file end
      end
    end
  end
end

-- Uses Rex's native `com.superlogical.terminal.process` fields (`script`,
-- `invoked_path`, `path`, `argv0`, `name`) as well as `ps` `argv`.
-- Accepts either a process table `p` or a process name string.
function M.is_app(app, proc_or_name, argv)
  argv = list(argv)
  local p = type(proc_or_name) == "table" and proc_or_name or { name = proc_or_name }
  for _, field in ipairs({ "name", "argv0", "invoked_path", "path" }) do
    if p[field] and basename(p[field]) == app then return true end
  end
  if argv[1] and basename(argv[1]) == app then return true end
  for _, field in ipairs({ "script", "path", "invoked_path" }) do
    if matches_script_path(app, p[field]) then return true end
  end
  local launcher = basename(argv[1] or p.name or "")
  if launcher:match("^node") or launcher:match("^bun") or is_app_executable(app, launcher) then
    for i = 2, math.min(#argv, 4) do
      if matches_script_path(app, argv[i]) then return true end
    end
  end
  return false
end

local function chat_in(p, info, block_id)
  local files = info.files[p.pid]
  local argv = argv_of(p.pid, info.ps[p.pid])
  local id, store = M.fx_session(files)
  if id then return { kind = "chat", app = "fx", id = id, store = store, argv = argv } end
  for _, app in ipairs(M.APPS) do
    if app ~= "fx" then
      local matched = M.is_app(app, p, argv)
      local rec, found, file
      if not matched and has_app_alias(app, p, argv) then
        rec = M.block_record(block_id, p.pid, app, info.state_dir)
        if rec then
          matched = true
        elseif app == "cursor-agent" then
          found, file = M.cursor_agent_session(files)
          if found or has_cursor_open_file(files) then matched = true end
        end
      end
      if matched then
        if app == "cursor-agent" then
          argv = sanitize_cursor_argv(argv)
          if is_non_chat_cursor_argv(argv) then
            return { kind = "program", argv = argv }
          end
        end
        rec = rec or M.block_record(block_id, p.pid, app, info.state_dir)
        if rec then
          local rec_argv = (type(rec.argv) == "table" and #rec.argv > 0) and rec.argv or argv
          if app == "cursor-agent" then rec_argv = sanitize_cursor_argv(rec_argv) end
          if rec.ephemeral == true then
            return { kind = "program", argv = rec_argv }
          end
          if type(rec.id) == "string" and rec.id ~= "" then
            return { kind = "chat", app = app, id = rec.id, session_file = rec.session_file,
                     argv = rec_argv, pid = p.pid }
          end
          argv = rec_argv
        end
        if not found then
          if app == "claude" then
            found, file = M.claude_session(files)
          elseif app == "codex" then
            found, file = M.codex_session(files)
          elseif app == "pi" then
            found, file = M.pi_session(files)
          elseif app == "agy" then
            found, file = M.agy_session(files)
          elseif app == "droid" then
            found, file = M.droid_session(files)
          elseif app == "cursor-agent" then
            found, file = M.cursor_agent_session(files)
          end
        end
        if not found then
          local argv_id, argv_file = M.argv_session(app, argv)
          found, file = argv_id, argv_file or file
        end
        return { kind = "chat", app = app, id = found,
                 session_file = file, argv = argv, pid = p.pid }
      end
    end
  end
end

-- What a tab is running: a chat, another program, or just its shell.
function M.describe(proc, info, block_id)
  local home = (type(proc) == "table" and proc.home) or HOME
  local chain = M.chain_of(proc)
  if #chain == 0 then return { kind = "shell", cwd = home } end
  local outer = chain[#chain]
  local inner = {}
  for i = 1, is_shell(outer) and #chain - 1 or #chain do inner[i] = chain[i] end
  for _, p in ipairs(inner) do
    local chat = chat_in(p, info, block_id)
    if chat then
      chat.cwd = p.cwd or outer.cwd or home
      return chat
    end
  end
  if #inner == 0 then return { kind = "shell", cwd = outer.cwd or home } end
  local top = inner[#inner]
  local top_argv = argv_of(top.pid, info.ps[top.pid])
  if #top_argv == 0 and (top.invoked_path or top.name) then
    top_argv = { top.invoked_path or top.name }
  end
  return { kind = "program", cwd = top.cwd or outer.cwd or home, argv = top_argv }
end

local function codex_cwd(path)
  local line = first_line(path)
  local ok, meta = pcall(function() return line and rex.json.decode(line) end)
  local payload = (ok and type(meta) == "table") and (meta.payload or meta) or {}
  return payload.cwd
end

local function pi_header(path)
  local line = first_line(path)
  local ok, meta = pcall(function() return line and rex.json.decode(line) end)
  if ok and type(meta) == "table" and meta.type == "session" then return meta end
end

local function droid_header(path)
  local line = first_line(path)
  local ok, meta = pcall(function() return line and rex.json.decode(line) end)
  if ok and type(meta) == "table" and meta.type == "session_start" then return meta end
end

local function cursor_workspace_arg(argv, cwd)
  argv = list(argv)
  local i = cursor_args_start(argv)
  local ws
  while i <= #argv do
    local a = argv[i]
    if a == "--" then break end
    if a == "--workspace" and argv[i + 1] then
      ws = argv[i + 1]
      i = i + 2
    else
      local val = a:match("^%-%-workspace=(.+)$")
      if val then ws = val end
      i = i + 1
    end
  end
  if not ws or ws == "" then return nil end
  if ws:sub(1, 1) ~= "/" and cwd and cwd ~= "" then
    ws = normalize_cwd(cwd) .. "/" .. ws
  end
  return normalize_cwd(ws)
end

local function realpath_of(dir)
  if not dir or dir == "" then return nil end
  local rp = stdout_of({ "sh", "-c", 'cd -- "$1" 2>/dev/null && pwd -P', "sh", dir }):gsub("%s+$", "")
  return rp ~= "" and normalize_cwd(rp) or nil
end

local function newest_cursor_session(pane, since)
  local dirs, dir_set = {}, {}
  local function add_dir(d)
    local norm = normalize_cwd(d)
    if norm and not dir_set[norm] then
      dir_set[norm] = true
      dirs[#dirs + 1] = norm
      local rp = realpath_of(norm)
      if rp and not dir_set[rp] then
        dir_set[rp] = true
        dirs[#dirs + 1] = rp
      end
    end
  end
  add_dir(cursor_workspace_arg(pane.argv, pane.cwd))
  add_dir(pane.cwd)

  local entries, stat_paths = {}, {}
  local seen_subdirs = {}
  for _, dir in ipairs(dirs) do
    local hash = M.md5(dir)
    if hash then
      for _, subdir in ipairs(list_dir(HOME .. "/.cursor/chats/" .. hash)) do
        local id = basename(subdir)
        if id:match("^" .. UUID .. "$") and not seen_subdirs[subdir] then
          seen_subdirs[subdir] = true
          local meta = cursor_meta(subdir .. "/meta.json")
          local meta_cwd = meta and type(meta.cwd) == "string" and normalize_cwd(meta.cwd) or nil
          if not meta_cwd or dir_set[meta_cwd] then
            local check_files = {}
            for _, fname in ipairs({ "store.db", "store.db-wal", "meta.json" }) do
              local p = subdir .. "/" .. fname
              if file_exists(p) then
                check_files[#check_files + 1] = p
                stat_paths[#stat_paths + 1] = p
              end
            end
            entries[#entries + 1] = {
              id = id,
              subdir = subdir,
              has_conv = not (meta and meta.hasConversation == false),
              updated_s = meta and tonumber(meta.updatedAtMs) and math.floor(tonumber(meta.updatedAtMs) / 1000) or nil,
              files = check_files,
            }
          end
        end
      end
    end
  end
  if #entries == 0 then return nil end

  local times = mtimes(stat_paths)
  local best, best_has_conv, best_time
  for _, e in ipairs(entries) do
    local t = e.updated_s
    for _, p in ipairs(e.files) do
      if times[p] and (not t or times[p] > t) then t = times[p] end
    end
    if t and t >= since then
      if not best
        or (e.has_conv and not best_has_conv)
        or (e.has_conv == best_has_conv and t > best_time) then
        best, best_has_conv, best_time = e, e.has_conv, t
      end
    end
  end
  if not best then return nil end
  local db = best.subdir .. "/store.db"
  return best.id, file_exists(db) and db or (best.subdir .. "/meta.json")
end

local function newest_session_file(pane, info)
  if pane.app == "agy" then return nil end
  local age = (info.ps[pane.pid] or {}).age or 0
  local since = info.now - age - 5
  if pane.app == "cursor-agent" then
    return newest_cursor_session(pane, since)
  end
  local candidates = {}
  if pane.app == "claude" then
    candidates = list_dir(HOME .. "/.claude/projects/" .. M.claude_slug(pane.cwd), ".jsonl")
  elseif pane.app == "pi" then
    for _, path in ipairs(list_dir(pi_sessions_root() .. "/" .. M.pi_slug(pane.cwd), ".jsonl")) do
      local header = pi_header(path)
      if not header or not header.cwd or header.cwd == pane.cwd then
        candidates[#candidates + 1] = path
      end
    end
  elseif pane.app == "droid" then
    local sdir = HOME .. "/.factory/sessions/" .. M.droid_slug(pane.cwd)
    for _, path in ipairs(list_dir(sdir, ".jsonl")) do
      local header = droid_header(path)
      if not M.droid_is_subagent(header) and (not header or not header.cwd or header.cwd == pane.cwd) then
        candidates[#candidates + 1] = path
      end
    end
  elseif pane.app == "codex" then
    local minutes = tostring(math.floor(age / 60) + 2)
    for _, path in ipairs(lines(stdout_of({ "find", HOME .. "/.codex/sessions", "-name",
                                            "rollout-*.jsonl", "-mmin", "-" .. minutes }))) do
      if codex_cwd(path) == pane.cwd then candidates[#candidates + 1] = path end
    end
  end
  local best, best_time
  for path, t in pairs(mtimes(candidates)) do
    if t >= since and (not best_time or t > best_time) then best, best_time = path, t end
  end
  if not best then return nil end
  if pane.app == "claude" then return best:match("/(" .. UUID .. ")%.jsonl$"), best end
  if pane.app == "droid" then
    local header = droid_header(best)
    local id = (header and type(header.id) == "string" and header.id ~= "" and header.id)
      or best:match("/(" .. UUID .. ")%.jsonl$")
    return id, best
  end
  if pane.app == "pi" then
    local header = pi_header(best)
    local id = (header and type(header.id) == "string" and header.id ~= "" and header.id)
      or best:match("_(" .. UUID .. ")%.jsonl$")
      or best:match("/(" .. UUID .. ")%.jsonl$")
    return id, best
  end
  return best:match("%-(" .. UUID .. ")%.jsonl$"), best
end

local function resolve_chats(pending, info, carried)
  carried = carried or {}
  local groups = {}
  for _, pane in ipairs(pending) do
    local key = pane.app .. "\0" .. tostring(pane.cwd)
    groups[key] = groups[key] or {}
    table.insert(groups[key], pane)
  end
  for _, group in pairs(groups) do
    for _, pane in ipairs(group) do
      if #group == 1 then pane.id, pane.session_file = newest_session_file(pane, info) end
      if not pane.id and pane.block_id and carried[pane.block_id] then
        local prev = carried[pane.block_id]
        if prev.app == pane.app and prev.cwd == pane.cwd and prev.id
          and (not prev.session_file or file_exists(prev.session_file)) then
          pane.id, pane.session_file = prev.id, prev.session_file
          if #list(pane.argv) <= 1 and type(prev.argv) == "table" and #prev.argv > 1 then
            pane.argv = prev.argv
          end
        end
      end
      if not pane.id then
        pane.kind, pane.app, pane.session_file = "program", nil, nil
        pane.note = "conversation unknown"
      end
    end
  end
end

---------------------------------------------------------------------------
-- Reading Rex: every session, window, split, and what each tab runs

function M.panes(node, out)
  out = out or {}
  if type(node) ~= "table" then return out end
  if node.split then
    M.panes(node.split.before, out)
    M.panes(node.split.after, out)
  elseif node.pane then
    out[#out + 1] = node.pane
  end
  return out
end

local function convert(node, procs, blocks_by_id, win, local_host_id, info, pending)
  if type(node) ~= "table" then return nil end
  if node.split then
    local before = convert(node.split.before, procs, blocks_by_id, win, local_host_id, info, pending)
    local after = convert(node.split.after, procs, blocks_by_id, win, local_host_id, info, pending)
    if not before or not after then return before or after end
    return { split = { direction = node.split.direction, ratio = node.split.ratio or 0.5,
                       before = before, after = after } }
  end
  local bid = node.block_id
  if not bid then return nil end
  local bmeta = blocks_by_id[bid]
  local focused = (win and win.focused_block_id == bid) or (node.focused and true) or false
  local zoomed = (win and win.zoomed_block_id == bid) or nil
  local custom_label = (bmeta and type(bmeta.label) == "string" and bmeta.label ~= "" and bmeta.label ~= "shell")
    and bmeta.label or nil
  if local_host_id and bmeta and bmeta.host_id and bmeta.host_id ~= local_host_id then
    return { pane = { kind = "remote", block_id = bid, host_id = bmeta.host_id,
                      focused = focused, zoomed = zoomed, label = custom_label } }
  end
  local proc = procs[bid]
  if not proc then return nil end
  local pane = M.describe(proc, info, bid)
  pane.block_id = bid
  pane.focused = focused
  pane.zoomed = zoomed
  pane.label = custom_label
  if pane.kind == "chat" and not pane.id then pending[#pending + 1] = pane end
  return { pane = pane }
end

local function read_state() return read_json(STATE_FILE) or {} end

local function carried_chats(instance_id)
  local carried = {}
  local before = read_json(SNAP_DIR .. "/" .. tostring(instance_id) .. ".json")
  for _, s in ipairs(list(before and before.sessions)) do
    for _, w in ipairs(list(s.windows)) do
      for _, p in ipairs(M.panes(w.layout)) do
        if p.kind == "chat" and p.block_id and p.id then
          carried[p.block_id] = { app = p.app, id = p.id, session_file = p.session_file,
                                  cwd = p.cwd, argv = p.argv }
        end
      end
    end
  end
  local state = read_state()
  if state.reopened_instance == instance_id and type(state.reopened) == "table" then
    for block_id, rec in pairs(state.reopened) do
      if type(rec) == "table" and rec.id then carried[block_id] = rec end
    end
  end
  return carried
end

local function collect()
  local status = assert(rex.call("server.status"))
  local local_host_id = status.host_id
  local listing = rex.call("session.list") or {}
  local raw, pids = {}, {}
  for _, s in ipairs(list(listing.sessions)) do
    local view, err = session_view(s.session_id)
    local entry = { id = s.session_id, label = s.label, view = view, procs = {}, blocks = {} }
    if not view then log("couldn't read session " .. tostring(s.label) .. ": " .. tostring(err), "warn") end
    for _, w in ipairs(list(view and view.windows)) do
      for _, layer in ipairs(list(w.layers)) do
        for _, b in ipairs(list(layer.blocks)) do
          entry.blocks[b.block_id] = b
          local is_local = not (local_host_id and b.host_id and b.host_id ~= local_host_id)
          if b.creator_name == TERMINAL and is_local then
            local proc = rex.block.call(TERMINAL, "process",
              { session_id = s.session_id, block_id = b.block_id }) or {}
            entry.procs[b.block_id] = proc
            for _, p in ipairs(M.chain_of(proc)) do pids[#pids + 1] = p.pid end
          end
        end
      end
    end
    raw[#raw + 1] = entry
  end

  local info = { ps = processes(pids), files = open_files(pids), now = os.time(),
                 state_dir = STATE_DIR }
  local sessions, pending = {}, {}
  for _, entry in ipairs(raw) do
    if entry.view then
      local windows = {}
      for _, w in ipairs(list(entry.view.windows)) do
        local tiled
        for _, layer in ipairs(list(w.layers)) do
          if layer.kind == "tiled" then tiled = layer break end
        end
        local layout = tiled and convert(tiled.layout, entry.procs, entry.blocks, w, local_host_id, info, pending)
        if layout then
          local label = w.label
          local short = label and label:match("^Window (%x%x%x%x%x%x%x%x)$")
          if short and tostring(w.window_id):sub(-8) == short then label = nil end
          windows[#windows + 1] = { window_id = w.window_id, label = label,
                                    active = w.window_id == entry.view.active_window_id,
                                    layout = layout }
        end
      end
      sessions[#sessions + 1] = { session_id = entry.id, label = entry.view.label or entry.label,
                                  revision = entry.view.revision, windows = windows }
    end
  end
  resolve_chats(pending, info, carried_chats(status.instance_id))
  for _, s in ipairs(sessions) do
    for _, w in ipairs(s.windows) do
      for _, pane in ipairs(M.panes(w.layout)) do pane.pid = nil end
    end
  end
  return {
    tool = "rex-durable", version = M.VERSION, saved_at = now_iso(),
    server = { instance_id = status.instance_id, host_id = local_host_id,
               started_at = status.started_at },
    sessions = sessions,
  }
end
M.collect = collect

---------------------------------------------------------------------------
-- Saves

local function ensure_dirs()
  run({ "mkdir", "-p", SNAP_DIR, CHECKPOINT_DIR, HISTORY_DIR, BLOCKS_DIR })
end

local function snapshot_path(instance) return SNAP_DIR .. "/" .. instance .. ".json" end

local function load_snapshots()
  local out = {}
  for _, path in ipairs(list_dir(SNAP_DIR, ".json")) do
    local snap = read_json(path)
    if type(snap) == "table" and type(snap.server) == "table" and snap.saved_at then
      snap.path = path
      out[#out + 1] = snap
    end
  end
  table.sort(out, function(a, b) return a.saved_at > b.saved_at end)
  return out
end

local function checkpoint_path(name)
  return CHECKPOINT_DIR .. "/" .. tostring(name):gsub("[^%w%._%-]", "-") .. ".json"
end

local function previous_snapshot(instance)
  for _, snap in ipairs(load_snapshots()) do
    if snap.server.instance_id ~= instance then return snap end
  end
end

local function load_source(name)
  if name then
    local snap = read_json(checkpoint_path(name))
    if not snap then error("no checkpoint named " .. name .. " in " .. CHECKPOINT_DIR, 0) end
    return snap
  end
  return load_snapshots()[1]
end

function M.is_default_session(s)
  local windows = list(s.windows)
  if #windows ~= 1 then return false end
  local panes = M.panes(windows[1].layout)
  return #panes == 1 and panes[1].kind == "shell"
    and (panes[1].cwd == HOME or panes[1].cwd == HOME .. "/")
end

function M.is_blank(snap)
  for _, s in ipairs(list(snap and snap.sessions)) do
    if not M.is_default_session(s) then return false end
  end
  return true
end

function M.summary(snap)
  local sessions, tabs, chats, programs = 0, 0, 0, 0
  local apps = {}
  for _, s in ipairs(list(snap and snap.sessions)) do
    if not M.is_default_session(s) then
      sessions = sessions + 1
      for _, w in ipairs(list(s.windows)) do
        tabs = tabs + 1
        for _, p in ipairs(M.panes(w.layout)) do
          if p.kind == "chat" then
            chats = chats + 1
            apps[p.app] = (apps[p.app] or 0) + 1
          elseif p.kind == "program" then
            programs = programs + 1
          end
        end
      end
    end
  end
  local parts = {}
  for _, app in ipairs(M.APPS) do
    if apps[app] then parts[#parts + 1] = apps[app] .. " " .. app end
  end
  local text = string.format("%d sessions, %d tabs, %d chats", sessions, tabs, chats)
  if #parts > 0 then text = text .. " (" .. table.concat(parts, ", ") .. ")" end
  return text .. string.format(", %d other programs", programs), chats, programs, apps
end

function M.counts(snap)
  local tabs, chats = 0, 0
  for _, s in ipairs(list(snap and snap.sessions)) do
    for _, w in ipairs(list(s.windows)) do
      tabs = tabs + 1
      for _, p in ipairs(M.panes(w.layout)) do
        if p.kind == "chat" then chats = chats + 1 end
      end
    end
  end
  return { tabs = tabs, chats = chats }
end

function M.big_drop(before, after)
  local a, b = M.counts(before), M.counts(after)
  local lost_tabs, lost_chats = a.tabs - b.tabs, a.chats - b.chats
  return (lost_tabs >= DROP_MIN and b.tabs <= a.tabs * DROP_KEEP)
    or (lost_chats >= DROP_MIN and b.chats <= a.chats * DROP_KEEP)
end

local function stamp_time(name)
  local y, mo, d, h, mi, s = name:match("(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)")
  if not y then return 0 end
  return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                   hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
end

local function keep_newest(paths, n)
  table.sort(paths)
  for i = 1, #paths - n do os.remove(paths[i]) end
end

local function add_history(snap)
  local copies = list_dir(HISTORY_DIR, ".json")
  table.sort(copies)
  local newest = copies[#copies]
  if newest and os.time() - stamp_time(basename(newest)) < HISTORY_EVERY then return end
  write_json(HISTORY_DIR .. "/" .. os.date("%Y%m%d-%H%M%S") .. ".json", snap)
  keep_newest(list_dir(HISTORY_DIR, ".json"), HISTORY_KEEP)
end

local function prune_block_records(snap)
  local live_files = {}
  for _, s in ipairs(list(snap and snap.sessions)) do
    for _, w in ipairs(list(s.windows)) do
      for _, p in ipairs(M.panes(w.layout)) do
        if p.block_id then live_files[M.safe_block_name(p.block_id)] = true end
      end
    end
  end
  for _, path in ipairs(list_dir(BLOCKS_DIR, ".json")) do
    if not live_files[basename(path)] then os.remove(path) end
  end
end

local function read_closed_tabs(path)
  local data = read_json(path or CLOSED_TABS_FILE)
  return type(data) == "table" and data or {}
end

function M.prune_closed_tabs(entries, now, max_items, max_age)
  now = now or os.time()
  max_items = max_items or CLOSED_TABS_MAX
  max_age = max_age or CLOSED_TABS_MAX_AGE
  local kept = {}
  for _, e in ipairs(list(entries)) do
    if type(e) == "table" and (e.kind == "window" or e.kind == "session") then
      local ts = tonumber(e.closed_ts) or 0
      if now - ts <= max_age then
        kept[#kept + 1] = e
      end
    end
  end
  if #kept > max_items then
    local trimmed = {}
    for i = #kept - max_items + 1, #kept do
      trimmed[#trimmed + 1] = kept[i]
    end
    return trimmed
  end
  return kept
end

function M.diff_closed(before, snap, now)
  if type(before) ~= "table" or type(snap) ~= "table" then return {} end
  local bi = before.server and before.server.instance_id
  local si = snap.server and snap.server.instance_id
  if not bi or not si or bi ~= si then return {} end
  -- If every tab on the server vanished at once (e.g. server exit/teardown),
  -- don't treat it as the user manually closing tabs.
  if M.counts(snap).tabs == 0 then return {} end

  now = now or os.time()
  local closed_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now)
  local live_sessions = {}
  for _, s in ipairs(list(snap.sessions)) do
    if s.session_id then live_sessions[s.session_id] = s end
  end

  local closed = {}
  for _, bs in ipairs(list(before.sessions)) do
    local b_windows = list(bs.windows)
    if #b_windows > 0 then
      local live_s = bs.session_id and live_sessions[bs.session_id]
      if not live_s then
        if not M.is_default_session(bs) then
          closed[#closed + 1] = {
            kind = "session",
            closed_at = closed_at,
            closed_ts = now,
            server_instance = bi,
            session_id = bs.session_id,
            session_label = bs.label,
            session = bs,
          }
        end
      else
        local live_win_ids = {}
        for _, lw in ipairs(list(live_s.windows)) do
          if lw.window_id then live_win_ids[lw.window_id] = true end
        end
        local window_order = {}
        for _, bw in ipairs(b_windows) do
          if bw.window_id then window_order[#window_order + 1] = bw.window_id end
        end
        for wi, bw in ipairs(b_windows) do
          if bw.window_id and not live_win_ids[bw.window_id] then
            closed[#closed + 1] = {
              kind = "window",
              closed_at = closed_at,
              closed_ts = now,
              server_instance = bi,
              session_id = bs.session_id,
              session_label = bs.label,
              window_id = bw.window_id,
              window_index = wi,
              window_order = window_order,
              window = bw,
            }
          end
        end
      end
    end
  end
  return closed
end

local function record_closed_tabs(before, snap, now, path)
  local newly_closed = M.diff_closed(before, snap, now)
  if #newly_closed == 0 then return end
  local target = path or CLOSED_TABS_FILE
  local stack = read_closed_tabs(target)
  for _, entry in ipairs(newly_closed) do
    stack[#stack + 1] = entry
  end
  write_json(target, M.prune_closed_tabs(stack, now))
end

local function save()
  ensure_dirs()
  local snap = collect()
  local path = snapshot_path(snap.server.instance_id)
  local before = read_json(path)
  if type(before) == "table" and M.big_drop(before, snap) then
    local name = AUTO_PREFIX .. os.date("%Y%m%d-%H%M%S")
    write_json(checkpoint_path(name), before)
    local auto = {}
    for _, p in ipairs(list_dir(CHECKPOINT_DIR, ".json")) do
      if basename(p):sub(1, #AUTO_PREFIX) == AUTO_PREFIX then auto[#auto + 1] = p end
    end
    keep_newest(auto, AUTO_KEEP)
    local a, b = M.counts(before), M.counts(snap)
    log(string.format("%d tabs and %d chats closed at once (%d -> %d tabs); kept the save from " ..
                      "before as checkpoint %s. Run durable_repair to bring them back.",
                      a.tabs - b.tabs, a.chats - b.chats, a.tabs, b.tabs, name), "warn")
    notify(string.format("%d Rex tabs closed at once. rex-durable kept a copy. " ..
                         "To bring them back, run Durable: Repair Missing Tabs.", a.tabs - b.tabs))
  end
  record_closed_tabs(before, snap)
  write_json(path, snap)
  add_history(snap)
  prune_block_records(snap)
  local all = load_snapshots()
  for i = KEEP_SNAPSHOTS + 1, #all do os.remove(all[i].path) end
  return snap
end

---------------------------------------------------------------------------
-- Commands that reopen a chat

local fx_help = {}
local function fx_accepts(exe, option)
  if fx_help[exe] == nil then
    local r = run({ exe, "--help" }, { timeout = 10 })
    fx_help[exe] = r and ((r.stdout or "") .. (r.stderr or "")) or false
  end
  if not fx_help[exe] then return option ~= "--sessions-v2" end
  return fx_help[exe]:find(option, 1, true) ~= nil
end
M.fx_accepts = fx_accepts

function M.kept_options(argv, spec)
  local out, i = {}, 2
  argv = list(argv)
  spec = spec or { values = {}, switches = {} }
  local switches = spec.switches or {}
  local values = spec.values or {}
  local optional_values = spec.optional_values or {}
  while i <= #argv do
    local a = argv[i]
    if a == "--" then break end
    i = i + 1
    local name = a:match("^(%-%-?[%w%-]+)=") or a
    if switches[a] then
      out[#out + 1] = a
    elseif values[name] then
      if a ~= name then
        out[#out + 1] = a
      elseif i <= #argv then
        out[#out + 1] = a
        out[#out + 1] = argv[i]
        i = i + 1
      end
    elseif optional_values[name] then
      if a ~= name then
        out[#out + 1] = a
      else
        out[#out + 1] = a
        if i <= #argv and optional_value_arg(argv[i]) then
          out[#out + 1] = argv[i]
          i = i + 1
        end
      end
    end
  end
  return out
end

local function chat_executable(pane)
  local exe = list(pane.argv)[1]
  if not exe or not is_app_executable(pane.app, exe) then exe = pane.app end
  if exe:find("/", 1, true) and not file_exists(exe) then exe = basename(exe) end
  return exe
end

function M.resume_argv(pane, accepts)
  accepts = accepts or fx_accepts
  local exe = chat_executable(pane)
  local argv = { exe }
  if pane.app == "codex" then argv[#argv + 1] = "resume" end
  local has_v2 = false
  for _, option in ipairs(M.kept_options(pane.argv, M.CHATS[pane.app])) do
    if option == "--sessions-v2" then
      if accepts(exe, "--sessions-v2") and not has_v2 then
        has_v2 = true
        argv[#argv + 1] = option
      end
    else
      argv[#argv + 1] = option
    end
  end
  if pane.app == "fx" then
    if pane.store == "v2" and not has_v2 and accepts(exe, "--sessions-v2") then
      argv[#argv + 1] = "--sessions-v2"
    end
    argv[#argv + 1] = "--resume"
  elseif pane.app == "claude" or pane.app == "droid" or pane.app == "cursor-agent" then
    argv[#argv + 1] = "--resume"
  elseif pane.app == "pi" then
    argv[#argv + 1] = "--session"
    if pane.session_file and not under(pane.session_file, pi_sessions_root() .. "/") then
      argv[#argv + 1] = pane.session_file
      return argv
    end
  elseif pane.app == "agy" then
    argv[#argv + 1] = "--conversation"
  end
  argv[#argv + 1] = pane.id
  return argv
end

local function command_for(pane)
  if pane.kind == "chat" then return M.join(M.resume_argv(pane)) .. "\n" end
  if pane.kind == "program" and #list(pane.argv) > 0 then return M.join(pane.argv) end
end

local function open_chats(saved, live)
  local open = {}
  for _, s in ipairs(list(live and live.sessions)) do
    for _, w in ipairs(list(s.windows)) do
      for _, p in ipairs(M.panes(w.layout)) do
        if p.kind == "chat" and p.id then open[p.app .. ":" .. p.id] = true end
      end
    end
  end
  local paths, owner = {}, {}
  for _, s in ipairs(list(saved.sessions)) do
    for _, w in ipairs(list(s.windows)) do
      for _, p in ipairs(M.panes(w.layout)) do
        if p.kind == "chat" and p.id then
          local path = p.session_file
          if p.app == "fx" then
            path = HOME .. "/.fx/sessions/" ..
              (p.store == "v2" and ("v2/" .. p.id .. "/lock") or (p.id .. "/session.lock"))
          elseif p.app == "agy" then
            path = path or (HOME .. "/.gemini/antigravity-cli/brain/" .. p.id)
          elseif p.app == "cursor-agent" then
            if not path and p.cwd then
              local hash = M.md5(normalize_cwd(p.cwd))
              if hash then path = HOME .. "/.cursor/chats/" .. hash .. "/" .. p.id .. "/store.db" end
            end
          end
          if path and p.app ~= "claude" and p.app ~= "pi" and p.app ~= "droid" then
            paths[#paths + 1] = path
            owner[path] = p.app .. ":" .. p.id
          end
        end
      end
    end
  end
  for path in pairs(held_files(paths)) do
    if owner[path] then open[owner[path]] = true end
  end
  return open
end

---------------------------------------------------------------------------
-- Reopening programs in the tabs Rex restored

function M.plan_reopen(saved, live, open, opts)
  opts = opts or {}
  local writes, notes, busy = {}, {}, 0
  local skip = opts.skip_blocks or {}
  local by_id, by_label, by_block = {}, {}, {}
  for _, s in ipairs(list(live.sessions)) do
    by_id[s.session_id] = s
    by_label[s.label or ""] = by_label[s.label or ""] or {}
    table.insert(by_label[s.label or ""], s)
    for _, w in ipairs(list(s.windows)) do
      for _, p in ipairs(M.panes(w.layout)) do by_block[p.block_id] = { pane = p, session = s } end
    end
  end
  local used, claimed = {}, {}
  for _, s in ipairs(list(saved.sessions)) do
    local target = by_id[s.session_id]
    if not target then
      for _, candidate in ipairs(by_label[s.label or ""] or {}) do
        if not used[candidate.session_id] then target = candidate break end
      end
    end
    if target then used[target.session_id] = true end
    for wi, w in ipairs(list(s.windows)) do
      local want = M.panes(w.layout)
      local have_list
      local tw = target and list(target.windows)[wi]
      if tw and #list(target.windows) == #list(s.windows) then
        have_list = M.panes(tw.layout)
        if #have_list ~= #want then have_list = nil end
      end
      for pi, p in ipairs(want) do
        local where = string.format("%s tab %d", s.label or "session", wi)
        if #want > 1 then where = where .. string.format(" pane %d", pi) end
        local command = command_for(p)
        if command and (p.kind == "chat" or opts.programs ~= false) then
          local hit = by_block[p.block_id]
          local have, session_id = hit and hit.pane, hit and hit.session.session_id
          if not have and have_list then have, session_id = have_list[pi], target.session_id end
          local key = p.kind == "chat" and (p.app .. ":" .. p.id)
          if not have then
            notes[#notes + 1] = where .. ": no matching tab"
          elseif skip[have.block_id] then
            -- Typed into on an earlier try.
          elseif (have.kind == "chat" and key == (have.app .. ":" .. tostring(have.id)))
            or (have.kind == "program" and p.kind == "program"
                and M.join(list(have.argv)) == M.join(list(p.argv))) then
            -- Already running in its own tab.
          elseif have.kind ~= "shell" or claimed[have.block_id] then
            notes[#notes + 1] = where .. ": the tab is busy, left alone"
            busy = busy + 1
          elseif key and open[key] then
            notes[#notes + 1] = where .. ": " .. p.app .. " chat " .. p.id .. " is already open"
          else
            if p.cwd and have.cwd and p.cwd ~= have.cwd and (opts.dir_exists or dir_exists)(p.cwd) then
              command = "cd " .. M.quote(p.cwd) .. " && " .. command
            end
            claimed[have.block_id] = true
            if key then open[key] = true end
            writes[#writes + 1] = { session_id = session_id, block_id = have.block_id,
                                    data = command, where = where, kind = p.kind, key = key or nil,
                                    pane = p }
          end
        end
      end
    end
  end
  return writes, notes, busy
end

local function perform(writes)
  local completed = {}
  for _, w in ipairs(writes) do
    ensure_session(w.session_id)
    -- Guard with Rex's terminal.modes so we never type shell commands into an alternate-screen TUI.
    local modes = rex.block.call(TERMINAL, "modes",
      { session_id = w.session_id, block_id = w.block_id })
    if type(modes) == "table" and modes.screen == "alternate" then
      log(w.where .. ": alternate screen active, left alone")
    else
      local ok, err = rex.block.call(TERMINAL, "write",
        { session_id = w.session_id, block_id = w.block_id, data = w.data })
      if ok then
        completed[#completed + 1] = w
      else
        log(w.where .. ": couldn't type into the tab: " .. tostring(err))
      end
      rex.sleep(TYPE_DELAY)
    end
  end
  return completed
end

local function count_kind(writes, kind)
  local n = 0
  for _, w in ipairs(writes) do if w.kind == kind then n = n + 1 end end
  return n
end

local function record_reopened(instance_id, writes)
  if not instance_id or #writes == 0 then return end
  local state = read_state()
  if state.reopened_instance ~= instance_id or type(state.reopened) ~= "table" then
    state.reopened_instance = instance_id
    state.reopened = {}
  end
  local changed = false
  for _, w in ipairs(writes) do
    if w.kind == "chat" and w.pane and w.pane.id then
      state.reopened[w.block_id] = {
        app = w.pane.app,
        id = w.pane.id,
        session_file = w.pane.session_file,
        cwd = w.pane.cwd,
        argv = M.resume_argv(w.pane),
      }
      changed = true
    end
  end
  if changed then write_json(STATE_FILE, state) end
end

local function reopen(saved, live, dry_run, tries)
  local written, typed, planned = {}, {}, {}
  local chats, programs, last_notes = 0, 0, {}
  tries = (dry_run and 1) or tries or SETTLE_TRIES
  for try = 1, tries do
    if try > 1 then
      rex.sleep(SETTLE_WAIT)
      live = collect()
    end
    local open = open_chats(saved, live)
    for key in pairs(typed) do open[key] = true end
    local writes, notes, busy = M.plan_reopen(saved, live, open,
      { programs = args.programs, skip_blocks = written })
    last_notes = notes
    for _, w in ipairs(writes) do
      local preview = (w.data:gsub("\n$", w.kind == "chat" and " (run)" or ""))
      log(string.format("  %s %s: %s", dry_run and "would type" or "type", w.where, preview))
      planned[#planned + 1] = { where = w.where, block_id = w.block_id, kind = w.kind, command = preview }
    end
    if not dry_run then
      local completed = perform(writes)
      record_reopened(live and live.server and live.server.instance_id, completed)
      for _, w in ipairs(completed) do
        written[w.block_id] = true
        if w.key then typed[w.key] = true end
      end
      chats = chats + count_kind(completed, "chat")
      programs = programs + count_kind(completed, "program")
    end
    if busy == 0 or try == tries then
      for _, note in ipairs(notes) do log("  skip " .. note) end
      break
    end
    log(string.format("  %d tabs are busy, maybe still starting; trying again in %d seconds",
                      busy, SETTLE_WAIT))
  end
  return chats, programs, planned, last_notes
end

---------------------------------------------------------------------------
-- Rebuilding sessions using official `rex.layout.*` builders & fidelity

local function build_split(direction, ratio, before, after)
  if rex.layout and rex.layout.horizontal and rex.layout.vertical then
    if direction == "vertical" then
      return rex.layout.vertical(ratio or 0.5, before, after)
    end
    return rex.layout.horizontal(ratio or 0.5, before, after)
  end
  return { split = { direction = direction, ratio = ratio or 0.5, before = before, after = after } }
end

local function build_block(options, label)
  local spec = { flavor = SHELL_FLAVOR }
  if label and label ~= "" and label ~= "shell" then spec.label = label end
  if next(options) then spec.options = options end
  if rex.layout and rex.layout.block then return rex.layout.block(spec) end
  return { block = spec }
end

local function create_layout(node, open, leaves)
  if node.split then
    return build_split(
      node.split.direction,
      node.split.ratio,
      create_layout(node.split.before, open, leaves),
      create_layout(node.split.after, open, leaves)
    )
  end
  local p = node.pane
  leaves[#leaves + 1] = p
  local options = {}
  if p.cwd and dir_exists(p.cwd) then options.cwd = p.cwd end
  local key = p.kind == "chat" and (p.app .. ":" .. p.id)
  if not (key and open[key]) then
    local command = command_for(p)
    if command and (p.kind == "chat" or args.programs ~= false) then options.initial_input = command end
    if key then open[key] = true end
  end
  return build_block(options, p.label)
end

-- Restore custom block labels, focused pane, and zoomed state for a created window.
local function apply_window_fidelity(session_id, window_id, block_ids, leaves, writes_out)
  ensure_session(session_id)
  local focused_idx, has_zoom = 1, false
  for j, p in ipairs(leaves or {}) do
    local bid = list(block_ids)[j]
    if bid then
      if p.label and p.label ~= "" and p.label ~= "shell" then
        rex.session.set_block_label{ session_id = session_id, block_id = bid, label = p.label }
      end
      if p.focused then focused_idx = j end
      if p.zoomed then has_zoom = true end
      if writes_out and p.kind == "chat" and p.id then
        writes_out[#writes_out + 1] = { block_id = bid, kind = "chat", pane = p }
      end
    end
  end
  local focus_bid = list(block_ids)[focused_idx]
  if focus_bid then
    rex.session.focus_block{ session_id = session_id, block_id = focus_bid }
  end
  if has_zoom and window_id then
    rex.session.zoom_block{ session_id = session_id, window_id = window_id, zoom = true }
  elseif has_zoom and focus_bid then
    rex.session.zoom_block{ session_id = session_id, block_id = focus_bid, zoom = true }
  end
  return focus_bid
end

local function rebuild_session(s, open, instance_id)
  local windows, leaves_by_window = {}, {}
  for i, w in ipairs(s.windows) do
    local leaves = {}
    local window = { layout = create_layout(w.layout, open, leaves) }
    if w.label then window.window_label = w.label end
    windows[i], leaves_by_window[i] = window, leaves
  end
  local request = { initial_windows = windows }
  if s.label then request.label = s.label end
  local result, err = rex.call("session.create", request)
  if not result and request.label then
    request.label = request.label .. " (restored)"
    result, err = rex.call("session.create", request)
  end
  if result then
    log("  rebuilt session " .. tostring(s.label))
    ensure_session(result.session_id)
    local active_window_id
    local writes = {}
    for i, made_window in ipairs(list(result.initial_windows)) do
      apply_window_fidelity(
        result.session_id, made_window.window_id, made_window.block_ids, leaves_by_window[i], writes
      )
      if s.windows[i].active then active_window_id = made_window.window_id end
    end
    if active_window_id then
      rex.session.focus_window{ session_id = result.session_id, window_id = active_window_id }
    end
    record_reopened(instance_id, writes)
    rex.sleep(TYPE_DELAY)
    return result.session_id, result
  end
  log("  couldn't rebuild session " .. tostring(s.label) .. ": " .. tostring(err))
end

local function rebuild(saved, live)
  local open = open_chats(saved, live)
  local instance_id = live and live.server and live.server.instance_id
  local made = 0
  for _, s in ipairs(list(saved.sessions)) do
    if not M.is_default_session(s) and #list(s.windows) > 0 and rebuild_session(s, open, instance_id) then
      made = made + 1
    end
  end
  return made
end

---------------------------------------------------------------------------
-- Repairing tabs that closed while the server kept running

function M.plan_repair(saved, live, open, repaired)
  repaired = repaired or {}
  local by_id, by_label, blocks, windows = {}, {}, {}, {}
  for _, s in ipairs(list(live.sessions)) do
    by_id[s.session_id] = s
    by_label[s.label or ""] = by_label[s.label or ""] or s
    for _, w in ipairs(list(s.windows)) do
      if w.window_id then windows[w.window_id] = true end
      for _, p in ipairs(M.panes(w.layout)) do blocks[p.block_id] = true end
    end
  end
  local actions = {}
  for _, s in ipairs(list(saved.sessions)) do
    if not M.is_default_session(s) and #list(s.windows) > 0 then
      local target = by_id[s.session_id] or by_id[repaired[s.session_id] or ""] or by_label[s.label or ""]
      if not target then
        actions[#actions + 1] = { kind = "session", saved = s }
      else
        for wi, w in ipairs(list(s.windows)) do
          local again = w.window_id and repaired[w.window_id]
          local present, chats, open_count = again ~= nil and windows[again] == true, 0, 0
          for _, p in ipairs(M.panes(w.layout)) do
            if blocks[p.block_id] then present = true end
            if p.kind == "chat" then
              chats = chats + 1
              if open[p.app .. ":" .. tostring(p.id)] then open_count = open_count + 1 end
            end
          end
          if not present and not (chats > 0 and open_count == chats) then
            actions[#actions + 1] = { kind = "window", session_id = target.session_id,
                                      label = s.label, saved = w, index = wi, session = s }
          end
        end
      end
    end
  end
  return actions
end

local function reorder_windows(session_id, saved_session, made)
  local view = session_view(session_id)
  if not view then return end
  local window_of = {}
  for _, w in ipairs(list(view.windows)) do
    for _, layer in ipairs(list(w.layers)) do
      for _, b in ipairs(list(layer.blocks)) do window_of[b.block_id] = w.window_id end
    end
  end
  local ordered, used = {}, {}
  for wi, w in ipairs(list(saved_session.windows)) do
    local id = made[wi]
    if not id then
      for _, p in ipairs(M.panes(w.layout)) do id = id or window_of[p.block_id] end
    end
    if id and not used[id] then ordered[#ordered + 1] = id; used[id] = true end
  end
  for _, w in ipairs(list(view.windows)) do
    if not used[w.window_id] then ordered[#ordered + 1] = w.window_id end
  end
  for _, id in ipairs(ordered) do
    rex.call("session.move_window", { session_id = session_id, window_id = id })
  end
end

local function repair(saved, dry_run)
  local live = collect()
  local chats, programs, planned_writes = reopen(saved, live, dry_run, 1)
  live = collect()
  local instance_id = live and live.server and live.server.instance_id
  local open = open_chats(saved, live)
  local state = read_state()
  state.repaired = state.repaired or {}
  local actions = M.plan_repair(saved, live, open, state.repaired)
  local tabs, sessions, made, touched, new_writes, planned_adds = 0, 0, {}, {}, {}, {}
  for _, a in ipairs(actions) do
    if a.kind == "session" then
      log(string.format("  %s session %s (%d tabs)", dry_run and "would rebuild" or "rebuild",
                        tostring(a.saved.label), #list(a.saved.windows)))
      planned_adds[#planned_adds + 1] = { kind = "session", label = a.saved.label,
                                          tabs = #list(a.saved.windows) }
      if not dry_run then
        local new_id, result = rebuild_session(a.saved, open, instance_id)
        if new_id then
          sessions = sessions + 1
          state.repaired[a.saved.session_id] = new_id
          for i, w in ipairs(list(result.initial_windows)) do
            local saved_window = list(a.saved.windows)[i]
            if saved_window and saved_window.window_id and w.window_id then
              state.repaired[saved_window.window_id] = w.window_id
            end
          end
        end
      end
    else
      log(string.format("  %s %s tab %d", dry_run and "would add" or "add", tostring(a.label), a.index))
      planned_adds[#planned_adds + 1] = { kind = "window", session = a.label, tab = a.index }
      if not dry_run then
        ensure_session(a.session_id)
        local leaves = {}
        local layout = create_layout(a.saved.layout, open, leaves)
        local request = { session_id = a.session_id, layout = layout, focus = false }
        if a.saved.label then request.window_label = a.saved.label end
        local result, err = rex.call("session.new_window", request)
        if result then
          tabs = tabs + 1
          made[a.session_id] = made[a.session_id] or {}
          made[a.session_id][a.index] = result.window_id
          if a.saved.window_id then state.repaired[a.saved.window_id] = result.window_id end
          apply_window_fidelity(a.session_id, result.window_id, result.block_ids, leaves, new_writes)
          touched[a.session_id] = a.session
          rex.sleep(TYPE_DELAY)
        else
          log("  couldn't add the tab: " .. tostring(err))
        end
      end
    end
  end
  if not dry_run then
    local latest = read_state()
    latest.repaired = state.repaired
    write_json(STATE_FILE, latest)
    record_reopened(instance_id, new_writes)
    for session_id, saved_session in pairs(touched) do
      reorder_windows(session_id, saved_session, made[session_id] or {})
    end
    local current = {}
    for _, s in ipairs(list((rex.call("session.list") or {}).sessions)) do current[s.label or ""] = s.session_id end
    if sessions > 0 then
      local moved = {}
      for _, s in ipairs(list(saved.sessions)) do
        local id = current[s.label or ""]
        if id and not moved[id] then
          rex.call("session.move", { session_id = id })
          moved[id] = true
        end
      end
      for _, s in ipairs(list((rex.call("session.list") or {}).sessions)) do
        if not moved[s.session_id] then rex.call("session.move", { session_id = s.session_id }) end
      end
    end
  end
  return chats, programs, tabs, sessions, planned_adds, planned_writes
end

local function tell(message)
  emit_text(message)
  if args.palette == true then notify(message) end
end

---------------------------------------------------------------------------
-- Undoing recently closed tabs and sessions

function M.insert_window_order(current_ids, new_id, before_ids, old_id, target_index)
  local rest, pos_of = {}, {}
  for _, id in ipairs(list(current_ids)) do
    if id ~= new_id then
      rest[#rest + 1] = id
      pos_of[id] = #rest
    end
  end
  local old_idx
  for i, id in ipairs(list(before_ids)) do
    if id == old_id then old_idx = i break end
  end
  local prev_pos, next_pos
  if old_idx then
    for i = old_idx - 1, 1, -1 do
      if pos_of[before_ids[i]] then prev_pos = pos_of[before_ids[i]] break end
    end
    for i = old_idx + 1, #before_ids do
      if pos_of[before_ids[i]] then next_pos = pos_of[before_ids[i]] break end
    end
  end
  local pos
  if prev_pos then
    pos = prev_pos + 1
  elseif next_pos then
    pos = math.min(next_pos, target_index or next_pos)
  else
    pos = math.min(target_index or (#rest + 1), #rest + 1)
  end
  if pos < 1 then pos = 1 end
  if pos > #rest + 1 then pos = #rest + 1 end
  table.insert(rest, pos, new_id)
  return rest
end

local function place_window_in_order(session_id, new_window_id, entry)
  local view = session_view(session_id)
  if not view then return end
  local current_ids = {}
  for _, w in ipairs(list(view.windows)) do
    if w.window_id then current_ids[#current_ids + 1] = w.window_id end
  end
  local ordered = M.insert_window_order(
    current_ids, new_window_id, entry.window_order, entry.window_id, entry.window_index
  )
  for _, id in ipairs(ordered) do
    rex.call("session.move_window", { session_id = session_id, window_id = id })
  end
end

local function inspect_entry_panes(windows, open, include_programs)
  local seen = {}
  for k, v in pairs(open or {}) do seen[k] = v end
  local chats, skipped, programs = {}, {}, {}
  for _, w in ipairs(list(windows)) do
    for _, p in ipairs(M.panes(w and w.layout)) do
      if p.kind == "chat" and p.id then
        local key = p.app .. ":" .. p.id
        if seen[key] then
          skipped[#skipped + 1] = { app = p.app, id = p.id, reason = "already open" }
        else
          seen[key] = true
          chats[#chats + 1] = { app = p.app, id = p.id, command = M.join(M.resume_argv(p)) }
        end
      elseif p.kind == "program" and include_programs and #list(p.argv) > 0 then
        programs[#programs + 1] = { command = M.join(p.argv) }
      end
    end
  end
  return chats, skipped, programs
end

local function undo_close(dry_run)
  ensure_dirs()
  local raw = read_closed_tabs()
  local stack = M.prune_closed_tabs(raw)
  if #stack == 0 then
    if #raw > 0 and not dry_run then write_json(CLOSED_TABS_FILE, {}) end
    local msg = "No recently closed tabs to reopen."
    tell(msg)
    if JSON_MODE then
      return { restored = false, dry_run = dry_run == true, remaining = 0, message = msg }
    end
    return
  end

  local entry = stack[#stack]
  local live = collect()
  local saved_for_open = entry.kind == "session"
    and { sessions = { entry.session } }
    or { sessions = { { session_id = entry.session_id, label = entry.session_label, windows = { entry.window } } } }
  local open = open_chats(saved_for_open, live)
  local already_open = {}
  for k, v in pairs(open) do already_open[k] = v end
  local windows = entry.kind == "session"
    and list(entry.session and entry.session.windows)
    or { entry.window }
  local chats, skipped, programs = inspect_entry_panes(windows, open, args.programs ~= false)
  local label = entry.session_label or entry.session_id or "session"

  for _, s in ipairs(skipped) do
    log(string.format("  skip %s chat %s: already open", s.app, s.id))
  end

  if dry_run then
    if entry.kind == "session" then
      emit_text(string.format("Would reopen closed session %s (%d tabs, %d chats, %d skipped).",
        tostring(label), #windows, #chats, #skipped))
    else
      emit_text(string.format("Would reopen closed tab %s #%s (%d chats, %d skipped).",
        tostring(label), tostring(entry.window_index or "?"), #chats, #skipped))
    end
    for _, c in ipairs(chats) do
      log("  would run: " .. c.command)
    end
    if JSON_MODE then
      return {
        restored = false,
        dry_run = true,
        kind = entry.kind,
        session_label = entry.session_label,
        window_index = entry.window_index,
        window_label = entry.kind == "window" and entry.window and entry.window.label or nil,
        closed_at = entry.closed_at,
        tabs = #windows,
        chats = chats,
        skipped = skipped,
        programs = programs,
        remaining = #stack - 1,
      }
    end
    return
  end

  local instance_id = live and live.server and live.server.instance_id
  local restored_session_id, restored_window_id
  if entry.kind == "session" then
    local new_sid, res = rebuild_session(entry.session, open, instance_id)
    if not new_sid then
      local msg = "Couldn't reopen closed session " .. tostring(label) .. "."
      tell(msg)
      if JSON_MODE then return { restored = false, dry_run = false, remaining = #stack, message = msg } end
      return
    end
    restored_session_id = new_sid
    restored_window_id = list(res and res.initial_windows)[1] and res.initial_windows[1].window_id or nil
  else
    local target
    for _, s in ipairs(list(live.sessions)) do
      if s.session_id == entry.session_id then target = s break end
    end
    if not target and entry.session_label then
      for _, s in ipairs(list(live.sessions)) do
        if s.label == entry.session_label then target = s break end
      end
    end
    if target then
      ensure_session(target.session_id)
      local leaves = {}
      local layout = create_layout(entry.window.layout, open, leaves)
      local request = { session_id = target.session_id, layout = layout, focus = true }
      if entry.window.label then request.window_label = entry.window.label end
      local result, err = rex.call("session.new_window", request)
      if not result then
        local msg = "Couldn't reopen closed tab: " .. tostring(err)
        tell(msg)
        if JSON_MODE then return { restored = false, dry_run = false, remaining = #stack, message = msg } end
        return
      end
      local new_writes = {}
      local focus_bid = apply_window_fidelity(
        target.session_id, result.window_id, result.block_ids, leaves, new_writes
      )
      place_window_in_order(target.session_id, result.window_id, entry)
      rex.session.focus_window{ session_id = target.session_id, window_id = result.window_id }
      if focus_bid then
        rex.session.focus_block{ session_id = target.session_id, block_id = focus_bid }
      end
      local recorded = {}
      for _, w in ipairs(new_writes) do
        local key = w.pane and w.pane.app and w.pane.id and (w.pane.app .. ":" .. w.pane.id)
        if not (key and already_open[key]) then recorded[#recorded + 1] = w end
      end
      record_reopened(instance_id, recorded)
      rex.sleep(TYPE_DELAY)
      restored_session_id, restored_window_id = target.session_id, result.window_id
    else
      local synth = {
        session_id = entry.session_id,
        label = entry.session_label,
        windows = { entry.window },
      }
      local new_sid, res = rebuild_session(synth, open, instance_id)
      if not new_sid then
        local msg = "Couldn't reopen closed tab for missing session " .. tostring(label) .. "."
        tell(msg)
        if JSON_MODE then return { restored = false, dry_run = false, remaining = #stack, message = msg } end
        return
      end
      restored_session_id = new_sid
      restored_window_id = list(res and res.initial_windows)[1] and res.initial_windows[1].window_id or nil
    end
  end

  table.remove(stack)
  write_json(CLOSED_TABS_FILE, stack)

  local summary
  if entry.kind == "session" then
    summary = string.format("Reopened closed session %s (%d tabs, %d chats).",
      tostring(label), #windows, #chats)
  else
    summary = string.format("Reopened closed tab in %s (%d chats).", tostring(label), #chats)
  end
  tell(summary)
  if JSON_MODE then
    return {
      restored = true,
      dry_run = false,
      kind = entry.kind,
      session_id = restored_session_id,
      session_label = entry.session_label,
      window_id = restored_window_id,
      window_index = entry.window_index,
      window_label = entry.kind == "window" and entry.window and entry.window.label or nil,
      closed_at = entry.closed_at,
      tabs = #windows,
      chats = chats,
      skipped = skipped,
      programs = programs,
      remaining = #stack,
    }
  end
end

---------------------------------------------------------------------------
-- Modes

local function startup()
  ensure_dirs()
  local status = assert(rex.call("server.status"))
  local state = read_state()
  if state.instance == status.instance_id then return save() end
  state.instance = status.instance_id
  write_json(STATE_FILE, state)
  local saved = previous_snapshot(status.instance_id)
  local cutoff = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - MAX_AGE_DAYS * 86400)
  if not saved or M.is_blank(saved) or saved.saved_at < cutoff then
    log("new Rex server; nothing to bring back")
    return save()
  end
  log("new Rex server; bringing back the save from " .. saved.saved_at)
  local live = collect()
  if M.is_blank(live) then
    local made = rebuild(saved, live)
    log(string.format("rebuilt %d sessions", made))
    if made > 0 then notify(string.format("Brought back %d sessions.", made)) end
  else
    local chats, programs = reopen(saved, live, false)
    log(string.format("reopened %d chats; typed %d other programs", chats, programs))
    if chats + programs > 0 then
      local text = string.format("Reopened %d chats", chats)
      if programs > 0 then text = text .. string.format(" and typed %d other programs", programs) end
      notify(text .. ".")
    end
  end
  local updated = read_state()
  updated.last_restore = { at = now_iso(), from = saved.saved_at, instance = status.instance_id }
  write_json(STATE_FILE, updated)
  return save()
end

local function status_mode()
  local status = rex.call("server.status") or {}
  local snaps = load_snapshots()
  local state = read_state()

  local recent = {}
  for i = 1, math.min(#snaps, 3) do
    local snap = snaps[i]
    local summary_text, chats, programs, apps = M.summary(snap)
    recent[#recent + 1] = {
      saved_at = snap.saved_at,
      this_server = snap.server.instance_id == status.instance_id,
      instance_id = snap.server.instance_id,
      summary = summary_text,
      chats = chats,
      programs = programs,
      apps = apps,
    }
  end

  local checkpoints = {}
  for _, path in ipairs(list_dir(CHECKPOINT_DIR, ".json")) do
    local snap = read_json(path) or {}
    local name = basename(path):gsub("%.json$", "")
    local summary_text, chats, programs = M.summary(snap)
    checkpoints[#checkpoints + 1] = {
      name = name,
      saved_at = snap.saved_at,
      summary = summary_text,
      chats = chats,
      programs = programs,
    }
  end

  if JSON_MODE then
    if args.palette == true and recent[1] then
      notify("Saved: " .. recent[1].summary)
    end
    return {
      version = M.VERSION,
      state_dir = STATE_DIR,
      server = {
        instance_id = status.instance_id,
        host_id = status.host_id,
        started_at = status.started_at,
      },
      snapshots = recent,
      checkpoints = checkpoints,
      last_restore = state.last_restore,
    }
  end

  emit_text("rex-durable " .. M.VERSION .. " (" .. STATE_DIR .. ")")
  emit_text("Rex server: " .. tostring(status.instance_id) .. ", started " .. tostring(status.started_at))
  if #recent == 0 then emit_text("No saves yet.") end
  for _, r in ipairs(recent) do
    local which = r.this_server and "this server" or "an earlier server"
    emit_text(string.format("Save from %s (%s): %s", r.saved_at, which, r.summary))
  end
  for _, c in ipairs(checkpoints) do
    emit_text(string.format("Checkpoint %s, from %s: %s", c.name, tostring(c.saved_at), c.summary))
  end
  if state.last_restore then
    emit_text(string.format("Last brought back at %s, from the save of %s", state.last_restore.at,
                            state.last_restore.from))
  end
end

-- In-process event-driven watcher following Rex Lua Events best practices:
--   * Subscribes to `terminal.process_changed` (fires whenever foreground agent
--     processes start or exit inside a shell) plus layout/status events.
--   * Uses trailing burst debounce (`pending:cancel()` + `rex.after`) bounded by
--     `MAX_DEBOUNCE_WAIT`, running `startup()` / `save()` directly in-process
--     without spawning child `rex` processes.
local function watch()
  is_all_scope = true -- `rex do --all` already bootstrapped event_scope="all"
  local instance
  local pending, burst_started_at

  local function cancel_pending()
    if pending then
      pending:cancel()
      pending = nil
    end
    burst_started_at = nil
  end

  local function tick()
    cancel_pending()
    local status = rex.call("server.status")
    if not status then return end
    local ok, err
    if status.instance_id ~= instance then
      instance = status.instance_id
      ok, err = pcall(startup)
    else
      ok, err = pcall(save)
    end
    if not ok then log("watcher tick error: " .. tostring(err), "error") end
  end

  local function schedule_save()
    local now = os.time()
    if not burst_started_at then burst_started_at = now end
    if pending then
      if now - burst_started_at >= MAX_DEBOUNCE_WAIT then return end
      pending:cancel()
    end
    pending = rex.after(DEBOUNCE_WAIT, tick)
  end

  for _, event in ipairs({
    "session_created",
    "session_destroyed",
    "session_label_changed",
    "session_view_changed",
    "block_created",
    "block_closed",
    "terminal.process_changed",
    "terminal.program_status_changed",
    "terminal.pwd_changed",
    "terminal.child_exited",
  }) do
    rex.on(event, schedule_save)
  end

  log("rex-durable " .. M.VERSION .. " watching; saves in " .. STATE_DIR)
  tick()
  rex.every(SAVE_EVERY, tick)
end

local function main()
  local mode = args.mode or "watch"
  if mode == "watch" then return watch() end
  if mode == "version" then
    if JSON_MODE then return { tool = "rex-durable", version = M.VERSION } end
    emit_text("rex-durable " .. M.VERSION)
    return
  end
  if mode == "status" then return status_mode() end
  if mode == "startup" then
    local snap = startup()
    if JSON_MODE then
      local summary_text, chats, programs = M.summary(snap)
      return { saved_at = snap.saved_at, summary = summary_text, chats = chats, programs = programs }
    end
    return
  end
  if mode == "save" then
    local snap = save()
    local summary_text, chats, programs, apps = M.summary(snap)
    if args.verbose == true or args.palette == true then tell("Saved " .. summary_text .. ".") end
    if JSON_MODE then
      return { saved_at = snap.saved_at, summary = summary_text, chats = chats,
               programs = programs, apps = apps }
    end
    return
  end
  if mode == "checkpoint" then
    ensure_dirs()
    local snap = save()
    local name = args.name or os.date("%Y%m%d-%H%M%S")
    write_json(checkpoint_path(name), snap)
    local summary_text, chats, programs = M.summary(snap)
    tell("Pinned checkpoint " .. name .. ": " .. summary_text)
    if JSON_MODE then
      return { name = name, saved_at = snap.saved_at, summary = summary_text,
               chats = chats, programs = programs }
    end
    return
  end
  if mode == "reopen" then
    local saved = load_source(args.from)
    local live = collect()
    if not args.from then
      saved = previous_snapshot(live.server.instance_id) or saved
    end
    if not saved then
      emit_text("No save to reopen from.")
      if JSON_MODE then return { chats = 0, programs = 0, message = "No save to reopen from." } end
      return
    end
    emit_text("Reopening programs from the save of " .. saved.saved_at)
    local chats, programs, planned, notes = reopen(saved, live, args.dry_run == true)
    if args.dry_run ~= true then
      tell(string.format("Reopened %d chats; typed %d other programs.", chats, programs))
    end
    if JSON_MODE then
      return { from = saved.saved_at, dry_run = args.dry_run == true,
               chats = chats, programs = programs, writes = planned, notes = notes }
    end
    return
  end
  if mode == "repair" then
    local saved, from = nil, args.from
    if from then
      saved = load_source(from)
    else
      local auto = {}
      for _, p in ipairs(list_dir(CHECKPOINT_DIR, ".json")) do
        if basename(p):sub(1, #AUTO_PREFIX) == AUTO_PREFIX then auto[#auto + 1] = p end
      end
      table.sort(auto)
      if #auto > 0 then
        saved = read_json(auto[#auto])
        from = basename(auto[#auto]):gsub("%.json$", "")
      else
        saved = load_snapshots()[1]
        from = "the latest save"
      end
    end
    if not saved then
      emit_text("No save to repair from.")
      if JSON_MODE then return { tabs = 0, sessions = 0, chats = 0, programs = 0 } end
      return
    end
    emit_text(string.format("Repairing from %s (saved %s): %s", from, tostring(saved.saved_at), (M.summary(saved))))
    local chats, programs, tabs, sessions, adds, writes = repair(saved, args.dry_run == true)
    if args.dry_run ~= true then
      tell(string.format("Added %d tabs and %d sessions; reopened %d chats; typed %d other programs.",
                         tabs, sessions, chats, programs))
    end
    if JSON_MODE then
      return { source = from, saved_at = saved.saved_at, dry_run = args.dry_run == true,
               tabs = tabs, sessions = sessions, chats = chats, programs = programs,
               additions = adds, writes = writes }
    end
    return
  end
  if mode == "undo_close" then
    return undo_close(args.dry_run == true)
  end
  if mode == "rebuild" then
    local live = collect()
    local saved = args.from and load_source(args.from) or previous_snapshot(live.server.instance_id)
    if not saved then
      emit_text("No save to rebuild from.")
      if JSON_MODE then return { rebuilt = 0, message = "No save to rebuild from." } end
      return
    end
    if not M.is_blank(live) and args.yes ~= true then
      local msg = "This Rex server already has sessions. Use durable_reopen to put programs back in " ..
                  "them, or add yes=true to add the saved sessions next to them."
      emit_text(msg)
      if JSON_MODE then return { rebuilt = 0, message = msg } end
      return
    end
    local made = rebuild(saved, live)
    emit_text(string.format("Rebuilt %d sessions.", made))
    if JSON_MODE then return { rebuilt = made, from = saved.saved_at } end
    return
  end
  error("unknown mode " .. tostring(mode) ..
        "; use watch, status, save, reopen, repair, undo_close, checkpoint, rebuild, or version", 0)
end

-- For the tests: the helpers that read processes and files.
M._processes, M._open_files, M._held_files = processes, open_files, held_files
M._mtimes, M._argv_of = mtimes, argv_of

if rawget(_G, "REX_DURABLE_LIB") then return M end
local result = main()
if (rex.args or {}).mode ~= "watch" then detach_attached_sessions() end
return result
