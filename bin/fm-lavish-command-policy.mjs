#!/usr/bin/env node
// Semantic policy for the lavish-guard: does a shell command run bare
// `lavish-axi` instead of firstmate's entry point?
//
// A bare `lavish-axi` binds loopback and hands the captain a
// http://127.0.0.1:<port>/... link that opens nothing on his own devices, and
// it fails silently - the board looks correct on the machine that made it. That
// mistake has already been made here after the problem was written down, which
// is why this is a guard and not a note: instructions do not reach an agent's
// non-interactive shell, and habit beats memory.
//
// The environmental scoping - only where bin/fm-lavish.sh actually exists -
// lives in the bin/fm-lavish-pretool-check.sh transport, not here.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy
// never evaluates, expands, sources, or runs any byte of the submitted command;
// it inspects lexical command positions only.
//
// Usage:
//   fm-lavish-command-policy.mjs --command '<cmd>' [--wrapper <abs path>]
//
// Prints "allow", or "deny\t<code>\t<reason>". --wrapper supplies the absolute
// path this checkout's wrapper actually lives at, which only the transport
// knows; without it the reason names the repo-relative path.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const GUARDED = "lavish-axi";

function reasonFor(wrapper) {
  return (
    `bare \`${GUARDED}\` is blocked in a firstmate checkout because it binds loopback and writes a http://127.0.0.1 link that opens nothing on the captain's own devices, and it fails silently. Run \`${wrapper}\` with the same arguments instead: it resolves this vessel's tailnet address and a port no co-hosted vessel is using, and it says so plainly when there is no tailnet rather than emitting a link that will not open.`
  );
}

function basename(value) {
  const cleaned = value.endsWith("/") ? value.slice(0, -1) : value;
  const slash = cleaned.lastIndexOf("/");
  return slash === -1 ? cleaned : cleaned.slice(slash + 1);
}

// `command -v lavish-axi` and `type lavish-axi` ask whether the tool exists;
// they never start a server or emit a link. bin/fm-bootstrap.sh does exactly
// this, so denying it would break tool detection to prevent nothing.
function hasCommandQueryPrefix(position) {
  let commandPrefix = false;
  for (const word of position.words.slice(position.prefixAssignments, position.index)) {
    if (basename(word.value) === "command") {
      commandPrefix = true;
      continue;
    }
    if (commandPrefix && /^-[^-]*[vV]/.test(word.value)) return true;
  }
  return false;
}

function decision(command, wrapper = "bin/fm-lavish.sh") {
  const lexed = new Lexer(command).tokenize();
  // Fail open on syntax this classifier cannot tokenize. The threat model is an
  // agent reaching for the familiar tool, which always tokenizes, so zero false
  // blocks matters more than catching deliberate obfuscation.
  if (lexed.error) return { decision: "allow" };

  // Every top-level command list runs its command, so unlike the cd-guard there
  // is no subshell or background exemption to make: a backgrounded or piped
  // `lavish-axi` emits exactly the same unreachable link.
  const { nodes } = splitProgram(lexed.tokens);
  for (let index = 0; index < nodes.length; index += 1) {
    const position = commandPosition(nodes[index]);
    if (hasCommandQueryPrefix(position)) continue;
    let executed = position.command;
    let wordIndex = position.index;
    while (executed && (executed.value === "builtin" || executed.value === "command")) {
      wordIndex += 1;
      executed = position.words[wordIndex];
    }
    if (!executed) continue;
    if (basename(executed.value) !== GUARDED) continue;
    return { decision: "deny", code: "bare-lavish-axi", reason: reasonFor(wrapper) };
  }
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false, wrapper: "bin/fm-lavish.sh" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command") {
      if (i + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[i + 1];
      result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    if (name === "--wrapper") {
      if (i + 1 >= argv.length) throw new Error("--wrapper requires a value");
      result.wrapper = argv[i + 1];
      i += 1;
      continue;
    }
    if (name.startsWith("--wrapper=")) {
      result.wrapper = name.slice("--wrapper=".length);
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command, args.wrapper);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
