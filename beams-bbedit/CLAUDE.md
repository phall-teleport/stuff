# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

A BBEdit package (`Teleport Beams.bbpackage`) that exposes Teleport Beams operations as items in
BBEdit's Scripts menu and one Text Filter. It is the BBEdit port of
`~/git/teleport-toys-internal/beam-vs-code`; consult that extension when adding features so
`tsh` usage stays consistent.

## Commands

```bash
make check        # bash -n + py_compile
make test         # python3 tests/test_helpers.py (offline)
make lint         # shellcheck if installed
./install.sh      # copy into ~/Library/Application Support/BBEdit/Packages, then relaunch BBEdit
                  # (--link symlinks, but BBEdit does not reliably load symlinked packages)
```

There is no build step. Scripts are plain `#!/bin/bash` files run by BBEdit.

## Architecture

- `Contents/Scripts/Teleport Beams/NN) Name.sh` — one script per menu item. The `NN)` prefix orders the
  menu and is hidden by BBEdit. Every script starts by sourcing
  `Contents/Resources/lib/beams-lib.sh` via `$(dirname "$0")/../../Resources/lib`.
- `beams-lib.sh` — the only place that knows how to talk to `tsh`, show dialogs, or edit
  `~/.ssh/config`. Key helpers: `beams_require` (current beam or picker), `beams_exec`,
  `beams_exec_script`, `beams_tsh`, `beams_show` (stdin → new BBEdit document), `beams_ask`,
  `beams_choose`, `beams_confirm`, `beams_choose_button`, `beams_terminal`, `beams_sftp_url`.
- Python helpers in `Resources/lib/` do all parsing: `beams_json.py`, `ssh_config.py`, `activity.py`.
  They are unit-tested in `tests/test_helpers.py`; the shell scripts are not.

## Conventions and gotchas

- Helpers that can fail show their own error dialog and return non-zero; callers write
  `x=$(helper) || exit 1`. A helper inside `$(...)` cannot exit the caller.
- Never call `"$TSH"` directly for cluster operations: use `beams_tsh` (errors → dialog),
  `beams_tsh_raw` (stderr passes through) or `beams_tsh_cmdline` (for Terminal). They add
  `--proxy=$BEAMS_PROXY`, resolved at lib load from `BEAMS_CLUSTER` in the config file or the first
  `*.beams.sh` profile — the user's *current* tsh profile may be a different cluster entirely.
- `tsh beams exec` joins argv into one remote command line. Always pass a single string and quote
  user input with `beams_shell_quote`. Scripts that need stdin on the beam use `bash -s` / `python3 -`.
- Scripts must stay quiet on stdout: BBEdit shows any stdout in its Unix Script Output window.
  Use `beams_show` for results and `beams_notify`/`beams_alert` for status.
- The Text Filter must always emit *something* — on any failure it echoes the original input so the
  selection is not destroyed.
- SSH aliases are `bbedit--<beam>.<cluster>` with the identity pinned (`IdentitiesOnly yes` +
  `IdentityFile`/`CertificateFile` from `tsh config --proxy`). Without pinning, ssh exhausts
  `MaxAuthTries` and BBEdit's SFTP connection fails with "too many authentication failures".
- Host-key verification: BBEdit invokes ssh with `-oStrictHostKeyChecking=ask` on the command
  line (config cannot override it), so the alias must be *verifiable*. Beams present a host
  certificate from the cluster host CA with principal `<uuid>.<cluster>`; the alias therefore uses
  `HostName <uuid>.<cluster>` and `UserKnownHostsFile ~/.tsh/known_hosts`. Do not try to record
  plain host keys (TOFU) — the presented key is not stable between connections, and
  `UserKnownHostsFile /dev/null` makes BBEdit ask every time.
- Every run appends to `~/.config/teleport-beams-bbedit/last-run.log` (stderr is tee'd there);
  read it first when a menu item "produced no output".
- BBEdit SFTP URLs: `sftp://user@host/x` is relative to the login home; absolute needs `//`.
- The managed `~/.ssh/config` block is inserted before the first `Host`/`Match`/`Include` line so
  it precedes any `Host *.<cluster>` wildcard; a backup is written on every change.
- BBEdit runs scripts with a minimal `PATH`; the lib prepends Homebrew and `/usr/local/bin`.
- Avoid naming shell variables `path` — harmless in bash, but it is tied to `$PATH` in zsh and
  bites anyone testing snippets interactively.
