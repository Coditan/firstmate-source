import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

// PreToolUse seatbelt for OpenCode: deny a bare `lavish-axi` before the agent's
// bash tool runs it and hands the captain a http://127.0.0.1 link that opens
// nothing on his own devices (see bin/fm-lavish-pretool-check.sh and
// docs/lavish-access.md). This mirrors fm-primary-cd-check.js, calling the
// lavish-guard owner instead of the cd-guard one. tool.execute.before can block
// by throwing (verified 2026-07-09 against OpenCode 1.17.15 for the watcher-arm
// plugin; the same mechanism carries this guard). Unlike the cd-guard, the
// owner script is deliberately NOT primary-checkout-only: it fires wherever
// bin/fm-lavish.sh exists, because boards get opened from crew worktrees too.

function runProcess(command, args) {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolvePromise({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? 0, stdout, stderr }));
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

export const FmPrimaryLavishCheck = async ({ directory, worktree }) => {
  const root = worktree ? (() => {
    try {
      return realpathSync(worktree);
    } catch {
      return resolve(worktree);
    }
  })() : await resolveRoot(directory);

  return {
    "tool.execute.before": async (input, output) => {
      if (!root || input?.tool !== "bash") return;
      const command = output?.args?.command;
      if (!command || typeof command !== "string") return;

      const result = await runProcess(`${root}/bin/fm-lavish-pretool-check.sh`, ["--command", command]);
      if (result.code !== 2) return;

      const reason = result.stderr.trim() || "denied by the lavish-guard PreToolUse seatbelt";
      throw new Error(reason);
    },
  };
};
