#!/usr/bin/env bash
# Shared owner of bounded child execution.
#
# Every timed read in this tree runs through run_bounded_process, so the
# fallback's signal hardening - the same handler on ALRM and on HUP/INT/TERM,
# tearing the child's process group down instead of orphaning it - can never be
# half-present in a second copy. The function execs, so callers that need to
# keep running invoke it inside a subshell.
#
# FM_CHECK_OWNED_GROUP=1 keeps the child in the caller's own process group for a
# caller that already owns and tears down that group; the default gives the
# child its own. FM_CHECK_FORCE_FALLBACK=1 selects the perl path even where
# timeout or gtimeout exists, so the fallback stays testable everywhere.

run_bounded_process() {  # <timeout-seconds> <command> [args...]
  local t=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$t" "$@"
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$t" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$t" "${FM_CHECK_OWNED_GROUP:-0}" "$@"
  fi
}
