# Teleport Beams for BBEdit

A BBEdit package for working with [Teleport Beams](https://www.beams.run/) — ephemeral
sandbox VMs for agentic workloads — without leaving the editor. It is the BBEdit
counterpart of the `beam-vs-code` extension and drives the same `tsh beams` CLI.

Everything appears under **Scripts → Teleport Beams** (also in the Scripts palette, where
you can assign keyboard shortcuts), plus one entry in **Text → Apply Text Filter**.

## What you get

| Menu item | What it does |
|---|---|
| Status | Active cluster/user and a table of your beams in a new document |
| Login… | Opens Terminal running `tsh login --proxy=<cluster>` |
| Select Beam… | Picks the *current* beam the other items act on |
| Create Beam | `tsh beams add`, makes it current, writes its SSH alias, offers to open it |
| Delete Beam… | Confirms, `tsh beams rm`, removes the SSH alias |
| Browse Files (SFTP) | Opens `/home/beams` in BBEdit’s SFTP browser — edits save straight to the beam |
| Open File on Beam… | Opens one remote file over SFTP |
| SSH in Terminal | `tsh beams ssh` in Terminal (or iTerm, see Configuration) |
| Run Command on Beam… | One command, output in a new document |
| Run Document on Beam | Streams the front document to the beam and runs it (interpreter from `#!`) |
| Run Selection on Beam | Runs the selection as a bash script, output in a new document |
| Publish / Unpublish Beam, Copy Beam URL | HTTP or TCP publishing; URL goes to the clipboard |
| Git Status / Git Diff / Git Commit… / Git Push | Against the first repository under `/home/beams`; push offers the GitHub PR link |
| Agent Activity | Tokens, estimated cost, recent tool calls and event tail from the beam’s latest Claude Code transcript |
| Setup GitHub on Beam… | Git identity plus Teleport Git proxy (`tsh git`) or a PAT via `gh`; optional clone |
| Export Beam Archive… | tar.gz of a beam directory into `~/Downloads` via `tsh beams scp` |
| Clean Up SSH Config | Removes aliases for beams that no longer exist |
| *Text filter:* Run on Beam (Replace with Output) | Replaces the selection with the output of running it on the beam |

## Prerequisites

- BBEdit 14 or later with its command-line tools installed (BBEdit → Install Command Line Tools);
  `/Applications/BBEdit.app/Contents/Helpers/bbedit_tool` is used as a fallback.
- [`tsh`](https://goteleport.com/docs/installation/) in `PATH` (or Teleport Connect installed), logged in: `tsh login --proxy=<cluster>.beams.sh`.
- `python3` (Xcode Command Line Tools or Homebrew).

## Install

```bash
git clone <this repo> && cd beams-bbedit
./install.sh          # copies the package into ~/Library/Application Support/BBEdit/Packages
```

Then **quit and relaunch BBEdit** — it scans the Packages folder at launch. The items appear under
the Scripts menu (the script-icon menu to the right of Window) as a “Teleport Beams” submenu, and in
the Scripts palette. `./install.sh --uninstall` removes the package. `./install.sh --link` symlinks
instead of copying, but BBEdit does not reliably load symlinked packages, so re-run `./install.sh`
after edits rather than relying on the link.

## How it works

- **SFTP through Teleport.** BBEdit’s SFTP browser shells out to `/usr/bin/ssh`, which honours
  `~/.ssh/config`. The package writes one self-contained `Host bbedit--<beam>.<cluster>` alias per
  beam inside a marker-delimited block, with `ProxyCommand tsh proxy ssh … %r@teleport.internal/beams/alias=<beam>`
  and the cluster’s identity/certificate pinned (otherwise ssh offers every certificate in the agent
  and trips `MaxAuthTries`). The block is inserted before the first `Host`/`Match`/`Include` line so the
  specific aliases beat any `Host *.<cluster>` wildcard from `tsh config`. A backup is written to
  `~/.ssh/config.teleport-beams-bbedit.bak` on every change.
- **Host keys are verified, not trusted-on-first-use.** BBEdit runs
  `/usr/bin/ssh … -oStrictHostKeyChecking=ask`, which overrides the config file, so any host key ssh
  cannot verify produces a dialog on every connection. A beam presents a host *certificate* signed by
  the cluster's host CA whose principal is `<beam uuid>.<cluster>`, so the alias sets `HostName` to
  that UUID form and `UserKnownHostsFile` to tsh's own `~/.tsh/known_hosts` (which holds the
  `@cert-authority` line for the cluster). ssh then validates the certificate and never asks.
  Recording plain keys does not work: the certificate's underlying key is not stable across
  connections.
- **SFTP paths.** Absolute paths use the `sftp://beams@<alias>//home/beams/...` double-slash form; a
  single slash is relative to the login's home directory.
- **Cluster pinning.** `tsh` acts on whichever profile you logged in to last, so logging in to another
  cluster would silently break Beams commands (“unknown service teleport.beams.v1.BeamService”). The
  package resolves the Beams cluster once per run (`BEAMS_CLUSTER` from the config file, else any
  `*.beams.sh` profile) and passes `--proxy=<cluster>` on every `tsh` call.
- **Everything else is `tsh beams …`** — `ls -f json`, `add -f json`, `rm`, `exec`, `publish`, `scp`.
  `tsh beams exec` joins its argv into one remote command line, so remote commands are passed as a
  single string and user input is single-quoted with `beams_shell_quote`.
- **Dialogs** are AppleScript (`display dialog`, `choose from list`, notifications) addressed to
  BBEdit so they appear in front of the editor.
- **Output** documents are created with the `bbedit` tool (`-t` title, `-m` language, `--clean`).

## Configuration

Optional, in `~/.config/teleport-beams-bbedit/config` (shell syntax):

```bash
BEAMS_CLUSTER=super-grass.beams.sh  # pin the Beams cluster (set automatically by “Login…”)
BEAMS_TERMINAL=iTerm            # Terminal (default) or iTerm
BEAMS_TSH=/usr/local/bin/tsh    # override tsh discovery
BEAMS_GITHUB_USERNAME=octocat   # remembered by “Setup GitHub on Beam…”
BEAMS_GITHUB_EMAIL=octocat@users.noreply.github.com
BEAMS_GITHUB_AUTH=tsh-git       # or pat (the token itself is never stored)
BEAMS_GITHUB_DEFAULT_REPO=owner/repo
```

The current beam is remembered in `~/.config/teleport-beams-bbedit/current-beam`.

## Layout

```
Teleport Beams.bbpackage/Contents/
├── Info.plist
├── Scripts/Teleport Beams/        NN) Name.sh — one bash script per menu item (prefix sets order, hidden)
├── Text Filters/Teleport Beams/   Run on Beam (Replace with Output).sh
└── Resources/lib/
    ├── beams-lib.sh               shared helpers: dialogs, tsh wrappers, beam selection, SSH aliases
    ├── beams_json.py              tsh JSON → TSV / shell vars / menu lines
    ├── ssh_config.py              managed ~/.ssh/config block (ensure / remove / prune / list)
    └── activity.py                Claude Code JSONL transcript → Markdown summary
```

## Development

```bash
make check     # bash -n on every script, py_compile on helpers
make test      # offline unit tests for the Python helpers
make lint      # shellcheck, if installed
```

After editing, run `./install.sh` again to copy the package over (BBEdit reads the installed copy).
Scripts can also be run directly from a shell for quick checks, e.g.
`"Teleport Beams.bbpackage/Contents/Scripts/Teleport Beams/01) Status.sh"`.

## Not ported from the VS Code extension

Remote-SSH workspaces, the SCM panel with inline diffs, local Docker debug containers,
session profiles and the live-polling panels have no BBEdit equivalent; the SFTP browser,
Git scripts and Agent Activity report cover the same ground on demand instead.
