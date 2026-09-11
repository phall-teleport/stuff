# Beams

A macOS app, written in Go, that runs **Claude Code or another Beams supported model inside a Teleport Beam**
(an ephemeral sandbox VM), and keeps
the **conversation transcript and memory in GitHub** so nothing is
lost when the beam expires.

```
┌──────────────┐   tsh beams exec   ┌───────────────────────────┐
│  Beams.app   │ ─────────────────▶ │ beam (Debian sandbox VM)  │
│  Go + Wails  │ ◀───────────────── │  claude -p --output-format│
│              │  stream-json lines │         stream-json       │
│  transcript  │                    │  ~/.claude/projects/*/    │
│  + memory ───┼──▶ git commit/push │           memory/         │
└──────────────┘    (gh + git)      └───────────────────────────┘
```

## Features

**Sandboxes and sessions**
- The sidebar lists your beams (`tsh beams ls`); ＋ creates one (`tsh beams add`).
- Clicking a beam starts a session. Each prompt runs Claude Code inside the
  beam in print mode with stream-json output, using `--session-id` on the
  first turn and `--resume` after that, so the conversation continues exactly
  like a Claude Code session. All the work happens in the beam, never on your Mac.
- Beams ship with Claude Code preinstalled and authenticated through the
  tenant's Anthropic proxy, so the app never handles API keys.
- The transcript renders live: assistant text, collapsible tool calls with
  their results, and a per-turn footer with turns, duration and cost.
  Stop (■ or Esc) cancels the remote process.

**Memory**
- *Pull from beam* snapshots `~/.claude/projects/*/memory` and
  `~/.claude/CLAUDE.md` out of the sandbox. Files are browsable in the panel.
- *Restore from GitHub* pushes the last committed snapshot into a fresh beam
  so it starts with what earlier sessions learned.

**GitHub**
- The panel shows your `gh` sign-in state. *Sign in* runs the GitHub browser
  device flow and displays the one-time code in the app. Git traffic goes
  over HTTPS with `gh` as the credential helper, so private repos work with
  the gh login alone.
- Repository is a searchable list of every repo your login can access
  (owned, collaborator, org). Branch is a dropdown of the repo's real
  branches plus *＋ New branch…*; new branches are created from the repo's
  default branch. *Create private repo* creates the configured repo.
- *Sync beam session* commits `<prefix>/sessions/<id>/transcript.md`,
  `transcript.jsonl`, a per-session memory copy, and the latest snapshot at
  `<prefix>/memory/`, then pushes and links the commit. *Sync after every
  turn* automates it.

**Teleport login**
- On launch, and whenever a beam call fails on credentials, the app checks
  `tsh status` for your proxy. If you're logged out or the certificate
  expired, a banner appears with a username field and *Log in with tsh*.
- SSO tenants complete in the browser. Tenants with local password login
  can't prompt inside a GUI app, so the app opens Terminal.app with the exact
  `tsh login --proxy=… --user=…` command and picks up the new session
  automatically once you finish there.

**Published apps**
- When Claude runs `tsh beams publish`, the app is reachable at
  `https://<beam>-<port>.<tenant>`. The app watches the stream for URLs on
  your tenant's domain, opens them in your default browser (toggle in
  Settings), and shows a 🌐 pill in the session header to reopen them.
  Bare URLs in Claude's replies are clickable too.

## Requirements

- macOS, Go 1.22+, Xcode command line tools
- `tsh` with access to a beams-enabled cluster
- `gh` (`brew install gh`) for GitHub sync; the app can sign it in for you
- Wails CLI: `go install github.com/wailsapp/wails/v2/cmd/wails@latest`

## Build and run

```bash
wails build            # → build/bin/Beams.app
open build/bin/Beams.app
```

Development with a live dev server (also opens a native window):

```bash
wails dev
```

Run against simulated beams, no cluster needed:

```bash
BEAMSUI_MOCK=1 wails dev
```

Tests:

```bash
go vet ./... && go test ./internal/...
```

Note: stopping `wails dev` removes `build/bin`, so run `wails build` again
before opening the app bundle.

## Settings

⚙ Settings covers the Teleport proxy, Teleport user (for `tsh login`), the
login and working directory inside the beam, permission mode (bypass is the
sandbox default), model, and whether published apps open automatically.
GitHub settings live in the right-hand panel. Everything is stored in
`~/Library/Application Support/BeamsUI/config.json`; sessions and pulled
memory live next to it under `sessions/`.

## How it's put together

```
main.go                 Wails bootstrap, embeds frontend/
app.go                  methods bound to the frontend, event emission
internal/beams          tsh beams wrapper, mock backend, tsh status/login, PATH fix
internal/agent          Claude Code turn script, stream-json reader, published-URL detector
internal/store          config, sessions, transcripts, memory snapshots
internal/ghsync         clone/commit/push, repo and branch listing, gh login
frontend/               vanilla HTML/CSS/JS UI (no bundler)
build/appicon.svg       icon source (rendered to appicon.png with qlmanage)
```

Apps launched from the Dock get a minimal `PATH`, so the app rebuilds its
`PATH` from your login shell at startup (plus `/usr/local/bin`, Homebrew and
`~/.tsh/bin`) to find `tsh`, `gh` and `git`.

## Troubleshooting

- **"tsh: executable file not found"** — fixed by the PATH logic above; if it
  recurs, set the full path to `tsh` in Settings.
- **Sync does nothing** — sync commits a specific session; open one first.
  The panel tells you so, and logs each step below the buttons.
- **Old icon in the Dock** — `killall Dock`; if it persists,
  `sudo rm -rf /Library/Caches/com.apple.iconservices.store && killall Dock Finder`.
- **Beam list is empty with no error** — you may be on a cluster without
  BeamService; check the proxy in Settings.

See `CLAUDE.md` for the notes future Claude Code sessions should read before
changing the code.
