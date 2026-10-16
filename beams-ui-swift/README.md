# Beams (native)

A fully native SwiftUI port of the Beams app: run **Claude Code (or Codex)
inside a Teleport Beam** sandbox from a macOS window, stream the conversation,
and keep the transcript, Claude's memory and the generated files in **GitHub**. It shares its data directory
with the Go/Wails version, so both see the same sessions and settings.

```
┌──────────────┐   tsh beams exec   ┌───────────────────────────┐
│  Beams.app   │ ─────────────────▶ │ beam (Debian sandbox VM)  │
│  SwiftUI     │ ◀───────────────── │  claude -p --output-format│
│              │  stream-json lines │         stream-json       │
│  transcript  │                    │  ~/.claude/projects/*/    │
│  + memory ───┼──▶ git commit/push │           memory/         │
└──────────────┘    (gh + git)      └───────────────────────────┘
```

## Features

- **Sandboxes & sessions** — sidebar of beams (`tsh beams ls`), ＋ creates one.
  Each prompt runs Claude Code in the beam in print mode with stream-json
  output, `--session-id` first then `--resume`, so it behaves like a real
  Claude Code session. All agent work happens in the beam.
- **Agents** — Claude Code (default) or Codex, with a model picker in
  Settings. Cost shows in dollars for Claude and in tokens for Codex (which
  doesn't report dollars).
- **Transcript** — assistant markdown, collapsible tool cards with results,
  per-turn cost footer, stop button (⌘.). Enter sends, ⌥Enter inserts a newline.
  Copy buttons on code blocks, tool input/output and other copyable text.
- **Images** — paste (⌘V) or drop images into the chat box to have the agent
  look at them; thumbnails show before sending and in the transcript.
- **Permission prompts** — in any mode but bypass, Claude's tool requests
  appear as Allow / Deny cards in the conversation (Y / N).
- **MCP servers** — Settings → MCP servers: MCP apps in your Teleport cluster
  (`tsh mcp ls`; the beam connects with `tsh mcp connect`), or HTTP MCP servers
  on this Mac, which the app tunnels into the beam (`tsh ssh -R`, optionally
  fronted by `tsh proxy app`). Tunnels and proxies restart on their own and
  pause while your login is expired.
- **Services and logs** — right-click a sandbox for its beam-init services
  (`beamctl`): state, live logs, restart/stop/freeze/thaw. Beams created before
  beam-init became the default don't have it.
- **Local pi sessions** — the laptop icon opens a folder on this Mac and runs
  `pi` turns against it directly (`pi --mode json`), no beam or SSH involved;
  the agent/model picker and the "proxy the agent's Teleport app to this Mac"
  toggle double as pi's model backend. Experimental: no permission prompts,
  images, MCP, or GitHub sync yet.
- **Persistent session mode** (experimental) — keeps one `claude -p` process
  alive per session instead of spawning a fresh one every turn, preserving
  context without the per-turn tsh + claude startup cost.
- **Pick up where you left off** — ⌘O lists sessions synced to the GitHub repo
  and continues one in a new beam, restoring files, memory and the conversation.
- **Save locally** — save the beam's working directory to a folder on this Mac (⌘S).
- **Memory** — `~/.claude/projects/*/memory` + `CLAUDE.md` are pulled from the
  beam on every sync and put back when a session continues in a new beam
  (no panel of its own).
- **GitHub** — `gh` sign-in state and browser device-flow sign-in with the
  one-time code shown in the panel; searchable list of every repo you can
  access; branch dropdown with "＋ New branch…"; create a private repo; sync
  commits `<prefix>/sessions/<id>/transcript.{md,jsonl}`, the generated files
  and `<prefix>/memory/` over HTTPS using `gh` as the credential helper.
  Credentials are excluded and redacted before anything is committed; sync to a
  private repo.
- **Teleport login** — banner when `tsh` is logged out or expired, with a
  username field. SSO tenants finish in the browser; password tenants get
  iTerm2 (or Terminal.app) opened with the exact `tsh login` command and the
  app polls until you're in.
- **Published apps** — URLs on your tenant's domain (from `tsh beams publish`)
  are detected in the stream, opened in your browser, and shown as a 🌐 button
  in the toolbar.
- **Native** — real alerts and confirmations, Settings window (⌘,), sidebar
  and inspector, keyboard shortcuts, dark/light appearance.

## Run the prebuilt app

A compiled copy is committed at `dist/Beams.app`. It is signed ad hoc, so
after cloning or downloading, macOS will quarantine it; either right-click →
Open the first time, or clear the flag:

```bash
xattr -dr com.apple.quarantine dist/Beams.app && open dist/Beams.app
```

`Scripts/bundle.sh` refreshes `dist/Beams.app` on every build and bumps the
build number in `BUILD_NUMBER`, shown in About as "Version 0.1.0 (N)". Edit
`VERSION` to change the marketing version.

## Build

Only the Xcode Command Line Tools are required (no Xcode):

```bash
Scripts/bundle.sh            # swift build -c release → build/Beams.app (signed ad hoc, with icon)
open build/Beams.app
Scripts/test.sh              # Swift Testing suite
swift build                  # debug binary only
BEAMSUI_MOCK=1 .build/debug/Beams   # simulated beams, no cluster needed
```

`Scripts/bundle.sh` writes `Info.plist` (bundle id `com.teleport.beams.native`,
`NSAppleEventsUsageDescription` for the iTerm/Terminal hand-off) and renders
`AppIcon.icns` from `Resources/appicon.png`.

## Data

Same as the Go app: `~/Library/Application Support/BeamsUI/` with
`config.json`, `sessions/<id>/{meta.json,transcript.jsonl,memory/}` and a
`repos/` clone cache. You can run either app against the same data.

## Layout

```
Sources/Beams/BeamsApp.swift             @main, scenes, menu commands
Sources/Beams/AppModel.swift             @Observable state + all actions
Sources/Beams/AppModel+Files.swift       save-locally folder picker, workspace download
Sources/Beams/AppModel+MCP.swift         MCP tunnel/proxy reconciliation, agent proxy
Sources/Beams/Models.swift               Beam, Session, Config, stream events → transcript items
Sources/Beams/Services/ProcessRunner     child processes, PATH fix, streaming lines
Sources/Beams/Services/TshClient         tsh beams wrapper, status/login, MockClient
Sources/Beams/Services/Agent             Claude turn script, memory scripts, published-URL detector
Sources/Beams/Services/Codex             codex exec / exec resume, JSONL event mapping
Sources/Beams/Services/Pi                local pi turns against a folder on this Mac
Sources/Beams/Services/Beamctl           beam-init services: list/logs/restart/stop/freeze/thaw
Sources/Beams/Services/MCP               MCP server config, Teleport/laptop server kinds
Sources/Beams/Services/Supervisor        tunnel/proxy process lifecycle, backoff, health probes
Sources/Beams/Services/Images            paste/drop image attachments, scaling + encoding
Sources/Beams/Services/Secrets           exclude/redact patterns for sync and workspace pulls
Sources/Beams/Services/Store             config/sessions/transcripts/memory on disk
Sources/Beams/Services/GitHubSync        gh auth/repos/branches, git clone/commit/push, redaction
Sources/Beams/Views/*                    ContentView, TranscriptView, InspectorViews, SettingsView,
                                          MCPSettingsView, ServicesWindow, PreviousSessionsViews
Scripts/bundle.sh, Scripts/test.sh       app bundle and tests without Xcode
```

See `CLAUDE.md` for notes future Claude Code sessions should read first.
