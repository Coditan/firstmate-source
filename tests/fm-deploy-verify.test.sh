#!/usr/bin/env bash
# Behavior tests for bin/fm-deploy-verify.sh and contract tests for the
# `deploying` skill.
#
# Every behavioral test below drives the real script end to end against a stub
# host and asserts on its OUTPUT and EXIT STATUS. None asserts on implementation
# source text, because a verifier that passes its own tests by containing the
# right words is the defect it exists to prevent.
#
# Several tests come in pairs on purpose: the failing case and the control that
# would otherwise have passed. A test for "a stopped container never agrees" is
# worth nothing unless the same fixture, with the container running, does agree
# - otherwise it might be passing for any reason at all.
#
# Each defect test below was additionally checked against a mutation of the tool
# that reintroduces the defect it pins, and seen to FAIL there. A test added to
# pin a fix, that passes just as well without the fix, is no evidence for what it
# was added to prove; the mutations are named in this change's commit message.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-deploy-verify.sh"
SKILL="$ROOT/.agents/skills/deploying/SKILL.md"
AGENTS="$ROOT/AGENTS.md"

fm_test_tmproot T fm-deploy-verify
BIN=$(fm_fakebin "$T")

# --- the stub host ----------------------------------------------------------
#
# A faithful stand-in for the transport, not a convenience: real ssh joins its
# command arguments with single spaces and the remote LOGIN SHELL re-parses the
# result. Reproducing that second parse here is the only way a test can show
# that an argument carrying & or a space reaches the remote verb intact.
cat >"$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
host=$1; shift
printf '%s | %s\n' "$host" "$*" >>"${FM_FAKE_SSH_LOG:-/dev/null}"
# A host that accepts the connection and never answers: firewalled, blackholed,
# or simply wedged. The verifier's own --timeout is the only thing that ends it.
case "${FM_FAKE_SSH_SLEEP:-}" in
  '') : ;;
  *) sleep "$FM_FAKE_SSH_SLEEP"; exit 0 ;;
esac
# A transport that fails outright - unreachable, refused, host key changed -
# answers on stderr and never runs the payload at all.
case "${FM_FAKE_SSH_FAIL:-}" in
  '') : ;;
  *) printf '%s\n' "$FM_FAKE_SSH_FAIL" >&2; exit 255 ;;
esac
# A host that answers the transport but returns nothing for one verb. Real, and
# the reason the tool must not read an empty reply as a reading.
case "${FM_FAKE_SSH_EMPTY_VERB:-}" in
  '') : ;;
  *) case "$*" in
       *"'${FM_FAKE_SSH_EMPTY_VERB}'"*) exit 0 ;;
     esac ;;
esac
# The far side is a different machine: what it has on PATH is its business, so
# a test can give the host tools the verifier itself does not have.
case "${FM_FAKE_SSH_PATH:-}" in
  '') : ;;
  *) PATH=$FM_FAKE_SSH_PATH; export PATH ;;
esac
exec /bin/sh -c "$*"
EOF

cat >"$BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -u
all="$*"
printf '%s\n' "${all//$'\n'/ }" >>"${FM_FAKE_DOCKER_LOG:-/dev/null}"
case "${1:-}" in
  version) exit "${FM_FAKE_DOCKER_VERSION_RC:-0}" ;;
  inspect)
    if [ "${FM_FAKE_DOCKER_INSPECT_RC:-0}" != 0 ]; then
      echo "Error: No such object: fixture" >&2
      exit "$FM_FAKE_DOCKER_INSPECT_RC"
    fi
    cat "$FM_FAKE_DOCKER_INSPECT"
    ;;
  *) echo "fake docker: unexpected verb ${1:-}" >&2; exit 9 ;;
esac
EOF

cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -u
out=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --) shift; url=$1; shift ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s\n' "$url" >>"${FM_FAKE_CURL_LOG:-/dev/null}"
[ -n "$out" ] && printf '%s' "${FM_FAKE_CURL_BODY:-}" >"$out"
# A payload cut short after the probe file exists and before it is removed: the
# connection dropping, or the verifier's own bound firing on the far side.
case "${FM_FAKE_CURL_KILL_PAYLOAD:-}" in
  '') : ;;
  *)
    # curl runs inside a command substitution, so its parent is a forked
    # subshell; the payload itself is one level further up.
    payload=$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ')
    [ -n "$payload" ] && kill -TERM "$payload" 2>/dev/null
    ;;
esac
printf '%s' "${FM_FAKE_CURL_CODE:-200}"
EOF

cat >"$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -u
[ "${1:-}" = -n ] && shift
printf '%s\n' "$*" >>"${FM_FAKE_SUDO_LOG:-/dev/null}"
export FM_FAKE_UNDER_SUDO=1
exec "$@"
EOF

chmod +x "$BIN/ssh" "$BIN/docker" "$BIN/curl" "$BIN/sudo"
PATH="$BIN:$PATH"
export PATH

# --- the fixture repository -------------------------------------------------
#
# probe.txt is deliberately BYTE-IDENTICAL at A and B. That is not a contrived
# case: an unchanged file across two commits is the ordinary state of a repo,
# and it is exactly what makes a served-bytes reading unable to discriminate.
REPO="$T/repo"
fm_git_identity
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
printf 'alpha\n' >"$REPO/probe.txt"
printf 'one\n' >"$REPO/other.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm one
A=$(git -C "$REPO" rev-parse HEAD)
printf 'two\n' >"$REPO/other.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm two
B=$(git -C "$REPO" rev-parse HEAD)
printf 'beta\n' >"$REPO/probe.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm three
C=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" branch old "$A"
# A commit at which the probe path does NOT exist. Ordinary history: the file a
# later run probes for was added, or removed, at some point.
git -C "$REPO" checkout -q -b noprobe
git -C "$REPO" rm -q probe.txt
git -C "$REPO" commit -qm "no probe"
D=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q main
# An ANNOTATED tag: ls-remote answers with the tag object, and the commit only
# through the peeled entry. Deploys pinned to a tag are the ordinary case.
git -C "$REPO" tag -a v1 -m 'release 1' "$A"
# One name carried by two different refs at two different commits.
git -C "$REPO" branch collide "$A"
git -C "$REPO" tag -a collide -m collide "$C"

# A repository that HAS the path at its head and CANNOT read the blob: the
# ordinary state of a filtered clone whose promisor remote is unreachable,
# reproduced here by removing the loose object so the fixture needs no network.
# P's blob is the missing one; Q's is readable and matches the default served
# body, so one repository carries both an unruled-out candidate and a match.
BLOBLESS="$T/blobless"
mkdir -p "$BLOBLESS"
git -C "$BLOBLESS" init -q -b main
printf 'alpha\n' >"$BLOBLESS/probe.txt"
git -C "$BLOBLESS" add -A && git -C "$BLOBLESS" commit -qm "probe alpha"
BLOBLESS_P=$(git -C "$BLOBLESS" rev-parse HEAD)
BLOBLESS_P_BLOB=$(git -C "$BLOBLESS" rev-parse "HEAD:probe.txt")
printf 'beta\n' >"$BLOBLESS/probe.txt"
git -C "$BLOBLESS" add -A && git -C "$BLOBLESS" commit -qm "probe beta"
BLOBLESS_Q=$(git -C "$BLOBLESS" rev-parse HEAD)
rm -f "$BLOBLESS/.git/objects/${BLOBLESS_P_BLOB:0:2}/${BLOBLESS_P_BLOB:2}"

# path_without <dir> <command>... - a PATH directory holding everything the
# current PATH holds EXCEPT the named commands, so a test can run the tool on a
# machine that genuinely lacks a tool rather than on one pretending to.
path_without() {
  local dir=$1 d f b drop
  shift
  drop=" $* "
  mkdir -p "$dir"
  for d in ${PATH//:/ }; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -e "$f" ] || continue
      b=${f##*/}
      case "$drop" in *" $b "*) continue ;; esac
      [ -e "$dir/$b" ] && continue
      ln -s "$f" "$dir/$b" 2>/dev/null || true
    done
  done
}

# inspect_fixture <file> <running> <restarts> <revision> [extra template lines]
inspect_fixture() {
  local f=$1 running=$2 restarts=$3 rev=$4
  shift 4
  {
    printf 'running=%s\n' "$running"
    if [ "$running" = true ]; then printf 'status=running\n'; else printf 'status=exited\n'; fi
    printf 'restarts=%s\n' "$restarts"
    printf 'started=2026-08-19T21:34:05Z\n'
    printf 'image=sha256:deadbeef\n'
    printf 'revision=%s\n' "$rev"
    printf 'compose_working_dir=/opt/fixture\n'
    printf 'compose_config_files=/opt/fixture/docker-compose.yml\n'
    printf 'mount=/opt/fixture/app -> /srv/app (ro)\n'
    printf '%s\n' "$@"
  } >"$f"
}

RUNNING_AT_C="$T/inspect-running.txt"
RUNNING_AT_A="$T/inspect-running-at-a.txt"
STOPPED_AT_C="$T/inspect-stopped.txt"
NO_LABEL="$T/inspect-nolabel.txt"
inspect_fixture "$RUNNING_AT_C" true 0 "$C"
inspect_fixture "$RUNNING_AT_A" true 0 "$A"
inspect_fixture "$STOPPED_AT_C" false 17 "$C"
inspect_fixture "$NO_LABEL" true 0 '<no value>'

reset_env() {
  export FM_FAKE_SSH_LOG="$T/ssh.log"
  export FM_FAKE_DOCKER_LOG="$T/docker.log"
  export FM_FAKE_CURL_LOG="$T/curl.log"
  export FM_FAKE_SUDO_LOG="$T/sudo.log"
  : >"$FM_FAKE_SSH_LOG"; : >"$FM_FAKE_DOCKER_LOG"
  : >"$FM_FAKE_CURL_LOG"; : >"$FM_FAKE_SUDO_LOG"
  export FM_FAKE_DOCKER_INSPECT="$RUNNING_AT_C"
  export FM_FAKE_DOCKER_INSPECT_RC=0
  export FM_FAKE_DOCKER_VERSION_RC=0
  export FM_FAKE_CURL_CODE=200
  export FM_FAKE_CURL_BODY='beta
'
  unset FM_FAKE_SSH_EMPTY_VERB FM_FAKE_SSH_FAIL FM_FAKE_SSH_PATH FM_FAKE_SSH_SLEEP
  unset FM_FAKE_CURL_KILL_PAYLOAD
}

# run_tool <args...> - run the verifier against the stub host, capture output
# and exit status into OUT and RC.
run_tool() {
  RC=0
  OUT=$("$TOOL" --host stub-host "$@" 2>&1) || RC=$?
  record_verdicts "$OUT"
}

# Every verdict line any run below emits is kept, so a later guard can hold the
# skill's quoted verdicts against output the tool really produced rather than
# against its source.
VERDICTS="$T/emitted-verdicts.txt"
: >"$VERDICTS"
record_verdicts() {
  printf '%s\n' "$1" | sed -n '/^verdict: /p' >>"$VERDICTS"
}

# --- D2: a stopped container is never an agreement --------------------------

# The control comes FIRST so the failing case below cannot be passing for an
# unrelated reason: same fixture, same comparisons, container running.
test_a_running_container_that_matches_agrees() {
  reset_env
  run_tool --container svc --checkout "$REPO" --source-remote "$REPO" --source-ref refs/heads/main
  expect_code 0 "$RC" "a running container at the expected commit must agree"
  assert_contains "$OUT" 'verdict: AGREE' "the control run must reach AGREE"
  assert_contains "$OUT" 'AGREE ' "the control run must show agreeing comparisons"
  pass "control: a running container at the expected commit agrees and exits 0"
}

test_a_stopped_container_is_never_an_agreement() {
  reset_env
  export FM_FAKE_DOCKER_INSPECT="$STOPPED_AT_C"
  run_tool --container svc --checkout "$REPO" --source-remote "$REPO" --source-ref refs/heads/main
  [ "$RC" != 0 ] || fail "a stopped container must not exit 0 (got $RC)"$'\n'"$OUT"
  assert_not_contains "$OUT" 'verdict: AGREE' "a stopped container must never reach an AGREE verdict"
  assert_contains "$OUT" 'container: UNREAD' "the running-side reading must be reported unread"
  assert_contains "$OUT" 'state=exited' "the reason must name the container state"
  assert_contains "$OUT" 'restarts=17' "the reason must name the restart count"
  pass "a stopped container is reported unread, never as agreement"
}

# --- D3: an ambiguous served-bytes reading resolves to nothing --------------

test_a_served_reading_that_cannot_discriminate_resolves_to_nothing() {
  reset_env
  export FM_FAKE_CURL_BODY='alpha
'
  run_tool --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$REPO" \
    --candidate "$A" --candidate "$B"
  expect_code 3 "$RC" "a tied served-bytes reading must be indeterminate"
  assert_contains "$OUT" 'AMBIGUOUS' "the tie must be named as ambiguous"
  assert_contains "$OUT" "${A:0:12}" "the ambiguous reason must name the first tied candidate"
  assert_contains "$OUT" "${B:0:12}" "the ambiguous reason must name the second tied candidate"
  assert_not_contains "$OUT" 'verdict: AGREE' "a reading that cannot discriminate must not agree"
  pass "two candidates with an identical probe blob resolve to neither"
}

test_one_commit_offered_twice_is_one_candidate_and_not_a_tie() {
  # source head and checkout head are the SAME commit here, which is the
  # ordinary case. Counting it twice would manufacture a tie out of one commit.
  reset_env
  run_tool --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$REPO" \
    --checkout "$REPO" --source-remote "$REPO" --source-ref refs/heads/main
  expect_code 0 "$RC" "one commit offered from two sides must still resolve"
  assert_not_contains "$OUT" 'AMBIGUOUS' "an identical source and checkout head is not a tie"
  [ "$(printf '%s\n' "$OUT" | grep -c 'MATCH')" -eq 1 ] \
    || fail "one commit must produce exactly one MATCH line"$'\n'"$OUT"
  pass "an identical source and checkout head is deduplicated to one candidate"
}

test_no_candidate_match_is_unread_rather_than_a_guess() {
  reset_env
  export FM_FAKE_CURL_BODY='gamma
'
  run_tool --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$REPO" --candidate "$C"
  expect_code 3 "$RC" "unmatched served bytes must be indeterminate"
  assert_contains "$OUT" 'served:    UNREAD' "unmatched served bytes must render unread"
  pass "served bytes matching no candidate are unread, not resolved"
}

test_a_non_2xx_served_response_is_unread() {
  reset_env
  export FM_FAKE_CURL_CODE=503
  run_tool --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$REPO" --candidate "$C"
  expect_code 3 "$RC" "a non-2xx served response must be indeterminate"
  assert_contains "$OUT" 'HTTP 503' "the reason must name the status the URL answered with"
  pass "a non-2xx response is an unread reading rather than served bytes"
}

# A commit that does not hold the probe path, and a response body of no bytes,
# hash to the SAME well-defined digest. Inferring either from an empty hash
# makes every commit missing the file match an empty response.

test_a_candidate_without_the_probe_path_is_reported_absent_not_compared() {
  reset_env
  run_tool --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$REPO" \
    --candidate "$D"
  expect_code 3 "$RC" "a candidate that does not hold the probe path leaves the reading unresolved"
  assert_contains "$OUT" 'probe.txt is absent at that commit' \
    "a commit without the probe path must be reported absent, by its own reason"
  assert_contains "$OUT" 'probe.txt exists at no candidate commit, so the bytes' \
    "not one blob was opened, so the reading must say it compared against nothing"
  assert_not_contains "$OUT" 'MATCH' "a commit without the probe path must never match"
  assert_not_contains "$OUT" 'matches the bytes' \
    "nothing compared must not be reported as the repository disagreeing with the host"
  assert_not_contains "$OUT" 'differs' \
    "an absent path is not a differing blob: it was never compared"
  assert_not_contains "$OUT" 'verdict: AGREE' "a reading resolved from nothing must not agree"
  pass "a candidate lacking the probe path is reported absent and never compared"
}

# The control for the reason above: one candidate holds the path and differs, so
# a blob WAS opened, and that run must still read as a measured mismatch.
test_a_candidate_that_holds_the_path_and_differs_is_a_measured_mismatch() {
  reset_env
  export FM_FAKE_CURL_BODY='gamma
'
  run_tool --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$REPO" \
    --candidate "$C" --candidate "$D"
  expect_code 3 "$RC" "a measured mismatch is still an unresolved reading"
  assert_contains "$OUT" "matches the bytes" \
    "a blob that was opened and differed must be reported as a measured mismatch"
  assert_not_contains "$OUT" 'exists at no candidate commit' \
    "a run that opened a blob must not claim it compared against nothing"
  pass "a candidate that holds the path and differs is a measured mismatch, not nothing compared"
}

test_an_empty_served_body_is_unread_rather_than_bytes_that_match() {
  reset_env
  export FM_FAKE_CURL_BODY=''
  run_tool --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$REPO" \
    --candidate "$C" --candidate "$D"
  expect_code 3 "$RC" "a zero-byte 200 body must be indeterminate"
  assert_contains "$OUT" 'served:    UNREAD' "an empty body is an unread reading"
  assert_contains "$OUT" 'zero-byte body' "the reason must name the empty body"
  assert_not_contains "$OUT" 'MATCH' "no commit may match a response that carried no bytes"
  assert_not_contains "$OUT" 'verdict: AGREE' "an empty body must never reach agreement"
  pass "a zero-byte 200 response is unread, and matches no commit"
}

test_a_served_reading_with_no_candidate_says_nothing_was_compared() {
  reset_env
  run_tool --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$REPO"
  expect_code 3 "$RC" "a served reading with nothing to compare against is indeterminate"
  assert_contains "$OUT" 'no candidate commit was available' \
    "an empty candidate set must say nothing was compared"
  assert_not_contains "$OUT" 'matches the bytes' \
    "nothing compared must not read as a measured mismatch against the repository"
  assert_not_contains "$OUT" 'verdict: AGREE' "a run that compared no candidate must not agree"
  pass "a served reading with no candidate names that nothing was available to compare"
}

# --- what the served reading did NOT consider -------------------------------

test_the_container_revision_is_named_as_excluded_when_the_reading_resolves() {
  reset_env
  export FM_FAKE_DOCKER_INSPECT="$RUNNING_AT_A"
  run_tool --container svc --serves 'http://stub/probe.txt' --serves-path probe.txt \
    --clone "$REPO" --candidate "$C"
  assert_contains "$OUT" 'the container revision was NOT a candidate for these bytes' \
    "an operator must be told which reading was kept out of the candidate pool"
  assert_contains "$OUT" '--candidate' "the message must name how to have it compared"
  pass "a resolved served reading still says the container revision was not a candidate"
}

test_the_container_revision_is_named_as_excluded_when_the_reading_fails() {
  # The same statement is owed when the reading resolves to nothing: otherwise
  # the operator has to infer the exclusion from an empty result.
  reset_env
  export FM_FAKE_CURL_BODY='gamma
'
  export FM_FAKE_DOCKER_INSPECT="$RUNNING_AT_A"
  run_tool --container svc --serves 'http://stub/probe.txt' --serves-path probe.txt \
    --clone "$REPO" --candidate "$C"
  assert_contains "$OUT" 'served:    UNREAD' "this run must leave the served reading unresolved"
  assert_contains "$OUT" 'the container revision was NOT a candidate for these bytes' \
    "the exclusion must be stated whether or not the reading resolved"
  pass "an unresolved served reading also says the container revision was not a candidate"
}

test_the_container_revision_is_named_as_included_when_it_was_passed() {
  # The run the message above tells the operator to make. Repeating the
  # exclusion line here would state something untrue of this run, and would hide
  # the one thing worth knowing: the served bytes were confirmed by a commit the
  # container reading itself nominated.
  reset_env
  run_tool --container svc --serves 'http://stub/probe.txt' --serves-path probe.txt \
    --clone "$REPO" --candidate "$C"
  assert_contains "$OUT" 'the container revision was compared only because --candidate supplied it' \
    "a run that compared the container's own revision must say so"
  assert_contains "$OUT" 'did not establish it independently' \
    "the operator must learn that this reading did not stand on its own"
  assert_not_contains "$OUT" 'was NOT a candidate' \
    "the tool must not claim an exclusion that this run did not make"
  pass "a container revision that was passed as a candidate is reported as compared, not excluded"
}

test_a_commit_the_record_named_is_not_described_as_the_container_nominating_it() {
  # The ordinary successful deploy: source, checkout and container are one
  # commit, and NO --candidate is passed. The candidate came from the record, so
  # the served bytes did resolve it independently, and the tool must not hedge
  # its own clean verdict by describing that as the container's own nomination.
  reset_env
  run_tool --container svc --checkout "$REPO" --source-remote "$REPO" --source-ref refs/heads/main \
    --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$REPO"
  expect_code 0 "$RC" "the ordinary all-agree run must still agree"
  assert_contains "$OUT" "not on the container's own account" \
    "a commit the record named must be reported as an independent nomination"
  assert_contains "$OUT" 'these bytes resolved to it independently' \
    "this run did resolve to that commit, so the independence is established and may be said"
  assert_not_contains "$OUT" '--candidate supplied it' \
    "nothing was supplied with --candidate on this run"
  assert_not_contains "$OUT" 'did not establish it independently' \
    "these bytes did establish the commit independently of the container reading"
  pass "a candidate contributed by the record is not described as one the container made"
}

test_no_candidacy_is_claimed_when_the_served_reading_never_got_that_far() {
  # The served reading failed before any candidate pool was built, and the
  # operator had already passed --candidate. Telling them to pass --candidate is
  # advice they have followed, about a comparison that never happened.
  reset_env
  export FM_FAKE_CURL_CODE=503
  run_tool --container svc --serves 'http://stub/probe.txt' --serves-path probe.txt \
    --clone "$REPO" --candidate "$C"
  expect_code 3 "$RC" "a non-2xx served reading is indeterminate"
  assert_contains "$OUT" 'no candidate pool was built' \
    "a run that never built a pool must say candidacy was not established"
  assert_not_contains "$OUT" 'pass it with --candidate' \
    "the tool must not advise an argument this run was already given"
  assert_not_contains "$OUT" 'was compared' \
    "nothing was compared on a run that never opened a blob"
  pass "a served reading that failed early claims nothing about candidacy"
}

test_an_unread_container_revision_is_not_reported_as_an_excluded_candidate() {
  reset_env
  export FM_FAKE_DOCKER_INSPECT="$STOPPED_AT_C"
  run_tool --container svc --serves 'http://stub/probe.txt' --serves-path probe.txt \
    --clone "$REPO" --candidate "$C"
  assert_contains "$OUT" 'the container revision could not be read' \
    "with no revision read there is no commit of the container's to exclude"
  assert_not_contains "$OUT" 'pass it with --candidate' \
    "there is no revision to pass, so the tool must not advise passing one"
  pass "an unread container revision is reported as unread, not as an excluded candidate"
}

test_a_container_revision_absent_from_the_clone_is_not_advised_to_be_passed() {
  # --candidate does not help here: the same tool answers that the candidate is
  # absent from the local clone. Advising it would send the operator round a
  # loop that ends where it started.
  reset_env
  local f="$T/inspect-foreign.txt"
  inspect_fixture "$f" true 0 0123456789abcdef0123456789abcdef01234567
  export FM_FAKE_DOCKER_INSPECT="$f"
  run_tool --container svc --serves 'http://stub/probe.txt' --serves-path probe.txt \
    --clone "$REPO" --candidate "$C"
  assert_contains "$OUT" 'is not in --clone' \
    "a revision the clone does not hold must be reported as that, not as an exclusion"
  assert_contains "$OUT" 'point --clone at a repository that holds it' \
    "the notice must name the thing that would actually help"
  assert_not_contains "$OUT" 'pass it with --candidate' \
    "passing --candidate cannot compare a commit this clone does not have"
  pass "a container revision absent from --clone is reported as absent, not as an excluded candidate"
}

test_a_container_revision_whose_blob_is_unreadable_is_not_reported_as_compared() {
  reset_env
  local f="$T/inspect-blobless-p.txt"
  inspect_fixture "$f" true 0 "$BLOBLESS_P"
  export FM_FAKE_DOCKER_INSPECT="$f"
  run_tool --container svc --serves 'http://stub/probe.txt' --serves-path probe.txt \
    --clone "$BLOBLESS" --candidate "$BLOBLESS_P"
  assert_contains "$OUT" 'was a candidate for these bytes and was NOT compared' \
    "a candidate whose blob could not be read was not compared, and must not be said to be"
  assert_contains "$OUT" 'its blob could not be read' "the notice must carry why it was not compared"
  assert_not_contains "$OUT" '--candidate supplied it' \
    "the tool must not claim a comparison it could not make"
  pass "a container revision whose blob is unreadable is reported as not compared"
}

test_no_independence_is_claimed_when_the_served_reading_resolved_nothing() {
  reset_env
  export FM_FAKE_CURL_BODY='gamma
'
  run_tool --container svc --source-remote "$REPO" --source-ref refs/heads/main \
    --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$REPO"
  expect_code 3 "$RC" "served bytes matching no candidate leave the reading unresolved"
  assert_contains "$OUT" "not on the container's own account" \
    "the commit was still compared as a candidate the record named"
  assert_not_contains "$OUT" 'resolved to it independently' \
    "these bytes resolved nothing, so no independence may be claimed from them"
  assert_not_contains "$OUT" 'that commit was a candidate' \
    "the notice must not point at a commit the reader cannot identify"
  pass "a served reading that resolved nothing claims no independence"
}

test_no_exclusion_is_claimed_when_no_container_was_requested() {
  reset_env
  run_tool --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$REPO" \
    --candidate "$C"
  assert_not_contains "$OUT" 'the container revision was NOT a candidate' \
    "a run that asked for no container reading has no exclusion to report"
  pass "the exclusion is stated only where a container reading was actually taken"
}

# --- the served reading on a machine that ships shasum and no sha256sum -----

test_the_served_reading_survives_a_machine_without_sha256sum() {
  reset_env
  command -v shasum >/dev/null 2>&1 \
    || { echo "skip: shasum not found (needed to prove the sha256sum fallback)"; return 0; }
  local nosha="$T/path-no-sha256sum"
  [ -d "$nosha" ] || path_without "$nosha" sha256sum
  RC=0
  OUT=$(PATH="$nosha" "$TOOL" --host stub-host --checkout "$REPO" \
    --source-remote "$REPO" --source-ref refs/heads/main \
    --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$REPO" 2>&1) || RC=$?
  record_verdicts "$OUT"
  expect_code 0 "$RC" "a macOS-shaped machine must still take the served reading"
  assert_not_contains "$OUT" 'served:    UNREAD' \
    "a missing sha256sum must not make the served reading unreadable"
  assert_contains "$OUT" 'MATCH' "the candidate blob must still be hashed and compared"
  assert_contains "$OUT" 'verdict: AGREE' "the reading must resolve as it does with sha256sum"
  pass "the served reading falls back to shasum where sha256sum is absent"
}

test_a_host_with_no_hasher_says_so_rather_than_hashing_nothing() {
  reset_env
  local nohash="$T/path-no-hashers"
  [ -d "$nohash" ] || path_without "$nohash" sha256sum shasum
  RC=0
  OUT=$(PATH="$nohash" "$TOOL" --host stub-host --checkout "$REPO" \
    --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$REPO" \
    --candidate "$C" 2>&1) || RC=$?
  record_verdicts "$OUT"
  expect_code 3 "$RC" "a host that cannot hash must be indeterminate"
  assert_contains "$OUT" 'served:    UNREAD' "an unhashable reading must render unread"
  assert_contains "$OUT" 'available on the host' \
    "the reason must name the side that could not hash: the host fetching the bytes"
  assert_not_contains "$OUT" 'MATCH' "nothing may match when nothing could be hashed"
  assert_not_contains "$OUT" 'verdict: AGREE' "a reading that could not be taken must not agree"
  pass "a host with neither hasher names that, rather than hashing nothing"
}

test_a_verifier_with_no_hasher_says_so_rather_than_hashing_nothing() {
  # The asymmetric case, and the only one that reaches the LOCAL guard: the host
  # can hash the bytes it serves, and the machine running the verifier cannot
  # hash the candidate blobs it would compare them against.
  reset_env
  local nohash="$T/path-no-hashers"
  [ -d "$nohash" ] || path_without "$nohash" sha256sum shasum
  export FM_FAKE_SSH_PATH="$PATH"
  RC=0
  OUT=$(PATH="$nohash" "$TOOL" --host stub-host --checkout "$REPO" \
    --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$REPO" \
    --candidate "$C" 2>&1) || RC=$?
  record_verdicts "$OUT"
  expect_code 3 "$RC" "a verifier that cannot hash must be indeterminate"
  assert_contains "$OUT" 'no candidate blob could be hashed' \
    "the local guard must name that the candidate side could not be hashed"
  assert_not_contains "$OUT" 'available on the host' \
    "the host hashed its own bytes here, so the remote guard must not be the one that fired"
  assert_not_contains "$OUT" 'MATCH' "nothing may match when no candidate blob could be hashed"
  assert_not_contains "$OUT" 'verdict: AGREE' "a reading that could not be taken must not agree"
  pass "a verifier that cannot hash names the candidate side, not the host"
}

# --- D4: nothing checked is its own outcome ---------------------------------

test_a_run_that_compared_nothing_is_never_clean() {
  # Every requested reading SUCCEEDS here. The run still establishes nothing,
  # because no pair had both sides read. That must not read as agreement, and it
  # must not read as a failed reading either.
  reset_env
  run_tool --container svc
  expect_code 4 "$RC" "a run with no two-sided comparison must exit 4"
  assert_contains "$OUT" 'verdict: NOTHING CHECKED' "the nothing-compared outcome needs its own verdict"
  assert_not_contains "$OUT" 'verdict: AGREE' "nothing compared is not agreement"
  assert_not_contains "$OUT" 'verdict: INDETERMINATE' \
    "no reading failed, so this must not be reported as a reading that failed"
  pass "a run that compared nothing gets its own verdict and its own non-zero exit"
}

test_a_reading_not_requested_is_not_a_reading_that_failed() {
  # The other half of the same split: a complete image-baked run with no host
  # checkout must SUCCEED, because it asked for no checkout reading.
  reset_env
  run_tool --container svc --source-remote "$REPO" --source-ref refs/heads/main
  expect_code 0 "$RC" "an image-baked run with no checkout must be able to agree"
  assert_contains "$OUT" 'verdict: AGREE' "a complete run must reach AGREE"
  assert_contains "$OUT" 'NOT COMPARED - no --checkout given' \
    "the skipped pair must say it was never ordered"
  pass "a reading that was never requested does not force indeterminate"
}

test_drift_is_reported_when_both_sides_were_read_and_differ() {
  reset_env
  run_tool --container svc --source-remote "$REPO" --source-ref refs/heads/old
  expect_code 2 "$RC" "two read sides that differ must be DRIFT"
  assert_contains "$OUT" 'verdict: DRIFT' "a real disagreement must be reported as drift"
  assert_contains "$OUT" 'DIFFER' "the disagreeing pair must be named"
  pass "a disagreement between two read sides is reported as drift"
}

test_drift_alongside_an_unread_reading_says_both() {
  # Drift is still drift when another requested reading could not be taken, and
  # the verdict has to carry both: what disagrees may not be all of it.
  reset_env
  export FM_FAKE_DOCKER_INSPECT="$STOPPED_AT_C"
  run_tool --container svc --checkout "$REPO" --source-remote "$REPO" --source-ref refs/heads/old
  expect_code 2 "$RC" "a disagreement stays drift even when a reading was unreadable"
  assert_contains "$OUT" 'verdict: DRIFT' "the disagreement must still be reported as drift"
  assert_contains "$OUT" 'a requested reading could not be taken, so what disagrees may not be all of it' \
    "the verdict must name the unread reading alongside the drift"
  pass "drift alongside an unread reading reports both, and exits 2"
}

# --- D6: remote arguments survive the remote re-parse -----------------------

test_remote_arguments_survive_the_remote_reparse() {
  reset_env
  local spaced="$T/has space/co"
  mkdir -p "$spaced"
  git -C "$spaced" init -q -b main
  printf 'x\n' >"$spaced/f"
  git -C "$spaced" add -A && git -C "$spaced" commit -qm x
  export FM_FAKE_CURL_BODY='beta
'
  run_tool --checkout "$spaced" --serves 'http://stub/health?a=1&b=2' \
    --serves-path probe.txt --clone "$REPO" --candidate "$C"
  assert_contains "$OUT" "$spaced" "a checkout path containing a space must reach the remote verb intact"
  assert_not_contains "$OUT" 'checkout:  UNREAD' "the spaced checkout must read normally"
  assert_grep 'http://stub/health?a=1&b=2' "$FM_FAKE_CURL_LOG" \
    "the whole URL, & included, must reach curl on the far side"
  pass "arguments carrying a space and an & survive the remote shell's re-parse"
}

# --- D7: --sudo governs the git reading as well as the docker reading -------

test_sudo_no_keeps_the_checkout_reading_off_sudo() {
  reset_env
  run_tool --sudo no --checkout "$REPO"
  assert_contains "$OUT" 'read-as=none' "--sudo no must report an unelevated checkout reading"
  [ ! -s "$FM_FAKE_SUDO_LOG" ] || fail "--sudo no must not invoke sudo at all"$'\n'"$(cat "$FM_FAKE_SUDO_LOG")"
  pass "--sudo no keeps the git reading off sudo, and is seen to"
}

test_sudo_yes_forces_the_checkout_reading_through_sudo() {
  reset_env
  run_tool --sudo yes --checkout "$REPO"
  assert_contains "$OUT" 'read-as=sudo' "--sudo yes must report an elevated checkout reading"
  assert_grep 'rev-parse HEAD' "$FM_FAKE_SUDO_LOG" "the git reading itself must go through sudo"
  pass "--sudo yes forces the git reading through sudo, and is seen to"
}

test_sudo_auto_falls_back_only_when_the_plain_reading_fails() {
  reset_env
  # A git that refuses unless it is running under sudo: the locked-down host
  # this flag exists for.
  cat >"$BIN/git" <<'EOF'
#!/usr/bin/env bash
if [ -z "${FM_FAKE_UNDER_SUDO:-}" ]; then
  echo "fatal: detected dubious ownership" >&2
  exit 128
fi
exec /usr/bin/git "$@"
EOF
  chmod +x "$BIN/git"
  run_tool --sudo auto --checkout "$REPO"
  rm -f "$BIN/git"
  assert_contains "$OUT" 'read-as=sudo' "--sudo auto must fall back to sudo when the plain reading fails"
  assert_not_contains "$OUT" 'checkout:  UNREAD' "the fallback must produce a real reading"
  pass "--sudo auto probes unelevated first and falls back, reporting which it used"
}

# --- D8: an empty reply is an unread reading, and warns about nothing -------

test_an_empty_checkout_reply_is_unread_and_raises_no_dirty_warning() {
  reset_env
  export FM_FAKE_SSH_EMPTY_VERB=checkout
  run_tool --checkout "$REPO" --source-remote "$REPO" --source-ref refs/heads/main
  expect_code 3 "$RC" "an empty checkout reply must be indeterminate"
  assert_contains "$OUT" "checkout:  UNREAD - the checkout reading came back empty for $REPO" \
    "an empty reply is an unread reading, and it must say why"
  assert_not_contains "$OUT" 'uncommitted path(s)' \
    "a checkout that was never read must not produce a dirty warning"
  pass "an empty checkout reply renders unread and warns about nothing"
}

# --- D9: a source remote that would prompt is unread, not a hang ------------

test_a_source_remote_that_would_prompt_is_unread_within_a_bound() {
  reset_env
  # A remote read that blocks on a credential prompt is the one failure mode a
  # verifier must never have: an unattended run then returns no verdict at all.
  cat >"$BIN/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = ls-remote ]; then
  if [ "${GIT_TERMINAL_PROMPT:-}" != 0 ]; then
    sleep 120
  fi
  echo "fatal: could not read Username for 'https://example.invalid': terminal prompts disabled" >&2
  exit 128
fi
exec /usr/bin/git "$@"
EOF
  chmod +x "$BIN/git"
  local started ended
  started=$(date +%s)
  run_tool --source-remote 'https://example.invalid/private.git' --source-ref main --checkout "$REPO"
  ended=$(date +%s)
  rm -f "$BIN/git"
  [ $((ended - started)) -lt 30 ] || fail "the source reading must return within a bound, took $((ended - started))s"
  expect_code 3 "$RC" "an unreadable source must be indeterminate"
  assert_contains "$OUT" 'source:    UNREAD' "an unreadable source must render unread"
  pass "a source remote that would prompt returns unread within a bound"
}

# --- the source ref resolves to a commit, or to nothing ---------------------

test_an_annotated_tag_resolves_to_the_commit_it_points_at() {
  # ls-remote answers a bare annotated tag with the TAG OBJECT. Taking that sha
  # would compare a tag against commits and report a confident DRIFT produced by
  # this tool's own resolution rather than by anything on the host.
  reset_env
  export FM_FAKE_DOCKER_INSPECT="$RUNNING_AT_A"
  run_tool --container svc --source-remote "$REPO" --source-ref v1
  expect_code 0 "$RC" "a tag pointing at the running commit must agree"
  assert_contains "$OUT" "source:    ${A:0:12}" "the tag must resolve to the commit it points at"
  assert_contains "$OUT" 'verdict: AGREE' "a tag and a container at the same commit agree"
  pass "an annotated --source-ref resolves to its commit, not to the tag object"
}

test_a_source_ref_matching_two_refs_resolves_to_neither() {
  # A branch and a tag of the same name at different commits. Taking whichever
  # the remote listed first is the same fault the served-bytes tie refuses.
  reset_env
  run_tool --container svc --source-remote "$REPO" --source-ref collide
  expect_code 3 "$RC" "an ambiguous source ref must be indeterminate"
  assert_contains "$OUT" 'source:    UNREAD' "an ambiguous ref must render unread"
  assert_contains "$OUT" 'AMBIGUOUS' "the tie must be named as ambiguous"
  assert_contains "$OUT" 'refs/heads/collide' "the reason must name the first matched ref"
  assert_contains "$OUT" 'refs/tags/collide' "the reason must name the second matched ref"
  assert_not_contains "$OUT" 'verdict: DRIFT' \
    "a resolution this tool could not make must never be reported as the host disagreeing"
  pass "a source ref carried by two refs at two commits resolves to neither"
}

# --- a transport that failed says why ---------------------------------------

test_a_transport_failure_reaches_the_output_as_its_own_reason() {
  reset_env
  export FM_FAKE_SSH_FAIL='ssh: connect to host stub-host port 22: Connection refused'
  run_tool --container svc --checkout "$REPO"
  expect_code 3 "$RC" "a host that could not be reached must be indeterminate"
  assert_contains "$OUT" 'Connection refused' \
    "the transport's own words are the reason, and must not be discarded"
  assert_not_contains "$OUT" 'came back empty' \
    "a reply carrying a diagnostic was not empty, and must not be described as empty"
  pass "a transport failure is reported with the reason the transport gave"
}

# --- a reading the tool's own bound killed ----------------------------------

test_a_reading_cut_off_by_the_timeout_names_the_bound_that_killed_it() {
  command -v timeout >/dev/null 2>&1 \
    || { echo "skip: timeout not found (needed to bound a wedged reading)"; return 0; }
  reset_env
  export FM_FAKE_SSH_SLEEP=30
  RC=0
  OUT=$("$TOOL" --host stub-host --timeout 1 --checkout "$REPO" 2>&1) || RC=$?
  record_verdicts "$OUT"
  expect_code 3 "$RC" "a host that never answered must be indeterminate"
  assert_contains "$OUT" 'did not return within the 1s this run allowed' \
    "the bound that ended the reading is a fact the tool holds and must say"
  assert_not_contains "$OUT" 'came back empty' \
    "the host did not answer with nothing: it was cut off before it could answer"
  pass "a reading killed by --timeout names the bound rather than reporting an empty reply"
}

# --- a blob the clone cannot read is not an absent path ---------------------

test_a_blob_the_clone_cannot_read_is_not_reported_as_absent() {
  reset_env
  run_tool --serves 'http://stub/probe.txt' --serves-path probe.txt \
    --clone "$BLOBLESS" --candidate "$BLOBLESS_P"
  expect_code 3 "$RC" "a blob that could not be read leaves the reading unresolved"
  assert_contains "$OUT" 'its blob could not be read from' \
    "an unreadable blob must be reported as unreadable, in git's own terms"
  assert_not_contains "$OUT" 'is absent at that commit' \
    "the path IS at that commit; only its blob is missing from this clone"
  assert_not_contains "$OUT" 'exists at no candidate commit' \
    "the reason must not assert something the tree of that same clone contradicts"
  assert_not_contains "$OUT" 'MATCH' "nothing may match when no blob was read"
  assert_not_contains "$OUT" 'verdict: AGREE' "a reading taken from nothing must not agree"
  pass "a path whose blob this clone cannot read is not reported as absent at that commit"
}

test_a_match_beside_an_unreadable_candidate_does_not_resolve() {
  # Q matches the served bytes and P's blob could not be opened. Had P been
  # byte-identical to Q, this same run would have been refused as a tie, so a
  # definite answer here would rest on something the reading could not check.
  reset_env
  run_tool --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$BLOBLESS" \
    --candidate "$BLOBLESS_P" --candidate "$BLOBLESS_Q"
  expect_code 3 "$RC" "a reading that could not rule every candidate out must be indeterminate"
  assert_contains "$OUT" 'MATCH' "the match itself is still reported"
  assert_contains "$OUT" 'AMBIGUOUS' "a candidate left unread makes the reading unable to discriminate"
  assert_contains "$OUT" "${BLOBLESS_P:0:12}" "the reason must name the candidate left unruled-out"
  assert_not_contains "$OUT" 'MEASURED, resolved against blobs' \
    "a reading that could not rule out every candidate must not report a definite commit"
  assert_not_contains "$OUT" 'verdict: AGREE' "an unresolved served reading must not agree"
  pass "a match beside an unreadable candidate resolves to nothing rather than to the match"
}

test_a_mismatch_beside_an_unreadable_candidate_is_not_a_measured_no_match() {
  reset_env
  export FM_FAKE_CURL_BODY='gamma
'
  run_tool --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$BLOBLESS" \
    --candidate "$BLOBLESS_P" --candidate "$BLOBLESS_Q"
  expect_code 3 "$RC" "an unruled-out candidate leaves the reading unresolved"
  assert_contains "$OUT" 'so those commits are not ruled out' \
    "a no-match claim must not silently cover candidates whose blobs were never opened"
  assert_contains "$OUT" "${BLOBLESS_P:0:12}" "the unopened candidate must be named"
  pass "a mismatch beside an unreadable candidate is not reported as a measured no-match"
}

test_two_readable_candidates_still_resolve_to_the_one_that_matches() {
  # The control for both cases above: same shape, nothing unreadable.
  reset_env
  run_tool --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$REPO" \
    --candidate "$A" --candidate "$C"
  assert_contains "$OUT" 'MEASURED, resolved against blobs' \
    "with every candidate readable the reading still resolves"
  assert_not_contains "$OUT" 'AMBIGUOUS' "two readable candidates that differ are not a tie"
  pass "control: readable candidates still resolve to the one that matches"
}

test_a_readable_blob_at_the_same_shape_of_clone_still_compares() {
  # The control: same fixture repository, same probe path, blob present.
  reset_env
  run_tool --serves 'http://stub/probe.txt' --serves-path probe.txt \
    --clone "$REPO" --candidate "$C"
  assert_contains "$OUT" 'MATCH' "a readable blob must still be hashed and compared"
  assert_not_contains "$OUT" 'could not be read from' \
    "a clone that holds the blob must not report it unreadable"
  pass "control: a readable blob at the same probe path still compares"
}

# --- the probe file the payload puts on the host ----------------------------

test_the_host_probe_file_is_removed_even_when_the_payload_is_cut_short() {
  # The payload is killed after the probe file exists and before its own rm.
  # What the tool leaves on a host is the one side effect it promises never to
  # have, so it must survive the run being interrupted.
  command -v ps >/dev/null 2>&1 \
    || { echo "skip: ps not found (needed to interrupt the payload mid-fetch)"; return 0; }
  reset_env
  local probedir="$T/probe-tmpdir"
  rm -rf "$probedir"; mkdir -p "$probedir"
  export FM_FAKE_CURL_KILL_PAYLOAD=1
  TMPDIR="$probedir" run_tool --serves 'http://stub/probe.txt' --serves-path probe.txt \
    --clone "$REPO" --candidate "$C"
  unset FM_FAKE_CURL_KILL_PAYLOAD
  local left
  left=$(find "$probedir" -type f | head -5)
  [ -z "$left" ] || fail "the payload left a file on the host: $left"$'\n'"$OUT"
  pass "an interrupted payload leaves no probe file behind on the host"
}

# --- host identity ----------------------------------------------------------

test_expect_machine_refuses_before_any_other_reading_is_taken() {
  reset_env
  run_tool --expect-machine no-such-machine --container svc --checkout "$REPO"
  expect_code 1 "$RC" "a machine mismatch must refuse"
  assert_contains "$OUT" 'REFUSED' "the refusal must say so"
  [ ! -s "$FM_FAKE_DOCKER_LOG" ] \
    || fail "the refusal must come before any other reading"$'\n'"$(cat "$FM_FAKE_DOCKER_LOG")"
  pass "--expect-machine refuses before any other reading is taken"
}

test_expect_machine_refuses_when_the_identity_cannot_be_read() {
  reset_env
  export FM_FAKE_SSH_EMPTY_VERB=identity
  run_tool --expect-machine anything --container svc
  expect_code 1 "$RC" "an unreadable identity under --expect-machine must refuse"
  assert_contains "$OUT" 'REFUSED' "the refusal must say so"
  pass "--expect-machine refuses when the machine identity cannot be read"
}

test_an_unreadable_identity_makes_the_run_indeterminate() {
  reset_env
  export FM_FAKE_SSH_EMPTY_VERB=identity
  run_tool --container svc --source-remote "$REPO" --source-ref refs/heads/main
  expect_code 3 "$RC" "readings from an unidentified machine must not be clean"
  assert_contains "$OUT" 'host:      stub-host   UNREADABLE' "the identity must render unreadable"
  pass "readings from a machine that could not be identified are never clean"
}

# --- the running-side readings ----------------------------------------------

test_a_container_without_a_revision_label_is_unread() {
  reset_env
  export FM_FAKE_DOCKER_INSPECT="$NO_LABEL"
  run_tool --container svc --source-remote "$REPO" --source-ref refs/heads/main
  expect_code 3 "$RC" "a missing revision label must be indeterminate"
  assert_contains "$OUT" 'container: UNREAD' "an unlabelled container must render unread"
  pass "a container with no revision label is unread rather than assumed current"
}

test_a_missing_container_is_unread_with_the_reason() {
  reset_env
  export FM_FAKE_DOCKER_INSPECT_RC=1
  run_tool --container svc --source-remote "$REPO" --source-ref refs/heads/main
  expect_code 3 "$RC" "an absent container must be indeterminate"
  assert_contains "$OUT" 'docker inspect failed' "the reason must name what failed"
  pass "an absent container is unread, with the failure named"
}

test_restarts_on_a_running_container_are_stated_out_loud() {
  reset_env
  local f="$T/inspect-flapping.txt"
  inspect_fixture "$f" true 9 "$C"
  export FM_FAKE_DOCKER_INSPECT="$f"
  run_tool --container svc --source-remote "$REPO" --source-ref refs/heads/main
  expect_code 0 "$RC" "a running container that agrees still agrees"
  assert_contains "$OUT" 'WARNING: 9 restart(s)' "a restart count must be surfaced, not buried"
  pass "restarts on a running container are stated out loud without changing the verdict"
}

# --- D10: the target is read from the artefact ------------------------------

test_the_running_container_reports_what_it_actually_reads_from() {
  # 2b's third reading: not the machine, not the deploy directory, but the path
  # the service actually reads from. Taken here, so the skill's claim that the
  # tool covers it is true as written.
  reset_env
  run_tool --container svc
  assert_contains "$OUT" 'mounts (what this container actually reads from)' \
    "the mount reading must be taken and labelled"
  assert_contains "$OUT" '/opt/fixture/app -> /srv/app (ro)' "each mount must be reported"
  assert_contains "$OUT" 'compose working_dir=/opt/fixture' \
    "the directory the deploy path operates on must be read off the running container"
  assert_contains "$OUT" 'compose config_files=/opt/fixture/docker-compose.yml' \
    "the compose files the running container was created from must be reported"
  pass "the container reading names the directory it works in and the paths it reads from"
}

# --- read-only ---------------------------------------------------------------

test_the_tool_only_ever_reads() {
  # Asserted by effect: every docker invocation this tool makes across a full
  # run is logged, and every one of them must be a read.
  reset_env
  run_tool --container svc --checkout "$REPO" --source-remote "$REPO" --source-ref refs/heads/main \
    --serves 'http://stub/probe.txt' --serves-path probe.txt --clone "$REPO"
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      version*|inspect*) : ;;
      *) fail "the tool ran a docker command that is not a read: $line" ;;
    esac
  done <"$FM_FAKE_DOCKER_LOG"
  [ -s "$FM_FAKE_DOCKER_LOG" ] || fail "the read-only check proved nothing: no docker command was run"
  pass "every docker command the tool runs is a read"
}

test_a_local_run_needs_no_host() {
  reset_env
  RC=0
  OUT=$("$TOOL" --checkout "$REPO" --source-remote "$REPO" --source-ref refs/heads/main 2>&1) || RC=$?
  record_verdicts "$OUT"
  expect_code 0 "$RC" "a local run must work with no --host"
  assert_contains "$OUT" 'this machine' "a local run must name the machine it read"
  pass "the readings can be taken locally with no host"
}

# --- usage ------------------------------------------------------------------

test_serves_without_a_path_is_refused() {
  RC=0
  OUT=$("$TOOL" --serves http://stub/x 2>&1) || RC=$?
  expect_code 1 "$RC" "--serves without --serves-path must be refused"
  assert_contains "$OUT" '--serves-path' "the refusal must name what is missing"
  pass "a served-bytes reading with nothing to compare against is refused"
}

# --- the skill --------------------------------------------------------------
#
# The five cases below read SKILL.md and assert that particular sentences are in
# it. That is deliberate and it is not the source-substring anti-pattern: here
# the written procedure IS the deliverable, so checking its wording is checking
# the thing itself rather than using text as a proxy for behavior somewhere
# else. The verdict cross-check further down was a different kind of thing - it
# grepped the TOOL's source for strings the tool prints, which proves nothing
# about what it prints - and real output was available for the cost of keeping
# the lines the runs above already emitted, so it uses that instead.

test_the_skill_cites_no_private_report_paths() {
  # Other vessels adopt this skill and cannot read this home's task records, so
  # a data/<id>/report.md citation reads as a broken pointer while naming
  # private material.
  assert_no_grep 'data/' "$SKILL" \
    "the skill must cite no private data/ path: other vessels cannot read them"
  pass "the skill cites the evidence shape, never this home's private report paths"
}

test_the_skill_separates_fleet_general_from_host_specific() {
  assert_grep 'Fleet-general' "$SKILL" "the skill must mark what is fleet-general"
  assert_grep 'Specific to these hosts' "$SKILL" "the skill must mark what is host-specific"
  pass "the skill says which parts travel to another vessel and which do not"
}

test_the_skill_requires_the_target_to_be_proven_from_the_artefact() {
  assert_grep 'from the artefact' "$SKILL" \
    "the acceptance condition on this skill is that the target is proven from the artefact"
  assert_grep 'never inferred from the invocation or the directory it is run in' "$SKILL" \
    "the skill must state where the target may NOT be inferred from"
  pass "every mutating step must prove the target it resolves, from the artefact"
}

test_the_skill_carries_the_unreadable_state_rule() {
  assert_grep 'An unreadable state is not a stale state' "$SKILL" \
    "the non-idempotent deploy incident's own rule must be carried"
  pass "the skill carries the rule that an unreadable state is not a stale state"
}

test_the_skill_states_what_the_tool_does_not_cover() {
  assert_grep 'What the tool does not do' "$SKILL" \
    "the skill must scope the tool's coverage rather than implying it discharges a whole step"
  pass "the skill states the tool's limits rather than overstating its coverage"
}

# Guards the anti-pattern that put a paraphrased transcript under a label whose
# whole standard is that the output was really produced: any verdict line quoted
# in the skill must be one the runs above ACTUALLY EMITTED. The corpus is the
# verdict lines recorded from every run in this file, which between them cover
# all four exit statuses; the per-run counts are the only thing normalised away,
# because a transcript is quoted from one run and the corpus comes from another.
# It checks verdict lines only - the rest of a transcript stays an author's
# discipline - and a single reworded verdict fails here rather than shipping a
# quotation of output that no longer exists.
test_every_verdict_quoted_in_the_skill_is_one_the_tool_can_emit() {
  local line found=0 emitted="$T/emitted-verdicts-normalised.txt" want
  [ -s "$VERDICTS" ] || fail "no verdict line was captured, so this guard proved nothing"
  sed 's/[0-9][0-9]*/N/g' "$VERDICTS" | sort -u >"$emitted"
  for want in AGREE DRIFT INDETERMINATE 'NOTHING CHECKED'; do
    grep -Fq "verdict: $want" "$emitted" \
      || fail "the runs above emitted no $want verdict, so this guard covers less than it claims"
  done
  while IFS= read -r line; do
    found=1
    grep -Fqx -- "$(printf '%s' "$line" | sed 's/[0-9][0-9]*/N/g')" "$emitted" \
      || fail "the skill quotes a verdict line no run of this tool produced: $line"
  done < <(grep -ho 'verdict: [A-Z].*' "$SKILL" || true)
  [ "$found" = 1 ] || fail "the skill quotes no verdict line, so this guard proved nothing"
  pass "every verdict line quoted in the skill is one the tool was seen to emit"
}

test_the_skill_declares_its_load_trigger() {
  local desc
  desc=$(fm_skill_description "$ROOT/.agents/skills/deploying")
  [ -n "$desc" ] || fail "the deploying skill needs a description"
  printf '%s' "$desc" | grep -q 'Use ' \
    || fail "the description must state a load condition, not only a topic"
  [ "$(grep -c '^- `deploying`' "$AGENTS")" -eq 1 ] \
    || fail "AGENTS.md section 13 must carry exactly one deploying trigger line"
  pass "the deploying skill declares its load trigger in both places"
}

test_a_running_container_that_matches_agrees
test_a_stopped_container_is_never_an_agreement
test_a_served_reading_that_cannot_discriminate_resolves_to_nothing
test_one_commit_offered_twice_is_one_candidate_and_not_a_tie
test_no_candidate_match_is_unread_rather_than_a_guess
test_a_non_2xx_served_response_is_unread
test_a_candidate_without_the_probe_path_is_reported_absent_not_compared
test_a_candidate_that_holds_the_path_and_differs_is_a_measured_mismatch
test_an_empty_served_body_is_unread_rather_than_bytes_that_match
test_a_served_reading_with_no_candidate_says_nothing_was_compared
test_the_container_revision_is_named_as_excluded_when_the_reading_resolves
test_the_container_revision_is_named_as_excluded_when_the_reading_fails
test_the_container_revision_is_named_as_included_when_it_was_passed
test_no_exclusion_is_claimed_when_no_container_was_requested
test_a_container_revision_absent_from_the_clone_is_not_advised_to_be_passed
test_a_container_revision_whose_blob_is_unreadable_is_not_reported_as_compared
test_no_independence_is_claimed_when_the_served_reading_resolved_nothing
test_a_commit_the_record_named_is_not_described_as_the_container_nominating_it
test_no_candidacy_is_claimed_when_the_served_reading_never_got_that_far
test_an_unread_container_revision_is_not_reported_as_an_excluded_candidate
test_the_served_reading_survives_a_machine_without_sha256sum
test_a_host_with_no_hasher_says_so_rather_than_hashing_nothing
test_a_verifier_with_no_hasher_says_so_rather_than_hashing_nothing
test_a_run_that_compared_nothing_is_never_clean
test_a_reading_not_requested_is_not_a_reading_that_failed
test_drift_is_reported_when_both_sides_were_read_and_differ
test_drift_alongside_an_unread_reading_says_both
test_remote_arguments_survive_the_remote_reparse
test_sudo_no_keeps_the_checkout_reading_off_sudo
test_sudo_yes_forces_the_checkout_reading_through_sudo
test_sudo_auto_falls_back_only_when_the_plain_reading_fails
test_an_empty_checkout_reply_is_unread_and_raises_no_dirty_warning
test_a_source_remote_that_would_prompt_is_unread_within_a_bound
test_an_annotated_tag_resolves_to_the_commit_it_points_at
test_a_source_ref_matching_two_refs_resolves_to_neither
test_a_transport_failure_reaches_the_output_as_its_own_reason
test_a_reading_cut_off_by_the_timeout_names_the_bound_that_killed_it
test_a_blob_the_clone_cannot_read_is_not_reported_as_absent
test_a_readable_blob_at_the_same_shape_of_clone_still_compares
test_a_match_beside_an_unreadable_candidate_does_not_resolve
test_a_mismatch_beside_an_unreadable_candidate_is_not_a_measured_no_match
test_two_readable_candidates_still_resolve_to_the_one_that_matches
test_the_host_probe_file_is_removed_even_when_the_payload_is_cut_short
test_expect_machine_refuses_before_any_other_reading_is_taken
test_expect_machine_refuses_when_the_identity_cannot_be_read
test_an_unreadable_identity_makes_the_run_indeterminate
test_a_container_without_a_revision_label_is_unread
test_a_missing_container_is_unread_with_the_reason
test_restarts_on_a_running_container_are_stated_out_loud
test_the_running_container_reports_what_it_actually_reads_from
test_the_tool_only_ever_reads
test_a_local_run_needs_no_host
test_serves_without_a_path_is_refused
test_the_skill_cites_no_private_report_paths
test_the_skill_separates_fleet_general_from_host_specific
test_the_skill_requires_the_target_to_be_proven_from_the_artefact
test_the_skill_carries_the_unreadable_state_rule
test_the_skill_states_what_the_tool_does_not_cover
test_every_verdict_quoted_in_the_skill_is_one_the_tool_can_emit
test_the_skill_declares_its_load_trigger
