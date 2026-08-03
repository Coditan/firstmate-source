#!/usr/bin/env bash
# shellcheck shell=bash
# fm-blocker-class-lib.sh - one owner for "is a blocked-by target a real record".
#
# Usage: . bin/fm-blocker-class-lib.sh   then splice "$FM_BLOCKER_CLASS_JQ" ahead
# of a jq program string, e.g.  jq -n "$FM_BLOCKER_CLASS_JQ"'<program>'.
#
# A backlog dependency is recorded two ways that can silently diverge: the
# structured blocked_by edge tasks-axi reads, and the free-text "blocked-by:<id>"
# token fm-fleet-snapshot parses into blocked_by_ids and unresolved_blocker_ids.
# When the target id exists nowhere - never created, renamed, or mistyped -
# tasks-axi drops the edge (so `tasks-axi ready` lists the item) while the parsed
# token dangles forever and the status snapshots gate the item silently.
# fm-backlog-lint already names that a dangling BACKLOG_STALE finding; this def is
# the single predicate every reader uses so the snapshots agree with the lint on
# what "the target exists" means, instead of each script re-deciding it.
#
# fm_blocker_is_real($id; $live; $archive) is true when a structured record with
# that id is present in the live backlog OR the done archive. Both arguments are
# presence maps keyed by id whose values are any non-null token (the snapshots
# pass {id:true}; the lint passes its id->state and id->true maps directly), so
# absence is a null lookup and dangling is the sole way the predicate is false.
#
# fm_dangling_blockers($blocked_by_ids; $live; $archive) is the ids from that list
# whose target is not real - the integrity finding the snapshots surface instead
# of gating on.
# The value is a jq program fragment: the $-names are jq bindings, never shell.
# shellcheck disable=SC2016
FM_BLOCKER_CLASS_JQ='
  def fm_blocker_is_real($id; $live; $archive):
    (($live[$id]) != null) or (($archive[$id]) != null);
  def fm_dangling_blockers($ids; $live; $archive):
    [ ($ids // [])[] | select(fm_blocker_is_real(.; $live; $archive) | not) ];
'
export FM_BLOCKER_CLASS_JQ
