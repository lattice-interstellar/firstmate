#!/usr/bin/env bash
# fm-home-lib.sh - shared secondmate-home environment assertion for fm-spawn.sh
# and fm-teardown.sh. Sourced, never executed.
#
# A secondmate is a firstmate whose operational home is an isolated FM_HOME, so
# it must always be entered with that FM_HOME set explicitly. When the executing
# script's OWN home (SCRIPT_DIR/.., i.e. its resolved FM_ROOT) carries the
# secondmate marker but FM_HOME was lost - unset or empty - and no FM_*_OVERRIDE
# is redirecting the operational dirs, the launch environment was dropped. Every
# home-derived read and write would then silently fall back to the executing
# bin's own home instead of the intended one, which is the demonstrated
# cross-home meta-leak (a task's meta written into the wrong home's state/).
# Refuse instead of writing to the wrong home.
#
# This closes the W1/W3 env-lost tail that PR-A1's `export FM_HOME` cannot: an
# unset FM_HOME has no correct value to export, so exporting it only propagates
# the already-wrong fallback (data/fmfork-fix-plan-r4 PR-A2).
#
# The refusal is narrow by construction and refuses no legitimate production
# path: a primary home carries no marker (guard inert with FM_HOME unset), a
# secondmate launched normally carries an explicit FM_HOME (guard bypassed), and
# the test harness sets FM_*_OVERRIDE (guard bypassed).

# fm_assert_explicit_secondmate_home <own-home> <fm-home-was-set> <marker-name>
#   own-home        the executing script's own home (its resolved FM_ROOT)
#   fm-home-was-set "1" when FM_HOME held a non-empty value in the caller's
#                   environment before defaulting, empty otherwise
#   marker-name     the secondmate home marker filename (.fm-secondmate-home)
# Prints a loud error to stderr and returns 1 when the guard trips; returns 0
# (silent) otherwise. Callers exit non-zero on a non-zero return.
fm_assert_explicit_secondmate_home() {
  fm__own_home=$1
  fm__home_was_set=$2
  fm__marker=$3
  # A non-empty operational override means a deliberate redirection (the test
  # harness, or a caller purposely relocating dirs); leave the guard inert. An
  # empty override - as the secondmate launch prefix sets to clear any inherited
  # ones - counts as "no override in play".
  if [ -n "${FM_ROOT_OVERRIDE:-}${FM_STATE_OVERRIDE:-}${FM_DATA_OVERRIDE:-}${FM_PROJECTS_OVERRIDE:-}${FM_CONFIG_OVERRIDE:-}" ]; then
    return 0
  fi
  # An explicit FM_HOME is exactly what a secondmate needs; nothing to refuse.
  [ "$fm__home_was_set" = 1 ] && return 0
  # Only a secondmate-marked own home is a bug when entered without FM_HOME; a
  # primary home legitimately runs with FM_HOME unset.
  [ -f "$fm__own_home/$fm__marker" ] || return 0
  fm__marker_id=$(cat "$fm__own_home/$fm__marker" 2>/dev/null || true)
  {
    printf 'error: refusing to run in a secondmate home without an explicit FM_HOME\n'
    printf '  secondmate home: %s (marker: %s)\n' "$fm__own_home" "${fm__marker_id:-present}"
    printf '  FM_HOME is unset and no FM_*_OVERRIDE is redirecting operational dirs, so the\n'
    printf '  launch environment was lost; any state write would silently land in this home\n'
    printf '  regardless of which task it belongs to. Re-invoke with FM_HOME=%s explicitly\n' "$fm__own_home"
    printf '  (data/fmfork-fix-plan-r4 PR-A2).\n'
  } >&2
  return 1
}
