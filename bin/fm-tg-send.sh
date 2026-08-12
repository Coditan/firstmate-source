#!/usr/bin/env bash
# Send the captain one short message on this home's direct Telegram channel.
#
# This is the outbound half of the seam whose inbound half is
# bin/fm-tg-recv-arm.sh. It owns the delivery path and nothing else: what
# deserves the captain's attention is AGENTS.md section 9's, and how a message
# reaches Telegram is the per-home sender's. docs/telegram-outbound.md owns the
# contract, what the channel is for and not for, and the delivered-message
# proof behind it.
#
# Usage:
#   fm-tg-send.sh --text <message>          send that message
#   fm-tg-send.sh --text-file <path>        send the contents of that file
#   fm-tg-send.sh < message.txt             send the message read from stdin
#   fm-tg-send.sh --text <m> -- <args...>   pass everything after -- to the
#                                           per-home sender, unread
#   fm-tg-send.sh --help
#
# Exit status:
#   0  the sender reported the message delivered
#   2  the arguments were wrong and nothing was attempted
#   *  anything else means the message did NOT reach the captain; a sender's own
#      non-zero status is passed through unchanged, so read the diagnostic
#      rather than the number alone
#
# NEVER discard this exit status. A notification path that can fail quietly
# gets trusted while it is dead, which is the defect this channel exists to
# remove rather than to add another instance of.
#
# The per-home sender is config/fm-tg-send.sh, the sibling of the receiver's
# own config/fm-tg-recv.sh, and the credential it consumes is
# config/telegram.env. Both are captain-private and gitignored. This script
# never reads, sources, prints, or logs the credential; it hands the message to
# the sender on STDIN and lets the sender own the credential, the wire, and the
# redaction of its own diagnostics. Anything passed after -- lands on the
# sender's command line, so never put a credential there: /proc on a shared
# host makes another account's argv readable and its environment not.
#
# It refuses rather than sends when the message names a specific pull request
# and carries no https:// URL, because AGENTS.md section 9 requires the full
# URL before any shorthand reference, and a bare #number is least useful on the
# phone this channel reaches.
#
# An unconfigured home FAILS here rather than reporting itself inactive, and
# that asymmetry with bin/fm-tg-recv-arm.sh is the point rather than an
# inconsistency. An unarmed receiver is a feature that is off. An unsent
# notification is a message the captain did not get, and the caller is the only
# one who can still do something about it.
#
# Environment:
#   FM_HOME               the home whose config and state are used
#   FM_CONFIG_OVERRIDE    relocate the config directory (tests only)
#   FM_STATE_OVERRIDE     relocate the state directory (tests only)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ENV_FILE="$CONFIG/telegram.env"
SENDER="$CONFIG/fm-tg-send.sh"
RECEIVER="$CONFIG/fm-tg-recv.sh"

usage() {
  # The header comment block IS the help text, so the two cannot drift apart.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

diag() {
  printf 'telegram send: %s\n' "$*" >&2
}

# Every refusal says the message did not go, because "failed" alone reads as a
# transport hiccup somebody else will retry.
die() {
  diag "FAILED - $*"
  diag 'the message was NOT sent to the captain.'
  exit 1
}

usage_error() {
  diag "$*"
  usage >&2
  exit 2
}

text=
have_text=0
text_file=
sender_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --text)
      shift
      [ $# -gt 0 ] || usage_error "--text needs a value"
      text=$1
      have_text=1
      ;;
    --text-file)
      shift
      [ $# -gt 0 ] || usage_error "--text-file needs a path"
      text_file=$1
      ;;
    --)
      shift
      sender_args=("$@")
      break
      ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
  shift
done

[ "$have_text" -eq 1 ] && [ -n "$text_file" ] \
  && usage_error "--text and --text-file are two ways to say the same thing; pass one"

body=$(mktemp "${TMPDIR:-/tmp}/fm-tg-send.XXXXXX") \
  || die 'could not create the message file'
chmod 0600 "$body" 2>/dev/null || true
# shellcheck disable=SC2064 # $body is settled here and must expand now.
trap "rm -f '$body'" EXIT

if [ "$have_text" -eq 1 ]; then
  printf '%s\n' "$text" > "$body" || die 'could not stage the message'
elif [ -n "$text_file" ]; then
  [ -r "$text_file" ] || die "cannot read the message file $text_file"
  cat -- "$text_file" > "$body" || die "could not read the message file $text_file"
else
  [ -t 0 ] && usage_error 'no message: pass --text, --text-file, or pipe the message on stdin'
  cat > "$body" || die 'could not read the message from stdin'
fi

# Whitespace rather than emptiness, because --text '' and a file of blank lines
# both frame into a message the captain receives and cannot read.
grep -q '[^[:space:]]' "$body" || die 'refusing to send an empty message'

# The message the caller wrote is checked before this home's configuration is,
# so a composition mistake reads as a composition mistake on every home.
if ! grep -q 'https://' "$body"; then
  if grep -Eiq '(pull|merge) request[[:space:]]*[#!]?[0-9]+' "$body" \
    || grep -Eiq '(^|[^[:alnum:]])(PR|MR)[[:space:]]*[#!]?[0-9]+' "$body"; then
    diag 'the message names a pull request by number and carries no https:// URL.'
    die 'AGENTS.md section 9 requires the full URL before any shorthand reference'
  fi
fi

env_present=0
sender_present=0
[ -f "$ENV_FILE" ] && env_present=1
[ -f "$SENDER" ] && [ -x "$SENDER" ] && sender_present=1

if [ "$env_present" -eq 0 ] && [ "$sender_present" -eq 0 ]; then
  die 'this home has no way to reach the captain: config/telegram.env and config/fm-tg-send.sh are both absent'
fi
if [ "$env_present" -eq 0 ]; then
  die 'config/telegram.env is absent, so the channel has no credential'
fi
if [ "$sender_present" -eq 0 ]; then
  if [ -x "$RECEIVER" ]; then
    diag 'this home can hear the captain and cannot answer him: config/fm-tg-recv.sh is installed and config/fm-tg-send.sh is not.'
  fi
  die 'config/fm-tg-send.sh is missing or not executable, so this home has no sender'
fi

# The sender's own stdout and stderr flow straight through: its stdout is the
# reference a caller may want to keep, and its stderr is already redacted
# against the credential by whoever owns it.
FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" FM_STATE_OVERRIDE="$STATE" \
  "$SENDER" ${sender_args[@]+"${sender_args[@]}"} < "$body"
rc=$?

if [ "$rc" -ne 0 ]; then
  diag "FAILED - the sender exited $rc without delivering the message."
  diag 'the message was NOT sent to the captain.'
  exit "$rc"
fi

diag 'sent'
exit 0
