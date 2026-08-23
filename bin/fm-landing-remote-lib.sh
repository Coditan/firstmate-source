#!/usr/bin/env bash
# fm-landing-remote-lib.sh - which remote may be cited as proof that work has
# left this machine, and which one only looks like one.
#
# `git`'s own answer to "is this commit on a remote" counts EVERY
# remote-tracking ref. The validation pipeline pushes every task branch into its
# own bare mirror under ~/.no-mistakes/repos/<id>.git (docs/merged-branch-cleanup.md
# section 3). That mirror is a remote by git's reckoning, never reaches the
# forge, and is invisible to gh - so work that got no further than the pipeline's
# own scratch reads as preserved, and whatever the caller was about to destroy
# gets destroyed.
#
# That defect was reproduced and fixed for bin/fm-teardown.sh on 2026-08-22, and
# the same reasoning was still standing untouched three feet away in
# bin/fm-project-remove.sh, which discards a whole project clone rather than one
# worktree. This library exists so the NEXT caller inherits the recognition
# instead of re-deriving it: one owner for "which URL is the pipeline's own
# mirror, and when do two remote URLs name the same repository".
#
# What it deliberately does NOT own is what a caller does about it. Teardown
# drops an unreadable remote's cached refs and refuses; removal keeps them,
# warns, and refuses or passes on the landed-work evidence instead, because a
# clone whose remote is gone is exactly the clone an operator is trying to
# remove. Those policies genuinely differ and each script states its own; only
# the recognition below is shared.
#
# This is a confused-worker check, like bin/fm-gate-refuse-lib.sh, not an
# adversarial one: a caller that deliberately adds a remote and pushes to it is
# outside what any of this establishes.
#
# Pure and side-effect free. `remote_effective_url` shells out to git but
# contacts no network.

# The URL a remote actually uses. `remote get-url` reports the configured string;
# `ls-remote --get-url` reports what git would really talk to, with
# url.<base>.insteadOf rewriting applied, and contacts nothing to say so.
remote_effective_url() {  # <repo dir> <remote name>
  git -C "$1" ls-remote --get-url "$2" 2>/dev/null
}

# Compare URLs by the repository they address rather than by how they were typed:
# a trailing slash and a trailing .git name the same place.
normalized_remote_url() {  # <url>
  local url=$1
  url=${url%/}
  url=${url%.git}
  url=${url%/}
  printf '%s' "$url"
}

# The validation pipeline's own scratch mirror, recognized the way
# bin/fm-gate-refuse-lib.sh recognizes a gate worktree: by the pipeline's own
# path contract, plus NM_HOME for an install that relocated its state. The path
# shape is the signal that survives a renamed remote.
url_is_pipeline_mirror() {  # <url>
  local url=$1 nm_repos
  case "$url" in
    */.no-mistakes/repos/*) return 0 ;;
  esac
  if [ -n "${NM_HOME:-}" ]; then
    nm_repos="${NM_HOME%/}/repos/"
    case "$url" in "$nm_repos"*) return 0 ;; esac
  fi
  return 1
}

# A remote name callers may use as a `--remotes=<glob>` or `refs/remotes/<glob>`
# ref selector. A name carrying glob metacharacters would select refs it does not
# own, so it is rejected rather than guessed at, and its caller reports it as
# left out rather than silently counting or silently dropping it.
remote_name_selects_refs() {  # <remote name>
  case "${1:-}" in
    '') return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}
