#!/usr/bin/env bash
# fm-bounded-lib.sh - Run an external program under a deadline that holds on
# every seat this fleet runs on.
#
# Running an external program with a deadline is not one command on every seat
# this fleet runs on. GNU `timeout` is the ordinary answer; a Darwin seat without
# coreutils has neither `timeout` nor `gtimeout`, and a two-branch form that
# falls back to running the command bare is not bounded at all - it is bounded on
# Linux and unbounded exactly where the fallback was supposed to matter. So the
# last rung is perl's own alarm, which needs nothing installed.
#
# This lives in one file because a second copy of the ladder is a copy that
# drifts: the watcher grew the three rungs for its checks, and bin/fm-teardown.sh
# then needed the identical deadline around bin/fm-pr-poll.sh, which is the same
# program the watcher bounds. One owner, two callers.
#
# FM_CHECK_FORCE_FALLBACK=1 skips both binaries and takes the perl rung, so a
# test can exercise the fallback on a seat that does have them.

# Run "$@" under a deadline of <seconds>. stdout is the caller's to capture and
# stderr is discarded. The exit status is the command's OWN status, and a
# deadline that fires reports 124 like `timeout` does - so a caller that must
# tell "could not run" apart from "ran and answered" can read it, and a caller
# that discards it is unaffected.
fm_run_bounded() {  # <seconds> <command> [args...]
  local secs=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@" 2>/dev/null
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@" 2>/dev/null
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$secs" "$@" 2>/dev/null
  fi
}
