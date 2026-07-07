#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's leased crew/scout worktree acquisition (PR-B,
# data/fmfork-fix-plan-r4). When the installed treehouse advertises --lease, a
# ship/scout spawn acquires the worktree with
#   treehouse get --lease --lease-holder "fm:<abs-FM_HOME>:<id>"
# capturing the worktree path from stdout, records the owner token in the task
# meta as lease_holder=, and verifies the pane physically entered the worktree. On
# a treehouse WITHOUT --lease it falls back to a bare `treehouse get` + pane-cwd
# poll and records no lease_holder=. If a leased spawn fails before the meta is
# written, an EXIT trap returns the lease so a pool worktree is never stranded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-lease)

# Fake tmux: capture the launch command sent with `send-keys -l`, and answer the
# pane_current_path probe with FM_FAKE_PANE_PATH (the spawn polls this until it
# equals the worktree it is entering).
make_fake_tmux() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# Fake treehouse (lease-capable): `get --help` advertises --lease; `get --lease
# --lease-holder X` prints FM_FAKE_TH_WT (a worktree path) to stdout and records X
# to FM_FAKE_TH_HOLDER_LOG so a test can assert the exact owner token firstmate
# leased under; `return --force <wt>` records <wt> to FM_FAKE_TH_RETURN_LOG so a
# test can assert the abort-time lease return.
make_fake_treehouse() {
  local fakebin=$1
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    shift
    for a in "$@"; do
      if [ "$a" = --help ]; then
        printf 'Flags:\n      --lease   Durably lease a worktree without opening a subshell; print only its path to stdout\n'
        exit 0
      fi
    done
    holder=
    prev=
    for a in "$@"; do
      [ "$prev" = --lease-holder ] && holder=$a
      prev=$a
    done
    [ -n "${FM_FAKE_TH_HOLDER_LOG:-}" ] && printf '%s\n' "$holder" >> "$FM_FAKE_TH_HOLDER_LOG"
    printf '%s\n' "${FM_FAKE_TH_WT:?FM_FAKE_TH_WT unset}"
    exit 0
    ;;
  return)
    shift
    for a in "$@"; do
      case "$a" in
        --force) ;;
        *) [ -n "${FM_FAKE_TH_RETURN_LOG:-}" ] && printf '%s\n' "$a" >> "$FM_FAKE_TH_RETURN_LOG" ;;
      esac
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
}

# Fake treehouse (NO --lease): `get --help` does not mention --lease, so
# fm_treehouse_supports_lease is false and spawn takes the bare-get fallback.
make_fake_treehouse_nolease() {
  local fakebin=$1
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    shift
    for a in "$@"; do
      if [ "$a" = --help ]; then
        printf 'Flags:\n  -h, --help   help for get\n'
        exit 0
      fi
    done
    # bare `treehouse get` in the pane: no-op here; the fake tmux pane cwd stands in.
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
}

# Build one spawn sandbox. Echoes: case_dir|home|proj|wt|fakebin|launchlog|holderlog
make_lease_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  make_fake_tmux "$fakebin"
  make_fake_treehouse "$fakebin"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log|$case_dir/holder.log"
}

test_lease_spawn_records_holder_and_captures_worktree_from_stdout() {
  local rec case_dir home proj wt fakebin launchlog holderlog id
  local out rc home_real expected_holder meta
  id=lease-spawn-a1
  rec=$(make_lease_case lease-spawn "$id")
  IFS='|' read -r case_dir home proj wt fakebin launchlog holderlog <<EOF
$rec
EOF
  home_real=$(cd "$home" && pwd -P)
  expected_holder="fm:$home_real:$id"
  meta="$home/state/$id.meta"

  set +e
  # The pane reports the leased worktree, so the physical cd-poll succeeds. The
  # worktree recorded in meta comes from the lease stdout (the only place WT is set
  # in the lease branch), never the project pane-start dir.
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_LOG="$launchlog" \
    FM_FAKE_TH_WT="$wt" FM_FAKE_TH_HOLDER_LOG="$holderlog" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "lease spawn should succeed"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report success"

  [ -f "$meta" ] || fail "lease spawn did not write meta $meta"
  assert_grep "lease_holder=$expected_holder" "$meta" \
    "meta missing lease_holder=$expected_holder"
  assert_grep "worktree=$wt" "$meta" \
    "meta worktree= was not captured from the lease stdout"
  assert_no_grep "worktree=$proj" "$meta" \
    "meta worktree= is the project dir, not the leased worktree"

  # The token firstmate handed to `treehouse get --lease --lease-holder` must be
  # exactly the token recorded in meta.
  [ -f "$holderlog" ] || fail "lease spawn never called treehouse get --lease"
  assert_grep "$expected_holder" "$holderlog" \
    "treehouse get --lease was not handed the recorded owner token"
  pass "lease spawn records lease_holder= and captures the worktree from lease stdout"
}

test_bareget_fallback_records_no_lease_holder() {
  local rec case_dir home proj wt fakebin launchlog holderlog id out rc meta
  id=bareget-b2
  rec=$(make_lease_case bareget "$id")
  IFS='|' read -r case_dir home proj wt fakebin launchlog holderlog <<EOF
$rec
EOF
  make_fake_treehouse_nolease "$fakebin"
  meta="$home/state/$id.meta"

  set +e
  # No --lease support: spawn runs bare `treehouse get` in the pane and polls the
  # pane cwd (which the fake reports as $wt, distinct from the project) for the
  # worktree. No lease is held, so no lease_holder= is recorded.
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_LOG="$launchlog" \
    FM_FAKE_TH_HOLDER_LOG="$holderlog" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "bare-get fallback spawn should succeed"$'\n'"--- output ---"$'\n'"$out"
  [ -f "$meta" ] || fail "bare-get fallback did not write meta $meta"
  assert_grep "worktree=$wt" "$meta" "bare-get fallback did not capture the worktree from the pane cwd"
  assert_no_grep "lease_holder=" "$meta" "bare-get fallback must not record a lease_holder="
  [ ! -f "$holderlog" ] || fail "bare-get fallback must not call treehouse get --lease"
  pass "treehouse without --lease falls back to bare get and records no lease_holder="
}

test_lease_spawn_returns_lease_on_failure_before_meta() {
  local rec case_dir home proj wt fakebin launchlog holderlog id out rc returnlog meta
  id=lease-abort-c3
  rec=$(make_lease_case lease-abort "$id")
  IFS='|' read -r case_dir home proj wt fakebin launchlog holderlog <<EOF
$rec
EOF
  returnlog="$case_dir/return.log"
  meta="$home/state/$id.meta"
  # Lease a path that is NOT an isolated worktree (a plain dir), so
  # validate_spawn_worktree fails right after acquisition, before meta is written.
  # The EXIT trap must return the lease so the pool worktree is not stranded.
  local badwt="$case_dir/not-a-worktree"
  mkdir -p "$badwt"

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$badwt" FM_FAKE_LAUNCH_LOG="$launchlog" \
    FM_FAKE_TH_WT="$badwt" FM_FAKE_TH_HOLDER_LOG="$holderlog" \
    FM_FAKE_TH_RETURN_LOG="$returnlog" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "lease-abort: spawn should have failed on a non-isolated worktree"$'\n'"$out"
  [ ! -f "$meta" ] || fail "lease-abort: meta must not be written when the spawn aborts"
  [ -f "$returnlog" ] || fail "lease-abort: the lease was not returned on abnormal exit (no return recorded)"
  assert_grep "$badwt" "$returnlog" "lease-abort: the abnormal-exit trap did not return the leased worktree"
  pass "a leased spawn that fails before meta returns the lease (no stranded pool worktree)"
}

test_lease_spawn_records_holder_and_captures_worktree_from_stdout
test_bareget_fallback_records_no_lease_holder
test_lease_spawn_returns_lease_on_failure_before_meta
