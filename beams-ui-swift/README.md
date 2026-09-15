# Beams (native)

A fully native SwiftUI port of the Beams app: run **Claude Code inside a
Teleport Beam** sandbox from a macOS window, stream the conversation, and keep
the transcript and Claude's memory in **GitHub**. It shares its data directory
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
- **Transcript** — assistant markdown, collapsible tool cards with results,
  per-turn cost footer, stop button (⌘.). Enter sends, ⌥Enter inserts a newline.
- **Memory** — pull `~/.claude/projects/*/memory` + `CLAUDE.md` out of the
  beam; restore the last committed snapshot into a fresh beam.
- **GitHub** — `gh` sign-in state and browser device-flow sign-in with the
  one-time code shown in the panel; searchable list of every repo you can
  access; branch dropdown with "＋ New branch…"; create a private repo; sync
  commits `<prefix>/sessions/<id>/transcript.{md,jsonl}` and `<prefix>/memory/`
  over HTTPS using `gh` as the credential helper.
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

`Scripts/bundle.sh` refreshes `dist/Beams.app` on every build.

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
Sources/Beams/BeamsApp.swift            @main, scenes, menu commands
Sources/Beams/AppModel.swift            @Observable state + all actions
Sources/Beams/Models.swift              Beam, Session, Config, stream events → transcript items
Sources/Beams/Services/ProcessRunner    child processes, PATH fix, streaming lines
Sources/Beams/Services/TshClient        tsh beams wrapper, status/login, MockClient
Sources/Beams/Services/Agent            turn script, memory scripts, published-URL detector
Sources/Beams/Services/Store            config/sessions/transcripts/memory on disk
Sources/Beams/Services/GitHubSync       gh auth/repos/branches, git clone/commit/push
Sources/Beams/Views/*                   ContentView, TranscriptView, InspectorViews, SettingsView
Scripts/bundle.sh, Scripts/test.sh      app bundle and tests without Xcode
```

See `CLAUDE.md` for notes future Claude Code sessions should read first.
