#!/usr/bin/env bash
# Shared read-only Bridge inbox detection and durable wake publication.
#
# Source after bin/fm-wake-lib.sh.
#
# A Bridge envelope is the one event in this fleet's notification stream that
# states its own urgency in so many words, in its .priority field, and it is
# therefore the surface where an under-declaration can be seen and corrected.
# bridge_inbox_check delivers the EFFECTIVE priority - bin/fm-urgency-lib.sh's
# promoted reading of the pending envelopes - while bridge_check_interval below
# deliberately still reads the DECLARED one, because how long an event of a
# given urgency waits belongs to the batching unit and not to this file.
# bridge_inbox_surface [fetch]
#   Serializes fetch, signature comparison, wake append, and surfaced-marker
#   publication across the slow watcher and the fast frequency monitor.
#   Pass 1 to fetch origin/main before scanning, or 0 to scan the already-fetched
#   ref.
#   Prints one actionable reason only when it durably appended a new wake.

FM_BRIDGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v fm_urgency_effective >/dev/null 2>&1; then
  # shellcheck source=bin/fm-urgency-lib.sh
  . "$FM_BRIDGE_LIB_DIR/fm-urgency-lib.sh"
fi
FM_BRIDGE_LIB_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_BRIDGE_LIB_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_BRIDGE_LIB_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
BRIDGE_CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-${CHECK_TIMEOUT:-30}}
BRIDGE_ROOT=${FM_BRIDGE_ROOT:-$FM_HOME/projects/coditan-bridge}
BRIDGE_URGENT_CHECK_INTERVAL=${FM_BRIDGE_URGENT_CHECK_INTERVAL:-30}
BRIDGE_INBOX_LOCK=${FM_BRIDGE_INBOX_LOCK:-$STATE/.bridge-inbox.lock}

if [ -n "${FM_BRIDGE_VESSEL:-}" ]; then
  BRIDGE_VESSEL_RAW=$FM_BRIDGE_VESSEL
elif [ -f "$FM_HOME/config/bridge-vessel" ]; then
  IFS= read -r BRIDGE_VESSEL_RAW < "$FM_HOME/config/bridge-vessel" || BRIDGE_VESSEL_RAW=
else
  BRIDGE_VESSEL_RAW=
fi

# BRIDGE_VESSEL keeps the historical first/primary value while the ordered
# array preserves the existing optional multi-vessel watcher behavior.
BRIDGE_VESSELS=()
read -r -a BRIDGE_VESSELS <<< "$BRIDGE_VESSEL_RAW"
BRIDGE_VESSEL=${BRIDGE_VESSELS[0]:-}

bridge_run_bounded() {
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    timeout "$BRIDGE_CHECK_TIMEOUT" "$@" 2>/dev/null || true
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$BRIDGE_CHECK_TIMEOUT" "$@" 2>/dev/null || true
  else
    # shellcheck disable=SC2016
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$BRIDGE_CHECK_TIMEOUT" "$@" 2>/dev/null || true
  fi
}

bridge_pending_priority_scan() {
  local inbox="inbox/$BRIDGE_VESSEL/new" f priority rank=-1
  while IFS= read -r -d '' f; do
    case "$f" in *.json) ;; *) continue ;; esac
    priority=$(git -C "$BRIDGE_ROOT" show "origin/main:$inbox/$f" 2>/dev/null | jq -r '.priority // "normal"' 2>/dev/null || echo normal)
    case "$priority" in
      immediate) rank=3 ;;
      high) [ "$rank" -lt 2 ] && rank=2 ;;
      normal) [ "$rank" -lt 1 ] && rank=1 ;;
      low) [ "$rank" -lt 0 ] && rank=0 ;;
      *) [ "$rank" -lt 1 ] && rank=1 ;;
    esac
  done < <(git -C "$BRIDGE_ROOT" ls-tree -z --name-only "origin/main:$inbox" 2>/dev/null)
  case "$rank" in 3) echo immediate ;; 2) echo high ;; 1) echo normal ;; 0) echo low ;; *) echo none ;; esac
}
export -f bridge_pending_priority_scan

# Emit "<priority>\t<subject>" for every pending envelope, one per line.
#
# Deliberately does only the git and jq work: the urgency decision is made by
# bridge_pending_urgency in the calling shell, where it is pure string matching
# that costs nothing and cannot be cut short by the bounded-run timeout. Subject
# tabs and newlines are flattened here so one envelope is always one line.
bridge_pending_envelope_scan() {
  local inbox="inbox/$BRIDGE_VESSEL/new" f
  while IFS= read -r -d '' f; do
    case "$f" in *.json) ;; *) continue ;; esac
    git -C "$BRIDGE_ROOT" show "origin/main:$inbox/$f" 2>/dev/null \
      | jq -r '[(.priority // "normal"), ((.subject // "") | gsub("[\t\r\n]"; " "))] | @tsv' 2>/dev/null
  done < <(git -C "$BRIDGE_ROOT" ls-tree -z --name-only "origin/main:$inbox" 2>/dev/null)
}
export -f bridge_pending_envelope_scan

# The pending inbox's declared and effective highest priority, in one pass.
#
# Promotion is decided PER ENVELOPE against that envelope's own subject, then
# maximised, because an envelope's urgency is a property of its own content: a
# firewall opened to the internet does not become ordinary by arriving beside
# nine routine replies. Sets BRIDGE_URGENCY_DECLARED, BRIDGE_URGENCY_EFFECTIVE,
# BRIDGE_URGENCY_RULE, BRIDGE_URGENCY_MATCH, and BRIDGE_URGENCY_SUBJECT (the
# subject of the envelope that carried the winning promotion). All are "none"
# or empty when the inbox holds nothing pending.
#
# Cached against the inbox signature exactly as bridge_pending_priority is, so
# an unchanged inbox costs one rev-parse rather than a read of every envelope.
BRIDGE_URGENCY_DECLARED=none
BRIDGE_URGENCY_EFFECTIVE=none
BRIDGE_URGENCY_RULE=
BRIDGE_URGENCY_MATCH=
BRIDGE_URGENCY_SUBJECT=
bridge_pending_urgency() {  # [<signature>] [<vessel>]
  local sig=${1:-} vessel=${2:-$BRIDGE_VESSEL} cache cached_sig="" out
  local priority subject rank declared_rank=-1 effective_rank=-1

  BRIDGE_URGENCY_DECLARED=none
  BRIDGE_URGENCY_EFFECTIVE=none
  BRIDGE_URGENCY_RULE=
  BRIDGE_URGENCY_MATCH=
  BRIDGE_URGENCY_SUBJECT=

  [ -n "$vessel" ] || return 0
  [ -d "$BRIDGE_ROOT/.git" ] || return 0
  cache="$STATE/.bridge-urgency-cache$(bridge_state_suffix "$vessel")"
  [ -n "$sig" ] || sig=$(bridge_inbox_signature "$vessel")

  if [ -f "$cache" ]; then
    IFS=$'\t' read -r cached_sig BRIDGE_URGENCY_DECLARED BRIDGE_URGENCY_EFFECTIVE \
      BRIDGE_URGENCY_RULE BRIDGE_URGENCY_MATCH BRIDGE_URGENCY_SUBJECT < "$cache" 2>/dev/null || true
  fi
  if [ "$sig" = timeout ] || { [ -n "$cached_sig" ] && [ "$sig" = "$cached_sig" ]; }; then
    [ -n "${BRIDGE_URGENCY_DECLARED:-}" ] || BRIDGE_URGENCY_DECLARED=none
    [ -n "${BRIDGE_URGENCY_EFFECTIVE:-}" ] || BRIDGE_URGENCY_EFFECTIVE=none
    return 0
  fi

  BRIDGE_URGENCY_DECLARED=none
  BRIDGE_URGENCY_EFFECTIVE=none
  BRIDGE_URGENCY_RULE=
  BRIDGE_URGENCY_MATCH=
  BRIDGE_URGENCY_SUBJECT=
  out=$(BRIDGE_ROOT="$BRIDGE_ROOT" BRIDGE_VESSEL="$vessel" bridge_run_bounded bash -c 'bridge_pending_envelope_scan')
  while IFS=$'\t' read -r priority subject; do
    [ -n "$priority" ] || continue
    rank=$(fm_urgency_rank "$priority")
    [ "$rank" -le "$declared_rank" ] || declared_rank=$rank
    fm_urgency_effective "$priority" "$subject" || true
    rank=$(fm_urgency_rank "$FM_URGENCY_EFFECTIVE")
    if [ "$rank" -gt "$effective_rank" ]; then
      effective_rank=$rank
      BRIDGE_URGENCY_RULE=$FM_URGENCY_RULE
      BRIDGE_URGENCY_MATCH=$FM_URGENCY_MATCH
      BRIDGE_URGENCY_SUBJECT=$subject
    fi
  done <<EOF
$out
EOF

  [ "$declared_rank" -lt 0 ] || BRIDGE_URGENCY_DECLARED=$(fm_urgency_level "$declared_rank")
  [ "$effective_rank" -lt 0 ] || BRIDGE_URGENCY_EFFECTIVE=$(fm_urgency_level "$effective_rank")
  # An empty scan result is indistinguishable from a bounded run that was cut
  # short, so it is never cached: caching it would publish "nothing pending"
  # from an instrument that did not read.
  if [ "$BRIDGE_URGENCY_DECLARED" != none ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sig" "$BRIDGE_URGENCY_DECLARED" \
      "$BRIDGE_URGENCY_EFFECTIVE" "$BRIDGE_URGENCY_RULE" "$BRIDGE_URGENCY_MATCH" \
      "$BRIDGE_URGENCY_SUBJECT" > "$cache" 2>/dev/null || true
  fi
  return 0
}

bridge_inbox_signature_scan() {
  local inbox="inbox/$BRIDGE_VESSEL/new" sig
  sig=$(git -C "$BRIDGE_ROOT" rev-parse "origin/main:$inbox" 2>/dev/null || true)
  printf '%s' "${sig:-empty}"
}
export -f bridge_inbox_signature_scan

bridge_inbox_signature() {
  local vessel=${1:-$BRIDGE_VESSEL} out
  out=$(BRIDGE_ROOT="$BRIDGE_ROOT" BRIDGE_VESSEL="$vessel" bridge_run_bounded bash -c 'bridge_inbox_signature_scan')
  printf '%s' "${out:-timeout}"
}

# The primary vessel keeps the historical unsuffixed filenames.
bridge_state_suffix() {
  local vessel=$1
  [ "$vessel" = "$BRIDGE_VESSEL" ] && return 0
  printf -- '-%s' "$(printf '%s' "$vessel" | tr -c 'A-Za-z0-9_.-' '_')"
}

bridge_pending_priority() {
  local sig=${1:-} vessel=${2:-$BRIDGE_VESSEL} cache cached_sig="" cached_priority="" out
  [ -n "$vessel" ] || { printf '%s' none; return; }
  [ -d "$BRIDGE_ROOT/.git" ] || { printf '%s' none; return; }
  cache="$STATE/.bridge-priority-cache$(bridge_state_suffix "$vessel")"
  [ -n "$sig" ] || sig=$(bridge_inbox_signature "$vessel")
  if [ -f "$cache" ]; then
    IFS=$'\t' read -r cached_sig cached_priority < "$cache" 2>/dev/null || true
  fi
  if [ "$sig" = timeout ]; then printf '%s' "${cached_priority:-none}"; return; fi
  if [ -n "$cached_sig" ] && [ "$sig" = "$cached_sig" ]; then printf '%s' "${cached_priority:-none}"; return; fi
  out=$(BRIDGE_ROOT="$BRIDGE_ROOT" BRIDGE_VESSEL="$vessel" bridge_run_bounded bash -c 'bridge_pending_priority_scan')
  if [ -z "$out" ]; then printf '%s' "${cached_priority:-none}"; return; fi
  printf '%s\t%s\n' "$sig" "$out" > "$cache" 2>/dev/null || true
  printf '%s' "$out"
}

bridge_check_interval() {
  local vessel
  for vessel in "${BRIDGE_VESSELS[@]}"; do
    case "$(bridge_pending_priority "" "$vessel")" in
      high|immediate) echo "$BRIDGE_URGENT_CHECK_INTERVAL"; return ;;
    esac
  done
  echo "${CHECK_INTERVAL:-300}"
}

# Compose the wake payload for one vessel's pending inbox.
#
# "highest=" carries the EFFECTIVE priority, so an envelope that arrived marked
# below what its own subject says is delivered at the higher one rather than
# read as ordinary traffic. When a promotion happened the row also names the
# declared priority it came from and the rule that raised it, so the supervisor
# reading the wake can tell a promoted row from a genuinely urgent one without
# opening anything. The matched text and the subject stay OUT of the payload and
# go into the promotion record instead: this row is deliberately free of envelope
# content, and bin/fm-urgency.sh promotions is where the evidence is read back.
bridge_inbox_check() {
  local vessel=$1 sig=${2:-}
  local inbox="inbox/$vessel/new" count row
  bridge_pending_urgency "$sig" "$vessel"
  [ "$BRIDGE_URGENCY_EFFECTIVE" != none ] || return 0
  count=$(bridge_run_bounded git -C "$BRIDGE_ROOT" ls-tree --name-only "origin/main:$inbox" | awk '/[.]json$/' | wc -l | tr -d '[:space:]')
  row=$(printf 'bridge-inbox %s pending=%s highest=%s' "$vessel" "${count:-0}" "$BRIDGE_URGENCY_EFFECTIVE")
  if [ -n "$BRIDGE_URGENCY_RULE" ]; then
    row="$row declared=$BRIDGE_URGENCY_DECLARED promoted-by=$BRIDGE_URGENCY_RULE"
    # Recording cannot hold the wake back: a promoted event is delivered at its
    # promoted priority whether or not the record of why reached disk.
    fm_urgency_record check "bridge-inbox/$vessel" \
      "$BRIDGE_URGENCY_DECLARED" "$BRIDGE_URGENCY_EFFECTIVE" \
      "$BRIDGE_URGENCY_RULE" "$BRIDGE_URGENCY_MATCH" "$BRIDGE_URGENCY_SUBJECT" \
      || printf 'fm-bridge-inbox: could not record the promotion of %s from %s to %s (rule %s); it is still delivered at %s\n' \
        "$vessel" "$BRIDGE_URGENCY_DECLARED" "$BRIDGE_URGENCY_EFFECTIVE" \
        "$BRIDGE_URGENCY_RULE" "$BRIDGE_URGENCY_EFFECTIVE" >&2
  fi
  printf '%s\n' "$row"
}

bridge_inbox_fetch() {
  bridge_run_bounded git -C "$BRIDGE_ROOT" fetch --quiet origin main >/dev/null
}

bridge_inbox_surface() {
  local fetch=${1:-0} vessel marker sig surfaced vessel_out out="" reason="" status=0 i
  local marker_paths=() marker_sigs=()

  [ "${#BRIDGE_VESSELS[@]}" -gt 0 ] || return 0
  [ -d "$BRIDGE_ROOT/.git" ] || return 0
  fm_lock_acquire_wait "$BRIDGE_INBOX_LOCK" || return "$?"

  case "$fetch" in 1|true|TRUE|yes|YES) bridge_inbox_fetch ;; esac
  for vessel in "${BRIDGE_VESSELS[@]}"; do
    marker="$STATE/.bridge-surfaced$(bridge_state_suffix "$vessel")"
    sig=$(bridge_inbox_signature "$vessel")
    surfaced=$(cat "$marker" 2>/dev/null || true)
    [ "$sig" != timeout ] || continue
    [ "$sig" != "$surfaced" ] || continue
    vessel_out=$(bridge_inbox_check "$vessel" "$sig")
    if [ -n "$vessel_out" ]; then
      out="${out:+$out; }$vessel_out"
      marker_paths[${#marker_paths[@]}]=$marker
      marker_sigs[${#marker_sigs[@]}]=$sig
    else
      rm -f "$marker" 2>/dev/null || true
    fi
  done

  if [ -n "$out" ]; then
    reason="check: bridge-inbox: $out"
    fm_wake_append check bridge-inbox "$reason" || status=$?
    if [ "$status" -eq 0 ]; then
      i=0
      while [ "$i" -lt "${#marker_paths[@]}" ]; do
        printf '%s' "${marker_sigs[$i]}" > "${marker_paths[$i]}" 2>/dev/null || true
        i=$((i + 1))
      done
    fi
  fi
  fm_lock_release "$BRIDGE_INBOX_LOCK"
  [ "$status" -eq 0 ] || return "$status"
  [ -z "$reason" ] || printf '%s\n' "$reason"
}
