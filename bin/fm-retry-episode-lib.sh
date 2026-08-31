#!/usr/bin/env bash
# fm-retry-episode-lib.sh - the one owner of a bounded seat-relaunch episode.
#
# Two supervisors bring this home's primary firstmate seat back:
# bin/fm-seat-respawner.sh under a systemd user unit, and bin/fm-seat-keeper.sh
# hand-started in a terminal for a home where no such unit can run.
# docs/seat-respawner.md promises an operator that both bound their relaunches
# the same way, and two copies of that promise is how a defect gets fixed once
# and survives twice. The rule therefore lives here once and both source it.
#
# THE RULES THIS FILE OWNS. One episode is keyed by the condition that provoked
# it, never by the prose that reported it; bin/fm-delivery-lib.sh's
# fm_delivery_condition_key owns that key, because that file owns the verdict
# grammar the key is derived from. Attempts against one key are counted to a
# ceiling and spaced by a delay that doubles from a base up to a maximum, and the
# exhausted ceiling is filed ONCE as a high-severity finding rather than retried
# forever or passed over in silence. A different key is a different episode and
# starts from zero.
#
# THE LIFETIMES EACH CALLER OWNS. Every function takes the record paths it works
# on, because where an episode lives and how long it outlives its process is the
# supervisor's own situation rather than a rule to share: the respawner's record
# must survive the unit restarting under it, while the keeper's belongs to the
# state directory it was hand-started against. Each caller likewise owns its own
# log, so these functions print what happened and let the caller record it where
# its operator already looks.
#
# That split is why fm_retry_clear_exhausted_episode exists but is called by one
# caller only: a hand-start is an operator deciding to try again, and a unit
# restarting itself is not.
#
# fm_retry_giveup_emit shells out to bin/fm-finding.sh, so a caller must have set
# FM_HOME and FM_ROOT before calling it.

FM_RETRY_EPISODE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_retry_num_or_default() {  # <value> <default>
  case "$1" in ''|*[!0-9]*|0) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

fm_retry_kv_get() {  # <file> <key>
  local file=$1 key=$2 line
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$key"=*) printf '%s\n' "${line#*=}"; return 0 ;; esac
  done < "$file"
  return 1
}

# Reads the episode recorded at <record-file> into FM_RETRY_ATTEMPT_COUNT and
# FM_RETRY_ATTEMPT_NEXT. A record naming another key, an absent record, and an
# unreadable count are one answer: this key has no episode yet, so a supervisor
# never inherits another condition's exhausted bound.
fm_retry_read_attempts() {  # <record-file> <key>
  local file=$1 want=$2 key count next
  # shellcheck disable=SC2034 # Public source-library result read by callers.
  FM_RETRY_ATTEMPT_COUNT=0
  # shellcheck disable=SC2034 # Public source-library result read by callers.
  FM_RETRY_ATTEMPT_NEXT=0
  key=$(fm_retry_kv_get "$file" key 2>/dev/null || true)
  [ "$key" = "$want" ] || return 0
  count=$(fm_retry_kv_get "$file" count 2>/dev/null || true)
  next=$(fm_retry_kv_get "$file" next 2>/dev/null || true)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$next" in ''|*[!0-9]*) next=0 ;; esac
  # shellcheck disable=SC2034 # Public source-library result read by callers.
  FM_RETRY_ATTEMPT_COUNT=$count
  # shellcheck disable=SC2034 # Public source-library result read by callers.
  FM_RETRY_ATTEMPT_NEXT=$next
}

fm_retry_write_attempts() {  # <record-file> <key> <count> <next>
  local file=$1 tmp
  case "$file" in */*) mkdir -p "${file%/*}" || return 1 ;; esac
  tmp=$(mktemp "$file.XXXXXX") || return 1
  {
    printf 'key=%s\n' "$2"
    printf 'count=%s\n' "$3"
    printf 'next=%s\n' "$4"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file"
}

fm_retry_clear_episode() {  # <record-file> <giveup-file>
  rm -f "$1" "$2"
}

# Lifting an exhausted bound is an operator's decision, so only a supervisor
# whose start IS that decision calls this. bin/fm-seat-keeper.sh is hand-started
# and calls it once at startup; bin/fm-seat-respawner.sh runs as a unit that
# restarts itself, which is nobody's decision, so it deliberately never calls
# this and carries its episode across a restart. Prints the condition key whose
# bound was lifted, so the caller can name it where its operator looks, and
# returns 1 when there was no exhausted episode to lift.
fm_retry_clear_exhausted_episode() {  # <record-file> <giveup-file>
  local record=$1 giveup=$2 key
  [ -f "$giveup" ] || return 1
  key=$(fm_retry_kv_get "$giveup" key 2>/dev/null || true)
  [ -n "$key" ] || key=unknown
  fm_retry_clear_episode "$record" "$giveup"
  printf '%s\n' "$key"
}

fm_retry_backoff() {  # <count-after-attempt> <base> <max>
  local count=$1 delay=$2 max=$3
  while [ "$count" -gt 1 ]; do
    delay=$((delay * 2))
    [ "$delay" -le "$max" ] || { delay=$max; break; }
    count=$((count - 1))
  done
  printf '%s\n' "$delay"
}

# Files the exhausted-ceiling finding once for this episode and records that it
# did, so a supervisor that keeps polling does not keep filing the same claim.
# Prints one line for the caller's log, and returns non-zero when the finding
# could not be filed, because a supervisor that gave up unrecorded is itself
# something the operator has to see.
fm_retry_giveup_emit() {  # <giveup-file> <key> <officer> <claim> <where> <measurement>
  local giveup=$1 key=$2 officer=$3 claim=$4 where=$5 measurement=$6 out
  if [ -f "$giveup" ] && [ "$(fm_retry_kv_get "$giveup" key 2>/dev/null || true)" = "$key" ]; then
    return 0
  fi
  if out=$(env FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
      "$FM_RETRY_EPISODE_LIB_DIR/fm-finding.sh" emit \
      --class evidence \
      --severity high \
      --officer "$officer" \
      --claim "$claim" \
      --where "$where" \
      --measurement "$measurement" \
      --refuted-by "A fresh delivery status for the same queued work becomes deliverable after a launch attempt, or the stay-down marker is set deliberately." 2>&1); then
    {
      printf 'key=%s\n' "$key"
      printf 'finding=%s\n' "$(printf '%s\n' "$out" | awk -F= '/^id=/{print $2; exit}')"
    } > "$giveup" || true
    printf 'give-up finding emitted for %s\n' "$key"
    return 0
  fi
  printf 'give-up finding failed: %s\n' "$out"
  return 1
}
