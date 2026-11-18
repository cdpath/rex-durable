// Installed by rex-durable into ~/.pi/agent/extensions/rex-durable.ts
//
// Integrates Pi natively with Rex best practices:
// 1. Records { block_id, pid, id, session_file, argv } per REX_BLOCK so rex-durable
//    can disambiguate multiple Pi panes in the same directory, recover CLI flags
//    hidden by `process.title = "pi"`, and follow /resume or /fork switches.
// 2. Emits Rex's native Program Status Protocol (OSC 7501, app=pi) so unfocused
//    Pi tabs display spinners while working and blocked/done indicators in Rex.
// @ts-nocheck

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const CONFIGURED_STATE_DIR = "@STATE_DIR@";
const blockId = process.env.REX_BLOCK;
const rexSessionId = process.env.REX_SESSION;
const inRex = process.env.TERM_PROGRAM === "rex" || !!blockId;
const oscEnabled = inRex && process.env.REX_DURABLE_OSC7501 !== "0";

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

// Per Rex OSC 7501 spec: base64 UTF-8 with no control chars (U+0000..U+001F, U+007F, U+0080..U+009F).
function encodeOscText(text: string, maxBytes = 512): string | undefined {
  const cleaned = String(text || "")
    .replace(/[\u0000-\u001f\u007f-\u009f]+/g, " ")
    .trim();
  if (!cleaned) return undefined;
  let buf = Buffer.from(cleaned, "utf8");
  if (buf.length > maxBytes) {
    buf = buf.subarray(0, maxBytes);
    while (buf.length > 0 && (buf[buf.length - 1] & 0xc0) === 0x80) {
      buf = buf.subarray(0, buf.length - 1);
    }
    if (buf.length > 0 && buf[buf.length - 1] >= 0xc0) {
      buf = buf.subarray(0, buf.length - 1);
    }
  }
  return buf.length > 0 ? buf.toString("base64") : undefined;
}

function emitProgramStatus(
  state: "idle" | "working" | "done" | "blocked" | "error" | "clear",
  extra?: { kind?: "permission" | "question" | "auth"; msg?: string }
): void {
  if (!oscEnabled || !process.stdout?.isTTY) return;
  try {
    if (state === "clear") {
      process.stdout.write("\x1b]7501;state=clear\x1b\\");
      return;
    }
    const pairs = [`state=${state}`, "app=pi"];
    if (state === "blocked" && extra?.kind) {
      pairs.push(`kind=${extra.kind}`);
    }
    if (extra?.msg) {
      const encoded = encodeOscText(extra.msg);
      if (encoded) pairs.push(`msg=${encoded}`);
    }
    process.stdout.write(`\x1b]7501;${pairs.join(":")}\x1b\\`);
  } catch {
    // Ignore stdout errors on teardown.
  }
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
  if (!inRex) {
    return;
  }

  let tuiActive = false;
  let working = false;
  let blockedCount = 0;
  let blockedMsg: string | undefined;

  function syncStatus(settledDone = false): void {
    if (!tuiActive) return;
    if (blockedCount > 0) {
      emitProgramStatus("blocked", { kind: "question", msg: blockedMsg });
    } else if (working) {
      emitProgramStatus("working");
    } else if (settledDone) {
      emitProgramStatus("done");
    } else {
      emitProgramStatus("idle");
    }
  }

  pi.events?.on?.("herdr:blocked", (data: any) => {
    if (!tuiActive) return;
    if (!data?.active) {
      blockedCount = Math.max(0, blockedCount - 1);
      if (blockedCount === 0) blockedMsg = undefined;
    } else {
      blockedCount += 1;
      blockedMsg = typeof data.label === "string" ? data.label : undefined;
    }
    syncStatus(false);
  });

  pi.on("session_start", (_event: any, ctx: any) => {
    if (ctx?.mode !== "tui") {
      return;
    }
    tuiActive = true;
    writeBlockRecord(ctx);
    working = ctx?.isIdle?.() === false;
    syncStatus(false);
  });

  pi.on("agent_start", (_event: any, ctx: any) => {
    if (!tuiActive) {
      return;
    }
    writeBlockRecord(ctx);
    working = true;
    syncStatus(false);
  });

  pi.on("agent_settled", (_event: any, ctx: any) => {
    if (!tuiActive || ctx?.isIdle?.() !== true) {
      return;
    }
    writeBlockRecord(ctx);
    working = false;
    syncStatus(true);
  });
}
