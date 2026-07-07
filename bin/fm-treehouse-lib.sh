#!/usr/bin/env bash
# Shared treehouse-invocation helpers for firstmate crew/scout worktree leasing.
# Sourced by fm-spawn.sh (acquire side) and fm-teardown.sh (return side) so the
# treehouse-status parse lives in exactly one place. Exact treehouse flags and
# output shapes are pinned here, not in AGENTS.md prose.
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
#
# The teardown guard FAILS CLOSED: because `treehouse return` enforcement is
# entirely client-side (--force releases even a foreign-held lease with rc=0), the
# return only proceeds when the lease state is POSITIVELY confirmed - the worktree
# row is found in `treehouse status` AND either its holder matches our token or the
# row is explicitly present and unheld. Any unconfirmed state (row not found,
# unparseable/unrecognized status output, or a `treehouse status` error) refuses,
# rather than silently no-op in front of an unconditional `return --force`.

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

# _fm_treehouse_path_equals <candidate> <target-as-given> <target-canonical>:
# succeed when <candidate> names the same worktree as the target, comparing as
# given and (only for absolute candidates, never arbitrary relative tokens) after
# physical canonicalization.
_fm_treehouse_path_equals() {  # <candidate> <target-as-given> <target-canonical>
  local cand=$1 t1=$2 t2=$3 cand_real
  [ "$cand" = "$t1" ] && return 0
  [ -n "$t2" ] && [ "$cand" = "$t2" ] && return 0
  case "$cand" in
    /*) ;;
    *) return 1 ;;
  esac
  cand_real=$(cd "$cand" 2>/dev/null && pwd -P) || cand_real=""
  [ -n "$cand_real" ] || return 1
  [ "$cand_real" = "$t1" ] && return 0
  [ -n "$t2" ] && [ "$cand_real" = "$t2" ] && return 0
  return 1
}

# fm_treehouse_lease_state <worktree-path> <pool-dir>: classify the treehouse
# lease state of the worktree at <worktree-path> and echo exactly one of:
#   held<TAB><holder>  the worktree's row was found and is leased by <holder>
#   unheld             the worktree's row was found and carries no lease holder
#   notfound           status listed cleanly but no row matched the worktree path
#   error              the pool dir is missing/invalid or `treehouse status` failed
# The caller decides; this function never mutates. Returns 0 always (the classifier
# is on stdout so a subshell capture never trips set -e).
#
# treehouse resolves the pool from the working directory (same reason spawn cd's
# into the project and teardown_treehouse_return cd's into cd_dir), so status runs
# in a subshell from <pool-dir>. The v2.0.0 status format is one row per worktree:
#   `<index>  <state>  <path>[  (held by <holder>)]`
# (Go format `%-4s  %s%s  %s  (held by %s)`), with the path tilde-abbreviated
# (e.g. `~/.treehouse/...`) and optional indented continuation lines listing the
# in-use processes. Rows are parsed positionally so a path that itself contains a
# space is handled: the trailing `  (held by <holder>)` is split off first, then
# `<index>` and `<state>` are stripped, and everything left is the path (internal
# spaces preserved). A leading `~`/`~/` in the path is expanded to $HOME via
# parameter expansion (never eval) before comparison, since the target path from
# meta is the full absolute path. A row that does not parse into that shape is not
# matched, so an unrecognized/format-drifted status degrades to notfound/error and
# the caller refuses (fail closed), never to a skipped guard.
fm_treehouse_lease_state() {  # <worktree-path> <pool-dir>
  local wt=$1 pool=$2 wt_real="" status_out='' rc=0 line rowbody holder path
  if [ -z "$pool" ] || [ ! -d "$pool" ]; then
    printf 'error\n'
    return 0
  fi
  status_out=$( cd "$pool" && treehouse status 2>/dev/null ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'error\n'
    return 0
  fi
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || wt_real=""
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip blank lines and indented continuation (process) lines; only a top-level
    # row (index at column 0) describes a worktree.
    case "$line" in
      ''|[[:space:]]*) continue ;;
    esac
    # Split off a trailing "  (held by <holder>)" suffix when present.
    holder=''
    rowbody=$line
    case "$line" in
      *"  (held by "*")")
        holder=${line##*"  (held by "}
        holder=${holder%")"}
        rowbody=${line%"  (held by "*}
        ;;
    esac
    # rowbody == "<index>  <state>  <path>"; capture the path (which may contain
    # spaces) as everything after the first two whitespace-delimited columns.
    if [[ $rowbody =~ ^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+(.*[^[:space:]])[[:space:]]*$ ]]; then
      path=${BASH_REMATCH[1]}
    else
      continue
    fi
    # Expand a leading tilde to $HOME (parameter expansion only, never eval).
    if [ "$path" = '~' ]; then
      path=$HOME
    elif [ "${path#\~/}" != "$path" ]; then
      path="$HOME/${path#\~/}"
    fi
    if _fm_treehouse_path_equals "$path" "$wt" "$wt_real"; then
      if [ -n "$holder" ]; then
        printf 'held\t%s\n' "$holder"
      else
        printf 'unheld\n'
      fi
      return 0
    fi
  done <<EOF
$status_out
EOF
  printf 'notfound\n'
  return 0
}
