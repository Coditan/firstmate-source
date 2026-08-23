#!/usr/bin/env bash
# tests/fm-landing-remote-lib.test.sh - unit tests for the shared recognition of
# which remote may be cited as proof that work left this machine
# (bin/fm-landing-remote-lib.sh).
#
# bin/fm-teardown.sh and bin/fm-project-remove.sh both build on these predicates
# and both prove the end-to-end behavior in their own suites. What is covered
# HERE is what neither reaches from the outside: URL shapes, a relocated NM_HOME,
# and the ref-selector rule that decides whether a remote name may be used as a
# glob at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-landing-remote-lib.sh
. "$ROOT/bin/fm-landing-remote-lib.sh"

# --- the pipeline's own mirror ------------------------------------------------

for url in \
  /home/agent/.no-mistakes/repos/6e487fc7bf03.git \
  /home/agent/.no-mistakes/repos/6e487fc7bf03 \
  /srv/seats/two/.no-mistakes/repos/abc.git
do
  url_is_pipeline_mirror "$url" || fail "pipeline mirror not recognized: $url"
done
pass "the pipeline's default repos path is recognized as its own mirror, with or without .git"

for url in \
  git@github.com:Coditan/firstmate-source.git \
  https://github.com/Coditan/firstmate-source \
  /home/agent/forks/firstmate.git \
  https://forge.internal/team/proj.git
do
  ! url_is_pipeline_mirror "$url" || fail "a real remote was mistaken for the pipeline mirror: $url"
done
pass "an ordinary remote - forge, fork, or self-hosted - is not mistaken for the pipeline mirror"

# An install that relocated its state: the path shape no longer gives it away,
# and NM_HOME is the only thing that names it.
! url_is_pipeline_mirror /opt/nm-elsewhere/repos/abc.git \
  || fail "a relocated mirror was recognized without NM_HOME, so NM_HOME proves nothing here"
NM_HOME=/opt/nm-elsewhere url_is_pipeline_mirror /opt/nm-elsewhere/repos/abc.git \
  || fail "a relocated mirror named by NM_HOME was not recognized"
NM_HOME=/opt/nm-elsewhere/ url_is_pipeline_mirror /opt/nm-elsewhere/repos/abc.git \
  || fail "a trailing slash on NM_HOME defeated the relocated-mirror recognition"
NM_HOME=/opt/nm-elsewhere url_is_pipeline_mirror /opt/other/repos/abc.git \
  && fail "NM_HOME matched a path outside the relocated state directory"
pass "a relocated mirror is recognized through NM_HOME, and only inside the directory NM_HOME names"

# --- comparing two remote URLs ------------------------------------------------

[ "$(normalized_remote_url https://example.invalid/a/b.git)" = "https://example.invalid/a/b" ] \
  || fail "a trailing .git was not stripped"
[ "$(normalized_remote_url https://example.invalid/a/b/)" = "https://example.invalid/a/b" ] \
  || fail "a trailing slash was not stripped"
[ "$(normalized_remote_url https://example.invalid/a/b.git/)" = "https://example.invalid/a/b" ] \
  || fail "a trailing .git behind a slash was not stripped"
[ "$(normalized_remote_url https://example.invalid/a/b)" = "https://example.invalid/a/b" ] \
  || fail "a bare URL was altered"
pass "two remote URLs that name the same repository normalize to the same string"

# --- names that may serve as a ref selector -----------------------------------

for name in origin fork upstream no-mistakes my.remote seat_2; do
  remote_name_selects_refs "$name" || fail "an ordinary remote name was rejected: $name"
done
pass "an ordinary remote name may be used as a ref selector"

# A glob metacharacter in a remote name would select refs the remote does not
# own, so the name is rejected and its caller reports it rather than counting it.
for name in 'orig*' 'a?b' 'a[bc]' 'a b' '' 'a/b'; do
  ! remote_name_selects_refs "$name" \
    || fail "a name that cannot safely select refs was accepted: '$name'"
done
pass "a remote name carrying glob metacharacters, a space, a slash, or nothing at all is rejected"
