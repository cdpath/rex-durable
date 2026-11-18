---
name: rex-durable
description: Inspect, checkpoint, reopen, or repair persistent agent sessions (agy, pi, droid, claude, codex, fx) across Rex server restarts using rex-durable custom actions.
---

# rex-durable

`rex-durable` runs as a background Rex event watcher (`rex do ... --all`) and registers first-class custom actions in `~/.config/rex/init.lua`. It automatically snapshots active coding agent conversations (`agy`, `pi`, `droid`, `claude`, `codex`, `fx`) and restores them in their original tabs/splits after a Rex server restart or reboot.

## Commands

Run these directly via `rex do <action>` (no script path needed when `require("rex_durable")` is loaded in `init.lua`):

```sh
rex do durable_status --json                     # inspect current snapshots, checkpoints, and last restore
rex do durable_save --json                       # trigger an immediate snapshot
rex do durable_checkpoint name=before-upgrade    # pin a named checkpoint that autosaves won't overwrite
rex do durable_reopen dry_run=true --json        # preview what reopen would type into idle shells
rex do durable_reopen                            # reopen saved chats in restored tabs
rex do durable_repair dry_run=true --json        # preview missing tabs/sessions after an accidental mass close
rex do durable_repair                            # recreate missing tabs/sessions and resume their chats
rex do durable_rebuild from=before-upgrade yes=true
```

## Safety Rules

- Never send input directly to a pane that already has an active foreground program; `durable_reopen` and `durable_repair` check `com.superlogical.terminal.process`, `com.superlogical.terminal.modes` (`screen ~= "alternate"`), and open session files (`lsof`) so no conversation is opened twice.
- Use `dry_run=true` first when diagnosing or previewing a manual `durable_reopen` or `durable_repair`.
