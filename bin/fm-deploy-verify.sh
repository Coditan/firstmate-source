#!/usr/bin/env bash
# fm-deploy-verify.sh - take the readback readings a deploy claim rests on, and
# never report agreement that was not measured.
#
# Every reading here is READ-ONLY. Nothing in this script starts, stops, builds,
# pulls, restarts, or changes anything, on the host or in the local clone.
#
# It establishes up to four facts and compares every pair of them:
#
#   source     the commit a ref resolves to in the source repository
#              FROM THE RECORD - read from a repository, not from the host
#   checkout   the HEAD of a checkout directory on the host
#              MEASURED - read off the host now
#   container  the revision label of a container that is RUNNING on the host
#              MEASURED - read off the host now
#   served     the commit whose blob matches the bytes the host actually serves
#              MEASURED bytes, resolved against blobs FROM THE RECORD
#
# The two-class labelling is the point of the tool. A record says what SHOULD be
# there; only a measurement says what IS. The verdict never mixes them silently.
#
# Four outcomes, each with its own exit status, so "nothing was checked" can
# never be read as "everything agreed":
#
#   0  AGREE            at least one pair had both sides read, and every such pair agrees
#   2  DRIFT            at least one pair had both sides read and they differ
#   3  INDETERMINATE    a reading this run ASKED FOR could not be taken
#   4  NOTHING CHECKED  every requested reading was taken, and no pair had both sides read
#   1  refused          usage error, or --expect-machine did not match
#
# A reading that was never requested is not a failed reading. "Not requested"
# and "requested but unreadable" are tracked apart, and that split is what makes
# exit 4 reachable at all: without it, every empty run collapses into exit 3 and
# the operator cannot tell an unasked question from an unanswerable one.
#
# Two readings deliberately refuse to resolve rather than guess:
#   - a container that is not running yields NO running-side commit, because the
#     image a stopped container was created from is not evidence of what serves;
#   - a served-bytes probe that matches more than one candidate commit reports
#     the tie and resolves to none of them.
#
# Usage: fm-deploy-verify.sh --help
set -u

PROG=${0##*/}

usage() {
  cat <<'USAGE'
fm-deploy-verify.sh - read-only readback of what a host is actually running.

  --host <ssh-target>        host to read from; omit to read this machine
  --expect-machine <id>      refuse, before any other reading, unless the host's
                             machine-id or hostname equals this value
  --container <name>         read a container's state, revision label, image,
                             compose project labels and mounts
  --checkout <dir>           read HEAD, branch and dirty count of a checkout
  --source-remote <url|dir>  repository to resolve --source-ref against
  --source-ref <ref>         ref to resolve (default: HEAD)
  --serves <url>             fetch this URL and hash the bytes it serves
  --serves-path <path>       repo-relative path whose blob those bytes are
                             compared against (required with --serves)
  --candidate <commit>       extra candidate commit for the served-bytes
                             reading; repeatable. The source and checkout
                             commits are candidates automatically
  --clone <dir>              local clone the candidate blobs are read from
                             (default: the current directory; used only by
                             --serves)
  --sudo auto|yes|no         elevation policy for BOTH the docker and the git
                             readings on the host (default: auto, which probes
                             unelevated first and falls back to sudo -n). The
                             elevation actually used is printed as read-as=
  --timeout <seconds>        per-reading timeout (default: 30)
  --help                     this text

Exit status: 0 AGREE, 2 DRIFT, 3 INDETERMINATE, 4 NOTHING CHECKED, 1 refused.

Every reading is read-only. This script never changes anything.
USAGE
}

die() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  exit 1
}

HOST=
EXPECT_MACHINE=
CONTAINER=
CHECKOUT=
SOURCE_REMOTE=
SOURCE_REF=HEAD
SERVES=
SERVES_PATH=
CLONE=.
SUDO_MODE=auto
TIMEOUT=30
CANDIDATES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) [ "$#" -ge 2 ] || die "--host needs a value"; HOST=$2; shift 2 ;;
    --expect-machine) [ "$#" -ge 2 ] || die "--expect-machine needs a value"; EXPECT_MACHINE=$2; shift 2 ;;
    --container) [ "$#" -ge 2 ] || die "--container needs a value"; CONTAINER=$2; shift 2 ;;
    --checkout) [ "$#" -ge 2 ] || die "--checkout needs a value"; CHECKOUT=$2; shift 2 ;;
    --source-remote) [ "$#" -ge 2 ] || die "--source-remote needs a value"; SOURCE_REMOTE=$2; shift 2 ;;
    --source-ref) [ "$#" -ge 2 ] || die "--source-ref needs a value"; SOURCE_REF=$2; shift 2 ;;
    --serves) [ "$#" -ge 2 ] || die "--serves needs a value"; SERVES=$2; shift 2 ;;
    --serves-path) [ "$#" -ge 2 ] || die "--serves-path needs a value"; SERVES_PATH=$2; shift 2 ;;
    --candidate) [ "$#" -ge 2 ] || die "--candidate needs a value"; CANDIDATES+=("$2"); shift 2 ;;
    --clone) [ "$#" -ge 2 ] || die "--clone needs a value"; CLONE=$2; shift 2 ;;
    --sudo) [ "$#" -ge 2 ] || die "--sudo needs a value"; SUDO_MODE=$2; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || die "--timeout needs a value"; TIMEOUT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

case "$SUDO_MODE" in
  auto|yes|no) : ;;
  *) die "--sudo must be auto, yes or no" ;;
esac
case "$TIMEOUT" in
  ''|*[!0-9]*) die "--timeout must be a whole number of seconds" ;;
esac
if [ -n "$SERVES" ] && [ -z "$SERVES_PATH" ]; then
  die "--serves needs --serves-path: without it there is nothing to compare the served bytes against"
fi
if [ -z "$SERVES" ] && [ -n "$SERVES_PATH" ]; then
  die "--serves-path was given without --serves, so no bytes would be fetched"
fi

# Candidate blobs are hashed with whichever of the two hashers this machine has;
# macOS ships shasum and no sha256sum. Which one is decided once, and its
# absence is a named reason rather than an empty hash that matches nothing.
HASH_KIND=
if command -v sha256sum >/dev/null 2>&1; then
  HASH_KIND=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  HASH_KIND=shasum
fi
hash_stdin() {
  case "$HASH_KIND" in
    sha256sum) sha256sum | cut -d' ' -f1 ;;
    shasum) shasum -a 256 | cut -d' ' -f1 ;;
    *) return 127 ;;
  esac
}

TIMEOUT_BIN=$(command -v timeout 2>/dev/null || true)
tmo() {
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$TIMEOUT" "$@"
  else
    "$@"
  fi
}

# POSIX single-quote escaping. ssh joins its command arguments with spaces and
# the remote LOGIN SHELL re-parses the result, so an argument carrying &, a
# space, or any other metacharacter must survive that second parse. Passing the
# arguments unquoted is not merely untidy: an unescaped & backgrounds the
# payload with its stdin detached from the heredoc, and the reading then comes
# back empty for a reason that has nothing to do with the host.
shq() {
  local out='' a s
  for a in "$@"; do
    s=${a//\'/\'\\\'\'}
    out="$out '$s'"
  done
  printf '%s' "$out"
}

# The remote payload. One script, several verbs, invoked once per reading.
# It prints key=value lines and always exits 0: a reading that failed says so
# with an error= line, because a bare non-zero status cannot say WHY.
PAYLOAD=$(cat <<'FM_PAYLOAD'
set -u
mode=${1:-auto}
verb=${2:-}
shift 2 2>/dev/null || true

ELEV=none
run_elev() {
  if [ "$ELEV" = sudo ]; then
    sudo -n "$@"
  else
    "$@"
  fi
}

# The elevation policy is decided ONCE per reading and reported, so --sudo
# governs the git reading exactly as it governs the docker reading. A verb that
# hardcodes its own fallback makes the flag a lie on the reading the operator
# most wanted kept off sudo.
pick_elev() {
  case "$mode" in
    no) ELEV=none ;;
    yes) ELEV=sudo ;;
    *) if "$@" >/dev/null 2>&1; then ELEV=none; else ELEV=sudo; fi ;;
  esac
}

case "$verb" in
  identity)
    m=
    if [ -r /etc/machine-id ]; then m=$(cat /etc/machine-id 2>/dev/null || true); fi
    if [ -z "$m" ] && [ -r /var/lib/dbus/machine-id ]; then
      m=$(cat /var/lib/dbus/machine-id 2>/dev/null || true)
    fi
    h=$(hostname 2>/dev/null || true)
    if [ -z "$m" ] && [ -z "$h" ]; then
      echo "error=neither /etc/machine-id nor hostname could be read"
      exit 0
    fi
    echo "machine=$m"
    echo "hostname=$h"
    ;;
  container)
    name=${1:-}
    if [ -z "$name" ]; then echo "error=no container name given"; exit 0; fi
    pick_elev docker version
    echo "elevation=$ELEV"
    tpl='running={{.State.Running}}
status={{.State.Status}}
restarts={{.RestartCount}}
started={{.State.StartedAt}}
image={{.Image}}
revision={{index .Config.Labels "org.opencontainers.image.revision"}}
compose_working_dir={{index .Config.Labels "com.docker.compose.project.working_dir"}}
compose_config_files={{index .Config.Labels "com.docker.compose.project.config_files"}}
{{range .Mounts}}mount={{.Source}} -> {{.Destination}} ({{if .RW}}rw{{else}}ro{{end}})
{{end}}'
    if ! out=$(run_elev docker inspect --format "$tpl" -- "$name" 2>&1); then
      echo "error=docker inspect failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
      exit 0
    fi
    printf '%s\n' "$out"
    ;;
  checkout)
    dir=${1:-}
    if [ -z "$dir" ]; then echo "error=no checkout directory given"; exit 0; fi
    if [ ! -d "$dir" ]; then echo "error=no such directory on the host: $dir"; exit 0; fi
    pick_elev git -C "$dir" rev-parse --git-dir
    echo "elevation=$ELEV"
    if ! head=$(run_elev git -C "$dir" rev-parse HEAD 2>&1); then
      echo "error=git rev-parse HEAD failed in $dir: $(printf '%s' "$head" | tr '\n' ' ' | cut -c1-200)"
      exit 0
    fi
    branch=$(run_elev git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if dirtyout=$(run_elev git -C "$dir" status --porcelain 2>/dev/null); then
      if [ -z "$dirtyout" ]; then dirty=0; else dirty=$(printf '%s\n' "$dirtyout" | wc -l | tr -d ' '); fi
      echo "dirty=$dirty"
    fi
    echo "head=$head"
    echo "branch=$branch"
    ;;
  served)
    url=${1:-}
    seconds=${2:-30}
    if [ -z "$url" ]; then echo "error=no URL given"; exit 0; fi
    tmp=$(mktemp 2>/dev/null) || { echo "error=could not create a temporary file on the host"; exit 0; }
    if ! code=$(curl -sS --max-time "$seconds" -o "$tmp" -w '%{http_code}' -- "$url" 2>&1); then
      rm -f "$tmp"
      echo "error=fetch failed: $(printf '%s' "$code" | tr '\n' ' ' | cut -c1-200)"
      exit 0
    fi
    size=$(wc -c <"$tmp" | tr -d ' ')
    # macOS vessels ship shasum and no sha256sum. A host with neither says so:
    # a silently empty hash would be compared against candidate blobs as if it
    # were the bytes the host serves.
    if command -v sha256sum >/dev/null 2>&1; then
      sha=$(sha256sum <"$tmp" | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
      sha=$(shasum -a 256 <"$tmp" | cut -d' ' -f1)
    else
      rm -f "$tmp"
      echo "error=neither sha256sum nor shasum is available on the host, so the bytes it serves could not be hashed"
      exit 0
    fi
    rm -f "$tmp"
    echo "http=$code"
    echo "sha256=$sha"
    echo "bytes=$size"
    ;;
  *)
    echo "error=unknown verb: $verb"
    ;;
esac
FM_PAYLOAD
)

# read_host <verb> [args...] - run one payload verb, locally or over ssh.
read_host() {
  local verb=$1
  shift
  if [ -n "$HOST" ]; then
    printf '%s\n' "$PAYLOAD" | tmo ssh -o BatchMode=yes -o ConnectTimeout="$TIMEOUT" \
      -- "$HOST" "bash -s --$(shq "$SUDO_MODE" "$verb" "$@")" 2>&1
  else
    printf '%s\n' "$PAYLOAD" | tmo bash -s -- "$SUDO_MODE" "$verb" "$@" 2>&1
  fi
}

# field <output> <key> - first value of key=..., empty when absent.
field() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

# A docker template renders a missing label as the literal <no value>. Treat it
# and the empty string alike: an absent revision label is an unread reading, not
# a commit.
clean() {
  case "$1" in
    '<no value>'|'') printf '' ;;
    *) printf '%s' "$1" ;;
  esac
}

short() {
  printf '%s' "${1:0:12}"
}

# --- the four facts ---------------------------------------------------------
#
# Each fact carries three things, and the third is what the tool is for:
#   REQ_*     did this run ASK for the reading
#   VAL_*     the commit, empty when it could not be resolved
#   WHY_*     why it could not be resolved, in words, when VAL_ is empty
REQ_SOURCE=0;    VAL_SOURCE=;    WHY_SOURCE=
REQ_CHECKOUT=0;  VAL_CHECKOUT=;  WHY_CHECKOUT=
REQ_CONTAINER=0; VAL_CONTAINER=; WHY_CONTAINER=
REQ_SERVED=0;    VAL_SERVED=;    WHY_SERVED=

INDETERMINATE=0
NOTES=()
note() { NOTES+=("$1"); }

[ -n "$SOURCE_REMOTE" ] && REQ_SOURCE=1
[ -n "$CHECKOUT" ] && REQ_CHECKOUT=1
[ -n "$CONTAINER" ] && REQ_CONTAINER=1
[ -n "$SERVES" ] && REQ_SERVED=1

printf '%s - read-only readback, %s\n' "$PROG" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# --- host identity ----------------------------------------------------------
#
# Taken first and always. Host aliases are not machines: several aliases can
# resolve to one machine and say nothing about which, so a run that cannot name
# the machine it reached has not established where its other readings came from.
ID_OUT=$(read_host identity)
ID_ERR=$(field "$ID_OUT" error)
ID_MACHINE=$(field "$ID_OUT" machine)
ID_HOST=$(field "$ID_OUT" hostname)

if [ -n "$ID_ERR" ] || { [ -z "$ID_MACHINE" ] && [ -z "$ID_HOST" ]; }; then
  if [ -n "$EXPECT_MACHINE" ]; then
    printf 'REFUSED: --expect-machine %s was given and the host identity could not be read (%s)\n' \
      "$EXPECT_MACHINE" "${ID_ERR:-no identity in the reply}" >&2
    exit 1
  fi
  printf 'host:      %s   UNREADABLE - %s\n' "${HOST:-this machine}" "${ID_ERR:-no identity in the reply}"
  INDETERMINATE=1
  note "the machine behind ${HOST:-this machine} could not be identified, so no reading below is tied to a known machine"
else
  if [ -n "$EXPECT_MACHINE" ] && [ "$EXPECT_MACHINE" != "$ID_MACHINE" ] && [ "$EXPECT_MACHINE" != "$ID_HOST" ]; then
    printf 'REFUSED: --expect-machine %s, but %s is machine-id %s / hostname %s\n' \
      "$EXPECT_MACHINE" "${HOST:-this machine}" "${ID_MACHINE:-<none>}" "${ID_HOST:-<none>}" >&2
    exit 1
  fi
  printf 'host:      %s   machine-id %s   hostname %s   MEASURED\n' \
    "${HOST:-this machine}" "${ID_MACHINE:-<none>}" "${ID_HOST:-<none>}"
fi

# --- source: FROM THE RECORD ------------------------------------------------
if [ "$REQ_SOURCE" -eq 1 ]; then
  # GIT_TERMINAL_PROMPT=0 and batch-mode ssh are not tidiness. Without them a
  # private remote with no cached credential blocks on a prompt, and a verifier
  # that hangs is worse than one that reports it could not read: an unattended
  # run never returns a verdict at all.
  if src_out=$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/echo SSH_ASKPASS_REQUIRE=never \
      GIT_SSH_COMMAND='ssh -oBatchMode=yes' tmo git ls-remote --exit-code -- "$SOURCE_REMOTE" "$SOURCE_REF" 2>&1); then
    VAL_SOURCE=$(printf '%s\n' "$src_out" | awk 'NF{print $1; exit}')
    if [ -z "$VAL_SOURCE" ]; then
      WHY_SOURCE="the remote answered without a commit for $SOURCE_REF"
    fi
  else
    WHY_SOURCE="git ls-remote could not read $SOURCE_REF from $SOURCE_REMOTE: $(printf '%s' "$src_out" | tr '\n' ' ' | cut -c1-160)"
  fi
  if [ -n "$VAL_SOURCE" ]; then
    printf 'source:    %s   %s %s   FROM THE RECORD\n' "$(short "$VAL_SOURCE")" "$SOURCE_REMOTE" "$SOURCE_REF"
  else
    printf 'source:    UNREAD - %s\n' "$WHY_SOURCE"
    INDETERMINATE=1
    note "the source reading was requested and could not be taken: $WHY_SOURCE"
  fi
else
  printf 'source:    NOT REQUESTED - no --source-remote given\n'
fi

# --- checkout: MEASURED -----------------------------------------------------
if [ "$REQ_CHECKOUT" -eq 1 ]; then
  co_out=$(read_host checkout "$CHECKOUT")
  co_err=$(field "$co_out" error)
  co_head=$(field "$co_out" head)
  co_branch=$(field "$co_out" branch)
  co_dirty=$(field "$co_out" dirty)
  co_elev=$(field "$co_out" elevation)
  if [ -n "$co_err" ]; then
    WHY_CHECKOUT=$co_err
  elif [ -z "$co_head" ]; then
    # An empty reply is an unread reading, not a clean checkout. Reporting a
    # blank HEAD as a reading - and then warning about its blank dirty count -
    # is exactly the confident-about-nothing outcome this tool exists to stop.
    WHY_CHECKOUT="the checkout reading came back empty for $CHECKOUT"
  else
    VAL_CHECKOUT=$co_head
  fi
  if [ -n "$VAL_CHECKOUT" ]; then
    printf 'checkout:  %s   %s   branch=%s   read-as=%s   MEASURED\n' \
      "$(short "$VAL_CHECKOUT")" "$CHECKOUT" "${co_branch:-<unknown>}" "${co_elev:-none}"
    if [ -n "$co_dirty" ] && [ "$co_dirty" != 0 ]; then
      printf '           WARNING: %s uncommitted path(s) in that checkout\n' "$co_dirty"
      note "$CHECKOUT has $co_dirty uncommitted path(s), so its HEAD does not describe every file it holds"
    fi
  else
    printf 'checkout:  UNREAD - %s\n' "$WHY_CHECKOUT"
    INDETERMINATE=1
    note "the checkout reading was requested and could not be taken: $WHY_CHECKOUT"
  fi
else
  printf 'checkout:  NOT REQUESTED - no --checkout given\n'
fi

# --- container: MEASURED ----------------------------------------------------
if [ "$REQ_CONTAINER" -eq 1 ]; then
  ct_out=$(read_host container "$CONTAINER")
  ct_err=$(field "$ct_out" error)
  ct_running=$(field "$ct_out" running)
  ct_status=$(field "$ct_out" status)
  ct_restarts=$(field "$ct_out" restarts)
  ct_started=$(field "$ct_out" started)
  ct_image=$(field "$ct_out" image)
  ct_rev=$(clean "$(field "$ct_out" revision)")
  ct_wd=$(clean "$(field "$ct_out" compose_working_dir)")
  ct_cf=$(clean "$(field "$ct_out" compose_config_files)")
  ct_elev=$(field "$ct_out" elevation)
  ct_mounts=$(printf '%s\n' "$ct_out" | sed -n 's/^mount=//p')

  if [ -n "$ct_err" ]; then
    WHY_CONTAINER=$ct_err
  elif [ -z "$ct_running" ]; then
    WHY_CONTAINER="the container reading came back empty for $CONTAINER"
  elif [ "$ct_running" != true ]; then
    # docker inspect succeeds on a stopped and on a crash-looping container, so
    # the revision label is still there to read. It is not evidence: the image a
    # container was created from says nothing about what is being served by a
    # container that is serving nothing.
    WHY_CONTAINER="container $CONTAINER is not running (state=${ct_status:-unknown}, restarts=${ct_restarts:-unknown}); the image it was created from is not evidence of what is serving"
  elif [ -z "$ct_rev" ]; then
    WHY_CONTAINER="container $CONTAINER carries no org.opencontainers.image.revision label, so what it is running cannot be read from it"
  else
    VAL_CONTAINER=$ct_rev
  fi

  if [ -n "$VAL_CONTAINER" ]; then
    printf 'container: %s   %s   running=%s restarts=%s started=%s   read-as=%s   MEASURED\n' \
      "$(short "$VAL_CONTAINER")" "$CONTAINER" "$ct_running" "${ct_restarts:-?}" "${ct_started:-?}" "${ct_elev:-none}"
  else
    printf 'container: UNREAD - %s\n' "$WHY_CONTAINER"
    INDETERMINATE=1
    note "the running-side reading was requested and could not be taken: $WHY_CONTAINER"
  fi
  [ -n "$ct_image" ] && printf '           image=%s\n' "$ct_image"
  if [ "$ct_running" = true ] && [ -n "$ct_restarts" ] && [ "$ct_restarts" != 0 ]; then
    printf '           WARNING: %s restart(s) recorded; it is running now, and it has not been running steadily\n' "$ct_restarts"
    note "$CONTAINER has restarted $ct_restarts time(s)"
  fi
  # The target this deploy path acts on, read off the RUNNING container rather
  # than inferred from the directory a command was launched in.
  [ -n "$ct_wd" ] && printf '           compose working_dir=%s\n' "$ct_wd"
  [ -n "$ct_cf" ] && printf '           compose config_files=%s\n' "$ct_cf"
  if [ -n "$ct_mounts" ]; then
    printf '           mounts (what this container actually reads from):\n'
    printf '%s\n' "$ct_mounts" | while IFS= read -r m; do
      [ -n "$m" ] && printf '             %s\n' "$m"
    done
  else
    printf '           mounts: none reported\n'
  fi
else
  printf 'container: NOT REQUESTED - no --container given\n'
fi

# --- served bytes: MEASURED, resolved against blobs FROM THE RECORD ---------
if [ "$REQ_SERVED" -eq 1 ]; then
  sv_out=$(read_host served "$SERVES" "$TIMEOUT")
  sv_err=$(field "$sv_out" error)
  sv_http=$(field "$sv_out" http)
  sv_sha=$(field "$sv_out" sha256)
  sv_bytes=$(field "$sv_out" bytes)

  if [ -n "$sv_err" ]; then
    WHY_SERVED=$sv_err
  else
    case "$sv_http" in
      2??) : ;;
      *) WHY_SERVED="$SERVES answered HTTP ${sv_http:-<none>}, so the bytes it returned are not the served file" ;;
    esac
    if [ -z "$WHY_SERVED" ] && { [ -z "$sv_sha" ] || [ -z "$sv_bytes" ]; }; then
      WHY_SERVED="the fetch of $SERVES returned no bytes to hash"
    fi
    # A zero-byte body hashes to the well-defined digest of no input, and so
    # does every commit at which the probe path does not exist. Comparing it
    # would report a MATCH for a commit that never held the file.
    if [ -z "$WHY_SERVED" ] && [ "$sv_bytes" = 0 ]; then
      WHY_SERVED="$SERVES answered HTTP $sv_http with a zero-byte body, so there are no served bytes to compare against any commit"
    fi
  fi

  if [ -z "$WHY_SERVED" ]; then
    if ! git -C "$CLONE" rev-parse --git-dir >/dev/null 2>&1; then
      WHY_SERVED="--clone $CLONE is not a git repository, so no candidate blob could be read"
    elif [ -z "$HASH_KIND" ]; then
      WHY_SERVED="neither sha256sum nor shasum is available here, so no candidate blob could be hashed"
    fi
  fi

  if [ -z "$WHY_SERVED" ]; then
    # Deduplicate first. An unchanged source head and checkout head are ONE
    # candidate, and printing it twice would manufacture a tie out of a single
    # commit.
    raw=()
    [ -n "$VAL_SOURCE" ] && raw+=("$VAL_SOURCE")
    [ -n "$VAL_CHECKOUT" ] && raw+=("$VAL_CHECKOUT")
    [ "${#CANDIDATES[@]}" -gt 0 ] && raw+=("${CANDIDATES[@]}")

    resolved=()
    for c in ${raw[@]+"${raw[@]}"}; do
      full=$(git -C "$CLONE" rev-parse --verify --quiet "$c^{commit}" 2>/dev/null || true)
      if [ -z "$full" ]; then
        printf 'served:    candidate %s is absent from the local clone and was not compared\n' "$(short "$c")"
        continue
      fi
      dup=0
      for seen in ${resolved[@]+"${resolved[@]}"}; do
        [ "$seen" = "$full" ] && dup=1 && break
      done
      [ "$dup" -eq 0 ] && resolved+=("$full")
    done

    if [ "${#resolved[@]}" -eq 0 ]; then
      # Nothing was compared. Reporting that as "no candidate matches" would
      # read as a measured disagreement with the repository, which is the very
      # conflation the four verdicts exist to remove.
      WHY_SERVED="no candidate commit was available to compare the bytes $SERVES serves against; pass --candidate, or a --source-remote or --checkout that resolves"
    else
      matches=()
      compared=0
      for c in ${resolved[@]+"${resolved[@]}"}; do
        # cat-file's own status says whether the path exists at that commit. An
        # empty hash cannot: sha256 of no input is a well-defined digest, so
        # inferring absence from it hands every commit missing the file the same
        # digest an empty response body has.
        if ! blob=$(git -C "$CLONE" cat-file blob "$c:$SERVES_PATH" 2>/dev/null | hash_stdin
          exit "${PIPESTATUS[0]}"); then
          printf 'served:    candidate %s   %s is absent at that commit\n' "$(short "$c")" "$SERVES_PATH"
          continue
        fi
        compared=$((compared + 1))
        if [ "$blob" = "$sv_sha" ]; then
          printf 'served:    candidate %s   MATCH\n' "$(short "$c")"
          matches+=("$c")
        else
          printf 'served:    candidate %s   differs\n' "$(short "$c")"
        fi
      done

      if [ "${#matches[@]}" -eq 1 ]; then
        VAL_SERVED=${matches[0]}
      elif [ "$compared" -eq 0 ]; then
        # Candidates existed and not one blob was opened, so nothing was
        # compared. That is a third state, and it must not borrow the wording of
        # either the empty candidate set above or a measured no-match below: an
        # operator who mistyped --serves-path would otherwise read this as the
        # repository disagreeing with the host.
        WHY_SERVED="$SERVES_PATH exists at no candidate commit, so the bytes $SERVES serves were compared against nothing"
      elif [ "${#matches[@]}" -eq 0 ]; then
        WHY_SERVED="no candidate commit's $SERVES_PATH matches the bytes $SERVES serves"
      else
        # A reading that cannot discriminate must not produce a definite answer.
        # Taking the last match here is how a clean AGREE gets reported for a
        # host that could equally be running any of the tied commits.
        tied=
        for c in "${matches[@]}"; do tied="$tied $(short "$c")"; done
        WHY_SERVED="AMBIGUOUS: $SERVES_PATH is byte-identical at${tied}, so the served bytes cannot tell those commits apart"
      fi
    fi
  fi

  if [ -n "$VAL_SERVED" ]; then
    printf 'served:    %s   %s   sha256=%s bytes=%s   MEASURED, resolved against blobs FROM THE RECORD\n' \
      "$(short "$VAL_SERVED")" "$SERVES" "$(short "$sv_sha")" "${sv_bytes:-?}"
  else
    printf 'served:    UNREAD - %s\n' "$WHY_SERVED"
    INDETERMINATE=1
    note "the served-bytes reading was requested and could not be taken: $WHY_SERVED"
  fi
  # The container's own revision label is deliberately kept out of the candidate
  # pool: letting one reading nominate the commit a second reading then confirms
  # is a claim verifying itself, which is the fault this tool exists to catch.
  # Saying so out loud, resolved or not, is the tool's own rule turned on
  # itself - silence is what makes an unestablished reading look like agreement.
  if [ "$REQ_CONTAINER" -eq 1 ]; then
    printf '           the container revision was NOT a candidate for these bytes; pass it with --candidate to have it compared\n'
  fi
else
  printf 'served:    NOT REQUESTED - no --serves given\n'
fi

# --- comparisons ------------------------------------------------------------
COMPARED=0
DIFFERED=0

req_of() { eval "printf '%s' \"\$REQ_${1}\""; }
val_of() { eval "printf '%s' \"\$VAL_${1}\""; }
flag_of() {
  case "$1" in
    SOURCE) printf -- '--source-remote' ;;
    CHECKOUT) printf -- '--checkout' ;;
    CONTAINER) printf -- '--container' ;;
    SERVED) printf -- '--serves' ;;
  esac
}
label_of() {
  case "$1" in
    SOURCE) printf 'source' ;;
    CHECKOUT) printf 'checkout' ;;
    CONTAINER) printf 'container' ;;
    SERVED) printf 'served' ;;
  esac
}

printf '\ncomparisons\n'
compare() {
  local a=$1 b=$2 la lb pad
  la=$(label_of "$a"); lb=$(label_of "$b")
  pad=$(printf '%-9s vs %-9s' "$la" "$lb")
  if [ "$(req_of "$a")" -eq 0 ] || [ "$(req_of "$b")" -eq 0 ]; then
    local missing=
    [ "$(req_of "$a")" -eq 0 ] && missing="$(flag_of "$a")"
    [ "$(req_of "$b")" -eq 0 ] && missing="${missing:+$missing or }$(flag_of "$b")"
    printf '  %s  NOT COMPARED - no %s given, so this run ordered no such reading\n' "$pad" "$missing"
    return
  fi
  if [ -z "$(val_of "$a")" ] || [ -z "$(val_of "$b")" ]; then
    local unread=
    [ -z "$(val_of "$a")" ] && unread="$la"
    [ -z "$(val_of "$b")" ] && unread="${unread:+$unread and }$lb"
    printf '  %s  NOT COMPARED - %s was requested and could not be read\n' "$pad" "$unread"
    return
  fi
  COMPARED=$((COMPARED + 1))
  if [ "$(val_of "$a")" = "$(val_of "$b")" ]; then
    printf '  %s  AGREE %s\n' "$pad" "$(short "$(val_of "$a")")"
  else
    DIFFERED=$((DIFFERED + 1))
    printf '  %s  DIFFER %s vs %s\n' "$pad" "$(short "$(val_of "$a")")" "$(short "$(val_of "$b")")"
  fi
}

compare SOURCE CHECKOUT
compare SOURCE CONTAINER
compare SOURCE SERVED
compare CHECKOUT CONTAINER
compare CHECKOUT SERVED
compare CONTAINER SERVED

if [ "${#NOTES[@]}" -gt 0 ]; then
  printf '\nstated out loud\n'
  for n in "${NOTES[@]}"; do printf '  - %s\n' "$n"; done
fi

printf '\n'
if [ "$DIFFERED" -gt 0 ]; then
  if [ "$INDETERMINATE" -eq 1 ]; then
    printf 'verdict: DRIFT - %s of %s compared pair(s) disagree, and a requested reading could not be taken, so what disagrees may not be all of it\n' \
      "$DIFFERED" "$COMPARED"
  else
    printf 'verdict: DRIFT - %s of %s compared pair(s) disagree; the host is not running what this run expected\n' \
      "$DIFFERED" "$COMPARED"
  fi
  exit 2
fi
if [ "$INDETERMINATE" -eq 1 ]; then
  printf 'verdict: INDETERMINATE - a requested reading could not be taken; nothing here says the host is current\n'
  exit 3
fi
if [ "$COMPARED" -eq 0 ]; then
  # Distinct from INDETERMINATE on purpose. Every reading this run asked for
  # succeeded, and it still established nothing, because no two of them could be
  # held against each other. Collapsing this into the indeterminate message
  # tells the operator a reading failed when none did.
  printf 'verdict: NOTHING CHECKED - every requested reading was taken, and no comparison had both sides read, so this run establishes nothing about the host\n'
  exit 4
fi
printf 'verdict: AGREE - every requested reading was taken and all %s comparison(s) with both sides read agree\n' "$COMPARED"
exit 0
