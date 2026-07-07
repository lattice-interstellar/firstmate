# FM_HOME propagation into secondmate agent tool subshells

This note records the empirical per-harness check behind the secondmate `FM_HOME`
propagation hardening in `bin/fm-spawn.sh` (data/fmfork-fix-plan-r4 PR-A2).
It records facts, not assumptions, per the coding guidelines.

## Why this matters

A secondmate launch sets `FM_HOME=<home>` as a command prefix on the agent launch
command (`bin/fm-spawn.sh`, secondmate branch of the launch construction).
If the agent's harness runs its Bash tool with a scrubbed environment, the agent's
own shell and its tool subshells lose `FM_HOME`.
Any `bin/fm-spawn.sh` or `bin/fm-teardown.sh` the agent then runs (firstmate working
on firstmate) resolves `FM_HOME` from the executing bin's own location instead of
the intended home - the demonstrated cross-home meta-leak (W3, and the env-lost tail
of W1).
The marker gate in `bin/fm-home-lib.sh` refuses that case, and this pane-export
belt keeps the environment from being lost in the first place.

## The mechanism, and why the pane export is the robust one

`bin/fm-spawn.sh` already exports `GOTMPDIR` into the pane shell with a plain
`export GOTMPDIR=...` line sent before the launch command, so the agent (a child of
the pane shell) and every child process inherit it.
PR-A2 adds the same treatment for `FM_HOME` on secondmate launches: an
`export FM_HOME=<home>` line into the pane shell, in addition to the existing
command-prefix assignment.

## Evidence

Date: 2026-07-06.
Method: this check was run from inside a live `claude` crewmate spawned by
`bin/fm-spawn.sh` on the tmux backend.
That spawn exported `GOTMPDIR` into the pane shell before the agent started (the
pre-existing `export GOTMPDIR=...` line), so it is a direct probe of whether a
pane-exported variable survives into the harness's Bash-tool subshells.

Command run inside the agent's Bash tool:

```
$ echo "GOTMPDIR=${GOTMPDIR:-<UNSET>}"; env | grep -E '^(FM_|GOTMPDIR)'
GOTMPDIR=/tmp/fm-fmfork-secondmate-fmhome-a2/gotmp
GOTMPDIR=/tmp/fm-fmfork-secondmate-fmhome-a2/gotmp
```

Result: the pane-exported `GOTMPDIR` is present in the `claude` Bash-tool subshell.
Conclusion: `claude` does not scrub pane-shell environment out of its Bash-tool
subshells, so an `export FM_HOME=<home>` sent into the pane shell before launch
reliably reaches the secondmate agent's own shell and its Bash-tool subshells.

## Per-harness status

| Harness  | Pane-export reaches Bash-tool subshells | How verified |
| -------- | --------------------------------------- | ------------ |
| claude   | yes (verified)                          | live `GOTMPDIR` probe, 2026-07-06 (above) |
| codex    | not yet checked                         | - |
| opencode | not yet checked                         | - |
| pi       | not yet checked                         | - |
| grok     | not yet checked                         | - |

The pane `export FM_HOME` is shipped unconditionally for every secondmate launch
regardless of harness, so an unchecked harness gets the belt too.
When a harness above is checked, record its result here with the command and output.
