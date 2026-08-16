import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const operationalInputScript =
  process.env.FM_OPERATIONAL_INPUT_SCRIPT ||
  resolve(dirname(fileURLToPath(import.meta.url)), "../../../bin/fm-operational-input.sh");

export const FIRSTMATE_CURRENT_OPERATIONAL_KINDS = [
  "session-start",
  "watcher",
  "turn-end-guard",
  "away-supervisor",
  "from-firstmate",
  "launch-brief",
] as const;

export type FirstmateCurrentOperationalKind =
  (typeof FIRSTMATE_CURRENT_OPERATIONAL_KINDS)[number];

function runOperationalInputCommand(
  command: "encode" | "classify",
  content: string,
  kind?: FirstmateCurrentOperationalKind,
): string | undefined {
  const args = command === "encode" ? [command, kind ?? ""] : [command];
  const result = spawnSync(operationalInputScript, args, {
    encoding: "utf8",
    input: content,
    maxBuffer: 1024 * 1024,
  });
  if (result.status !== 0) return undefined;
  return command === "classify" ? result.stdout.replace(/\n$/, "") : result.stdout;
}

// The exact launch-brief input bin/fm-spawn.sh starts a crewmate with, derived
// from the brief's PATH. It routes through the same shell owner rather than
// re-implementing the pointer here, so this side cannot drift from what spawn
// actually sends. Reading the brief and encoding its body - what this used to
// do - is precisely what must not happen any more: the launch no longer carries
// the body, so a value built that way would never match.
export function firstmateLaunchBriefPointer(briefPath: string): string | undefined {
  const result = spawnSync(operationalInputScript, ["launch-pointer", briefPath], {
    encoding: "utf8",
    maxBuffer: 1024 * 1024,
  });
  if (result.status !== 0) return undefined;
  return result.stdout;
}

export function encodeFirstmateOperationalInput(
  kind: FirstmateCurrentOperationalKind,
  content: string,
): string {
  const encoded = runOperationalInputCommand("encode", content, kind);
  if (encoded === undefined) {
    throw new Error(`could not encode Firstmate operational input kind ${kind}`);
  }
  return encoded;
}

export function classifyFirstmateOperationalText(content: string): string | undefined {
  // This is a syntax and migration parser, not a live sender-provenance check.
  return runOperationalInputCommand("classify", content);
}
