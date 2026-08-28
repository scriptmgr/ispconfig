## Structure

Single file: `install.sh` at repo root. No source tree, no build step, no compiled artifact — the script itself is the shipped product.

## Language & conventions

- Bash (`#!/bin/bash`), `set -e` active — every command's exit status matters; guard expected-nonzero commands with `|| true` or an `if` test, never let one trip the script by accident
- All functions prefixed `__` (e.g. `__log`, `__step`, `__install_mail`)
- CasjaysDev header block at top of file (`##@Version`, `@@Author`, `@@License`, `@@Changelog`, etc.) — `VERSION="YYYYMMDDHHMM-git"` bumped in both the header and the `VERSION=` variable on every edit
- Comments go above the line they describe, never inline
- `grep` calls use `--` before the query
- No UUOC, no unnecessary subshells/forks

## Output model

- `__log` / `__warn` / `__error` / `__success` are the plain status-line helpers
- `__step "description" some_function args...` is the standard way to run any install phase: it captures the wrapped command's stdout/stderr to a temp logfile, shows a spinner (`__spin`, only when stdout is a tty) while it runs, and prints one collapsed `[OK]`/`[FAILED]` line
- `__failed` prints the failure marker plus the tail of the captured log and exits — this is what the user sees when a step breaks, nothing else is hidden
- Because `set -e` is active, any command inside `__step`'s own cleanup (kill/wait on the spinner job, etc.) that can legitimately return non-zero must be defused with `|| true` — a bare non-zero return there kills the whole script silently, not just the step

## Distro support

Detected once via `/etc/os-release` and dispatched by package manager (`apt` / `dnf` / `yum` / `zypper`) — every install function branches on `$PACKAGE_MANAGER`, not on distro name, except where a distro-specific quirk (e.g. Ubuntu's Ondrej PPA, RHEL's CodeReady Builder repo) requires it.

## Testing

No unit-test framework — this is an imperative system installer, not a library. Verification is:
1. `script-lint` agent must pass clean before every commit
2. Full end-to-end run via Incus (`incus launch images:almalinux/9`, push the script, run `__main "$@"` unmodified, tear the container down after) before claiming a fix works
3. When a real-host failure is reported, reproduce the exact failure mode locally (or via a minimal repro script) before changing anything — don't guess at a fix

## What this script must never do

- Never stream raw package-manager output to the terminal on the success path (`__step` exists specifically to prevent this)
- Never assume a controlling terminal is available for anything load-bearing — spinner is `[[ -t 1 ]]`-gated, nothing else depends on a tty
- Never leave a step half-applied on failure — a failed step must stop the script (`__failed` calls `exit`), not continue past broken state
