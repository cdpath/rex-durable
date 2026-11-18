# rex-durable

Keep the agent sessions and programs in your [Rex](https://www.superlogical.com/rex) tabs across server restarts and reboots (inspired by Herdr's auto-resume and based on [fazxes/rex-durable](https://github.com/fazxes/rex-durable), extended with **Pi** and **Antigravity CLI (`agy`)** support).

Rex saves your sessions, tabs, and splits when its server stops, and restores them when it starts again—but every pane returns as a fresh shell. `rex-durable` tracks what was running in each pane and automatically resumes your coding agents on their exact conversations:

| Running in the tab | After a restart |
| --- | --- |
| **Antigravity CLI (`agy`)** | Reopens on its conversation: `agy --conversation <id>` |
| **Pi coding agent (`pi`)** | Reopens on its conversation: `pi --session <id>` |
| **Claude Code (`claude`)** | Reopens on its conversation: `claude --resume <id>` |
| **Codex (`codex`)** | Reopens on its conversation: `codex resume <id>` |
| **[fx](https://fx.sh) (`fx`)** | Reopens on its conversation: `fx --resume <id>` |
| Any other program | Typed at the prompt, not run. Press Enter if you want it. |
| Plain shell | Left alone |

Chats preserve their CLI options (such as `--model`, `--effort`, `--thinking`, `--mode`, `--sandbox`, `--dangerously-skip-permissions`) and reopen in the exact same tab, split, and directory.

## Install

```sh
git clone https://github.com/cdpath/rex-durable ~/Developer/rex-durable
cd ~/Developer/rex-durable
./install.sh --add-to-config
```

The installer:

1. Finds Rex's `rex` CLI (preferring `~/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/` on macOS so Rex updates don't break it).
2. Copies `durable.lua` to `~/Library/Application Support/rex-durable/` on macOS (or `~/.local/share/rex-durable/` on Linux).
3. Installs the lightweight Pi extension `rex-durable.ts` into `~/.pi/agent/extensions/` (skip with `--no-pi-extension`).
4. Starts `durable.lua` as a login service (`launchd` agent on macOS, `systemd` user service on Linux).
5. Installs Rex command palette actions (`~/.config/rex/rex_durable.lua`) and loads them from `~/.config/rex/init.lua` when `--add-to-config` is passed.

## Usage

Day to day, everything runs automatically: `rex-durable` snapshots active tabs every 30 seconds and 5 seconds after layout/terminal events, and restores chats automatically when a new Rex server instance starts.

Manual commands:

```sh
S="$HOME/Library/Application Support/rex-durable/durable.lua"   # Linux: ~/.local/share/rex-durable/durable.lua

rex do "$S" mode=status                    # inspect saved state & last restore
rex do "$S" mode=save                      # force an immediate save
rex do "$S" mode=reopen dry_run=true       # preview what reopen would type
rex do "$S" mode=reopen                    # reopen programs in their tabs
rex do "$S" mode=repair dry_run=true       # preview missing tabs repair
rex do "$S" mode=repair                    # restore tabs closed while Rex stayed up
rex do "$S" mode=checkpoint name=my-snap   # pin a named checkpoint
rex do "$S" mode=rebuild from=my-snap yes=true
```

Or open the Rex Command Palette (`Cmd+Shift+P`) and search **"durable"**.

## How `pi` and `agy` Session Tracking Works

- **Antigravity CLI (`agy`)**: `agy` holds `~/.gemini/antigravity-cli/conversations/<id>.db*` and `~/.gemini/antigravity-cli/brain/<id>` open while running. `rex-durable` reads open file descriptors (`lsof` / `/proc`) to identify each pane's exact conversation ID, filters out subagent conversations via `transcript.jsonl`, and prevents reopening a conversation that is already open in another terminal.
- **Pi (`pi`)**: Combines two layers:
  1. **Pi Extension (`extensions/rex-durable.ts`)**: When running inside a Rex terminal (`REX_BLOCK`), records `{ block_id, pid, id, session_file, argv }` on `session_start`, `agent_start`, and `agent_settled`. Because `pi` overwrites `process.title = "pi"` on macOS and closes its `.jsonl` file between turns, this extension preserves original CLI flags (`--model`, `--thinking`, etc.), tracks `/resume` and `/fork` switches, and disambiguates multiple `pi` panes in the same directory.
  2. **Zero-config fallback**: Even without the extension (including already-running `pi` processes), `rex-durable` matches `~/.pi/agent/sessions/--<cwd-slug>--/<timestamp>_<id>.jsonl` by session header `cwd` and modification time, and carries reopened block mappings forward across restarts.

## Development & Tests

```sh
test/e2e.sh          # unit tests + full isolated e2e test on a throwaway Rex server
test/e2e.sh --unit   # unit tests only
```

## Uninstall

```sh
./uninstall.sh          # stop service & remove installed scripts (keeps snapshots)
./uninstall.sh --purge  # also delete saved snapshots
```

## License

[MIT](LICENSE)
