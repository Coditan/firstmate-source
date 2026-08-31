#!/usr/bin/env bash
# shellcheck shell=bash
# fm-captain-actionable-lib.sh - one owner of "is this record asking the captain",
# and of the disclosure that says which captain holds it did not return.
#
# Usage: . bin/fm-captain-actionable-lib.sh   then splice "$FM_CAPTAIN_ACTIONABLE_JQ"
# ahead of a jq program string, e.g.  jq -n "$FM_CAPTAIN_ACTIONABLE_JQ"'<program>'.
#
# WHY THE PREDICATE LIVES IN ITS OWN FILE
# This one expression decides what reaches every reader that asks what is waiting
# on the captain, up to and including the board he is asked to answer on. It has
# now produced false invisibility three times, each time because one clause of it
# looked obviously right and nobody re-read it:
#   - 2026-08-09: requiring BOTH hold fields made every hold filed exactly as
#     AGENTS.md section 10 instructs invisible. Measured on the main home, 35
#     records carried `hold-kind: captain` and the surface returned 32.
#   - 2026-08-29: requiring `state == "queued"` withheld every captain hold on
#     work already under way - the MORE urgent half, because such a question did
#     not merely precede the work, it stopped it. Measured on the main home, 9
#     records carried `hold-kind: captain` outside Done and the surface returned
#     8; the missing one was a Commodore decision. On a second vessel the same
#     clause hid a record for nineteen days.
#   - Still open, deliberately not repaired here: a captain hold carrying an
#     unresolved blocker is withheld. That is separately filed. This file
#     DISCLOSES it rather than fixing it.
# Giving it a name and a single home is what makes the fourth instance findable
# before a reader has to go looking for it record by record.
#
# THE AUDIENCE IS THE HOLD KIND, NEVER THE RECORD KIND
# A record kind says what the work IS - ship, scout, fog - and `tasks-axi hold
# --kind captain` is what says the captain is the one being asked. `hold --kind`
# is a closed vocabulary (captain, external, load, parked, future), so admitting
# on it alone admits only records someone deliberately held for him.
#
# WHY STATE STILL APPEARS AT ALL
# Only to exclude terminal records. `section_state` in bin/fm-fleet-snapshot.sh
# normalizes the backlog to exactly three states - in_flight, queued, done - and
# `## Archived <date>` also normalizes to done, so `!= "done"` is the whole of
# "not terminal" in this schema. That is the spelling `answered_pending_close`
# already used two lines above the predicate it disagreed with; the two are one
# spelling now.
#
# WHY WITHHOLDING IS DISCLOSED RATHER THAN SILENT
# A count that is short and a count that is complete look identical. The
# nineteen-day record was not missed because the rule was indefensible, it was
# missed because a count of 2 looked whole and nothing beside it said what it was
# not counting. So every NON-TERMINAL record carrying `hold-kind: captain` either
# comes back on the surface or is named in the omitted projection with the reason
# it did not, and those two sets are exhaustive over that population by
# construction.
#
# THE DISCLOSED POPULATION IS THE CANDIDATE POPULATION, NOT EVERY CAPTAIN HOLD
# A Done record was never a candidate for this surface, so counting it as
# "withheld" made the disclosure announce a withholding that was not one - on the
# main home the only entry it ever produced was a closed, already-answered
# decision, and the number therefore did not mean "decisions you are not being
# shown". `fm_captain_candidate` is that population: held for the captain AND not
# terminal. Shown plus withheld is exhaustive over it, and the count is 0 exactly
# when nothing answerable is hidden.
#
# fm_captain_candidate($r) - a captain-kind hold that could have reached the
#   surface: the population the predicate selects from and the disclosure is
#   exhaustive over.
# fm_captain_actionable($r) - the predicate. Read the FINAL record, after any
#   caller-side blocker reclassification, so a caller that rewrites
#   unresolved_blocker_ids decides for itself whether to re-evaluate it.
# fm_captain_withheld_reason($r) - why a candidate captain-kind hold is not on the
#   surface.
#   Never null for such a record: an unforeseen shape returns "unclassified"
#   rather than falling out of the disclosure, because silently dropping a
#   withheld record is the exact failure this file exists against.
# fm_captain_returned($r) - what the surface ACTUALLY returned for this record:
#   the stored flag when the record carries one, the predicate otherwise. The
#   disclosure is built on this rather than on the predicate, so a caller that
#   reclassifies blockers without re-evaluating the flag still discloses exactly
#   the set it withheld instead of a set it computed a second way.
# fm_captain_actionable_omitted($records) - the disclosure, in the snapshot's
#   existing `omitted[]` shape ({surface,count}) with the reason and the ids that
#   make it answerable rather than merely countable.
# The value is a jq program fragment: the $-names are jq bindings, never shell,
# and the quotes inside it are jq string literals that must survive verbatim into
# the program text - which is exactly what SC2089/SC2090 warn about and exactly
# what is wanted here. Every caller splices this into a jq program string, never
# into a command line, so the array they recommend cannot express it.
# shellcheck disable=SC2016,SC2089
FM_CAPTAIN_ACTIONABLE_JQ='
  def fm_captain_held($r):
    ($r.structured == true) and ($r.hold_kind == "captain");
  def fm_captain_candidate($r):
    fm_captain_held($r) and ($r.state != "done");
  def fm_captain_actionable($r):
    fm_captain_candidate($r)
    and ($r.hold_reason != null)
    and ((($r.unresolved_blocker_ids // []) | length) == 0)
    and ((($r.answered_pending_close // false)) | not);
  def fm_captain_withheld_reason($r):
    if ($r.hold_reason == null) then "hold_reason_missing"
    elif (($r.answered_pending_close // false)) then "answered_pending_close"
    elif ((($r.unresolved_blocker_ids // []) | length) > 0) then "blocked_by_unresolved"
    elif ((($r.dangling_blocker_ids // []) | length) > 0) then "dangling_blocker_edge"
    else "unclassified" end;
  def fm_captain_returned($r):
    if ($r | has("captain_actionable")) then ($r.captain_actionable == true)
    else fm_captain_actionable($r) end;
  def fm_captain_actionable_omitted($records):
    [ $records[] | select(fm_captain_candidate(.) and (fm_captain_returned(.) | not)) ]
    | group_by(fm_captain_withheld_reason(.))
    | map({surface:"captain_actionable",
           reason:fm_captain_withheld_reason(.[0]),
           count:length,
           ids:[.[].id]});
'
# shellcheck disable=SC2090
export FM_CAPTAIN_ACTIONABLE_JQ
