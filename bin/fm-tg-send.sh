#!/usr/bin/env bash
# Send the captain one short message, or one named file, on this home's direct
# Telegram channel.
#
# This is the outbound half of the seam whose inbound half is
# bin/fm-tg-recv-arm.sh. It owns the delivery path and nothing else: what
# deserves the captain's attention is AGENTS.md section 9's, and how a message
# reaches Telegram is the per-home sender's. docs/telegram-outbound.md owns the
# contract, what the channel is for and not for, what a sender must implement to
# claim it can send files, and the delivered-message proof behind it.
#
# Usage:
#   fm-tg-send.sh --text <message>          send that message
#   fm-tg-send.sh --text-file <path>        send the contents of that file
#   fm-tg-send.sh < message.txt             send the message read from stdin
#   fm-tg-send.sh --file <path>             send that one file
#   fm-tg-send.sh --file <path> --caption <text>
#                                           send that one file with a caption
#   fm-tg-send.sh --text <m> -- <args...>   pass everything after -- to the
#                                           per-home sender, unread
#   fm-tg-send.sh --help
#
# Exit status:
#   0  the sender reported the message or the file delivered
#   2  the arguments were wrong and nothing was attempted
#   *  anything else means it did NOT reach the captain; a sender's own non-zero
#      status is passed through unchanged, so read the diagnostic rather than
#      the number alone
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
# Sending a FILE is opt-in on both sides. --file names exactly one file, and the
# home's sender must have declared that it can send one by listing the token
# "file" in config/fm-tg-send.capabilities, the sender's own gitignored
# declaration. A home whose sender has not declared it is REFUSED here and
# nothing goes out. In particular the caption is never sent as a message
# instead: a caller told "sent" would have no way to learn the captain received
# words rather than the document, which is the one failure this whole channel
# exists to not have.
#
# The file request reaches the sender in FM_TG_SEND_* environment variables
# rather than on its command line, and the caption, which may be empty, arrives
# on stdin where the message body already does. docs/telegram-outbound.md is the
# one place those fields are defined, so a home implementing a sender reads it
# rather than this script.
#
# This path carries material OUT of the vessel, so what leaves is a deliberate
# decision every time: exactly one explicitly named file per call, never a
# directory, never a pattern, and never a --file repeated into ambiguity. It
# must never carry a secrets file, a credential, or a process environment; the
# secrets-handling skill owns that boundary. The one path refused here is one
# inside the home's own config directory, where the channel credential lives.
# That is a single named accident and NOT a secret scanner, and reading it as
# one would be the mistake.
#
# It refuses rather than sends when the message names a specific pull request
# and carries no https:// URL, because AGENTS.md section 9 requires the full
# URL before any shorthand reference, and a bare #number is least useful on the
# phone this channel reaches. A caption is captain-facing text too, so the same
# rule holds for it.
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
CAPABILITIES="$CONFIG/fm-tg-send.capabilities"
RECEIVER="$CONFIG/fm-tg-recv.sh"

usage() {
  # The header comment block IS the help text, so the two cannot drift apart.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

diag() {
  printf 'telegram send: %s\n' "$*" >&2
}

# Every refusal says the thing did not go, because "failed" alone reads as a
# transport hiccup somebody else will retry. The noun is the caller's own: a
# refused file must not report a message as unsent, or the caller reads it as
# the wrong kind of problem.
subject='message'

die() {
  diag "FAILED - $*"
  diag "the $subject was NOT sent to the captain."
  exit 1
}

usage_error() {
  diag "$*"
  usage >&2
  exit 2
}

resolve_file_path() {
  local candidate=$1 directory name target hops=0

  while [ "$hops" -lt 40 ]; do
    directory=$(cd -- "$(dirname -- "$candidate")" 2>/dev/null && pwd -P) || return 1
    name=$(basename -- "$candidate")
    candidate="$directory/$name"
    if [ ! -L "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    target=$(readlink "$candidate" 2>/dev/null) || return 1
    case "$target" in
      /*) candidate=$target ;;
      *) candidate="$directory/$target" ;;
    esac
    hops=$((hops + 1))
  done
  return 1
}

text=
have_text=0
text_file=
file_path=
have_file=0
caption=
have_caption=0
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
    --file)
      shift
      [ $# -gt 0 ] || usage_error "--file needs a path"
      # A second --file is ambiguous about which file leaves the vessel, and
      # quietly keeping the last one would make that choice on the caller's
      # behalf without saying so.
      [ "$have_file" -eq 0 ] \
        || usage_error "--file sends one deliberate file per call; pass it once"
      file_path=$1
      have_file=1
      ;;
    --caption)
      shift
      [ $# -gt 0 ] || usage_error "--caption needs a value"
      caption=$1
      have_caption=1
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

if [ "$have_file" -eq 1 ]; then
  subject='file'
  if [ "$have_text" -eq 1 ] || [ -n "$text_file" ]; then
    usage_error "a file's message is its caption; pass --caption rather than --text or --text-file"
  fi
elif [ "$have_caption" -eq 1 ]; then
  usage_error "--caption belongs to --file; pass --text for a message"
fi

body=$(mktemp "${TMPDIR:-/tmp}/fm-tg-send.XXXXXX") \
  || die 'could not create the message file'
chmod 0600 "$body" 2>/dev/null || true
# shellcheck disable=SC2064 # $body is settled here and must expand now.
trap "rm -f '$body'" EXIT

if [ "$have_file" -eq 1 ]; then
  # A file send never reads stdin: its message is the caption, and an empty one
  # is ordinary because the document is the payload.
  if [ -n "$caption" ]; then
    printf '%s\n' "$caption" > "$body" || die 'could not stage the caption'
  else
    : > "$body" || die 'could not stage the caption'
  fi
elif [ "$have_text" -eq 1 ]; then
  printf '%s\n' "$text" > "$body" || die 'could not stage the message'
elif [ -n "$text_file" ]; then
  [ -r "$text_file" ] || die "cannot read the message file $text_file"
  cat -- "$text_file" > "$body" || die "could not read the message file $text_file"
else
  [ -t 0 ] && usage_error 'no message: pass --text, --text-file, --file, or pipe the message on stdin'
  cat > "$body" || die 'could not read the message from stdin'
fi

# Whitespace rather than emptiness, because --text '' and a file of blank lines
# both frame into a message the captain receives and cannot read.
[ "$have_file" -eq 1 ] || grep -q '[^[:space:]]' "$body" \
  || die 'refusing to send an empty message'

# The message the caller wrote is checked before this home's configuration is,
# so a composition mistake reads as a composition mistake on every home. A
# caption is captain-facing text on the same phone, so it is held to this too.
if ! grep -q 'https://' "$body"; then
  if grep -Eiq '(pull|merge) request[[:space:]]*[#!]?[0-9]+' "$body" \
    || grep -Eiq '(^|[^[:alnum:]])(PR|MR)[[:space:]]*[#!]?[0-9]+' "$body"; then
    if [ "$have_file" -eq 1 ]; then
      diag 'the caption names a pull request by number and carries no https:// URL.'
    else
      diag 'the message names a pull request by number and carries no https:// URL.'
    fi
    die 'AGENTS.md section 9 requires the full URL before any shorthand reference'
  fi
fi

# The file the caller named is inspected here, before this home's configuration
# is, for the same reason the message is: a path mistake reads as a path mistake
# on every home. Each way a path can be wrong says which way it was wrong,
# because "could not send that" leaves the caller guessing between a typo, a
# directory, and a file that turned out to be empty.
file_name=
file_abs=
file_mime=
file_bytes=
if [ "$have_file" -eq 1 ]; then
  [ -e "$file_path" ] || die "there is no file at $file_path"
  [ ! -d "$file_path" ] \
    || die "$file_path is a directory, and this path never expands one into the files inside it"
  [ -f "$file_path" ] || die "$file_path is not a regular file"
  [ -r "$file_path" ] || die "cannot read the file $file_path"
  [ -s "$file_path" ] || die "refusing to send an empty file: $file_path"

  file_name=$(basename -- "$file_path")
  file_abs=$(resolve_file_path "$file_path") \
    || die "could not resolve the file at $file_path"

  # One named accident, not a secret scanner: config/ is where this channel's
  # own credential lives, so a path inside it is always the wrong thing to send
  # out of the vessel. Everything else about what may leave is the caller's
  # judgement, and the secrets-handling skill owns that boundary.
  config_dir=$(cd -- "$CONFIG" 2>/dev/null && pwd -P) || config_dir=
  if [ -n "$config_dir" ]; then
    case "$file_abs" in
      "$config_dir"/*)
        diag "that path is inside this home's private configuration, where the channel credential lives."
        die "refusing to send $file_name out of the vessel"
        ;;
    esac
  fi

  file_bytes=$(wc -c < "$file_abs" 2>/dev/null | tr -d '[:space:]')
  [ -n "$file_bytes" ] || die "could not measure $file_name"

  # Detected rather than guessed from the name, and only a well-formed type is
  # believed; anything else falls back to the type that claims nothing.
  file_mime=application/octet-stream
  if command -v file >/dev/null 2>&1; then
    detected=$(file --brief --mime-type -- "$file_abs" 2>/dev/null | head -n 1 | tr -d '[:space:]')
    case "$detected" in
      *[!A-Za-z0-9/._+-]* | /* | */ | */*/*) ;;
      */*) file_mime=$detected ;;
    esac
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

# Whether a sender can send files is asked before anything is handed over, and
# it is answered by a declaration rather than by running the sender to find out:
# a sender launched to be asked would already have the caption on its stdin, and
# a text-only one would send it. So the question has to be answerable without
# starting it, and a home that has not answered it is refused.
sender_declares() {
  local want=$1 line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ "$line" = "$want" ] && return 0
  done < "$CAPABILITIES"
  return 1
}

# There is deliberately NO fallback to sending the caption as a message here.
# That fallback is the tempting one and it is the wrong one: the caller believes
# a file arrived, the captain got a line of text or nothing, and nothing
# anywhere says so. Refusing is the only outcome that leaves someone able to act
# on it.
if [ "$have_file" -eq 1 ]; then
  if [ ! -f "$CAPABILITIES" ]; then
    diag 'a sender declares it can send files by listing "file" in config/fm-tg-send.capabilities, and this home has no such declaration.'
    diag 'docs/telegram-outbound.md says what a sender must implement before it can claim it.'
    die "this home's sender does not support sending files"
  fi
  if [ ! -r "$CAPABILITIES" ]; then
    die "config/fm-tg-send.capabilities cannot be read, so this home's file support is undeclared"
  fi
  if ! sender_declares file; then
    diag 'config/fm-tg-send.capabilities does not list "file", so this sender has declared only messages.'
    diag 'docs/telegram-outbound.md says what a sender must implement before it can claim it.'
    die "this home's sender does not support sending files"
  fi
fi

# Set here or removed here, never inherited: a stale value in whatever called
# this script must not be able to turn a message into a file, or point a file
# send at bytes nobody named on this command line.
unset FM_TG_SEND_KIND FM_TG_SEND_PATH FM_TG_SEND_ORIGINAL_NAME FM_TG_SEND_MIME FM_TG_SEND_BYTES
if [ "$have_file" -eq 1 ]; then
  export FM_TG_SEND_KIND=document
  export FM_TG_SEND_PATH="$file_abs"
  export FM_TG_SEND_ORIGINAL_NAME="$file_name"
  export FM_TG_SEND_MIME="$file_mime"
  export FM_TG_SEND_BYTES="$file_bytes"
fi

# The sender's own stdout and stderr flow straight through: its stdout is the
# reference a caller may want to keep, and its stderr is already redacted
# against the credential by whoever owns it.
FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" FM_STATE_OVERRIDE="$STATE" \
  "$SENDER" ${sender_args[@]+"${sender_args[@]}"} < "$body"
rc=$?

if [ "$rc" -ne 0 ]; then
  diag "FAILED - the sender exited $rc without delivering the $subject."
  diag "the $subject was NOT sent to the captain."
  exit "$rc"
fi

if [ "$have_file" -eq 1 ]; then
  diag "sent $file_name"
else
  diag 'sent'
fi
exit 0
