#!/usr/bin/env bash
# The bosun's default judge: one event in on stdin, one JSON verdict out.
#
# THE MODEL HERE IS PROVISIONAL, AND THAT IS THE POINT OF THIS FILE EXISTING.
# data/fm-bosun-model-survey/report.md recommends NVIDIA Nemotron 3 Nano on
# DeepInfra as the pilot, on latency, enforced schemas, and reversible open
# weights. The same survey found NO ranked third-party endpoint proven
# authenticated from this fleet: only Claude and Codex are reachable today. This
# unit judges nothing that has any effect, so it uses what is already reachable
# rather than asking the captain for a credential it does not yet need.
#
# Codex rather than Claude, for two reasons the survey establishes:
#   - Meter. The survey's criterion 2 excludes this fleet's Anthropic
#     subscription window (three exhaustion events on 2026-08-10) and explicitly
#     does NOT exclude Codex. Spending the protected window on an observer that
#     decides nothing is the wrong meter to spend.
#   - Enforced schema. `codex exec --output-schema` constrains the response
#     server-side, which is criterion 3. The Claude CLI path would be prompt-only
#     JSON here, which the survey rules insufficient.
#
# What this is NOT: it is not the survey's answer, and it is not evidence for the
# latency programme. Measured on this machine on 2026-08-12, one judgement takes
# roughly 6 seconds end to end, against the survey's sub-two-second gate - an
# agent CLI's startup and turn overhead, not a model's time to first token. An
# observer that decides nothing can afford that; a tier with authority cannot.
# docs/bosun-observer.md records this as provisional and lists what would settle
# it.
#
# THE SEAM
# Any command that reads one event on stdin and prints one JSON object on stdout
# is a valid judge. Point a home at another one with FM_BOSUN_JUDGE_CMD or
# config/bosun-judge - a direct schema-constrained call to a ranked endpoint is a
# few lines of curl, and swapping to it changes no code in the bosun itself.
#
# Output contract, read by fm_bosun_judge in bin/fm-bosun-lib.sh:
#   {"verdict":"escalate"|"routine","confidence":"high"|"low",
#    "reason":"<one line>","judge":"<identity>"}
# Anything else - no output, invalid JSON, a missing verdict - is treated by the
# caller as an escalation, so this script never needs to invent a safe answer. It
# exits non-zero and says nothing rather than guessing.
set -u

FM_BOSUN_CODEX_MODEL="${FM_BOSUN_CODEX_MODEL:-gpt-5.6-luna}"

command -v codex >/dev/null 2>&1 || {
  echo "fm-bosun-judge-codex.sh: codex is not on PATH" >&2
  exit 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/fm-bosun-judge.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

cat > "$work/prompt.txt"

# Server-enforced response shape. additionalProperties:false and the enums are
# what make an unusable answer a schema rejection rather than prose the caller
# has to guess at.
cat > "$work/schema.json" <<'JSON'
{
  "type": "object",
  "properties": {
    "verdict": {
      "type": "string",
      "enum": ["escalate", "routine"],
      "description": "escalate if a human supervisor must look at this now"
    },
    "confidence": {
      "type": "string",
      "enum": ["high", "low"],
      "description": "low if unsure; unsure is treated as escalate"
    },
    "reason": {
      "type": "string",
      "description": "one short sentence of reasoning"
    }
  },
  "required": ["verdict", "confidence", "reason"],
  "additionalProperties": false
}
JSON

# --ephemeral leaves no session on disk, --ignore-user-config keeps this repo's
# fleet-captain identity out of a judging turn, -s read-only and an empty working
# directory leave it nothing to act on, and </dev/null stops it waiting on the
# stdin this script already consumed. A judge with no tools is the point: it
# reads one event and answers.
if ! codex exec \
  --ephemeral \
  --ignore-user-config \
  --skip-git-repo-check \
  --sandbox read-only \
  --cd "$work" \
  --model "$FM_BOSUN_CODEX_MODEL" \
  --output-schema "$work/schema.json" \
  --output-last-message "$work/verdict.json" \
  - < "$work/prompt.txt" > /dev/null 2>"$work/err.txt"
then
  sed -n '$p' "$work/err.txt" >&2
  exit 1
fi

[ -s "$work/verdict.json" ] || {
  echo "fm-bosun-judge-codex.sh: judge produced no verdict" >&2
  exit 1
}

# Stamp the identity onto the verdict here rather than asking the model for it:
# a model reporting its own name is one more field it can get wrong, and the
# caller needs this to distinguish a judged verdict from a failure-path one.
jq -c --arg judge "codex:$FM_BOSUN_CODEX_MODEL" '. + {judge: $judge}' \
  < "$work/verdict.json" 2>/dev/null || {
  echo "fm-bosun-judge-codex.sh: judge output was not a JSON object" >&2
  exit 1
}
