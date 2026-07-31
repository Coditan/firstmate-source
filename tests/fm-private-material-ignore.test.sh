#!/usr/bin/env bash
# Regression tests for the captain-private material declared in AGENTS.md
# section 2. The rule under test is not "these particular files are ignored" but
# "a private file nobody has thought of yet is ignored by default": an ignore
# list that enumerates private config files one at a time fails open for every
# file added after it was last edited, which is how config/telegram.env came to
# hold a live bot token with no rule covering it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-private-material-ignore

# Names chosen so no enumerating list could contain them: a rule that matches
# these has to be a directory- or prefix-wide one.
UNFORESEEN="unforeseen-$$-$(basename "$TMP_ROOT")"

# Every path form AGENTS.md section 2 declares captain-private, each expressed as
# a file the ignore rules cannot have been written with in mind.
unforeseen_private_paths() {
  cat <<PATHS
config/telegram.env
config/fm-tg-recv.sh
config/$UNFORESEEN
config/$UNFORESEEN.env
config/$UNFORESEEN-subsystem/credentials.json
.env
.env.$UNFORESEEN
data/$UNFORESEEN.md
state/$UNFORESEEN.meta
projects/$UNFORESEEN/README.md
.no-mistakes/$UNFORESEEN.json
graphify-out/$UNFORESEEN.json
.local/axi/bin/$UNFORESEEN
PATHS
}

# The shared tracked surface AGENTS.md section 1 names. Every other assertion in
# this file proves the private rules are broad ENOUGH; without this list a
# .gitignore of just "*" would pass them all, so this is the direction that
# catches a widening which swallows the repository itself.
shared_tracked_surface() {
  cat <<'PATHS'
AGENTS.md
README.md
CONTRIBUTING.md
.tasks.toml
bin/
roles/
.agents/skills/
skills/
.github/workflows/
tests/
PATHS
}

# The shared rule has to be the one doing the ignoring: check-ignore succeeds for
# a clone-private .git/info/exclude or a developer's global core.excludesFile
# too, and those are exactly the sources a fresh vessel does not inherit. This
# checkout carries such a private exclude for config/, so asserting on the match
# source is what keeps this test honest here.
assert_ignored_by_tracked_gitignore() {
  local repo=$1 path=$2 match
  match=$(git -C "$repo" check-ignore -v --no-index -- "$path") \
    || fail "captain-private path has no shared ignore rule: $path"
  case "$match" in
    .gitignore:*) ;;
    *) fail "captain-private path is ignored by a private or global exclude, not the tracked .gitignore: $match" ;;
  esac
}

# A fresh clone that carries only the tracked .gitignore, so no private exclude
# from this checkout can mask a missing shared rule.
seed_fresh_clone() {
  local seed=$1 clone=$2
  mkdir -p "$seed" || fail "could not create the seed checkout under $TMP_ROOT"
  cp "$ROOT/.gitignore" "$seed/.gitignore" \
    || fail "could not seed .gitignore: is $ROOT/.gitignore still the tracked ignore file?"
  fm_git_identity
  git -C "$seed" init -q || fail "could not init the seed repository at $seed"
  git -C "$seed" add --force .gitignore || fail "could not stage .gitignore in $seed"
  git -C "$seed" commit -qm baseline || fail "could not commit the seed baseline in $seed"
  git clone --quiet "$seed" "$clone" || fail "could not clone $seed into $clone"
}

test_unforeseen_private_files_are_ignored_by_default() {
  local clone path status
  clone="$TMP_ROOT/fresh-clone"
  seed_fresh_clone "$TMP_ROOT/seed" "$clone"

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    mkdir -p "$(dirname "$clone/$path")" || fail "could not create the fixture parent for $path"
    : > "$clone/$path" || fail "could not create the private fixture $path"
    assert_ignored_by_tracked_gitignore "$clone" "$path"
  done < <(unforeseen_private_paths)

  status=$(git -C "$clone" status --porcelain --untracked-files=all) \
    || fail "could not read the fresh clone status at $clone"
  [ -z "$status" ] \
    || fail "captain-private files show up as untracked and can be staged by git add -A: $status"
  pass "private files invented after the ignore rules were written are still ignored"
}

# The wholesale config rule must stay in the form that permits re-inclusion
# (config/* rather than config/), because git cannot re-include a file whose
# parent directory is excluded. Nothing under config/ is tracked today; this
# proves the escape hatch exists for the day something must be.
test_a_config_file_can_still_be_deliberately_tracked() {
  local clone path
  clone="$TMP_ROOT/negation-clone"
  path="config/shared-example.toml"
  seed_fresh_clone "$TMP_ROOT/negation-seed" "$clone"

  printf '!%s\n' "$path" >> "$clone/.gitignore" \
    || fail "could not append the negation rule in $clone"
  mkdir -p "$clone/config" || fail "could not create config/ in $clone"
  : > "$clone/$path" || fail "could not create the negation fixture $path"

  ! git -C "$clone" check-ignore -q --no-index -- "$path" \
    || fail "the config ignore rule cannot be overridden by an explicit negation: a genuinely shared config file could never be tracked"
  pass "an explicit negation can still re-include a config file that must be shared"
}

test_no_captain_private_material_is_tracked() {
  local tracked
  tracked=$(git -C "$ROOT" ls-files -- \
    config/ data/ state/ projects/ .no-mistakes/ graphify-out/ .env .local/) \
    || fail "could not query the tracked file list in $ROOT"
  [ -z "$tracked" ] \
    || fail "captain-private material is tracked in the shared template: $tracked"
  pass "no captain-private material has ever been committed"
}

test_the_shared_tracked_surface_stays_visible_to_git_add() {
  local clone path hidden
  clone="$TMP_ROOT/breadth-clone"
  seed_fresh_clone "$TMP_ROOT/breadth-seed" "$clone"

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -n "$(git -C "$ROOT" ls-files -- "$path")" ] \
      || fail "fixture is broken: the shared surface $path is not tracked in $ROOT"
    ! git -C "$clone" check-ignore -q --no-index -- "$path" \
      || fail "the shared ignore is too broad and hides the tracked shared surface $path from git add"
  done < <(shared_tracked_surface)

  hidden=$(git -C "$ROOT" ls-files \
    | git -C "$clone" check-ignore --stdin --no-index || true) \
    || fail "could not test the tracked file list against the shared ignore"
  [ -z "$hidden" ] \
    || fail "the shared ignore hides tracked files from git add: $hidden"
  pass "no tracked file is swallowed by the captain-private ignore rules"
}

test_unforeseen_private_files_are_ignored_by_default
test_a_config_file_can_still_be_deliberately_tracked
test_no_captain_private_material_is_tracked
test_the_shared_tracked_surface_stays_visible_to_git_add

echo "# all fm-private-material-ignore tests passed"
