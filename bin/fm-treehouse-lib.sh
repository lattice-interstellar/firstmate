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

# fm_treehouse_status_holder <worktree-path>: echo the lease holder `treehouse
# status` reports for the worktree at <worktree-path>, or nothing when that
# worktree is absent from the pool or reports no holder. treehouse prints one
# line per worktree; a leased line ends with "  (held by <holder>)" (the
# treehouse v2.0.0 status format string is `%-4s  %s%s  %s  (held by %s)`). The
# path is matched both as given and canonicalized so a symlinked invocation path
# still lines up with treehouse's physically-resolved output.
fm_treehouse_status_holder() {  # <worktree-path>
  local wt=$1 wt_real="" line rest holder matched
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || wt_real=""
  while IFS= read -r line; do
    case "$line" in
      *"(held by "*")") ;;
      *) continue ;;
    esac
    matched=0
    case "$line" in *"$wt"*) matched=1 ;; esac
    if [ "$matched" -eq 0 ] && [ -n "$wt_real" ]; then
      case "$line" in *"$wt_real"*) matched=1 ;; esac
    fi
    [ "$matched" -eq 1 ] || continue
    rest=${line##*"(held by "}
    holder=${rest%")"}
    printf '%s\n' "$holder"
    return 0
  done < <(treehouse status 2>/dev/null)
}
