#!/usr/bin/env bash
# tests/fm-tg-send.test.sh - the outbound half of the direct Telegram seam.
#
# The load-bearing property is not that a message goes out. It is that a message
# which does NOT go out says so and exits non-zero, because a notification path
# trusted while dead is worse than no path at all. Every refusal below is
# asserted on the exit status as well as the wording for that reason.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-tg-send.sh"
fm_test_tmproot TMP_ROOT fm-tg-send-tests

# The seam hands the sender an absolute, symlink-resolved path, so the
# assertions about that path have to be made against a resolved root: TMPDIR is
# a symlink on some hosts, and comparing to the unresolved name would fail there
# on a correct implementation.
TMP_REAL=$(cd "$TMP_ROOT" && pwd -P) || fail "could not resolve the test temp root"

# Distinctive enough that finding it anywhere in the script's own output proves
# the seam read a credential it has no business reading.
FIXTURE_TOKEN="fixture-token-must-never-be-printed-$$"

# A home with a credential file and a recording sender, which is what a
# provisioned vessel looks like from this script's side.
new_home() {
  local home=$1
  mkdir -p "$home/config" "$home/state" || fail "could not create the fixture home $home"
  printf 'FMF_XO_BOT_TOKEN=%s\nFMF_XO_COMMODORE_ID=1234\n' "$FIXTURE_TOKEN" > "$home/config/telegram.env"
  chmod 0600 "$home/config/telegram.env"
}

install_sender() {
  local home=$1 exit_code=${2:-0}
  cat > "$home/config/fm-tg-send.sh" <<SH
#!/usr/bin/env bash
set -u
cat > "\$FM_HOME/state/sender-body"
printf '%s\n' "\$*" > "\$FM_HOME/state/sender-argv"
{
  printf 'FM_HOME=%s\n' "\${FM_HOME-}"
  printf 'FM_CONFIG_OVERRIDE=%s\n' "\${FM_CONFIG_OVERRIDE-}"
  printf 'FM_STATE_OVERRIDE=%s\n' "\${FM_STATE_OVERRIDE-}"
  printf 'FM_TG_SEND_KIND=%s\n' "\${FM_TG_SEND_KIND-}"
  printf 'FM_TG_SEND_PATH=%s\n' "\${FM_TG_SEND_PATH-}"
  printf 'FM_TG_SEND_ORIGINAL_NAME=%s\n' "\${FM_TG_SEND_ORIGINAL_NAME-}"
  printf 'FM_TG_SEND_MIME=%s\n' "\${FM_TG_SEND_MIME-}"
  printf 'FM_TG_SEND_BYTES=%s\n' "\${FM_TG_SEND_BYTES-}"
} > "\$FM_HOME/state/sender-env"
if [ "$exit_code" -ne 0 ]; then
  printf 'the message was refused by Telegram\n' >&2
  exit $exit_code
fi
printf 'R-abc123\n'
SH
  chmod +x "$home/config/fm-tg-send.sh"
}

# A sender's own declaration of what it can do. Installing the sender WITHOUT
# calling this is the text-only home every existing home already is, which is
# why the file refusals below are asserted against exactly that.
declare_capabilities() {
  local home=$1
  shift
  printf '%s\n' "$@" > "$home/config/fm-tg-send.capabilities"
}

run_send() {
  local home=$1
  shift
  FM_HOME="$home" "$SEND" "$@" 2>&1
}

# The sender records everything it was given, so "it never ran" is the only
# proof that nothing was transmitted; an exit status alone would not be.
assert_sender_never_ran() {
  local home=$1 msg=$2
  [ ! -e "$home/state/sender-body" ] || fail "$msg"
}

test_help_is_the_header() {
  local out status=0
  out=$("$SEND" --help 2>&1) || status=$?
  expect_code 0 "$status" "--help"
  assert_contains "$out" "fm-tg-send.sh --text <message>" "--help did not print the usage block"
  assert_contains "$out" "config/fm-tg-send.sh" "--help did not name the per-home sender"
  pass "--help prints the header block and exits 0"
}

# The regression this whole file exists for: an unconfigured home must not
# report success. bin/fm-tg-recv-arm.sh deliberately exits 0 on an unarmed home
# because an unarmed receiver is a feature that is off; an unsent notification
# is a message the captain did not get.
test_an_unconfigured_home_fails_rather_than_reporting_inactive() {
  local home="$TMP_ROOT/unconfigured" out status=0
  mkdir -p "$home/config" "$home/state"
  out=$(run_send "$home" --text 'the build is green') || status=$?
  [ "$status" -ne 0 ] || fail "an unconfigured home reported success for a message nobody received"
  assert_contains "$out" "no way to reach the captain" "the refusal did not say the home cannot reach the captain"
  assert_contains "$out" "was NOT sent" "the refusal did not say the message went nowhere"
  pass "an unconfigured home fails loudly instead of reporting itself inactive"
}

test_a_home_with_a_credential_and_no_sender_names_the_missing_half() {
  local home="$TMP_ROOT/no-sender" out status=0
  new_home "$home"
  out=$(run_send "$home" --text 'ready for review') || status=$?
  [ "$status" -ne 0 ] || fail "a home with no sender reported success"
  assert_contains "$out" "config/fm-tg-send.sh is missing or not executable" "the refusal did not name the missing sender"
  pass "a home with a credential and no sender names the half that is missing"
}

test_a_home_that_can_hear_but_not_speak_says_so_in_those_terms() {
  local home="$TMP_ROOT/deaf-mute" out status=0
  new_home "$home"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/config/fm-tg-recv.sh"
  chmod +x "$home/config/fm-tg-recv.sh"
  out=$(run_send "$home" --text 'ready for review') || status=$?
  [ "$status" -ne 0 ] || fail "a home that cannot speak reported success"
  assert_contains "$out" "can hear the captain and cannot answer him" "the refusal did not name the asymmetry a reader can act on"
  pass "a home with a receiver and no sender is told which half it is missing"
}

test_a_sender_without_a_credential_still_fails() {
  local home="$TMP_ROOT/no-credential" out status=0
  mkdir -p "$home/config" "$home/state"
  install_sender "$home"
  out=$(run_send "$home" --text 'ready for review') || status=$?
  [ "$status" -ne 0 ] || fail "a home with no credential reported success"
  assert_contains "$out" "config/telegram.env is absent" "the refusal did not name the absent credential"
  pass "a sender with no credential beside it is refused before it runs"
}

test_a_message_reaches_the_sender_on_stdin() {
  local home="$TMP_ROOT/delivers" out status=0
  new_home "$home"
  install_sender "$home"
  out=$(run_send "$home" --text 'the fix landed') || status=$?
  expect_code 0 "$status" "a configured home"
  assert_contains "$out" "R-abc123" "the sender's own reference did not reach the caller"
  assert_contains "$out" "telegram send: sent" "the seam did not report the send"
  assert_grep "the fix landed" "$home/state/sender-body" "the message did not reach the sender on stdin"
  pass "a configured home hands the message to its sender and relays the reference back"
}

# The message is not a secret, but keeping it off argv is the same discipline
# the credential needs, and argv on this fleet's hosts is readable across
# accounts while a process's own stdin is not.
test_the_message_never_reaches_the_senders_command_line() {
  local home="$TMP_ROOT/argv" status=0
  new_home "$home"
  install_sender "$home"
  run_send "$home" --text 'a body that must not be an argument' >/dev/null || status=$?
  expect_code 0 "$status" "a configured home"
  assert_no_grep "a body that must not be an argument" "$home/state/sender-argv" \
    "the message was passed to the sender on its command line"
  pass "the message reaches the sender on stdin and never on its command line"
}

test_the_sender_is_told_which_home_it_is_speaking_for() {
  local home="$TMP_ROOT/env" status=0
  new_home "$home"
  install_sender "$home"
  run_send "$home" --text 'hello' >/dev/null || status=$?
  expect_code 0 "$status" "a configured home"
  assert_grep "FM_HOME=$home" "$home/state/sender-env" "the sender was not told its home"
  assert_grep "FM_CONFIG_OVERRIDE=$home/config" "$home/state/sender-env" "the sender was not told its config directory"
  assert_grep "FM_STATE_OVERRIDE=$home/state" "$home/state/sender-env" "the sender was not told its state directory"
  pass "the sender is launched against the same home the seam resolved"
}

test_a_failing_sender_is_reported_and_never_reported_as_sent() {
  local home="$TMP_ROOT/sender-fails" out status=0
  new_home "$home"
  install_sender "$home" 3
  out=$(run_send "$home" --text 'the build broke') || status=$?
  [ "$status" -ne 0 ] || fail "a failed send reported success"
  assert_contains "$out" "the sender exited 3" "the failure did not name the sender's exit status"
  assert_contains "$out" "was NOT sent" "the failure did not say the message went nowhere"
  assert_contains "$out" "refused by Telegram" "the sender's own diagnostic was swallowed"
  assert_not_contains "$out" "telegram send: sent" "a failed send was also reported as sent"
  pass "a sender that fails is reported loudly and never as a delivery"
}

test_arguments_after_a_double_dash_reach_the_sender() {
  local home="$TMP_ROOT/passthrough" status=0
  new_home "$home"
  install_sender "$home"
  run_send "$home" --text 'go ahead?' -- --ask reversible >/dev/null || status=$?
  expect_code 0 "$status" "a configured home"
  assert_grep "--ask reversible" "$home/state/sender-argv" "the passthrough arguments did not reach the sender"
  pass "arguments after -- reach the per-home sender unread"
}

test_a_bare_pull_request_reference_is_refused_before_anything_is_sent() {
  local home="$TMP_ROOT/bare-pr" out status=0 form
  new_home "$home"
  install_sender "$home"
  for form in 'PR #91 is ready for your review' \
    'pr #91 is ready for your review' \
    'pull request 91 is green' \
    'merge request !12 needs a decision' \
    'MR12 is waiting'; do
    status=0
    out=$(run_send "$home" --text "$form") || status=$?
    [ "$status" -ne 0 ] || fail "a bare pull request reference was sent: $form"
    assert_contains "$out" "requires the full URL" "the refusal did not name the rule: $form"
    [ ! -e "$home/state/sender-body" ] \
      || fail "the sender ran for a message the seam had already refused: $form"
  done
  pass "a message naming a pull request with no URL is refused before the sender runs"
}

test_a_full_url_satisfies_the_rule() {
  local home="$TMP_ROOT/full-url" status=0
  new_home "$home"
  install_sender "$home"
  run_send "$home" --text 'ready for review: https://github.com/Freudator86/firstmate/pull/91 (PR #91)' >/dev/null || status=$?
  expect_code 0 "$status" "a message carrying the full URL"
  assert_grep "https://github.com/Freudator86/firstmate/pull/91" "$home/state/sender-body" \
    "the message did not reach the sender"
  pass "a pull request mentioned with its full URL goes out, shorthand and all"
}

# The guard fires on a SPECIFIC pull request, which is what the URL rule is
# about. Refusing every sentence containing the letters PR would make the safe
# path the one people work around.
test_prose_about_pull_requests_in_general_is_not_refused() {
  local home="$TMP_ROOT/no-false-positive" status=0
  new_home "$home"
  install_sender "$home"
  run_send "$home" --text 'both PRs are green and the review queue is empty' >/dev/null || status=$?
  expect_code 0 "$status" "prose naming no specific pull request"
  pass "prose about pull requests in general is not mistaken for a bare reference"
}

test_an_empty_message_is_refused() {
  local home="$TMP_ROOT/empty" out status=0
  new_home "$home"
  install_sender "$home"
  out=$(printf '' | FM_HOME="$home" "$SEND" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "an empty message reported success"
  assert_contains "$out" "refusing to send an empty message" "the refusal did not name the empty message"

  # --text '' and a file of blank lines both frame into a message the captain
  # receives and cannot read, so emptiness is measured in characters he could.
  status=0
  out=$(run_send "$home" --text '') || status=$?
  [ "$status" -ne 0 ] || fail "an empty --text reported success"
  status=0
  printf '\n  \n\t\n' > "$TMP_ROOT/blank.txt"
  out=$(run_send "$home" --text-file "$TMP_ROOT/blank.txt") || status=$?
  [ "$status" -ne 0 ] || fail "a whitespace-only message reported success"
  [ ! -e "$home/state/sender-body" ] || fail "the sender ran for a message with nothing in it"
  pass "an empty or whitespace-only message is refused rather than delivered as silence"
}

test_a_message_can_come_from_stdin_or_a_file() {
  local home="$TMP_ROOT/inputs" status=0
  new_home "$home"
  install_sender "$home"

  printf 'from stdin\n' | FM_HOME="$home" "$SEND" >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "a message on stdin"
  assert_grep "from stdin" "$home/state/sender-body" "the stdin message did not reach the sender"

  printf 'from a file\n' > "$TMP_ROOT/message.txt"
  status=0
  run_send "$home" --text-file "$TMP_ROOT/message.txt" >/dev/null || status=$?
  expect_code 0 "$status" "a message from a file"
  assert_grep "from a file" "$home/state/sender-body" "the file message did not reach the sender"
  pass "a script can pass the message as text, as a file, or on stdin"
}

test_an_unreadable_message_file_fails_rather_than_sending_nothing() {
  local home="$TMP_ROOT/missing-file" out status=0
  new_home "$home"
  install_sender "$home"
  out=$(run_send "$home" --text-file "$TMP_ROOT/does-not-exist.txt") || status=$?
  [ "$status" -ne 0 ] || fail "an unreadable message file reported success"
  assert_contains "$out" "cannot read the message file" "the refusal did not name the unreadable file"
  pass "an unreadable message file is a failure, not an empty send"
}

test_bad_arguments_are_a_usage_error_and_attempt_nothing() {
  local home="$TMP_ROOT/usage" out status=0
  new_home "$home"
  install_sender "$home"
  out=$(run_send "$home" --nonsense) || status=$?
  expect_code 2 "$status" "an unknown argument"
  assert_contains "$out" "unknown argument" "the usage error did not name the argument"
  [ ! -e "$home/state/sender-body" ] || fail "the sender ran despite a usage error"

  status=0
  out=$(run_send "$home" --text a --text-file "$TMP_ROOT/either-one.txt") || status=$?
  expect_code 2 "$status" "two ways to say the same thing"
  pass "bad arguments exit 2 and attempt no send"
}

# --- sending a file ---------------------------------------------------------

# THE regression this half exists for. A sender that cannot send files must
# refuse, and must never quietly send the caption as a message instead: the
# caller would be told "sent", the captain would have a line of text where a
# document should be, and nothing anywhere would say so.
test_a_sender_that_cannot_send_files_refuses_and_transmits_nothing() {
  local home="$TMP_ROOT/no-file-support" out status=0 payload="$TMP_ROOT/no-file-support.md"
  new_home "$home"
  install_sender "$home"
  printf 'the quarterly report\n' > "$payload"

  out=$(run_send "$home" --file "$payload" --caption 'the report you asked for') || status=$?
  [ "$status" -ne 0 ] || fail "a sender with no file support reported a file delivered"
  assert_contains "$out" "does not support sending files" "the refusal did not name file support as the reason"
  assert_contains "$out" "the file was NOT sent" "the refusal did not say the file went nowhere"
  assert_not_contains "$out" "telegram send: sent" "a refused file send was also reported as sent"
  assert_sender_never_ran "$home" "the sender ran for a file it cannot send"
  pass "a sender that cannot send files is refused, and the caption is not sent as a message instead"
}

test_a_declaration_that_does_not_claim_files_is_refused_the_same_way() {
  local home="$TMP_ROOT/other-capabilities" out status=0 payload="$TMP_ROOT/other-capabilities.md"
  new_home "$home"
  install_sender "$home"
  declare_capabilities "$home" '# this sender speaks and nothing more' 'message'
  printf 'the quarterly report\n' > "$payload"

  out=$(run_send "$home" --file "$payload") || status=$?
  [ "$status" -ne 0 ] || fail "a sender declaring no file capability reported a file delivered"
  assert_contains "$out" "does not support sending files" "the refusal did not name file support as the reason"
  assert_sender_never_ran "$home" "the sender ran for a file it had not declared"
  pass "a declaration that does not list file is refused exactly as an absent one is"
}

test_an_unreadable_declaration_is_refused_rather_than_assumed() {
  local home="$TMP_ROOT/unreadable-capabilities" out status=0 payload="$TMP_ROOT/unreadable-cap.md"
  new_home "$home"
  install_sender "$home"
  declare_capabilities "$home" 'file'
  printf 'the quarterly report\n' > "$payload"
  chmod 0000 "$home/config/fm-tg-send.capabilities"
  if [ -r "$home/config/fm-tg-send.capabilities" ]; then
    # A user who can read anything (root) cannot make this file unreadable, so
    # the assertion would be measuring nothing.
    printf '# skipped: this user can read a mode-0000 file\n'
    chmod 0600 "$home/config/fm-tg-send.capabilities"
    return 0
  fi

  out=$(run_send "$home" --file "$payload") || status=$?
  chmod 0600 "$home/config/fm-tg-send.capabilities"
  [ "$status" -ne 0 ] || fail "an unreadable declaration was treated as file support"
  assert_contains "$out" "cannot be read" "the refusal did not name the unreadable declaration"
  assert_sender_never_ran "$home" "the sender ran on a capability nobody could read"
  pass "an unreadable declaration is refused rather than assumed either way"
}

test_a_declared_sender_is_given_the_file_in_its_environment() {
  local home="$TMP_ROOT/file-send" out status=0 payload="$TMP_ROOT/quarterly-report.md" bytes
  new_home "$home"
  install_sender "$home"
  declare_capabilities "$home" 'file'
  printf 'the quarterly report\n' > "$payload"
  bytes=$(wc -c < "$payload" | tr -d '[:space:]')

  out=$(run_send "$home" --file "$payload" --caption 'the report you asked for') || status=$?
  expect_code 0 "$status" "a declared sender and a real file"
  assert_contains "$out" "R-abc123" "the sender's own reference did not reach the caller"
  assert_contains "$out" "sent quarterly-report.md" "the seam did not report which file went"
  assert_grep "FM_TG_SEND_KIND=document" "$home/state/sender-env" "the sender was not told what kind of transfer this is"
  assert_grep "FM_TG_SEND_PATH=$TMP_REAL/quarterly-report.md" "$home/state/sender-env" "the sender was not told where the bytes are"
  assert_grep "FM_TG_SEND_ORIGINAL_NAME=quarterly-report.md" "$home/state/sender-env" "the sender was not told the name the captain should see"
  assert_grep "FM_TG_SEND_BYTES=$bytes" "$home/state/sender-env" "the sender was not told the size it has to fit on the wire"
  grep -Eq '^FM_TG_SEND_MIME=[A-Za-z0-9._+-]+/[A-Za-z0-9._+-]+$' "$home/state/sender-env" \
    || fail "the sender was not given a well-formed media type"
  assert_grep "the report you asked for" "$home/state/sender-body" "the caption did not reach the sender on stdin"
  assert_no_grep "$payload" "$home/state/sender-argv" "the file path was passed on the sender's command line"
  pass "a declared sender is handed one file, its name, its size, its type, and the caption"
}

# The path is absolute so a sender that runs from anywhere reads the same bytes
# the caller named, and never a same-named file beside itself.
test_the_file_path_handed_over_is_absolute() {
  local home="$TMP_ROOT/relative-path" status=0
  new_home "$home"
  install_sender "$home"
  declare_capabilities "$home" 'file'
  mkdir -p "$TMP_ROOT/relative"
  printf 'the quarterly report\n' > "$TMP_ROOT/relative/report.md"

  ( cd "$TMP_ROOT/relative" && FM_HOME="$home" "$SEND" --file ./report.md >/dev/null 2>&1 ) || status=$?
  expect_code 0 "$status" "a file named by a relative path"
  assert_grep "FM_TG_SEND_PATH=$TMP_REAL/relative/report.md" "$home/state/sender-env" \
    "the sender was given a path it would have had to resolve itself"
  assert_grep "FM_TG_SEND_ORIGINAL_NAME=report.md" "$home/state/sender-env" \
    "the name the captain sees carried the caller's own path syntax"
  pass "a relative path is resolved before the sender sees it"
}

# The media type is detected rather than guessed from the name, and only a
# well-formed one is believed.
test_the_media_type_is_detected_and_a_malformed_one_is_not_believed() {
  local home="$TMP_ROOT/mime" status=0 fakebin payload="$TMP_ROOT/mime-payload.pdf"
  new_home "$home"
  install_sender "$home"
  declare_capabilities "$home" 'file'
  printf 'the quarterly report\n' > "$payload"
  fakebin=$(fm_fakebin "$TMP_ROOT/mime-tools")

  printf '#!/usr/bin/env bash\nprintf "application/pdf\\n"\n' > "$fakebin/file"
  chmod +x "$fakebin/file"
  PATH="$fakebin:$PATH" FM_HOME="$home" "$SEND" --file "$payload" >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "a detected media type"
  assert_grep "FM_TG_SEND_MIME=application/pdf" "$home/state/sender-env" "the detected media type did not reach the sender"

  status=0
  printf '#!/usr/bin/env bash\nprintf "cannot open %%s (No such file)\\n" "$*"\n' > "$fakebin/file"
  chmod +x "$fakebin/file"
  PATH="$fakebin:$PATH" FM_HOME="$home" "$SEND" --file "$payload" >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "an undetectable media type"
  assert_grep "FM_TG_SEND_MIME=application/octet-stream" "$home/state/sender-env" \
    "a malformed detection was passed on instead of falling back to the type that claims nothing"
  pass "the media type is detected, and anything malformed falls back rather than being believed"
}

test_a_file_may_go_with_no_caption_at_all() {
  local home="$TMP_ROOT/no-caption" status=0 payload="$TMP_ROOT/no-caption.md"
  new_home "$home"
  install_sender "$home"
  declare_capabilities "$home" 'file'
  printf 'the quarterly report\n' > "$payload"

  run_send "$home" --file "$payload" >/dev/null || status=$?
  expect_code 0 "$status" "a file with no caption"
  [ -e "$home/state/sender-body" ] || fail "the sender never ran for a file with no caption"
  [ ! -s "$home/state/sender-body" ] || fail "an absent caption reached the sender as content"
  pass "a file with no caption is an ordinary send, not an empty message"
}

# Each way a path can be wrong says which way it was wrong: "could not send
# that" leaves the caller guessing between a typo, a directory, and a file that
# turned out to be empty.
test_every_way_a_path_can_be_wrong_is_refused_before_anything_is_transmitted() {
  local home="$TMP_ROOT/bad-paths" out status=0
  new_home "$home"
  install_sender "$home"
  declare_capabilities "$home" 'file'

  out=$(run_send "$home" --file "$TMP_ROOT/never-written.pdf") || status=$?
  [ "$status" -ne 0 ] || fail "a path with no file at it reported success"
  assert_contains "$out" "there is no file at" "the refusal did not name the missing file"
  assert_sender_never_ran "$home" "the sender ran for a file that does not exist"

  status=0
  mkdir -p "$TMP_ROOT/bad-paths-dir"
  out=$(run_send "$home" --file "$TMP_ROOT/bad-paths-dir") || status=$?
  [ "$status" -ne 0 ] || fail "a directory reported success"
  assert_contains "$out" "is a directory" "the refusal did not name the directory"
  assert_contains "$out" "never expands one into the files inside it" \
    "the refusal did not say a directory is not shorthand for its contents"
  assert_sender_never_ran "$home" "the sender ran for a directory"

  status=0
  : > "$TMP_ROOT/empty-report.pdf"
  out=$(run_send "$home" --file "$TMP_ROOT/empty-report.pdf") || status=$?
  [ "$status" -ne 0 ] || fail "an empty file reported success"
  assert_contains "$out" "refusing to send an empty file" "the refusal did not name the empty file"
  assert_sender_never_ran "$home" "the sender ran for a file with nothing in it"

  status=0
  printf 'unreadable\n' > "$TMP_ROOT/unreadable-report.pdf"
  chmod 0000 "$TMP_ROOT/unreadable-report.pdf"
  if [ -r "$TMP_ROOT/unreadable-report.pdf" ]; then
    printf '# partly skipped: this user can read a mode-0000 file\n'
  else
    out=$(run_send "$home" --file "$TMP_ROOT/unreadable-report.pdf") || status=$?
    [ "$status" -ne 0 ] || fail "an unreadable file reported success"
    assert_contains "$out" "cannot read the file" "the refusal did not name the unreadable file"
    assert_sender_never_ran "$home" "the sender ran for a file it could not read"
  fi
  chmod 0600 "$TMP_ROOT/unreadable-report.pdf"
  pass "a missing, directory, empty, or unreadable path is refused with its own reason and sends nothing"
}

# This path carries material out of the vessel, and config/ is where the
# channel's own credential lives. One named accident, not a secret scanner.
test_a_path_inside_the_homes_private_configuration_is_refused() {
  local home="$TMP_ROOT/config-path" out status=0
  new_home "$home"
  install_sender "$home"
  declare_capabilities "$home" 'file'

  out=$(run_send "$home" --file "$home/config/telegram.env") || status=$?
  [ "$status" -ne 0 ] || fail "the channel credential was sent out of the vessel"
  assert_contains "$out" "private configuration" "the refusal did not name what that directory holds"
  assert_sender_never_ran "$home" "the sender ran for a file out of the private configuration"
  assert_not_contains "$out" "$FIXTURE_TOKEN" "the refusal printed the credential it was refusing to send"
  pass "a path inside the home's own private configuration is refused"
}

test_a_caption_naming_a_pull_request_without_its_url_is_refused_too() {
  local home="$TMP_ROOT/caption-pr" out status=0 payload="$TMP_ROOT/caption-pr.md"
  new_home "$home"
  install_sender "$home"
  declare_capabilities "$home" 'file'
  printf 'the quarterly report\n' > "$payload"

  out=$(run_send "$home" --file "$payload" --caption 'the review notes for PR #91') || status=$?
  [ "$status" -ne 0 ] || fail "a caption naming a pull request with no URL was sent"
  assert_contains "$out" "requires the full URL" "the refusal did not name the rule"
  assert_sender_never_ran "$home" "the sender ran for a caption the seam had already refused"
  pass "a caption is captain-facing text, so the pull request URL rule holds for it too"
}

test_a_failing_sender_on_a_file_send_is_never_reported_as_sent() {
  local home="$TMP_ROOT/file-sender-fails" out status=0 payload="$TMP_ROOT/file-fails.md"
  new_home "$home"
  install_sender "$home" 4
  declare_capabilities "$home" 'file'
  printf 'the quarterly report\n' > "$payload"

  out=$(run_send "$home" --file "$payload") || status=$?
  expect_code 4 "$status" "a sender that failed on a file"
  assert_contains "$out" "the sender exited 4" "the failure did not name the sender's exit status"
  assert_contains "$out" "the file was NOT sent" "the failure did not say the file went nowhere"
  assert_not_contains "$out" "telegram send: sent" "a failed file send was also reported as sent"
  pass "a sender that fails on a file is reported loudly and never as a delivery"
}

# One deliberate file per call, and nothing inherited: the request is what this
# command line said and nothing else.
test_ambiguous_file_arguments_are_usage_errors_and_attempt_nothing() {
  local home="$TMP_ROOT/file-usage" out status=0 payload="$TMP_ROOT/file-usage.md"
  new_home "$home"
  install_sender "$home"
  declare_capabilities "$home" 'file'
  printf 'the quarterly report\n' > "$payload"

  out=$(run_send "$home" --file "$payload" --file "$payload") || status=$?
  expect_code 2 "$status" "two files in one call"
  assert_contains "$out" "one deliberate file per call" "the usage error did not say why a second file is refused"

  status=0
  out=$(run_send "$home" --file "$payload" --text 'here it is') || status=$?
  expect_code 2 "$status" "a file and a message body"
  assert_contains "$out" "pass --caption" "the usage error did not point at the caption"

  status=0
  out=$(run_send "$home" --caption 'orphan') || status=$?
  expect_code 2 "$status" "a caption with no file"
  assert_contains "$out" "--caption belongs to --file" "the usage error did not say what a caption belongs to"

  assert_sender_never_ran "$home" "the sender ran despite a usage error"
  pass "ambiguous file arguments exit 2 and attempt no send"
}

# A stale value in whatever called this script must not be able to turn a
# message into a file, or point a file send at bytes nobody named here.
test_a_text_send_carries_no_file_request_even_from_a_dirty_environment() {
  local home="$TMP_ROOT/dirty-env" status=0
  new_home "$home"
  install_sender "$home"
  declare_capabilities "$home" 'file'

  FM_TG_SEND_KIND=document FM_TG_SEND_PATH=/etc/hostname \
    FM_TG_SEND_ORIGINAL_NAME=hostname FM_TG_SEND_MIME=text/plain FM_TG_SEND_BYTES=9 \
    FM_HOME="$home" "$SEND" --text 'the build is green' >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "a text send under an inherited file request"
  # Whole-line matches: the value has to be gone, not merely different.
  grep -Fqx "FM_TG_SEND_KIND=" "$home/state/sender-env" || fail "an inherited transfer kind reached the sender"
  grep -Fqx "FM_TG_SEND_PATH=" "$home/state/sender-env" || fail "an inherited file path reached the sender"
  grep -Fqx "FM_TG_SEND_ORIGINAL_NAME=" "$home/state/sender-env" || fail "an inherited file name reached the sender"
  pass "a text send removes an inherited file request rather than passing it through"
}

# The seam hands the credential to nobody, so the credential must not be able to
# come back out of it whatever happens on the way.
test_the_credential_never_appears_in_this_scripts_output() {
  local home="$TMP_ROOT/no-leak" out
  new_home "$home"
  install_sender "$home" 3
  out=$(run_send "$home" --text 'the build broke' || true)
  assert_not_contains "$out" "$FIXTURE_TOKEN" "the credential value reached the output of a failed send"

  install_sender "$home"
  out=$(run_send "$home" --text 'the build is green' || true)
  assert_not_contains "$out" "$FIXTURE_TOKEN" "the credential value reached the output of a successful send"
  pass "no credential value appears in the seam's output on either path"
}

test_help_is_the_header
test_an_unconfigured_home_fails_rather_than_reporting_inactive
test_a_home_with_a_credential_and_no_sender_names_the_missing_half
test_a_home_that_can_hear_but_not_speak_says_so_in_those_terms
test_a_sender_without_a_credential_still_fails
test_a_message_reaches_the_sender_on_stdin
test_the_message_never_reaches_the_senders_command_line
test_the_sender_is_told_which_home_it_is_speaking_for
test_a_failing_sender_is_reported_and_never_reported_as_sent
test_arguments_after_a_double_dash_reach_the_sender
test_a_bare_pull_request_reference_is_refused_before_anything_is_sent
test_a_full_url_satisfies_the_rule
test_prose_about_pull_requests_in_general_is_not_refused
test_an_empty_message_is_refused
test_a_message_can_come_from_stdin_or_a_file
test_an_unreadable_message_file_fails_rather_than_sending_nothing
test_bad_arguments_are_a_usage_error_and_attempt_nothing
test_a_sender_that_cannot_send_files_refuses_and_transmits_nothing
test_a_declaration_that_does_not_claim_files_is_refused_the_same_way
test_an_unreadable_declaration_is_refused_rather_than_assumed
test_a_declared_sender_is_given_the_file_in_its_environment
test_the_file_path_handed_over_is_absolute
test_the_media_type_is_detected_and_a_malformed_one_is_not_believed
test_a_file_may_go_with_no_caption_at_all
test_every_way_a_path_can_be_wrong_is_refused_before_anything_is_transmitted
test_a_path_inside_the_homes_private_configuration_is_refused
test_a_caption_naming_a_pull_request_without_its_url_is_refused_too
test_a_failing_sender_on_a_file_send_is_never_reported_as_sent
test_ambiguous_file_arguments_are_usage_errors_and_attempt_nothing
test_a_text_send_carries_no_file_request_even_from_a_dirty_environment
test_the_credential_never_appears_in_this_scripts_output

echo "# all fm-tg-send tests passed"
