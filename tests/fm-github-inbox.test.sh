#!/usr/bin/env bash
# Behavior tests for the GitHub notification watch.
#
# Every case serves a fixture feed through the script's real jq expressions, so
# the suite measures what the check DECIDES rather than what GitHub happened to
# contain on the day it was written. The stand-in reader emulates gh-axi's
# envelope, including the truncation flag, because that envelope is where two of
# the three ways this check can lie actually live.
#
# The properties under test are the ones that would let it lie:
#   a feed it could not read must never come back as an empty one;
#   a thread must never be recorded as surfaced unless it was printed;
#   work this fleet did itself must not wake anyone;
#   and somebody writing to this fleet must.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'ok - skipped: jq is not installed\n'; exit 0; }
command -v base64 >/dev/null 2>&1 || { printf 'ok - skipped: base64 is not installed\n'; exit 0; }

fm_test_tmproot TMP_ROOT fm-github-inbox-tests

CHECK_SCRIPT="$ROOT/bin/fm-github-inbox.sh"
HOME_DIR="$TMP_ROOT/home"
FIX="$TMP_ROOT/fixtures"
REQUEST_LOG="$TMP_ROOT/requests.log"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$FIX"

ME=fleetaccount

# --- the stand-in reader ----------------------------------------------------
#
# Serves fixture JSON through the caller's real jq expression and wraps the
# result in gh-axi's envelope. Page 2 and beyond are empty, which is what a
# short feed looks like.

FAKE_GH="$TMP_ROOT/fake-gh"
cat >"$FAKE_GH" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$FM_TEST_GH_LOG"
[ "${FM_TEST_GH_FAIL:-0}" = 1 ] && exit 1
path=$2
expr=$4
src=
case "$path" in
  user) src="$FM_TEST_GH_FIX/user.json" ;;
  notifications*)
    page=${path##*&page=}
    if [ "$page" = 1 ]; then
      src="$FM_TEST_GH_FIX/notifications.json"
    else
      src="$FM_TEST_GH_FIX/notifications-page-$page.json"
      [ -f "$src" ] || src="$FM_TEST_GH_FIX/empty.json"
    fi
    ;;
  repos/*/issues/*/timeline*)
    rest=${path#repos/*/issues/}
    number=${rest%%/*}
    src="$FM_TEST_GH_FIX/timeline-$number.json"
    [ -f "$src" ] || src="$FM_TEST_GH_FIX/empty.json"
    ;;
  *) src="$FM_TEST_GH_FIX/empty.json" ;;
esac
body=$(jq -r "$expr" <"$src" 2>/dev/null) || exit 1
printf 'api_response:\n  body: %s\n  truncated: %s\n' "$body" "${FM_TEST_GH_TRUNCATE:-false}"
EOF
chmod +x "$FAKE_GH"

printf '[]\n' >"$FIX/empty.json"
printf '{"login":"%s"}\n' "$ME" >"$FIX/user.json"

inbox() {
  env FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_GH_INBOX_GH="$FAKE_GH" FM_TEST_GH_FIX="$FIX" FM_TEST_GH_LOG="$REQUEST_LOG" \
      FM_GH_INBOX_PER_PAGE="${FM_GH_INBOX_PER_PAGE:-50}" \
      "$CHECK_SCRIPT" "$@"
}

reset_home() {
  rm -f "$HOME_DIR/state"/github-inbox.*
}

# notification <id> <reason> <updated> <type> <owner/repo> <api-path> <title>
notification() {
  printf '{"id":"%s","unread":true,"reason":"%s","updated_at":"%s","subject":{"title":"%s","type":"%s","url":"https://api.github.com/repos/%s"},"repository":{"full_name":"%s"}}' \
    "$1" "$2" "$3" "$7" "$4" "$6" "$5"
}

feed() {
  local first=1 out='['
  local n
  for n in "$@"; do
    [ "$first" = 1 ] || out="$out,"
    first=0
    out="$out$n"
  done
  printf '%s]\n' "$out" >"$FIX/notifications.json"
}

# timeline <number> <event:actor:time>...
timeline() {
  local number=$1 first=1 out='[' e ev ac ti
  shift
  for e in "$@"; do
    ev=${e%%:*}; ac=${e#*:}; ti=${ac#*:}; ac=${ac%%:*}
    [ "$first" = 1 ] || out="$out,"
    first=0
    out="$out{\"event\":\"$ev\",\"actor\":{\"login\":\"$ac\"},\"created_at\":\"$ti\"}"
  done
  printf '%s]\n' "$out" >"$FIX/timeline-$number.json"
}

# --- somebody writing to this fleet must wake it ----------------------------

reset_home
feed "$(notification 1 mention 2026-08-20T09:00:00Z PullRequest acme/widget acme/widget/pulls/7 'add a flag')"
out=$(inbox)
assert_contains "$out" "GITHUB_INBOX:" "a mention must wake firstmate"
assert_contains "$out" "https://github.com/acme/widget/pull/7" "the wake must carry a link a human can open"
assert_contains "$out" "mentioned" "the wake must say what happened"
pass "a mention on a change this fleet opened wakes firstmate"

reset_home
feed "$(notification 2 author 2026-08-20T09:00:00Z PullRequest acme/widget acme/widget/pulls/8 'add another flag')"
timeline 8 "commented:outsider:2026-08-20T08:59:00Z"
out=$(inbox)
assert_contains "$out" "outsider commented on https://github.com/acme/widget/pull/8" \
  "a review comment by somebody else on this fleet's change must wake firstmate"
pass "a comment by somebody else on a fleet-opened change wakes firstmate"

reset_home
feed "$(notification 3 author 2026-08-20T09:00:00Z PullRequest acme/widget acme/widget/pulls/9 'upstream contribution')"
timeline 9 "merged:maintainer:2026-08-20T08:58:00Z" "closed:maintainer:2026-08-20T08:58:01Z"
out=$(inbox)
assert_contains "$out" "maintainer merged https://github.com/acme/widget/pull/9" \
  "an upstream maintainer landing this fleet's contribution must be reported as a merge, not a close"
pass "a merge by somebody else is reported as a merge and wakes firstmate"

# --- work this fleet did itself must not -------------------------------------

reset_home
feed "$(notification 4 author 2026-08-20T09:00:00Z PullRequest acme/own acme/own/pulls/1 'our own change')"
timeline 1 "merged:$ME:2026-08-20T08:58:00Z" "closed:$ME:2026-08-20T08:58:01Z"
out=$(inbox)
[ -z "$out" ] || fail "a merge this fleet performed itself must not wake anyone, got: $out"
pass "a merge this fleet performed itself stays silent"

reset_home
feed "$(notification 5 state_change 2026-08-20T09:00:00Z PullRequest acme/own acme/own/pulls/2 'closed by us')" \
     "$(notification 6 subscribed 2026-08-20T09:00:00Z Issue acme/own acme/own/issues/3 'watched repo noise')"
out=$(inbox)
[ -z "$out" ] || fail "routine repository noise must not wake anyone, got: $out"
pass "state changes this fleet made and repository-watching noise stay silent"

# --- an unrecognised reason is a gap, and a gap must not go quiet ------------

reset_home
feed "$(notification 7 some_future_reason 2026-08-20T09:00:00Z PullRequest acme/widget acme/widget/pulls/4 'unknown shape')"
out=$(inbox)
assert_contains "$out" "unrecognised" "a reason this check does not know must be surfaced, not dropped"
pass "an unrecognised notification reason wakes firstmate rather than going quiet"

# --- a thread is named once -------------------------------------------------

reset_home
feed "$(notification 8 mention 2026-08-20T09:00:00Z PullRequest acme/widget acme/widget/pulls/5 'named once')"
first=$(inbox)
second=$(inbox)
assert_contains "$first" "GITHUB_INBOX:" "the first pass must name the thread"
[ -z "$second" ] || fail "a thread already named must not wake the fleet again, got: $second"
pass "a thread is named once, not on every sweep"

# --- a reply already surfaced does not wake the fleet again ------------------

reset_home
feed "$(notification 20 author 2026-08-20T09:00:00Z PullRequest acme/widget acme/widget/pulls/20 'one reply')"
timeline 20 "commented:outsider:2026-08-20T08:00:00Z"
first=$(inbox)
assert_contains "$first" "outsider commented on" "the reply must be surfaced once"
# The thread is touched again - a push, a label, anything - so the notification's
# own timestamp moves while the newest thing anyone said stays where it was.
feed "$(notification 20 author 2026-08-20T11:00:00Z PullRequest acme/widget acme/widget/pulls/20 'one reply')"
second=$(inbox)
[ -z "$second" ] || fail "a reply already surfaced must not wake the fleet again, got: $second"
timeline 20 "commented:outsider:2026-08-20T08:00:00Z" "commented:outsider:2026-08-20T12:00:00Z"
feed "$(notification 20 author 2026-08-20T12:00:01Z PullRequest acme/widget acme/widget/pulls/20 'one reply')"
third=$(inbox)
assert_contains "$third" "outsider commented on" "a NEWER reply on the same thread must wake the fleet"
pass "a thread speaks again only when something newer than what was surfaced happens on it"

# --- an unreadable feed is not an empty one ---------------------------------

reset_home
feed "$(notification 9 mention 2026-08-20T09:00:00Z PullRequest acme/widget acme/widget/pulls/6 'unreachable')"
out=$(FM_TEST_GH_FAIL=1 inbox)
assert_contains "$out" "cannot read the GitHub notification feed" \
  "a feed that could not be read must say so"
assert_contains "$out" "not an empty inbox" \
  "an unreadable feed must never be reported as a quiet one"
assert_absent "$HOME_DIR/state/github-inbox.seen" \
  "a reading that failed must record nothing at all"
again=$(FM_TEST_GH_FAIL=1 inbox)
[ -z "$again" ] || fail "a continuing outage must be reported once, got: $again"
recovered=$(inbox)
assert_contains "$recovered" "can be read again" "recovery must close the outage it opened"
pass "an unreadable feed reports itself once, records nothing, and closes on recovery"

reset_home
feed "$(notification 10 mention 2026-08-20T09:00:00Z PullRequest acme/widget acme/widget/pulls/10 'cut short')"
out=$(FM_TEST_GH_TRUNCATE=true inbox)
assert_contains "$out" "cannot read the GitHub notification feed" \
  "a response the reader cut short is a partial reading, not a complete one"
pass "a truncated response is reported as unreadable rather than believed"

# --- nothing is recorded as surfaced unless it was printed ------------------

reset_home
feed "$(notification 11 mention 2026-08-20T09:00:00Z PullRequest acme/widget acme/widget/pulls/11 'first')" \
     "$(notification 12 mention 2026-08-20T09:00:00Z PullRequest acme/widget acme/widget/pulls/12 'second')"
out=$(FM_GH_INBOX_MAX_NAMED=1 inbox)
assert_contains "$out" "1 GitHub thread addressed to this fleet" "the name cap must hold"
assert_contains "$out" "1 more wait to be named" "what did not fit must be counted out loud"
recorded=$(wc -l <"$HOME_DIR/state/github-inbox.seen" | tr -d ' ')
[ "$recorded" = 1 ] || fail "only the thread that was printed may be recorded, got $recorded records"
next=$(FM_GH_INBOX_MAX_NAMED=1 inbox)
assert_contains "$next" "pull/12" "the thread that did not fit must be named on the next pass"
pass "a thread beyond the name cap is carried to the next pass, never consumed unseen"

reset_home
feed "$(notification 13 author 2026-08-20T09:00:00Z PullRequest acme/widget acme/widget/pulls/13 'one')" \
     "$(notification 14 author 2026-08-20T09:00:00Z PullRequest acme/widget acme/widget/pulls/14 'two')"
timeline 13 "commented:outsider:2026-08-20T08:00:00Z"
timeline 14 "commented:outsider:2026-08-20T08:00:00Z"
out=$(FM_GH_INBOX_MAX_INSPECT=1 inbox)
assert_contains "$out" "still queued" "threads not examined this pass must be counted out loud"
later=$(FM_GH_INBOX_MAX_INSPECT=1 inbox)
assert_contains "$later" "pull/14" "a thread not examined must be examined on a later pass"
pass "a thread beyond the inspection cap is examined later, never dropped"

# --- a feed larger than one page window advances across sweeps --------------

reset_home
feed "$(notification 21 mention 2026-08-20T09:00:00Z PullRequest acme/widget acme/widget/pulls/21 'newest')"
printf '%s\n' "[$(notification 22 mention 2026-08-20T08:00:00Z PullRequest acme/widget acme/widget/pulls/22 'older')]" >"$FIX/notifications-page-2.json"
printf '%s\n' "[$(notification 23 mention 2026-08-20T07:00:00Z PullRequest acme/widget acme/widget/pulls/23 'oldest')]" >"$FIX/notifications-page-3.json"
first=$(FM_GH_INBOX_PER_PAGE=1 FM_GH_INBOX_MAX_PAGES=1 inbox)
assert_contains "$first" "pull/21" "the first bounded sweep must read the first page"
second=$(FM_GH_INBOX_PER_PAGE=1 FM_GH_INBOX_MAX_PAGES=1 inbox)
assert_contains "$second" "pull/22" "the next bounded sweep must resume at the next page"
third=$(FM_GH_INBOX_PER_PAGE=1 FM_GH_INBOX_MAX_PAGES=1 inbox)
assert_contains "$third" "pull/23" "later bounded sweeps must reach older notifications"
pass "bounded notification sweeps advance through older pages"

FM_GH_INBOX_PER_PAGE=1 FM_GH_INBOX_MAX_PAGES=1 inbox >/dev/null
feed "$(notification 24 mention 2026-08-20T10:00:00Z PullRequest acme/widget acme/widget/pulls/24 'new newest')"
newest=$(FM_GH_INBOX_PER_PAGE=1 FM_GH_INBOX_MAX_PAGES=1 inbox)
assert_contains "$newest" "pull/24" "reaching the feed end must return the next sweep to page one"
pass "a complete notification sweep returns to the newest page"

reset_home
printf '%s\n' '90 2026-08-20T06:00:00Z named -' >"$HOME_DIR/state/github-inbox.seen"
FM_GH_INBOX_PER_PAGE=1 FM_GH_INBOX_MAX_PAGES=1 inbox >/dev/null
assert_contains "$(cat "$HOME_DIR/state/github-inbox.seen")" "90 2026-08-20T06:00:00Z named -" \
  "a partial feed read must retain records outside its current window"
pass "a partial notification sweep does not prune unseen records"
rm -f "$FIX"/notifications-page-*.json

# --- a history too long to read is not an all-clear -------------------------

reset_home
feed "$(notification 15 author 2026-08-20T09:00:00Z PullRequest acme/widget acme/widget/pulls/15 'very long history')"
long='['
i=0
while [ "$i" -lt 100 ]; do
  [ "$i" = 0 ] || long="$long,"
  long="$long{\"event\":\"subscribed\",\"actor\":{\"login\":\"$ME\"},\"created_at\":\"2026-08-01T00:00:00Z\"}"
  i=$((i + 1))
done
printf '%s]\n' "$long" >"$FIX/timeline-15.json"
out=$(inbox)
assert_contains "$out" "could not be read in full" \
  "a history longer than one reading reaches must be surfaced with that caveat"
pass "a thread whose history could not be read in full is surfaced, not assumed quiet"

# --- arming refuses to baseline on nothing ----------------------------------

reset_home
feed "$(notification 16 mention 2026-08-20T09:00:00Z PullRequest acme/widget acme/widget/pulls/16 'arm me')"
out=$(FM_TEST_GH_FAIL=1 inbox --arm 2>&1)
status=$?
[ "$status" = 1 ] || fail "arming on an unreadable feed must fail, got exit $status"
assert_contains "$out" "refusing to arm" "arming must refuse a feed it could not read"
assert_absent "$HOME_DIR/state/github-inbox.check.sh" "a refused arming must leave no check behind"
pass "arming refuses an unreadable feed instead of baselining on nothing"

reset_home
out=$(inbox --arm 2>&1)
status=$?
[ "$status" = 0 ] || fail "arming on a readable feed must succeed, got exit $status: $out"
assert_contains "$out" "verified:" "arming must state what it verified, not imply it"
assert_contains "$out" "1 unread thread" "arming must report the size of the reading it took"
assert_present "$HOME_DIR/state/github-inbox.check.sh" "arming must write the check"
assert_present "$HOME_DIR/state/github-inbox.check-trust" "arming must register the check"
pass "arming verifies a real reading first and says what it verified"

# --- nothing is ever marked read --------------------------------------------

assert_present "$REQUEST_LOG" "the request log must contain executable evidence"
[ -s "$REQUEST_LOG" ] || fail "the request log must not be empty"
while IFS= read -r request; do
  case "$request" in
    api\ *\ --jq\ *) ;;
    *) fail "every GitHub request must use the plain GET interface, got: $request" ;;
  esac
  case "$request" in
    *' --method '*|*' -X '*) fail "the notification watch must not select a mutating method, got: $request" ;;
  esac
done <"$REQUEST_LOG"
pass "the notification watch issues no mutating GitHub request, so it can consume nothing"

# --- the staleness report is opt-in -----------------------------------------

reset_home
out=$(inbox --armed)
[ -z "$out" ] || fail "a home that never armed this watch must not be told it stopped, got: $out"
inbox --arm >/dev/null 2>&1 || fail "arming must succeed before the staleness case"
out=$(env FM_GH_INBOX_NOW=$(( $(date +%s) + 7200 )) \
      FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_GH_INBOX_GH="$FAKE_GH" FM_TEST_GH_FIX="$FIX" FM_TEST_GH_LOG="$REQUEST_LOG" "$CHECK_SCRIPT" --armed)
assert_contains "$out" "GITHUB_INBOX:" "a watch that armed and then stopped must say so"
pass "the staleness report is silent on homes that never armed and speaks on ones that did"

printf 'ok - fm-github-inbox\n'
