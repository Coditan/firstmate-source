#!/usr/bin/env bash
# Network-free behavior tests for the upstream firstmate update check.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-firstmate-update-check-tests

commit_file() {
  local repo=$1 path=$2 content=$3
  mkdir -p "$repo/$(dirname "$path")"
  printf '%s\n' "$content" > "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q -m "$content"
  git -C "$repo" rev-parse HEAD
}

run_check() {
  local repo=$1 state=$2 upstream=$3
  FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_STATE_OVERRIDE="$state" \
    FM_FIRSTMATE_COMPARE_REPO="$repo" FM_FIRSTMATE_UPSTREAM_HEAD="$upstream" \
    "$ROOT/bin/fm-firstmate-update-check.sh"
}

test_relevant_update_found_and_cleared_when_current() {
  local repo state current upstream out
  repo="$TMP_ROOT/relevant"
  state="$TMP_ROOT/relevant-state"
  fm_git_init_commit "$repo"
  current=$(commit_file "$repo" AGENTS.md local)
  git -C "$repo" branch upstream-fixture
  upstream=$(commit_file "$repo" bin/new-check.sh upstream)
  git -C "$repo" branch -f upstream-fixture "$upstream"
  git -C "$repo" reset -q --hard "$current"

  out=$(run_check "$repo" "$state" "$upstream")
  assert_contains "$out" 'FIRSTMATE_UPDATE_AVAILABLE:' "relevant upstream update was not reported"
  assert_grep 'FIRSTMATE_UPDATE_AVAILABLE:' "$state/firstmate-update.available" "available signal was not persisted"

  git -C "$repo" merge --ff-only -q upstream-fixture
  out=$(run_check "$repo" "$state" "$upstream")
  [ -z "$out" ] || fail "up-to-date check emitted a diagnostic: $out"
  [ ! -f "$state/firstmate-update.available" ] || fail "up-to-date check did not clear the available signal"
  pass "relevant upstream updates are signaled and an up-to-date deployment is silent"
}

test_installer_only_update_is_not_relevant() {
  local repo state current upstream out
  repo="$TMP_ROOT/installer-only"
  state="$TMP_ROOT/installer-only-state"
  fm_git_init_commit "$repo"
  current=$(commit_file "$repo" AGENTS.md local)
  upstream=$(commit_file "$repo" skills/example/SKILL.md installer-only)
  git -C "$repo" reset -q --hard "$current"

  out=$(run_check "$repo" "$state" "$upstream")
  [ -z "$out" ] || fail "installer-only update was treated as relevant: $out"
  [ ! -f "$state/firstmate-update.available" ] || fail "installer-only update persisted an available signal"
  pass "public installer-skill-only changes do not trigger a running-vessel update"
}

# Real fetch path (no FM_FIRSTMATE_COMPARE_REPO), so the resolved comparison
# base is actually the repository git reads from. Both sides are local paths, so
# these stay network-free.
run_fetching_check() {
  local repo=$1 state=$2 config=$3
  FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-firstmate-update-check.sh"
}

# A deployment clone plus a source repository holding one instruction-surface
# commit the deployment does not have.
make_deployment_and_source() {
  local name=$1 source deployment
  source="$TMP_ROOT/$name-source"
  deployment="$TMP_ROOT/$name-deployment"
  fm_git_init_commit "$source"
  git clone -q "$source" "$deployment"
  commit_file "$source" bin/new-check.sh source-only >/dev/null
}

test_configured_base_is_the_repository_compared() {
  local repo state config out
  make_deployment_and_source configured
  repo="$TMP_ROOT/configured-deployment"
  state="$TMP_ROOT/configured-state"
  config="$TMP_ROOT/configured-config"
  mkdir -p "$config"
  printf '%s\n' "$TMP_ROOT/configured-source" > "$config/firstmate-update-base"

  out=$(run_fetching_check "$repo" "$state" "$config")
  assert_contains "$out" 'FIRSTMATE_UPDATE_AVAILABLE:' "the configured comparison base was not compared against"
  [ ! -f "$state/firstmate-update.stuck" ] || fail "a usable configured base recorded a stuck diagnostic"
  pass "a configured update base is the repository actually compared"
}

test_environment_override_beats_the_configured_base() {
  local repo state config out
  make_deployment_and_source envwins
  repo="$TMP_ROOT/envwins-deployment"
  state="$TMP_ROOT/envwins-state"
  config="$TMP_ROOT/envwins-config"
  mkdir -p "$config"
  printf '%s\n' "$TMP_ROOT/envwins-absent-source" > "$config/firstmate-update-base"

  out=$(FM_FIRSTMATE_UPSTREAM_URL="$TMP_ROOT/envwins-source" \
    run_fetching_check "$repo" "$state" "$config")
  assert_contains "$out" 'FIRSTMATE_UPDATE_AVAILABLE:' "the environment override was not used as the comparison base"
  assert_not_contains "$out" 'FIRSTMATE_UPDATE_STUCK:' "the environment override did not beat the configured base"
  pass "an explicit environment base outranks the configured update base"
}

test_unusable_configured_base_refuses_loudly() {
  local repo state config out
  repo="$TMP_ROOT/badconfig"
  state="$TMP_ROOT/badconfig-state"
  config="$TMP_ROOT/badconfig-config"
  fm_git_init_commit "$repo"
  mkdir -p "$config"
  printf 'relative/path\n' > "$config/firstmate-update-base"

  out=$(run_fetching_check "$repo" "$state" "$config")
  assert_contains "$out" 'FIRSTMATE_UPDATE_STUCK: config/firstmate-update-base is unusable' \
    "an unusable configured base did not refuse loudly"
  assert_grep 'is unusable' "$state/firstmate-update.stuck" "the refusal was not persisted"
  [ ! -f "$state/firstmate-update.available" ] || fail "a refused check published an update signal"
  pass "an unusable configured update base refuses instead of comparing against the default"
}

# Direct coverage of the shared resolver both checks use, including the case a
# behavior test cannot reach without the network: an unconfigured home must
# still resolve the documented default.
test_resolver_precedence_and_default() {
  local config
  config="$TMP_ROOT/resolver-config"
  mkdir -p "$config"
  unset FM_FIRSTMATE_UPSTREAM_URL
  # shellcheck source=bin/fm-currency-base-lib.sh disable=SC1091
  . "$ROOT/bin/fm-currency-base-lib.sh"

  [ "$FM_CURRENCY_BASE_DEFAULT" = 'https://github.com/kunchenguid/firstmate.git' ] \
    || fail "the documented default base changed: $FM_CURRENCY_BASE_DEFAULT"

  fm_currency_base_resolve "$config" "$FM_CURRENCY_BASE_UPDATE_ITEM" \
    || fail "an absent config file refused instead of falling back"
  [ "$FM_CURRENCY_BASE_VALUE" = "$FM_CURRENCY_BASE_DEFAULT" ] \
    || fail "an absent config file did not resolve the default: $FM_CURRENCY_BASE_VALUE"

  printf 'https://example.invalid/fleet.git\n' > "$config/$FM_CURRENCY_BASE_UPDATE_ITEM"
  fm_currency_base_resolve "$config" "$FM_CURRENCY_BASE_UPDATE_ITEM" \
    || fail "a usable config file refused"
  [ "$FM_CURRENCY_BASE_VALUE" = 'https://example.invalid/fleet.git' ] \
    || fail "the config file was not used: $FM_CURRENCY_BASE_VALUE"

  FM_FIRSTMATE_UPSTREAM_URL='https://example.invalid/env.git'
  fm_currency_base_resolve "$config" "$FM_CURRENCY_BASE_UPDATE_ITEM" \
    || fail "an environment base refused"
  [ "$FM_CURRENCY_BASE_VALUE" = 'https://example.invalid/env.git' ] \
    || fail "the environment base did not win: $FM_CURRENCY_BASE_VALUE"
  unset FM_FIRSTMATE_UPSTREAM_URL

  # The two bases are independent, so a curator vessel can configure both.
  fm_currency_base_resolve "$config" "$FM_CURRENCY_BASE_FORK_ITEM" \
    || fail "the fork base refused while only the update base was configured"
  [ "$FM_CURRENCY_BASE_VALUE" = "$FM_CURRENCY_BASE_DEFAULT" ] \
    || fail "the update base leaked into the fork base: $FM_CURRENCY_BASE_VALUE"

  pass "the shared resolver applies environment, then config file, then the documented default"
}

test_resolver_rejects_unusable_values() {
  local config value
  config="$TMP_ROOT/reject-config"
  mkdir -p "$config"
  unset FM_FIRSTMATE_UPSTREAM_URL
  # shellcheck source=bin/fm-currency-base-lib.sh disable=SC1091
  . "$ROOT/bin/fm-currency-base-lib.sh"

  for value in '' '   ' '--upload-pack=evil' 'relative/path' 'not a url' 'plainword' \
    'relative/path:withcolon'; do
    printf '%s\n' "$value" > "$config/$FM_CURRENCY_BASE_UPDATE_ITEM"
    if fm_currency_base_resolve "$config" "$FM_CURRENCY_BASE_UPDATE_ITEM"; then
      fail "unusable base '$value' was accepted as $FM_CURRENCY_BASE_VALUE"
    fi
    [ -n "$FM_CURRENCY_BASE_REASON" ] || fail "unusable base '$value' produced no reason"
  done

  printf 'https://example.invalid/one.git\nhttps://example.invalid/two.git\n' \
    > "$config/$FM_CURRENCY_BASE_UPDATE_ITEM"
  fm_currency_base_resolve "$config" "$FM_CURRENCY_BASE_UPDATE_ITEM" \
    && fail "an ambiguous two-value file was accepted"

  for value in 'https://example.invalid/fleet.git' 'ssh://git@example.invalid/fleet.git' \
    'git@example.invalid:fleet.git' 'git@github.com:kunchenguid/firstmate.git' \
    'example.invalid:srv/fleet.git' 'git@example.invalid:/srv/fleet.git' \
    '/srv/fleet.git' 'file:///srv/fleet.git'; do
    printf '%s\n' "$value" > "$config/$FM_CURRENCY_BASE_UPDATE_ITEM"
    fm_currency_base_resolve "$config" "$FM_CURRENCY_BASE_UPDATE_ITEM" \
      || fail "usable base '$value' was refused: $FM_CURRENCY_BASE_REASON"
    [ "$FM_CURRENCY_BASE_VALUE" = "$value" ] \
      || fail "usable base '$value' resolved to $FM_CURRENCY_BASE_VALUE"
  done

  pass "the shared resolver refuses unusable bases with a reason and accepts git's remote spellings"
}

# A configured item that exists but cannot be read is an operator intent this
# resolver cannot honour, so it must refuse rather than resolve the default.
test_resolver_refuses_present_but_unusable_file() {
  local config dangling
  config="$TMP_ROOT/unusable-file-config"
  mkdir -p "$config"
  unset FM_FIRSTMATE_UPSTREAM_URL
  # shellcheck source=bin/fm-currency-base-lib.sh disable=SC1091
  . "$ROOT/bin/fm-currency-base-lib.sh"

  mkdir -p "$config/$FM_CURRENCY_BASE_UPDATE_ITEM"
  if fm_currency_base_resolve "$config" "$FM_CURRENCY_BASE_UPDATE_ITEM"; then
    fail "a directory in place of the config file resolved $FM_CURRENCY_BASE_VALUE"
  fi
  [ "$FM_CURRENCY_BASE_VALUE" != "$FM_CURRENCY_BASE_DEFAULT" ] \
    || fail "a directory in place of the config file silently fell back to the default"
  assert_contains "$FM_CURRENCY_BASE_REASON" 'not a regular file' \
    "a directory config path gave the wrong reason"
  rmdir "$config/$FM_CURRENCY_BASE_UPDATE_ITEM"

  dangling="$TMP_ROOT/unusable-file-config-missing-target"
  ln -s "$dangling" "$config/$FM_CURRENCY_BASE_UPDATE_ITEM"
  if fm_currency_base_resolve "$config" "$FM_CURRENCY_BASE_UPDATE_ITEM"; then
    fail "a dangling symlink resolved $FM_CURRENCY_BASE_VALUE"
  fi
  [ -n "$FM_CURRENCY_BASE_REASON" ] || fail "a dangling symlink produced no reason"
  rm -f "$config/$FM_CURRENCY_BASE_UPDATE_ITEM"

  printf 'https://example.invalid/fleet.git\n' > "$config/$FM_CURRENCY_BASE_UPDATE_ITEM"
  chmod 000 "$config/$FM_CURRENCY_BASE_UPDATE_ITEM"
  if [ -r "$config/$FM_CURRENCY_BASE_UPDATE_ITEM" ]; then
    # Root ignores the mode bits, so the unreadable case is unreachable here.
    chmod 644 "$config/$FM_CURRENCY_BASE_UPDATE_ITEM"
  else
    if fm_currency_base_resolve "$config" "$FM_CURRENCY_BASE_UPDATE_ITEM" 2>/dev/null; then
      fail "an unreadable config file resolved $FM_CURRENCY_BASE_VALUE"
    fi
    assert_contains "$FM_CURRENCY_BASE_REASON" 'not readable' \
      "an unreadable config file gave the wrong reason"
    chmod 644 "$config/$FM_CURRENCY_BASE_UPDATE_ITEM"
  fi

  rm -f "$config/$FM_CURRENCY_BASE_UPDATE_ITEM"
  fm_currency_base_resolve "$config" "$FM_CURRENCY_BASE_UPDATE_ITEM" \
    || fail "a genuinely absent config file refused: $FM_CURRENCY_BASE_REASON"
  [ "$FM_CURRENCY_BASE_VALUE" = "$FM_CURRENCY_BASE_DEFAULT" ] \
    || fail "a genuinely absent config file did not resolve the default: $FM_CURRENCY_BASE_VALUE"

  pass "a present but unusable config item refuses with its own reason instead of falling back"
}

test_relevant_update_found_and_cleared_when_current
test_installer_only_update_is_not_relevant
test_configured_base_is_the_repository_compared
test_environment_override_beats_the_configured_base
test_unusable_configured_base_refuses_loudly
test_resolver_precedence_and_default
test_resolver_rejects_unusable_values
test_resolver_refuses_present_but_unusable_file
