-- rex-durable command palette actions.
--
-- install.sh copies this file next to your Rex config as rex_durable.lua and
-- fills in the two paths below. Load it from ~/.config/rex/init.lua with:
--
--   require("rex_durable")
--
-- Then reload the config (rex config reload) and search the command palette
-- for "durable".

local REX = "@REX@"
local SCRIPT = "@SCRIPT@"

local function start(mode, extra)
  local argv = { REX, "--autostart=false", "do", SCRIPT, "mode=" .. mode, "palette=true" }
  for _, word in ipairs(extra or {}) do argv[#argv + 1] = word end
  local handle, err = rex.exec.start(argv, { detach = true })
  if not handle then error("rex-durable: " .. tostring(err), 0) end
end

rex.action{
  name = "durable_reopen",
  title = "Reopen Programs in Their Tabs",
  category = "rex-durable",
  keywords = "durable restore resume reopen programs chats sessions fx claude codex pi agy antigravity",
  run = function() start("reopen") end,
}

rex.action{
  name = "durable_repair",
  title = "Repair Missing Tabs",
  category = "rex-durable",
  keywords = "durable repair restore missing closed tabs sessions chats pi agy",
  run = function() start("repair") end,
}

rex.action{
  name = "durable_save",
  title = "Save Open Programs Now",
  category = "rex-durable",
  keywords = "durable save snapshot sessions programs chats pi agy",
  run = function() start("save") end,
}

rex.action{
  name = "durable_checkpoint",
  title = "Pin a Checkpoint of Open Programs",
  category = "rex-durable",
  keywords = "durable checkpoint pin backup sessions programs chats pi agy",
  run = function() start("checkpoint") end,
}
