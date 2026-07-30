// hooks/m2herd-session.pi.ts — pi session_start extension that wraps
// hooks/m2herd-session.sh, so a pi ORCHESTRATOR gets the same live m2herd
// context-fabric snapshot Claude Code gets from its SessionStart hook.
//
// One code path, one snapshot format: this extension only shells out to the
// existing bash hook and injects its `additionalContext`. It NEVER reimplements
// the digest (goal/status/areas/RESUME/NEXT). A missing hook, a timeout, a
// non-zero exit, or unparseable output is treated as "no snapshot" — this
// extension must NEVER break a pi session. pi is a general coding agent and
// most sessions are not m2herd sessions, so when no .m2herd/ fabric is present
// in the session cwd (or $M2HERD_DIR) nothing is injected and no process is
// spawned.
//
// Installed by scripts/install.sh --pi: the extension and the hook are
// symlinked side-by-side into ~/.pi/agent/extensions/, and the extension is
// also listed in ~/.pi/agent/settings.json extensions[]. pi dedupes extension
// loads by realpath (see pi's resource-loader/package-manager), so the file is
// loaded exactly once regardless of how it is registered.
//
// API used (pi 0.83.0, docs/extensions.md):
//   - pi.on("session_start", async (event, ctx) => {...})  — lifecycle event
//     fired on startup/new/resume/fork/reload (extensions.md §Session Events).
//   - ctx.cwd                                                 (extensions.md §ExtensionContext).
//   - ctx.sessionManager.getSessionId()                       (extensions.md §ExtensionContext).
//   - pi.on("before_agent_start", async (event) => { return { systemPrompt } })
//     — the documented mechanism for injecting context into the LLM: it can
//     "inject a message and/or modify the system prompt" (extensions.md
//     §before_agent_start). The claude-rules.ts example loads state at
//     session_start and appends it to event.systemPrompt here; we follow that
//     pattern so the fabric snapshot persists across every turn.

import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const HOOK_NAME = "m2herd-session.sh";
const DEFAULT_TIMEOUT_MS = 8000;

function envTimeoutMs(): number {
  const raw = process.env.M2HERD_PI_HOOK_TIMEOUT_MS;
  if (!raw) return DEFAULT_TIMEOUT_MS;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_TIMEOUT_MS;
}

// Resolve the hook script. Prefer the copy next to this extension's real
// location (install.sh symlinks both files from the same hooks/ dir, so this
// is the common path), then the installed copy in the pi extensions dir, then
// the remote-install cache checkout. Returns undefined when nothing is found.
function resolveHook(): string | undefined {
  const candidates: string[] = [];
  let here = "";
  try {
    here = path.dirname(fileURLToPath(import.meta.url));
    candidates.push(path.join(here, HOOK_NAME));
  } catch {}
  try {
    const real = path.dirname(fs.realpathSync(fileURLToPath(import.meta.url)));
    if (real !== here) candidates.push(path.join(real, HOOK_NAME));
  } catch {}
  candidates.push(path.join(os.homedir(), ".pi", "agent", "extensions", HOOK_NAME));
  candidates.push(path.join(os.homedir(), ".cache", "herdr-factory-loop-skill", "hooks", HOOK_NAME));
  for (const c of candidates) {
    try {
      if (fs.existsSync(c) && fs.statSync(c).isFile()) return c;
    } catch {}
  }
  return undefined;
}

// Does this session's cwd (or $M2HERD_DIR) carry an .m2herd/ fabric? Mirrors
// the hook's own ROOT resolution so we skip the spawn entirely for the common
// case: pi is a general coding agent and most sessions are not m2herd ones.
function fabricRoot(cwd: string): string | undefined {
  try {
    const m2 = process.env.M2HERD_DIR;
    if (m2 && fs.existsSync(path.join(m2, ".m2herd"))) return m2;
  } catch {}
  try {
    if (fs.existsSync(path.join(cwd, ".m2herd"))) return cwd;
  } catch {}
  return undefined;
}

// Run the hook with the session id on stdin, capture stdout, parse the JSON
// envelope, return .hookSpecificOutput.additionalContext (or undefined on any
// failure — timeout, non-zero exit, unparseable output, missing field).
async function computeSnapshot(
  cwd: string,
  sessionId: string | undefined,
  hookPath: string,
): Promise<string | undefined> {
  const input = JSON.stringify(sessionId ? { session_id: sessionId } : {});
  return new Promise((resolve) => {
    let child: ReturnType<typeof spawn> | undefined;
    let settled = false;
    const finish = (value: string | undefined) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer!);
      try {
        child?.kill("SIGKILL");
      } catch {}
      resolve(value);
    };
    const timer = setTimeout(() => finish(undefined), envTimeoutMs());
    timer.unref?.();

    try {
      child = spawn("bash", [hookPath], {
        cwd,
        stdio: ["pipe", "pipe", "pipe"],
        env: process.env,
      });
    } catch {
      finish(undefined);
      return;
    }

    let stdout = "";
    child.stdout?.on("data", (d: Buffer) => {
      stdout += d.toString();
    });
    child.on("error", () => finish(undefined));
    child.on("close", (code) => {
      if (code !== 0) {
        finish(undefined);
        return;
      }
      const text = stdout.trim();
      if (!text) {
        finish(undefined);
        return;
      }
      try {
        const parsed = JSON.parse(text);
        const ctx = parsed?.hookSpecificOutput?.additionalContext;
        if (typeof ctx === "string" && ctx.length > 0) finish(ctx);
        else finish(undefined);
      } catch {
        finish(undefined);
      }
    });

    try {
      child.stdin?.end(input);
    } catch {
      // stdin already closed; the hook reads EOF and proceeds.
    }
  });
}

export default function m2herdSessionPi(pi: ExtensionAPI): void {
  // Snapshot computed once per session_start; injected on every turn via
  // before_agent_start so the orchestrator stays oriented throughout.
  let snapshotPromise: Promise<string | undefined> | undefined;
  let warnedMissingHook = false;

  pi.on("session_start", async (_event, ctx) => {
    try {
      const cwd = ctx.cwd ?? process.cwd();
      if (!fabricRoot(cwd)) {
        // No context fabric → nothing to say. Stay silent, spawn nothing.
        snapshotPromise = Promise.resolve(undefined);
        return;
      }
      const hookPath = resolveHook();
      if (!hookPath) {
        if (!warnedMissingHook) {
          warnedMissingHook = true;
          // A fabric is present but the hook script cannot be located — a real
          // install gap worth one line on stderr (never stdout, never a throw).
          console.error(
            "[m2herd-session.pi] .m2herd fabric detected but hooks/m2herd-session.sh not found; skipping fabric snapshot. Re-run scripts/install.sh --pi.",
          );
        }
        snapshotPromise = Promise.resolve(undefined);
        return;
      }
      let sessionId: string | undefined;
      try {
        sessionId = ctx.sessionManager?.getSessionId?.();
      } catch {}
      snapshotPromise = computeSnapshot(cwd, sessionId, hookPath);
    } catch {
      snapshotPromise = Promise.resolve(undefined);
    }
  });

  pi.on("before_agent_start", async (event) => {
    try {
      if (!snapshotPromise) return;
      const snap = await snapshotPromise;
      if (typeof snap !== "string" || snap.length === 0) return;
      return {
        systemPrompt: `${event.systemPrompt}\n\n${snap}`,
      };
    } catch {
      return undefined;
    }
  });
}
