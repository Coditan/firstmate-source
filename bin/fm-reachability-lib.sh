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
# THE RULE. Claiming MORE reach than is currently held requires ESTABLISHED
# evidence - probed by this run, or carried from a run that probed it. Lowering
# the claim, or restating it unchanged, passes freely, because a run may always
# report less than it found.
#
# A run therefore begins at untested, holding nothing. That matters more than it
# looks: an earlier version of this rule began at the top of the scale instead,
# so the first write of every run was a lowering and the refusal never fired at
# all. Starting from nothing is what makes the gate live on the very first
# verdict - a resolver that opened with `tailnet assumed` would be refused and
# would emit untested, which is the honest answer for a run that has looked at
# nothing.
#
# A refusal returns 1 and changes NOTHING, so a caller that ignores the status
# still cannot end up with half a resolution - the verdict and its evidence move
# together or not at all. Callers that pair the verdict with other fields (an
# address to bind, a name to link) must therefore act on the status, because
# those fields are not this library's to keep consistent.
#
# Functions (source this file; it defines only fm_*reachability* names):
#   fm_reachability_rank <verdict>            how much reach it claims
#   fm_reachability_init                      begin a run holding nothing
#   fm_set_reachability <verdict> <evidence>  0 when set, 1 when refused
#
# It reads and writes two globals the caller may read but must not assign:
# REACHABILITY and REACHABILITY_EVIDENCE.

fm_reachability_rank() {
  case "${1:-}" in
    tailnet) printf '3\n' ;;
    tailnet-proxied) printf '2\n' ;;
    loopback) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

# Nothing looked at, nothing claimed. Every real verdict has to be established
# to get above this, which is the whole point of starting here.
fm_reachability_init() {
  REACHABILITY=untested
  REACHABILITY_EVIDENCE=none
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
