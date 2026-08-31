#!/usr/bin/env bash
# Make GitHub's notification feed readable by the fleet, and wake firstmate only
# when a thread is actually addressed to it.
#
# WHY THIS EXISTS
# The fleet acts under the captain's personal GitHub identity, so every change a
# worker opens is authored by him and every thread notifies him. He does not want
# those notifications; the fleet does, and until this existed nothing here read
# them. A mention on a pull request this fleet opened had been sitting unread,
# addressed to a reader who was never going to look. The information was not lost
# because nobody was told - it was lost because it was told to the wrong reader.
# A machine account per vessel is the real correction and is filed separately;
# this makes the feed readable in the meantime, so unwatching costs him nothing.
#
# WHAT IT NEVER DOES
# It never marks anything read. Marking read is how a notification is consumed,
# and consuming one nobody saw is the same silent loss in a new place. Every
# request this script makes is a GET; there is no call to
# PUT /notifications or PUT /notifications/threads/<id> anywhere in it, and
# tests/fm-github-inbox.test.sh records the requests the reader receives and
# asserts that all of them use its non-mutating interface. What has been
# surfaced is tracked in this home's own record instead, where being wrong
# costs a repeat rather than a loss.
#
# IT HAS NO BASELINE, DELIBERATELY
# The upstream-pull-request watch was armed twice on nothing before it was
# caught, because a first reading that came back empty was written down as the
# starting point and every later reading matched it. This check cannot repeat
# that: it has no "state at arming" to compare against. Its first run evaluates
# every unread notification exactly as its thousandth run does, and an inbox
# backlog is the point rather than a thing to be swallowed. The only durable
# record is what has already been SURFACED, and a reading that failed writes
# nothing at all. --arm additionally takes a live reading and refuses to arm
# when the feed cannot be read, printing what it verified.
#
# AN UNREADABLE FEED IS NOT AN EMPTY ONE
# An unreachable API and a quiet inbox look identical from here. Three things
# separate them: gh-axi's exit status, a marker this script asks jq to emit with
# every successful payload, and gh-axi's own `truncated:` flag. A missing marker
# or a truncated body is reported as unable to read, never as nothing to report.
# The truncation flag is not theoretical: gh-axi cuts a response body at about
# 4000 characters, measured, which is why the feed is read in small pages and why
# every payload is base64 so a cut is detectable rather than silently plausible.
# docs/github-inbox.md holds those measurements.
#
# WHAT DESERVES A WAKE
# The discriminator is not the notification's `reason` alone, because every
# activity on a pull request its author opened - a reply, a review, a merge, a
# close - arrives with reason `author`. `subject.latest_comment_url` does not
# separate them either: it was measured equal to `subject.url` on every
# notification in this fleet's inbox, including ones carrying real replies from
# other people. So a conditional notification is decided from the thread's own
# timeline, in one further request:
#   always wake        mention, team_mention, review_requested, assign,
#                      ci_activity, security_alert, manual - somebody or
#                      something is addressing this fleet directly
#   never wake         state_change and subscribed - work this fleet did itself,
#                      and the repository-watching firehose
#   decided by thread  author and comment - wake when somebody OTHER than this
#                      account has spoken on the thread or disposed of it
#                      (commented, reviewed, closed, merged, reopened, assigned,
#                      review requested) since the last time that thread was
#                      surfaced. A merge firstmate performed itself is this
#                      account's own act and stays silent; a merge or close by
#                      an upstream maintainer is news and does not.
#   anything else      wake, naming the reason. An unrecognised reason is a gap
#                      in this list, and a gap that goes quiet is the defect
#                      this whole check exists to remove.
# Pushes to the branch are deliberately not in the timeline set: a `committed`
# event carries a git author NAME rather than a login, so it cannot be matched
# against this account at all, and a push is not addressed to anyone.
#
# NOISE CONTROL
# A thread is named once. What has been named is recorded, so the same reply does
# not wake the fleet every five minutes, and a thread only speaks again when
# something newer than what was surfaced happens on it. Readability is reported
# as a transition, so a forge outage costs one line rather than one every sweep.
#
# NOTHING IS DROPPED TO STAY WITHIN BUDGET
# A watcher check gets 30 seconds. Two caps keep this inside it, and neither
# discards anything: at most FM_GH_INBOX_MAX_INSPECT threads are examined per
# sweep and at most FM_GH_INBOX_MAX_NAMED are named in the line. Whatever is not
# examined or not named is simply not recorded as surfaced, so the next sweep
# picks it up. A backlog drains across sweeps; it is never consumed unseen.
#
# IT DOES NOT MESSAGE THE CAPTAIN
# It prints one line, the watcher wakes firstmate, and firstmate decides what
# reaches the captain and how. That routing is firstmate's under AGENTS.md
# section 9.
#
# Usage:
#   fm-github-inbox.sh            evaluate; print at most one line; always exit 0,
#                                 because the watcher reads the line, not the status
#   fm-github-inbox.sh --status   print the current evaluation in full whether or
#                                 not anything changed; records nothing
#   fm-github-inbox.sh --arm      verify a live reading, then write and register
#                                 this home's watcher check (idempotent)
#   fm-github-inbox.sh --armed    print one line when a home that armed this check
#                                 has stopped running it; silent on a home that
#                                 never armed it, because watching this feed is a
#                                 per-home opt-in and several homes draining one
#                                 inbox would each surface it separately
#   fm-github-inbox.sh --help
#
# Exit status:
#   0  default, --arm on success, --armed: always
#   0  --status: the feed was read
#   3  --status: the feed could not be read, so no verdict is issued
#   1  --arm: the feed could not be read, or the check could not be written
#   2  usage error
#
# State, under FM_HOME/state:
#   github-inbox.seen      one record per notification this check has evaluated:
#                          id, the updated_at it was evaluated at, the verdict,
#                          and the newest foreign activity already surfaced for
#                          that thread. Pruned only after a complete feed pass.
#   github-inbox.state     readable or unreadable, and since when
#   github-inbox.cursor    first notification-feed page for the next sweep
#   github-inbox.check.sh  the armed watcher check (with .check-trust)
#
# Environment:
#   FM_GH_INBOX_MAX_INSPECT  threads whose timeline may be read per sweep (6)
#   FM_GH_INBOX_MAX_NAMED    threads named in one line (4)
#   FM_GH_INBOX_PER_PAGE     notifications per feed request (15; kept well under
#                            gh-axi's measured body cut)
#   FM_GH_INBOX_MAX_PAGES    feed requests per sweep (5)
#   FM_GH_INBOX_IGNORE       comma-separated logins whose activity is not news,
#                            for example a review bot the fleet has stopped
#                            wanting woken for. Empty by default: a review on
#                            this fleet's contribution is exactly what this
#                            check is for, bot or not.
#   FM_GH_INBOX_STALE        seconds without a completed pass before --armed
#                            calls the check stopped (1800)
#   FM_GH_INBOX_GH           the GitHub reader to use (gh-axi)
#   FM_GH_INBOX_NOW          override the current epoch (tests)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The cross-home arm guard: an armed check must land in the state
# directory of the home it bakes (bin/fm-check-lib.sh).
# shellcheck source=bin/fm-check-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-check-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

SEEN="$STATE/github-inbox.seen"
STATE_FILE="$STATE/github-inbox.state"
CURSOR="$STATE/github-inbox.cursor"
CHECK="$STATE/github-inbox.check.sh"

GH=${FM_GH_INBOX_GH:-gh-axi}
MAX_INSPECT=${FM_GH_INBOX_MAX_INSPECT:-6}
MAX_NAMED=${FM_GH_INBOX_MAX_NAMED:-4}
PER_PAGE=${FM_GH_INBOX_PER_PAGE:-15}
MAX_PAGES=${FM_GH_INBOX_MAX_PAGES:-5}
IGNORE=${FM_GH_INBOX_IGNORE:-}
STALE=${FM_GH_INBOX_STALE:-1800}
NOW=${FM_GH_INBOX_NOW:-$(date +%s)}

case "$MAX_INSPECT" in *[!0-9]*|'') MAX_INSPECT=6 ;; esac
case "$MAX_NAMED" in *[!0-9]*|'') MAX_NAMED=4 ;; esac
case "$PER_PAGE" in *[!0-9]*|'') PER_PAGE=15 ;; esac
case "$MAX_PAGES" in *[!0-9]*|'') MAX_PAGES=5 ;; esac
case "$STALE" in *[!0-9]*|'') STALE=1800 ;; esac

MARK=FMGHINBOXv1:

MODE=detect
case "${1:-}" in
  '') ;;
  --status) MODE=status ;;
  --arm) MODE=arm ;;
  --armed) MODE=armed ;;
  --help|-h)
    printf 'usage: %s [--status|--arm|--armed|--help]\n' "$(basename "$0")"
    exit 0 ;;
  *)
    printf 'usage: %s [--status|--arm|--armed|--help]\n' "$(basename "$0")" >&2
    exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  printf 'usage: %s [--status|--arm|--armed|--help]\n' "$(basename "$0")" >&2
  exit 2
fi

human_duration() {
  local s=$1
  [ "$s" -lt 0 ] && s=0
  if [ "$s" -lt 60 ]; then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm%ds' "$((s / 60))" "$((s % 60))"
  else printf '%dh%dm' "$((s / 3600))" "$(((s % 3600) / 60))"
  fi
}

# --- reading ----------------------------------------------------------------
#
# One reader for every request, so there is exactly one place where "could not
# read" is decided. The payload is base64 inside a marker, for two reasons that
# were both measured rather than guessed (docs/github-inbox.md):
#   1. gh-axi renders a jq string result into a YAML envelope that quotes and
#      escapes on its own rules, so a payload carrying quotes, colons, or
#      newlines cannot be parsed back out reliably. Base64 has none of those
#      characters, so the token can be lifted out of any envelope shape.
#   2. gh-axi cuts a long body at about 4000 characters. It says so in a
#      `truncated:` field, which this refuses on - and a cut base64 token would
#      also fail to decode, so a silent half-reading has two independent ways of
#      being caught and none of passing.
#
# gh_read <path> <jq-expression-producing-a-string>
# On success the decoded payload is in GH_READ_OUT and the status is 0;
# GH_READ_WHY carries the reason on failure. Both are globals rather than stdout
# because a caller reading the payload through a command substitution would run
# this in a subshell and lose the reason with it - which is exactly how the first
# version of this reported an unreadable feed with no reason attached.
# Every path here is a GET; no method is ever passed, which is the mechanical
# half of never marking anything read.
GH_READ_WHY=
GH_READ_OUT=

gh_read() {
  local path=$1 expr=$2 raw rc token
  GH_READ_WHY=
  GH_READ_OUT=
  case "$path" in
    *[[:space:]]*) GH_READ_WHY="a malformed request path was refused"; return 1 ;;
  esac
  raw=$("$GH" api "$path" --jq "\"$MARK\" + ((${expr}) | @base64)" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    GH_READ_WHY="the GitHub reader exited $rc for $path"
    return 1
  fi
  case "$raw" in
    *'truncated: true'*)
      GH_READ_WHY="the response for $path was cut short by the GitHub reader, so it was read in part and is not a complete answer"
      return 1 ;;
  esac
  case "$raw" in
    *"$MARK"*) ;;
    *)
      GH_READ_WHY="the response for $path carried no readable payload, which is not the same as an empty one"
      return 1 ;;
  esac
  token=$(printf '%s' "$raw" | grep -o "${MARK}[A-Za-z0-9+/=]*" | head -n 1 | sed "s/^$MARK//")
  if [ -z "$token" ]; then
    # A genuinely empty payload base64-encodes to the empty string, so this is
    # the one case where nothing after the marker means exactly that.
    return 0
  fi
  if ! GH_READ_OUT=$(printf '%s' "$token" | base64 -d 2>/dev/null); then
    GH_READ_OUT=
    GH_READ_WHY="the payload for $path did not decode, so it arrived damaged rather than empty"
    return 1
  fi
  return 0
}

# --- the feed ---------------------------------------------------------------
#
# Compact on purpose: five fixed-width-ish fields and a shortened title, so a
# page stays far inside the body cut. Whitespace is squeezed out of the title in
# jq so a record is one line and the first five fields never contain a space.
FEED_JQ='"" + ([.[] | select(.unread) | .id + " " + (.reason // "-") + " " + (.updated_at // "-") + " " + (.subject.type // "-") + " " + ((.subject.url // "-") | sub("^https://api.github.com/repos/"; "")) + " " + ((.subject.title // "-") | gsub("[\\s]+"; " ") | if (length > 60) then (.[0:57] + "...") else . end)] | join("\n"))'

FEED=
FEED_COUNT=0
FEED_BOUNDED=
NEXT_CURSOR=1

read_cursor() {
  local page
  page=$(awk 'NR == 1 { print $1 }' "$CURSOR" 2>/dev/null)
  case "$page" in ''|*[!0-9]*|0) printf '1' ;; *) printf '%s' "$page" ;; esac
}

read_feed() {
  local page start_page payload lines pages=0
  page=$(read_cursor)
  start_page=$page
  FEED=
  FEED_COUNT=0
  FEED_BOUNDED=
  NEXT_CURSOR=$page
  while [ "$pages" -lt "$MAX_PAGES" ]; do
    gh_read "notifications?all=false&per_page=$PER_PAGE&page=$page" "$FEED_JQ" || return 1
    payload=$GH_READ_OUT
    lines=0
    if [ -n "$payload" ]; then
      lines=$(printf '%s\n' "$payload" | grep -c '^[0-9]' || true)
      FEED="${FEED}${payload}"
      FEED="$FEED
"
    fi
    FEED_COUNT=$((FEED_COUNT + lines))
    if [ "$lines" -lt "$PER_PAGE" ]; then
      NEXT_CURSOR=1
      if [ "$start_page" -ne 1 ]; then
        FEED_BOUNDED=1
      fi
      return 0
    fi
    page=$((page + 1))
    pages=$((pages + 1))
  done
  # Every page came back full, so there are unread threads this reading did not
  # reach. Said out loud rather than trimmed away.
  FEED_BOUNDED=1
  NEXT_CURSOR=$page
  return 0
}

# --- the thread -------------------------------------------------------------
#
# One request per conditional thread. The count header is what makes the page
# bound visible: an ascending timeline read at per_page=100 that returns exactly
# 100 events may be hiding the newest ones, which is the dangerous direction.
# shellcheck disable=SC2016  # $a is a jq binding, not a shell variable
TIMELINE_JQ='"#" + (length | tostring) + "\n" + ([.[] | select(.event == "commented" or .event == "reviewed" or .event == "line-commented" or .event == "commit-commented" or .event == "closed" or .event == "merged" or .event == "reopened" or .event == "review_requested" or .event == "assigned" or .event == "ready_for_review" or .event == "converted_to_draft") | ((.actor.login // ((.comments // []) | .[0].user.login) // "?") as $a | $a + " " + .event + " " + (.created_at // .submitted_at // "-"))] | join("\n"))'

ME=
ME_READ=

read_me() {
  [ -n "$ME_READ" ] && { [ -n "$ME" ]; return; }
  ME_READ=1
  gh_read user '.login' || { ME=; return 1; }
  ME=$GH_READ_OUT
  [ -n "$ME" ]
}

is_ignored() {
  local who=$1 entry
  [ -z "$IGNORE" ] && return 1
  local saved=$IFS
  IFS=,
  for entry in $IGNORE; do
    if [ "$entry" = "$who" ]; then IFS=$saved; return 0; fi
  done
  IFS=$saved
  return 1
}

# thread_foreign <owner/repo> <number>
# Sets THREAD_WHO / THREAD_WHAT / THREAD_WHEN to the NEWEST activity on the
# thread by anyone other than this account, or leaves them empty when there is
# none. Returns 1 when the thread could not be read completely.
THREAD_WHO=
THREAD_WHAT=
THREAD_WHEN=

thread_foreign() {
  local repo=$1 number=$2 payload total who what when merged_who=
  THREAD_WHO=; THREAD_WHAT=; THREAD_WHEN=
  gh_read "repos/$repo/issues/$number/timeline?per_page=100" "$TIMELINE_JQ" || return 1
  payload=$GH_READ_OUT
  total=$(printf '%s\n' "$payload" | sed -n 's/^#\([0-9]*\)$/\1/p' | head -n 1)
  if [ -n "$total" ] && [ "$total" -ge 100 ]; then
    GH_READ_WHY="the history of $repo#$number is longer than one reading reaches, so its newest activity was not seen"
    return 1
  fi
  while read -r who what when; do
    case "$who" in ''|'#'*) continue ;; esac
    [ "$who" = "$ME" ] && continue
    is_ignored "$who" && continue
    # GitHub records a merge as `merged` and then `closed`, a second apart on a
    # real pull request this fleet opened. Reporting the close would tell the
    # fleet its contribution was rejected when it was accepted, so a merge
    # anywhere in the history claims the close that follows it.
    [ "$what" = merged ] && merged_who=$who
    THREAD_WHO=$who
    THREAD_WHAT=$what
    THREAD_WHEN=$when
  done <<EOT
$(printf '%s\n' "$payload")
EOT
  if [ "$THREAD_WHAT" = closed ] && [ -n "$merged_who" ]; then
    THREAD_WHAT=merged
    THREAD_WHO=$merged_who
  fi
  return 0
}

# --- the durable record -----------------------------------------------------
#
# One record per notification: <id> <updated_at> <verdict> <newest-foreign-seen>.
# The verdict is `named` when this check printed that thread, or `routine` when
# it decided the thread was this fleet's own work. Nothing here is a GitHub read
# receipt; it only records what has already been said out loud.

seen_field() {
  local id=$1 field=$2
  [ -f "$SEEN" ] || return 1
  awk -v id="$id" -v f="$field" '$1 == id { print $f; found = 1 } END { exit !found }' "$SEEN"
}

read_state() {
  [ -f "$STATE_FILE" ] || { printf 'readable'; return; }
  awk 'NR == 1 { print $1 }' "$STATE_FILE" 2>/dev/null | grep -E '^(readable|unreadable)$' || printf 'readable'
}

read_state_since() {
  local since
  since=$(awk 'NR == 1 { print $2 }' "$STATE_FILE" 2>/dev/null)
  case "$since" in ''|*[!0-9]*) printf '%s' "$NOW" ;; *) printf '%s' "$since" ;; esac
}

write_state() {
  local verdict=$1 since=$2 tmp
  umask 077
  tmp=$(mktemp "$STATE/.fm-github-inbox-state.XXXXXX") || return 1
  printf '%s %s\n' "$verdict" "$since" >"$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$STATE_FILE" || { rm -f -- "$tmp"; return 1; }
}

write_seen() {
  local body=$1 tmp
  umask 077
  tmp=$(mktemp "$STATE/.fm-github-inbox-seen.XXXXXX") || return 1
  printf '%s' "$body" >"$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$SEEN" || { rm -f -- "$tmp"; return 1; }
}

write_cursor() {
  local tmp
  umask 077
  tmp=$(mktemp "$STATE/.fm-github-inbox-cursor.XXXXXX") || return 1
  printf '%s\n' "$NEXT_CURSOR" >"$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$CURSOR" || { rm -f -- "$tmp"; return 1; }
}

# --- classification ---------------------------------------------------------

# reason_class <reason> -> wake | routine | thread | unknown
reason_class() {
  case "$1" in
    mention|team_mention|review_requested|assign|ci_activity|security_alert|manual) printf 'wake' ;;
    state_change|subscribed) printf 'routine' ;;
    author|comment) printf 'thread' ;;
    *) printf 'unknown' ;;
  esac
}

# event_phrase <timeline-event> -> what that event reads as in a sentence
event_phrase() {
  case "$1" in
    commented) printf 'commented on' ;;
    reviewed) printf 'reviewed' ;;
    line-commented) printf 'left review comments on' ;;
    commit-commented) printf 'commented on a commit in' ;;
    closed) printf 'closed' ;;
    merged) printf 'merged' ;;
    reopened) printf 'reopened' ;;
    review_requested) printf 'requested a review on' ;;
    assigned) printf 'assigned' ;;
    ready_for_review) printf 'marked ready for review' ;;
    converted_to_draft) printf 'converted to draft' ;;
    *) printf '%s' "$1" ;;
  esac
}

# reason_phrase <notification-reason> -> what that reason reads as in a sentence
reason_phrase() {
  case "$1" in
    mention) printf 'this fleet was mentioned on' ;;
    team_mention) printf 'a team this fleet belongs to was mentioned on' ;;
    review_requested) printf 'a review was requested from this fleet on' ;;
    assign) printf 'this fleet was assigned' ;;
    ci_activity) printf 'a check result arrived on' ;;
    security_alert) printf 'a security alert on' ;;
    manual) printf 'a thread this fleet subscribed to changed:' ;;
    *) printf '%s on' "$1" ;;
  esac
}

# html_url <owner/repo/kind/number> -> a link a human can open
html_url() {
  local ref=$1 repo kind number
  case "$ref" in
    */*/*) ;;
    *) printf 'a GitHub thread this feed gave no link for'; return ;;
  esac
  repo=${ref%/*/*}
  kind=${ref#"$repo"/}
  number=${kind#*/}
  kind=${kind%%/*}
  case "$kind" in
    pulls) printf 'https://github.com/%s/pull/%s' "$repo" "$number" ;;
    issues) printf 'https://github.com/%s/issues/%s' "$repo" "$number" ;;
    *) printf 'https://github.com/%s' "$repo" ;;
  esac
}

# --- evaluation -------------------------------------------------------------
#
# VERDICT is one of: readable, unreadable.
VERDICT=unreadable
WHY=
NAMED=()
PENDING=0
ROUTINE=0
DEFERRED=0
NEW_SEEN=

evaluate() {
  local id reason updated type ref title class record prior_when prior_updated
  local inspected=0 item repo number caveat

  if ! read_feed; then
    WHY=$GH_READ_WHY
    return
  fi
  VERDICT=readable

  while read -r id reason updated type ref title; do
    [ -z "$id" ] && continue
    case "$id" in [!0-9]*) continue ;; esac
    THREAD_WHEN=

    prior_updated=$(seen_field "$id" 2) || prior_updated=
    prior_when=$(seen_field "$id" 4) || prior_when=
    [ "$prior_when" = '-' ] && prior_when=
    if [ -n "$prior_updated" ] && [ "$prior_updated" = "$updated" ]; then
      # Already decided at this exact revision of the thread. Carry the record
      # forward untouched; nothing about it has changed since it was decided.
      record=$(awk -v id="$id" '$1 == id { print; exit }' "$SEEN")
      NEW_SEEN="${NEW_SEEN}${record}
"
      continue
    fi

    class=$(reason_class "$reason")
    caveat=
    item=
    case "$class" in
      routine)
        ROUTINE=$((ROUTINE + 1))
        NEW_SEEN="${NEW_SEEN}$id $updated routine -
"
        continue ;;
      wake)
        item="$(reason_phrase "$reason") $(html_url "$ref")" ;;
      unknown)
        item="an unrecognised notification reason ($reason) on $(html_url "$ref")" ;;
      thread)
        repo=${ref%/*/*}
        number=${ref##*/}
        case "$type" in
          PullRequest|Issue) ;;
          *)
            # No thread to read, so this cannot be judged. It is surfaced rather
            # than dropped.
            item="a $type notification ($reason) on $(html_url "$ref")"
            ;;
        esac
        if [ -z "$item" ]; then
          if [ "$inspected" -ge "$MAX_INSPECT" ]; then
            # Not examined this sweep, so not recorded: the next sweep takes it.
            DEFERRED=$((DEFERRED + 1))
            continue
          fi
          inspected=$((inspected + 1))
          if ! read_me; then
            WHY="this fleet's own GitHub identity could not be read ($GH_READ_WHY), so nobody else's activity could be told apart from its own"
            VERDICT=unreadable
            return
          fi
          if thread_foreign "$repo" "$number"; then
            if [ -z "$THREAD_WHO" ]; then
              ROUTINE=$((ROUTINE + 1))
              NEW_SEEN="${NEW_SEEN}$id $updated routine -
"
              continue
            fi
            if [ -n "$prior_when" ] && ! [ "$THREAD_WHEN" \> "$prior_when" ]; then
              ROUTINE=$((ROUTINE + 1))
              NEW_SEEN="${NEW_SEEN}$id $updated routine $prior_when
"
              continue
            fi
            item="$THREAD_WHO $(event_phrase "$THREAD_WHAT") $(html_url "$ref")"
          else
            caveat=" (its history could not be read in full, so this may be more than it looks)"
            item="$(reason_phrase "$reason") $(html_url "$ref")$caveat"
          fi
        fi
        ;;
    esac

    [ -n "$title" ] && [ "$title" != '-' ] && item="$item \"$title\""

    if [ "${#NAMED[@]}" -lt "$MAX_NAMED" ]; then
      NAMED+=("$item")
      NEW_SEEN="${NEW_SEEN}$id $updated named ${THREAD_WHEN:--}
"
    else
      # Beyond what one line can name. Deliberately not recorded, so it is
      # named by the next sweep instead of being consumed unseen.
      PENDING=$((PENDING + 1))
    fi
  done <<EOT
$(printf '%s' "$FEED")
EOT

  if [ -n "$FEED_BOUNDED" ] && [ -f "$SEEN" ]; then
    while read -r record; do
      [ -n "$record" ] || continue
      id=${record%% *}
      if ! printf '%s' "$FEED" | awk -v id="$id" '$1 == id { found = 1 } END { exit !found }'; then
        NEW_SEEN="${NEW_SEEN}${record}
"
      fi
    done <"$SEEN"
  fi
}

compose_line() {
  local line item extras
  [ "${#NAMED[@]}" -eq 0 ] && return 1
  line="GITHUB_INBOX: ${#NAMED[@]} GitHub thread"
  [ "${#NAMED[@]}" -eq 1 ] || line="${line}s"
  line="$line addressed to this fleet:"
  for item in "${NAMED[@]}"; do
    line="$line $item;"
  done
  line=${line%;}
  line="$line."
  extras=
  [ "$PENDING" -gt 0 ] && extras="$extras $PENDING more wait to be named on the next pass."
  [ "$DEFERRED" -gt 0 ] && extras="$extras $DEFERRED were not examined this pass and are still queued."
  [ "$ROUTINE" -gt 0 ] && extras="$extras $ROUTINE further unread thread(s) were this fleet's own work and were not surfaced."
  [ -n "$FEED_BOUNDED" ] && extras="$extras There are more unread notifications than one reading reaches; later sweeps continue from older pages."
  printf '%s%s\n' "$line" "$extras"
  return 0
}

# --- modes ------------------------------------------------------------------

arm() {
  local desired current tmp
  # Before the write, not after: refusing only at registration would
  # still leave the other home's check overwritten and its trust stale.
  fm_check_arm_refuse fm-github-inbox "$STATE" "$FM_HOME" || return 1
  desired=$(cat <<SHIM
#!/usr/bin/env bash
# GENERATED by bin/fm-github-inbox.sh --arm - do not hand-edit.
#
# firstmate's watcher sweeps state/*.check.sh and wakes on any line one prints.
# This shim is only the seam: what counts as a thread addressed to this fleet,
# and what is this fleet's own work, live in the script itself, so they arrive by
# self-update instead of being frozen into every home's copy.
export FM_HOME="$FM_HOME"
export FM_STATE_OVERRIDE="$STATE"
export FM_DATA_OVERRIDE="$DATA"
exec "$SCRIPT_DIR/fm-github-inbox.sh"
SHIM
)
  current=$(cat "$CHECK" 2>/dev/null || true)
  if [ "$current" != "$desired" ] || [ ! -x "$CHECK" ]; then
    umask 077
    tmp=$(mktemp "$STATE/.fm-github-inbox-check.XXXXXX") || return 1
    printf '%s\n' "$desired" >"$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0700 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$CHECK" || { rm -f -- "$tmp"; return 1; }
  fi
  "$SCRIPT_DIR/fm-check-register.sh" github-inbox >/dev/null || return 1
}

armed_diagnostic() {
  local mtime age
  # Silent on a home that never armed this: watching one inbox from several homes
  # would have each of them surface it separately, so this is an opt-in and its
  # absence is a choice rather than a fault.
  [ -f "$CHECK" ] || return 0
  if [ ! -x "$CHECK" ]; then
    printf 'GITHUB_INBOX: the GitHub notification watch on this home cannot run, so nothing here is reading threads addressed to this fleet (fix: %s/fm-github-inbox.sh --arm)\n' \
      "$SCRIPT_DIR"
    return 0
  fi
  if [ ! -f "$STATE_FILE" ]; then
    mtime=$(stat -c %Y "$CHECK" 2>/dev/null) || return 0
    age=$((NOW - mtime))
    [ "$age" -gt "$STALE" ] &&
      printf 'GITHUB_INBOX: the GitHub notification watch was armed %s ago and has never completed a reading, so nothing here is reading threads addressed to this fleet (fix: %s/fm-github-inbox.sh --status)\n' \
        "$(human_duration "$age")" "$SCRIPT_DIR"
    return 0
  fi
  mtime=$(stat -c %Y "$STATE_FILE" 2>/dev/null) || return 0
  age=$((NOW - mtime))
  [ "$age" -gt "$STALE" ] &&
    printf 'GITHUB_INBOX: the GitHub notification watch last read the feed %s ago and has stopped running, so threads addressed to this fleet are going unread (fix: %s/fm-github-inbox.sh --status)\n' \
      "$(human_duration "$age")" "$SCRIPT_DIR"
  return 0
}

case "$MODE" in
  arm)
    # The coherence guard speaks first, ahead of the feed. arm() holds it too,
    # but only after a reading that costs a round trip and can fail for its own
    # reasons - and an unreadable feed would then be reported as the cause of a
    # refusal that a mismatched home had already decided.
    fm_check_arm_refuse fm-github-inbox "$STATE" "$FM_HOME" || exit 1
    # Rule against baselining on nothing: arming is refused unless a real
    # reading was taken, and what was verified is printed rather than implied.
    if ! read_feed; then
      printf 'fm-github-inbox: refusing to arm - the GitHub notification feed could not be read (%s). An unreadable feed is not an empty one, and a watch armed on it would be silent forever.\n' \
        "$GH_READ_WHY" >&2
      exit 1
    fi
    arm || { printf 'fm-github-inbox: cannot arm the notification watch in %s\n' "$STATE" >&2; exit 1; }
    printf 'verified: the GitHub notification feed is readable; %s unread thread(s) in this reading%s\n' \
      "$FEED_COUNT" "$([ -n "$FEED_BOUNDED" ] && printf ' (and more than one reading reaches)')"
    printf 'armed: %s\n' "$CHECK"
    exit 0 ;;
  armed)
    armed_diagnostic
    exit 0 ;;
  status)
    evaluate
    if [ "$VERDICT" = unreadable ]; then
      printf 'github-inbox: UNREADABLE - %s\n' "$WHY"
      printf 'this is not an empty inbox: threads addressed to this fleet may be waiting and this could not tell\n'
      exit 3
    fi
    printf 'github-inbox: read %s unread thread(s)%s\n' "$FEED_COUNT" \
      "$([ -n "$FEED_BOUNDED" ] && printf ', and there are more than one reading reaches')"
    if [ "${#NAMED[@]}" -eq 0 ]; then
      printf 'nothing is addressed to this fleet that it has not already been shown\n'
    else
      for item in "${NAMED[@]}"; do printf 'addressed to this fleet: %s\n' "$item"; done
    fi
    [ "$PENDING" -gt 0 ] && printf 'waiting to be named: %s\n' "$PENDING"
    [ "$DEFERRED" -gt 0 ] && printf 'not examined this pass: %s\n' "$DEFERRED"
    printf "work this fleet did itself, not surfaced: %s\n" "$ROUTINE"
    printf 'nothing was marked read; this records only what it has said out loud\n'
    exit 0 ;;
esac

# --- detect -----------------------------------------------------------------
#
# The watcher reads the line, not the exit status, so this mode always exits 0.

evaluate

PREVIOUS=$(read_state)
SINCE=$(read_state_since)

if [ "$VERDICT" = unreadable ]; then
  if [ "$PREVIOUS" != unreadable ]; then
    write_state unreadable "$NOW" || true
    printf 'GITHUB_INBOX: cannot read the GitHub notification feed - %s. This is not an empty inbox.\n' "$WHY"
  fi
  exit 0
fi

if [ "$PREVIOUS" = unreadable ]; then
  write_state readable "$NOW" || true
  printf 'GITHUB_INBOX: the GitHub notification feed can be read again after %s.\n' "$(human_duration "$((NOW - SINCE))")"
  # The recovery is this sweep's news; whatever it found is named next sweep,
  # once nothing has been recorded as surfaced that was not printed.
  exit 0
fi

write_state readable "$SINCE" || true

if LINE=$(compose_line); then
  # The record is written only after the line exists, so a thread is recorded as
  # named exactly when it was named.
  write_seen "$NEW_SEEN" || {
    printf 'GITHUB_INBOX: %s\n' \
      "the notification watch read the feed but could not record what it surfaced in $SEEN, so it stopped rather than risk surfacing the same threads forever or none of them"
    exit 0
  }
  write_cursor || true
  printf '%s\n' "$LINE"
  exit 0
fi

write_seen "$NEW_SEEN" || true
write_cursor || true
exit 0
