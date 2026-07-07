#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's leased crew/scout worktree acquisition (PR-B,
# data/fmfork-fix-plan-r4). When the installed treehouse advertises --lease, a
# ship/scout spawn acquires the worktree with
#   treehouse get --lease --lease-holder "fm:<abs-FM_HOME>:<id>"
# capturing the worktree path from stdout (never the pane cwd), and records the
# owner token in the task meta as lease_holder=.
#
# These tests drive fm-spawn through a fake tmux pane and a fake treehouse whose
# `get --help` advertises --lease and whose `get --lease` prints a real isolated
# worktree path while recording the lease-holder token it was handed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-lease)

# Fake tmux: capture the launch command sent with `send-keys -l`, and answer the
# pane_current_path probe with FM_FAKE_PANE_PATH (a decoy here, to prove the
# leased path comes from stdout, not the pane).
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

# Fake treehouse: `get --help` advertises --lease; `get --lease --lease-holder X`
# prints FM_FAKE_TH_WT (a real isolated worktree) to stdout and records X to
# FM_FAKE_TH_HOLDER_LOG so a test can assert the exact owner token firstmate
# leased under.
make_fake_treehouse() {
  local fakebin=$1
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = get ]; then
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
fi
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
  local out rc home_real expected_holder decoy meta
  id=lease-spawn-a1
  rec=$(make_lease_case lease-spawn "$id")
  IFS='|' read -r case_dir home proj wt fakebin launchlog holderlog <<EOF
$rec
EOF
  # Decoy pane cwd: a path that is NOT the leased worktree. If the spawn read the
  # pane cwd instead of the lease stdout, worktree= would be this decoy.
  decoy="$case_dir/decoy-pane"
  mkdir -p "$decoy"
  home_real=$(cd "$home" && pwd -P)
  expected_holder="fm:$home_real:$id"
  meta="$home/state/$id.meta"

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$decoy" FM_FAKE_LAUNCH_LOG="$launchlog" \
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
  assert_no_grep "worktree=$decoy" "$meta" \
    "meta worktree= came from the pane cwd decoy, not the lease stdout"

  # The token firstmate handed to `treehouse get --lease --lease-holder` must be
  # exactly the token recorded in meta.
  [ -f "$holderlog" ] || fail "lease spawn never called treehouse get --lease"
  assert_grep "$expected_holder" "$holderlog" \
    "treehouse get --lease was not handed the recorded owner token"
  pass "lease spawn records lease_holder= and captures the worktree from lease stdout"
}

test_lease_spawn_records_holder_and_captures_worktree_from_stdout
