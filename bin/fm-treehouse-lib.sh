#!/usr/bin/env bash
# Shared treehouse-invocation helpers for firstmate crew/scout worktree leasing.
# Sourced by fm-spawn.sh (acquire side) and fm-teardown.sh (return side) so the
# treehouse-status holder parse lives in exactly one place. Exact treehouse flags
# and output shapes are pinned here, not in AGENTS.md prose.
#
# Leasing model (root cause B, data/fmfork-fix-plan-r4 PR-B): a treehouse pool is
# keyed by the origin remote URL, so two firstmate homes cloning a same-origin
# repo share one pool. A non-leased `treehouse get` can then hand the same idle
# worktree to both homes, and one home's teardown can `treehouse return` a
# worktree the other is live in. Acquiring with
#   treehouse get --lease --lease-holder <owner-token>
# durably reserves the worktree (treehouse never re-hands or prunes a leased
# worktree until `treehouse return`) and prints only its path to stdout.
# Recording the <owner-token> lets teardown read the live holder from
# `treehouse status` and refuse to return a worktree another home holds.

# fm_treehouse_supports_lease: succeed when the installed treehouse `get`
# advertises --lease. Mirrors the probe in bin/fm-bootstrap.sh so both agree on
# what "lease support" means.
fm_treehouse_supports_lease() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'
}

# fm_treehouse_owner_token <home> <id>: build the lease-holder label that encodes
# the owning firstmate home and task, e.g. fm:/abs/home:fix-login-k3. The home is
# canonicalized to its physical path when possible so the same home yields the
# same token regardless of a symlinked invocation path.
fm_treehouse_owner_token() {  # <home> <id>
  local home=$1 id=$2 home_real
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || home_real=$home
  printf 'fm:%s:%s\n' "$home_real" "$id"
}

# fm_treehouse_status_holder <worktree-path> <pool-dir>: echo the lease holder
# `treehouse status` reports for the worktree at <worktree-path>, or nothing when
# that worktree is absent from the pool or reports no holder. treehouse resolves
# the pool from the working directory (same reason spawn cd's into the project and
# teardown_treehouse_return cd's into cd_dir), so status runs in a subshell from
# <pool-dir>; when <pool-dir> is empty or not a directory the function returns
# nothing rather than reading a pool from an arbitrary cwd. treehouse prints one
# line per worktree; a leased line ends with "  (held by <holder>)" (the
# treehouse v2.0.0 status format string is `%-4s  %s%s  %s  (held by %s)`). Each
# line is split into whitespace-delimited fields with `read -ra` (no word-split or
# glob expansion of the line) and the worktree path is matched as a whole field,
# both as given and canonicalized, so a path like .../wt-2 never matches a
# .../wt-20 line and a symlinked invocation path still lines up with treehouse's
# physically-resolved output.
fm_treehouse_status_holder() {  # <worktree-path> <pool-dir>
  local wt=$1 pool=$2 wt_real="" line rest holder matched field field_real
  local -a fields=()
  [ -n "$pool" ] && [ -d "$pool" ] || return 0
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || wt_real=""
  while IFS= read -r line; do
    case "$line" in
      *"(held by "*")") ;;
      *) continue ;;
    esac
    matched=0
    read -ra fields <<< "$line"
    for field in "${fields[@]}"; do
      if [ "$field" = "$wt" ] || { [ -n "$wt_real" ] && [ "$field" = "$wt_real" ]; }; then
        matched=1
        break
      fi
      field_real=$(cd "$field" 2>/dev/null && pwd -P) || field_real=""
      if [ -n "$field_real" ] && { [ "$field_real" = "$wt" ] || [ "$field_real" = "$wt_real" ]; }; then
        matched=1
        break
      fi
    done
    [ "$matched" -eq 1 ] || continue
    rest=${line##*"(held by "}
    holder=${rest%")"}
    printf '%s\n' "$holder"
    return 0
  done < <( cd "$pool" && treehouse status 2>/dev/null )
}
