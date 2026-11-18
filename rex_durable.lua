-- rex-durable custom actions for ~/.config/rex/init.lua.
--
-- Installed by install.sh as ~/.config/rex/rex_durable.lua and loaded via:
--
--   require("rex_durable")
--
-- Follows Rex Custom Actions best practices:
--   * Explicit typed `args` schemas so Rex validates CLI/keybinding arguments.
--   * Structured JSON return values when invoked from CLI/scripts (`rex do durable_status`).
--   * Non-blocking detached execution when invoked interactively from the Command Palette
--     or keyboard shortcuts (`ctx.origin == "palette" or ctx.origin == "key"`).

local REX = "@REX@"
local SCRIPT = "@SCRIPT@"
local CATEGORY = "Durable Sessions"

local function push_args(argv, tbl, keys)
  if type(tbl) ~= "table" then return end
  for _, k in ipairs(keys) do
    if tbl[k] ~= nil then
      argv[#argv + 1] = k .. "=" .. tostring(tbl[k])
    end
  end
end

local function is_interactive(ctx)
  local origin = type(ctx) == "table" and ctx.origin or nil
  return origin == "palette" or origin == "key"
end

local function reject_unexpected_args(tbl)
  if type(tbl) == "table" then
    local k = next(tbl)
    if k ~= nil then
      error(string.format('no argument named "%s"; this action takes no arguments', tostring(k)), 0)
    end
  end
end

local function run_sync(mode, action_args, keys, is_palette)
  local argv = { REX, "--autostart=false", "do", SCRIPT, "--all", "mode=" .. mode, "json=true" }
  if is_palette then argv[#argv + 1] = "palette=true" end
  push_args(argv, action_args, keys or {})
  local r, err = rex.exec(argv, { timeout = 25 })
  if r == nil then error("rex-durable: " .. tostring(err), 0) end
  if not r.ok then
    local msg = (r.stderr ~= "" and r.stderr) or r.stdout or ("exit code " .. tostring(r.code))
    error(msg:gsub("%s+$", ""), 0)
  end
  local trimmed = (r.stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then return nil end
  local decoded, derr = rex.json.decode(trimmed)
  if decoded ~= nil then return decoded end
  return { output = trimmed, parse_note = derr }
end

local function run_detached(mode, action_args, keys)
  local argv = { REX, "--autostart=false", "do", SCRIPT, "--all", "mode=" .. mode, "palette=true" }
  push_args(argv, action_args, keys or {})
  local handle, err = rex.exec.start(argv, { detach = true })
  if not handle then error("rex-durable: " .. tostring(err), 0) end
end

rex.action{
  name        = "durable_status",
  title       = "Durable: Show Saved Sessions Status",
  description = "Inspect the current Rex server's saved durable snapshots, checkpoints, and last restore.",
  category    = CATEGORY,
  keywords    = "durable status inspect snapshots saves sessions chats fx claude codex pi agy antigravity",
  run         = function(ctx, a)
    reject_unexpected_args(a)
    return run_sync("status", a, {}, is_interactive(ctx))
  end,
}

rex.action{
  name        = "durable_save",
  title       = "Durable: Save Open Programs Now",
  description = "Immediately snapshot all open Rex sessions, tabs, splits, and running agent conversations.",
  category    = CATEGORY,
  keywords    = "durable save snapshot sessions programs chats fx claude codex pi agy antigravity",
  run         = function(ctx, a)
    reject_unexpected_args(a)
    return run_sync("save", a, {}, is_interactive(ctx))
  end,
}

rex.action{
  name        = "durable_checkpoint",
  title       = "Durable: Pin a Checkpoint of Open Programs",
  description = "Save a named checkpoint that automatic snapshots will never overwrite.",
  category    = CATEGORY,
  keywords    = "durable checkpoint pin backup sessions programs chats pi agy",
  args        = { name = "string?" },
  run         = function(ctx, a)
    return run_sync("checkpoint", a, { "name" }, is_interactive(ctx))
  end,
}

rex.action{
  name        = "durable_reopen",
  title       = "Durable: Reopen Programs in Their Tabs",
  description = "Resume saved coding agent chats (agy, pi, claude, codex, fx) and stage other commands in restored idle tabs.",
  category    = CATEGORY,
  keywords    = "durable restore resume reopen programs chats sessions fx claude codex pi agy antigravity",
  args        = { dry_run = "boolean?", from = "string?", programs = "boolean?" },
  run         = function(ctx, a)
    local keys = { "dry_run", "from", "programs" }
    if is_interactive(ctx) and not (a and a.dry_run) then
      run_detached("reopen", a, keys)
      return
    end
    return run_sync("reopen", a, keys, false)
  end,
}

rex.action{
  name        = "durable_repair",
  title       = "Durable: Repair Missing Tabs",
  description = "Recreate tabs and sessions that closed while the Rex server stayed running, and resume their chats.",
  category    = CATEGORY,
  keywords    = "durable repair restore missing closed tabs sessions chats pi agy",
  args        = { dry_run = "boolean?", from = "string?", programs = "boolean?" },
  run         = function(ctx, a)
    local keys = { "dry_run", "from", "programs" }
    if is_interactive(ctx) and not (a and a.dry_run) then
      run_detached("repair", a, keys)
      return
    end
    return run_sync("repair", a, keys, false)
  end,
}

rex.action{
  name        = "durable_rebuild",
  title       = "Durable: Rebuild Saved Sessions",
  description = "Recreate saved sessions, splits, labels, and agent chats on an empty (or existing, with yes=true) Rex server.",
  category    = CATEGORY,
  keywords    = "durable rebuild recreate sessions layout chats pi agy",
  args        = { from = "string?", programs = "boolean?", yes = "boolean?" },
  run         = function(ctx, a)
    local keys = { "from", "programs", "yes" }
    if is_interactive(ctx) then
      run_detached("rebuild", a, keys)
      return
    end
    return run_sync("rebuild", a, keys, false)
  end,
}
