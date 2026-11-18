-- Print the newest save as one line per tab, for test/e2e.sh to check:
--   <session> <window>.<pane> <kind> <app or -> <id or command> <block id>
-- Run as: rex do test/e2e_show.lua state_dir=DIR

local dir = rex.args.state_dir .. "/snapshots"
local r = rex.exec({ "sh", "-c", 'ls -t "$1"/*.json | head -1', "sh", dir })
local path = r.stdout:gsub("%s+$", "")
local f = assert(io.open(path, "rb"))
local snap = rex.json.decode(f:read("*a"))
f:close()

local function panes(node, out)
  if node.split then
    panes(node.split.before, out)
    panes(node.split.after, out)
  else
    out[#out + 1] = node.pane
  end
  return out
end

local out = {}
for _, s in ipairs(snap.sessions or {}) do
  for wi, w in ipairs(s.windows or {}) do
    for pi, p in ipairs(panes(w.layout, {})) do
      local what = p.id or (p.argv and table.concat(p.argv, " ")) or "-"
      out[#out + 1] = string.format("%s %d.%d %s %s %s %s", s.label or "-", wi, pi, p.kind,
                                    p.app or "-", what, p.block_id)
    end
  end
end
table.sort(out)
print(table.concat(out, "\n"))
