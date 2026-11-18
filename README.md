# rex-durable

Automatic agent session & layout persistence for [Rex](https://www.superlogical.com/rex), built around Rex's native Lua, event, action, layout, and `OSC 7501` protocols.

Rex saves your sessions, windows (tabs), and splits when its server stops, and restores them when it starts again—but every pane returns as a fresh shell. `rex-durable` watches your workspace in real time and automatically resumes your coding agents on their exact conversations:

| Running in the pane | After a Rex server restart / reboot |
| --- | --- |
| **Antigravity CLI (`agy`)** | Resumes exact conversation: `agy --conversation <id>` |
| **Pi coding agent (`pi`)** | Resumes exact conversation: `pi --session <id>` (+ native `OSC 7501` tab status!) |
| **Factory Droid (`droid`)** | Resumes exact conversation: `droid --resume <id>` |
| **Claude Code (`claude`)** | Resumes exact conversation: `claude --resume <id>` |
| **Codex (`codex`)** | Resumes exact conversation: `codex resume <id>` |
| **[fx](https://fx.sh) (`fx`)** | Resumes exact conversation: `fx --resume <id>` |
| Any other program | Staged at the shell prompt without executing (press Enter to run) |
| Plain shell | Left untouched |

Chats preserve their CLI options (`--model`, `--effort`, `--thinking`, `--mode`, `--sandbox`, `--dangerously-skip-permissions`, etc.) and come back in the exact same tab, split, working directory, custom block label, focus, and zoom state.

## Rex Best Practices Architecture

Unlike polling/shell-heavy approaches, `rex-durable` is designed specifically around Rex's native APIs:

- **Real-time `terminal.process_changed` event stream**: Runs a single in-process `rex do --all` watcher subscribing to `terminal.process_changed`, `terminal.program_status_changed`, `session_view_changed`, and lifecycle events with bounded trailing burst debouncing (`pending:cancel()` + `rex.after`)—no periodic child `rex` process spawning.
- **Zero `client_connected` noise (`session.attach_all`)**: Uses `session.attach_all` instead of per-session `session.attach`, so `rex-durable` never pollutes `session.list_clients` or emits spurious client join/leave events.
- **Native `com.superlogical.terminal.process` & `modes` inspection**: Uses Rex's kernel-resolved `script`, `invoked_path`, and `argv0` fields to identify Node/Bun agent wrappers, skips remote `host_id` blocks, and checks `com.superlogical.terminal.modes` (`screen ~= "alternate"`) before typing into any pane.
- **Full layout fidelity via `rex.layout.*`**: Rebuilds splits with `rex.layout.horizontal` / `rex.layout.vertical` / `rex.layout.block`, preserving window focus (`w.focused_block_id`), zoomed panes (`w.zoomed_block_id`), and custom block labels (`b.label`).
- **First-class `rex.action` commands**: Registers typed actions (`durable_status`, `durable_save`, `durable_reopen`, `durable_repair`, `durable_checkpoint`, `durable_rebuild`) with `args` validation schemas—callable from the Command Palette, keybindings (`rex.bind`), or directly via `rex do <action> [--json]`.
- **Native `OSC 7501` Program Status for Pi**: Since Rex doesn't yet ship a built-in hook for Pi, `extensions/rex-durable.ts` both tracks `REX_BLOCK` $\rightarrow$ `sessionId` + `process.argv` and emits spec-compliant `OSC 7501` (`app=pi`: `idle`, `working`, `blocked`, `done`) so Pi gets native Rex tab spinners and session-picker badges.
- **`SessionStart` hook for Claude Code and Droid**: `install.sh` registers `hooks/rex-durable-hook.sh` in `~/.claude/settings.json` and `~/.factory/settings.json`. Inside a Rex pane the hook records which session each block runs, so two agents in one folder resume on their own sessions. Outside Rex it does nothing, and it ignores Droid Task subagent sessions. Pass `--no-hooks` to skip it. `uninstall.sh` removes it. Without the hook, `rex-durable` falls back to the newest main session file in the folder, and only when a single tab runs that agent there. Two Droid tabs in one folder are then saved as plain programs with no session to resume.

## Install

```sh
git clone https://github.com/cdpath/rex-durable ~/Developer/rex-durable
cd ~/Developer/rex-durable
./install.sh --add-to-config
```

## Usage

Day to day, everything is automatic. Whenever you want to inspect or control snapshots manually, use the first-class Rex actions from any terminal (or press `Cmd+Shift+P` and search **"Durable"**):

```sh
rex do durable_status                         # inspect snapshots, checkpoints & last restore (JSON)
rex do durable_save                           # snapshot immediately
rex do durable_checkpoint name=before-update  # pin a named checkpoint
rex do durable_reopen dry_run=true            # preview what reopen would type
rex do durable_reopen                         # resume saved chats in idle tabs
rex do durable_repair dry_run=true            # preview missing tabs after a mass close
rex do durable_repair                         # recreate closed tabs/sessions & resume chats
rex do durable_rebuild from=before-update yes=true
```

You can also bind keys in `~/.config/rex/init.lua`:

```lua
require("rex_durable")
rex.bind("ctrl+b>ctrl+s", "durable_checkpoint")
rex.bind("ctrl+b>ctrl+r", "durable_repair")
```

## Development & Tests

```sh
test/e2e.sh          # unit tests + isolated e2e suite on a throwaway Rex server
test/e2e.sh --unit   # unit tests only
```

## Uninstall

```sh
./uninstall.sh          # stop service & remove installed scripts/extensions/skills (keeps snapshots)
./uninstall.sh --purge  # also delete saved snapshots
```

## Credits & License

Inspired by Herdr's automatic agent session resumption and [fazxes/rex-durable](https://github.com/fazxes/rex-durable). Released under the [MIT License](LICENSE).
