#!/usr/bin/env bash
# The one owner of a service's reachability verdict and of how that verdict was
# established.
#
# It exists because three separate review rounds found three different paths
# asserting the flattering answer on evidence that did not support it: one
# claimed proxy reach from tailscaled merely being up, one restated a run's own
# choice as a host fact, and one asserted no-reach where nothing had been
# tested. Each was fixed where it was found, and the next round found the next
# one. So the verdict stopped being a bare value: it is now a value plus its
# backing, and one function is the only thing that may set either.
#
# The vocabulary is documented for consumers in bin/fm-service-port.sh's header,
# which owns the emitted record contract; this file owns the rule.
#
# Verdicts, ordered by how much reach they claim:
#
#   tailnet          rank 3, this node's own address, bound directly
#   tailnet-proxied  rank 2, reached over that address through a serve route
#   loopback         rank 1, tested and there is no reach off this machine
#   untested         rank 0, nothing established either way
#
# Evidence:
#
#   probed   this run tested the claim itself.
#   carried  restated from the resolution a previous allocation recorded, which
#            some earlier run did test.
#   assumed  inferred from signals that do not test it, such as tailscaled being
#            up, or a run with no port to test with.
#   none     nothing was established at all.
#
# TWO RULES, and between them a run can only ever say what it has earned.
#
#   1. Claiming MORE reach than is currently held requires ESTABLISHED evidence,
#      probed by this run or carried from a run that probed it. Lowering the
#      claim, or restating it unchanged, passes freely, because a run may always
#      report less than it found.
#   2. A verdict a test has RULED OUT may never be claimed again, on any
#      evidence at all. Ruling one out is itself a measurement - a bind that
#      fails EADDRNOTAVAIL rules out binding that address - and a second-hand
#      record cannot overturn a test this run performed.
#
# A run begins at untested, holding nothing and having ruled nothing out. That
# matters more than it looks: an earlier version of this rule began at the top
# of the scale instead, so the first write of every run was a lowering and the
# refusal never fired at all.
#
# The two rules together are what let the caller stop hand-filtering. A run on a
# node whose address it has just PROVED unbindable can read a record that says
# `tailnet` and hand it straight to this door, because rule 2 refuses it; the
# caller does not have to remember which recorded values are still credible.
#
# A refusal returns 1 and changes NOTHING, so the verdict and its evidence move
# together or not at all. Callers that pair the verdict with other fields (an
# address to bind, a name to link) must still ACT on the status, because those
# fields are not this library's to keep consistent: a caller that ignores a
# refusal and rewrites its bind address anyway emits a record whose two halves
# disagree.
#
# Functions (source this file; it defines only fm_*reachability* names):
#   fm_reachability_rank <verdict>            how much reach it claims
#   fm_reachability_init                      begin a run holding nothing
#   fm_reachability_rule_out <verdict>        a test showed it is unachievable
#   fm_set_reachability <verdict> <evidence>  0 when set, 1 when refused,
#                                             2 when the vocabulary is wrong
#
# It reads and writes three globals the caller may read but must not assign:
# REACHABILITY, REACHABILITY_EVIDENCE and REACHABILITY_CEILING.

fm_reachability_rank() {
  case "${1:-}" in
    tailnet) printf '3\n' ;;
    tailnet-proxied) printf '2\n' ;;
    loopback) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

# Nothing looked at, nothing claimed, nothing ruled out.
fm_reachability_init() {
  REACHABILITY=untested
  REACHABILITY_EVIDENCE=none
  REACHABILITY_CEILING=3
}

# This run tested something and the named verdict cannot be true. Everything at
# or above its rank is barred from here on, and the bar only ever tightens.
#
# A verdict already held that the new bar contradicts falls back to untested
# rather than standing: the run has just learned its own held answer is false,
# and keeping it would leave the library asserting something it now bars.
fm_reachability_rule_out() {
  local barred
  barred=$(fm_reachability_rank "${1:-}")
  barred=$((barred - 1))
  [ "$barred" -lt "${REACHABILITY_CEILING:-3}" ] && REACHABILITY_CEILING=$barred
  if [ "$(fm_reachability_rank "${REACHABILITY:-untested}")" -gt "$REACHABILITY_CEILING" ]; then
    REACHABILITY=untested
    REACHABILITY_EVIDENCE=none
  fi
  return 0
}

fm_set_reachability() {
  local to=${1:-} evidence=${2:-} rank
  case "$to" in
    tailnet|tailnet-proxied|loopback|untested) ;;
    *)
      printf 'fm_set_reachability: unknown reachability %s\n' "${to:-(empty)}" >&2
      return 2
      ;;
  esac
  case "$evidence" in
    probed|carried|assumed|none) ;;
    *)
      printf 'fm_set_reachability: unknown evidence %s\n' "${evidence:-(empty)}" >&2
      return 2
      ;;
  esac
  rank=$(fm_reachability_rank "$to")
  [ "$rank" -le "${REACHABILITY_CEILING:-3}" ] || return 1
  case "$evidence" in
    probed|carried) ;;
    *) [ "$rank" -le "$(fm_reachability_rank "${REACHABILITY:-untested}")" ] || return 1 ;;
  esac
  # shellcheck disable=SC2034
  REACHABILITY=$to
  # shellcheck disable=SC2034
  REACHABILITY_EVIDENCE=$evidence
  return 0
}
