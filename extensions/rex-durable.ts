// Installed by rex-durable into ~/.pi/agent/extensions/rex-durable.ts
// Records the active Pi session ID and original CLI flags per Rex terminal block
// so rex-durable can disambiguate multiple Pi panes in the same directory and
// track /resume or /fork switches across Rex server restarts.
// @ts-nocheck

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const CONFIGURED_STATE_DIR = "@STATE_DIR@";
const blockId = process.env.REX_BLOCK;
const rexSessionId = process.env.REX_SESSION;

function resolveStateDir(): string {
  if (process.env.REX_DURABLE_STATE_DIR) {
    return process.env.REX_DURABLE_STATE_DIR;
  }
  if (CONFIGURED_STATE_DIR && !CONFIGURED_STATE_DIR.startsWith("@")) {
    return CONFIGURED_STATE_DIR;
  }
  const home = os.homedir();
  if (process.platform === "darwin") {
    return path.join(home, "Library", "Application Support", "rex-durable");
  }
  const xdgState = process.env.XDG_STATE_HOME || path.join(home, ".local", "state");
  return path.join(xdgState, "rex-durable");
}

function safeBlockFile(id: string): string {
  return id.replace(/[^A-Za-z0-9._-]/g, "_") + ".json";
}

function writeBlockRecord(ctx: any): void {
  if (!blockId) return;
  try {
    const sessionFile = ctx?.sessionManager?.getSessionFile?.();
    const sessionId = ctx?.sessionManager?.getSessionId?.();
    const hasFile = typeof sessionFile === "string" && sessionFile.startsWith("/");
    const hasId = typeof sessionId === "string" && sessionId.length > 0;
    const cliArgs = Array.isArray(process.argv) ? ["pi", ...process.argv.slice(2)] : ["pi"];
    const ephemeral = cliArgs.includes("--no-session") || (!hasFile && !hasId);

    const blocksDir = path.join(resolveStateDir(), "blocks");
    fs.mkdirSync(blocksDir, { recursive: true });
    const target = path.join(blocksDir, safeBlockFile(blockId));
    const tmp = `${target}.${process.pid}.tmp`;
    const record = {
      block_id: blockId,
      session_id: rexSessionId || undefined,
      app: "pi",
      pid: process.pid,
      id: hasId ? sessionId : undefined,
      session_file: hasFile ? sessionFile : undefined,
      cwd: process.cwd(),
      argv: cliArgs,
      ephemeral,
      updated_at: Math.floor(Date.now() / 1000),
    };
    fs.writeFileSync(tmp, JSON.stringify(record, null, 2) + "\n", "utf8");
    fs.renameSync(tmp, target);
  } catch {
    // Best-effort tracking; never interfere with Pi's TUI loop.
  }
}

export default function (pi: any) {
  if (!blockId) {
    return;
  }

  pi.on("session_start", (_event: any, ctx: any) => {
    if (ctx?.mode !== "tui") {
      return;
    }
    writeBlockRecord(ctx);
  });

  pi.on("agent_start", (_event: any, ctx: any) => {
    if (ctx?.mode !== "tui") {
      return;
    }
    writeBlockRecord(ctx);
  });

  pi.on("agent_settled", (_event: any, ctx: any) => {
    if (ctx?.mode !== "tui") {
      return;
    }
    writeBlockRecord(ctx);
  });
}
