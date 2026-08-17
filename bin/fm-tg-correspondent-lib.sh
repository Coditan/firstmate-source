#!/usr/bin/env bash
# fm-tg-correspondent-lib.sh - parse the local Telegram correspondent lane.
#
# The single registration file is config/fm-tg-correspondent under the effective
# config directory.
# It is captain-private and gitignored, like the Telegram credential and the
# per-home sender and receiver implementations.
#
# Format:
#   name=<slug>
#   chat_id=<telegram-chat-id>
#
# Blank lines and # comments are ignored.
# The name becomes the local inbox directory under state/tg-correspondents/, so
# it is deliberately a slug rather than free prose.
# The chat id is local contact data and must never be copied into tracked docs,
# tests that describe real people, commits, or pull request bodies.

FM_TG_CORRESPONDENT_CONFIG_ERROR=
FM_TG_CORRESPONDENT_NAME=
FM_TG_CORRESPONDENT_CHAT_ID=

fm_tg_correspondent_config_path() {  # <config-dir>
  printf '%s/fm-tg-correspondent\n' "$1"
}

fm_tg_correspondent_trim() {  # <value> <result-var>
  local value=$1 result_var=$2 trimmed
  trimmed=$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  printf -v "$result_var" '%s' "$trimmed"
}

fm_tg_correspondent_reject() {  # <reason>
  FM_TG_CORRESPONDENT_CONFIG_ERROR=$1
  return 2
}

fm_tg_correspondent_validate_name() {  # <name>
  case "$1" in
    ''|.|..|*/*|*[!A-Za-z0-9._-]*)
      fm_tg_correspondent_reject 'config/fm-tg-correspondent has an invalid name; use only letters, numbers, dot, underscore, and dash'
      return
      ;;
  esac
  return 0
}

fm_tg_correspondent_validate_chat_id() {  # <chat-id>
  local rest=$1
  case "$rest" in
    -*) rest=${rest#-} ;;
  esac
  case "$rest" in
    ''|*[!0-9]*)
      fm_tg_correspondent_reject 'config/fm-tg-correspondent has an invalid chat_id; use the numeric Telegram chat id'
      return
      ;;
  esac
  return 0
}

fm_tg_correspondent_load() {  # <config-dir>
  local config_dir=$1 path line clean key value name='' chat_id='' seen_name=0 seen_chat_id=0

  # shellcheck disable=SC2034 # Public source-library result read by callers.
  FM_TG_CORRESPONDENT_CONFIG_ERROR=
  # shellcheck disable=SC2034 # Public source-library result read by callers.
  FM_TG_CORRESPONDENT_NAME=
  # shellcheck disable=SC2034 # Public source-library result read by callers.
  FM_TG_CORRESPONDENT_CHAT_ID=

  path=$(fm_tg_correspondent_config_path "$config_dir")
  [ -f "$path" ] || return 1
  [ -r "$path" ] \
    || { fm_tg_correspondent_reject 'config/fm-tg-correspondent cannot be read'; return; }

  while IFS= read -r line || [ -n "$line" ]; do
    clean=${line%%#*}
    fm_tg_correspondent_trim "$clean" clean
    [ -n "$clean" ] || continue
    case "$clean" in
      *=*) ;;
      *)
        fm_tg_correspondent_reject 'config/fm-tg-correspondent lines must be key=value'
        return
        ;;
    esac
    key=${clean%%=*}
    value=${clean#*=}
    fm_tg_correspondent_trim "$key" key
    fm_tg_correspondent_trim "$value" value
    case "$key" in
      name)
        [ "$seen_name" -eq 0 ] \
          || { fm_tg_correspondent_reject 'config/fm-tg-correspondent repeats name'; return; }
        seen_name=1
        name=$value
        ;;
      chat_id)
        [ "$seen_chat_id" -eq 0 ] \
          || { fm_tg_correspondent_reject 'config/fm-tg-correspondent repeats chat_id'; return; }
        seen_chat_id=1
        chat_id=$value
        ;;
      *)
        fm_tg_correspondent_reject "config/fm-tg-correspondent has unknown key '$key'"
        return
        ;;
    esac
  done < "$path"

  [ -n "$name" ] \
    || { fm_tg_correspondent_reject 'config/fm-tg-correspondent is missing name'; return; }
  [ -n "$chat_id" ] \
    || { fm_tg_correspondent_reject 'config/fm-tg-correspondent is missing chat_id'; return; }
  fm_tg_correspondent_validate_name "$name" || return
  fm_tg_correspondent_validate_chat_id "$chat_id" || return

  # shellcheck disable=SC2034 # Public source-library result read by callers.
  FM_TG_CORRESPONDENT_NAME=$name
  # shellcheck disable=SC2034 # Public source-library result read by callers.
  FM_TG_CORRESPONDENT_CHAT_ID=$chat_id
  return 0
}

fm_tg_correspondent_inbox_dir() {  # <state-dir> <name>
  printf '%s/tg-correspondents/%s\n' "$1" "$2"
}

fm_tg_correspondent_inbox_path() {  # <state-dir> <name>
  printf '%s/inbox.jsonl\n' "$(fm_tg_correspondent_inbox_dir "$1" "$2")"
}
