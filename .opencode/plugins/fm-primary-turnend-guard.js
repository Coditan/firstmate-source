import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";

let skipNextIdle = false;

function runProcess(command, args, input = "") {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolve({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
    child.stdin.end(input);
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

function runGuard(root) {
  if (!root) return Promise.resolve({ code: 0, stderr: "" });
  return runProcess(`${root}/bin/fm-turnend-guard.sh`, [], '{"stop_hook_active":false}');
}

const OPERATOR_HEADLINE =
  "TURN WOULD END BLIND - supervision is off. " +
  "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.";
const WORKER_HEADLINE =
  "SUPERVISION IS OFF IN THE HOME THAT LAUNCHED THIS TASK. " +
  "Repairing it belongs to firstmate, not to a task worker: report the stalled supervision in your task status line " +
  "and carry on with your own task in this worktree.";

// This plugin prepends its own instruction to the shared guard's message, so it
// has to pick the same addressee the shared guard did: the JS mirror of
// fm_session_operates_home in bin/fm-primary-scope-lib.sh. The plugin is loaded
// from the checkout the session runs in, while FM_ROOT_OVERRIDE still names the
// home that launched a task worker. An unresolvable path answers "not the
// operator", the addressee handed no command and so the safe fallback.
function sessionOperatesHome(root) {
  if (!root) return false;
  const home = process.env.FM_ROOT_OVERRIDE || root;
  try {
    return realpathSync(root) === realpathSync(home);
  } catch {
    return false;
  }
}

async function letWatchArmRun(sessionID, client) {
  const coordinator = globalThis[COORDINATOR_KEY];
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID, client);
  return status === "armed" || status === "wake" || status === "failed";
}

export const FmPrimaryTurnendGuard = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;

      if (skipNextIdle) {
        skipNextIdle = false;
        return;
      }

      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;

      if (await letWatchArmRun(sessionID, client)) return;

      const result = await runGuard(root);
      if (result.code !== 2) return;

      try {
        const headline = sessionOperatesHome(root) ? OPERATOR_HEADLINE : WORKER_HEADLINE;
        const text = await encodeFirstmateOperationalInput(
          root,
          "turn-end-guard",
          `${headline}\n\n${result.stderr}`,
        );
        await client.session.promptAsync({
          path: { id: sessionID },
          body: {
            parts: [{ type: "text", text }],
          },
        });
        skipNextIdle = true;
      } catch {
        skipNextIdle = false;
      }
    },
  };
};
