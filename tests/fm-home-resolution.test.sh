#!/usr/bin/env bash
# Regression-lock for the FM_HOME-authoritative invariant (PR-A1,
# data/fmfork-fix-plan-r4).
#
# fm-spawn.sh and fm-teardown.sh resolve operational home-derived reads (state,
# data, projects, config, and the mode/yolo, harness, and guard-supervision
# lookups their helper scripts perform) through FM_HOME, while FM_ROOT is reserved
# for primary-repo reads. The audit for this PR found that the "W2 split-brain"
# (a foreign bin/ with FM_HOME set diverging into two homes) does NOT manifest on
# current code, because every helper independently re-resolves
#   FM_HOME="${FM_HOME:-...}"
# and derives DATA/CONFIG/STATE from it. These tests PIN that invariant so a future
# refactor cannot silently re-introduce W2 by switching a helper's operational read
# to FM_ROOT.
#
# The shape under test is exactly W2: FM_HOME points at a temp home B while the
# executing bin/ is this real repo (its FM_ROOT/SCRIPT_DIR is A, != B), with NO
# FM_*_OVERRIDE in play. Every assertion proves the operational read followed B, not
# the executing bin's home A.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-home-resolution)

# Run <helper> with FM_HOME=<home> and EVERY FM_*_OVERRIDE cleared, so resolution
# can only come from FM_HOME (or, absent it, the executing bin's FM_ROOT). This is
# the W2 environment: a set FM_HOME with a foreign executing bin and no overrides.
run_foreign_bin() {  # <home> <helper-rel-path> [args...]
  local home=$1; shift
  local helper=$1; shift
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_CONFIG_OVERRIDE \
    FM_HOME="$home" "$ROOT/bin/$helper" "$@"
}

# mode/yolo (fm-project-mode.sh) and harness (fm-harness.sh) resolve through
# FM_HOME even when the executing bin/ belongs to a different home.
test_mode_yolo_and_harness_follow_fm_home() {
  local home out
  home="$TMP_ROOT/homeB"
  mkdir -p "$home/data" "$home/config"
  # B registers alpha as direct-PR +yolo and pins the crew harness to grok; the
  # executing repo A registers neither, so a leak to A could not produce B's values.
  printf -- '- alpha [direct-PR +yolo] - homeB alpha (added 2026-01-01)\n' > "$home/data/projects.md"
  printf 'grok\n' > "$home/config/crew-harness"

  out=$(run_foreign_bin "$home" fm-project-mode.sh alpha)
  [ "$out" = "direct-PR on" ] \
    || fail "mode/yolo did not resolve through FM_HOME (got '$out', expected 'direct-PR on')"

  out=$(run_foreign_bin "$home" fm-harness.sh crew)
  [ "$out" = grok ] \
    || fail "harness did not resolve through FM_HOME (got '$out', expected 'grok')"
  pass "mode/yolo and harness resolve through FM_HOME with a foreign executing bin"
}

# fm-guard.sh's supervision read (STATE=$FM_HOME/state) follows FM_HOME. Proven by
# the DIFFERENCE between two homes that share the same foreign executing bin: an
# in-flight home with no watcher beacon trips the WATCHER DOWN banner, an empty
# home does not. If the guard read the executing bin's home instead of FM_HOME,
# both runs would read the same state and could not differ.
test_guard_supervision_follows_fm_home() {
  local busy empty out
  busy="$TMP_ROOT/guard-busy"
  empty="$TMP_ROOT/guard-empty"
  mkdir -p "$busy/state" "$empty/state"
  # One in-flight task and no watcher beacon in the busy home.
  fm_write_meta "$busy/state/task-z1.meta" "window=fake:fm-task-z1" "kind=ship"

  out=$(run_foreign_bin "$busy" fm-guard.sh 2>&1 || true)
  assert_contains "$out" "WATCHER DOWN" \
    "guard did not read the busy FM_HOME's in-flight state"

  out=$(run_foreign_bin "$empty" fm-guard.sh 2>&1 || true)
  assert_not_contains "$out" "WATCHER DOWN" \
    "guard saw in-flight work in an empty FM_HOME (it read the wrong home's state)"
  pass "guard supervision reads FM_HOME's state, not the executing bin's home"
}

test_mode_yolo_and_harness_follow_fm_home
test_guard_supervision_follows_fm_home
