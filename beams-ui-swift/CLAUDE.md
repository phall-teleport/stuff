# Beams (native SwiftUI) — project memory for Claude Code

Native macOS port of the Go/Wails Beams app in `../beams-ui-client-vibe`.
Same job: run Claude Code inside Teleport Beams sandboxes, stream the
transcript, keep transcript + memory in GitHub. Same data directory
(`~/Library/Application Support/BeamsUI`) and JSON layout, so both apps share
sessions and settings. Read the Go project's CLAUDE.md for tenant/beam facts;
this file covers what's specific to the Swift build.

## Toolchain constraints (the important part)

- Built with **SwiftPM + Command Line Tools only** (Swift 6.4, macOS 27 SDK).
  No Xcode is installed. Language mode is Swift 5 (`swiftLanguageVersions`).
- **`@State` does not compile here**: with the macOS 27 SDK it's a macro whose
  plugin (`SwiftUIMacros`) ships only with Xcode. Use `@StateObject` with the
  `LocalFlag` class in `Views/LocalState.swift` for per-view flags, and keep
  app state in the `@Observable AppModel`. `@Environment(AppModel.self)`,
  `@Bindable`, `@FocusState`, `@StateObject` are fine.
- **XCTest is unavailable**; tests use Swift Testing (`import Testing`,
  `@Test`, `#expect`). Run them with `Scripts/test.sh`, which passes
  `-plugin-path …/host/plugins/testing` — plain `swift test` fails to find the
  macro plugin.
- Bare-slash regex literals need `#/…/#` delimiters in Swift 5 mode.
- `Scripts/bundle.sh` makes `build/Beams.app`: release build, Info.plist,
  `AppIcon.icns` from `Resources/appicon.png` (full-bleed, macOS 26 masks it),
  ad-hoc codesign. Bundle id `com.teleport.beams.native` (distinct from the Go
  app). `NSAppleEventsUsageDescription` is required for the iTerm/Terminal
  hand-off via `NSAppleScript`.

## Permission prompts (verified 2026-09-15 against a real beam)

Print mode can't answer terminal permission prompts, so turns always run
`claude -p --output-format stream-json --input-format stream-json`; the prompt
is the first stream-json `user` message on stdin (`TurnOptions.userMessage`).
For any mode other than bypass we add `--permission-prompt-tool stdio`, and
Claude Code then emits
`{"type":"control_request","request_id":…,"request":{"subtype":"can_use_tool","tool_name","display_name","input","description","permission_suggestions","tool_use_id"}}`.
We reply on stdin with `control_response` → `{"behavior":"allow","updatedInput"}`
or `{"behavior":"deny","message"}` (`AppModel.answer`), and close stdin after
the `result` event so the process exits. `PermissionCard` renders the pending
request inline (Y/N shortcuts); decisions are recorded as `beamsui.permission`
lines in the transcript. `RunningProcess.send/closeStdin` are the plumbing.

## Do NOT use FileHandle.bytes / AsyncBytes for child output

`FileHandle.bytes.lines` (AsyncBytes) **stops delivering once the parent writes
to the child's stdin**, which deadlocks the interactive permission protocol
above (Claude asks, we write the allow, AsyncBytes never yields the result, the
turn hangs forever and the UI stacks retries). `Shell.run` reads stdout/stderr
with `StreamReader`, a blocking `availableData` loop on a `Thread`. Keep it that
way. Verified 2026-09-15: AsyncBytes hangs, StreamReader completes cleanly.

## tsh serializes on a credential lock

Concurrent `tsh` commands contend on a per-key file lock in `~/.tsh`; while one
holds it, others block (seen as `could not acquire lock for TLS credential`, or
just a hang). A pile of background `tsh` probes will freeze the app's
`beams ls`, leaving an empty sidebar with no error. `Shell.run` now takes a
`timeout:` and `TshClient` uses it (ls/status 30-45s, create 180s, rm 60s) so a
wedged call surfaces an error instead of hanging. Don't run many concurrent
`tsh` commands against the same profile.

## Agents: Claude Code and Codex

`config.agent` selects the CLI run in the beam: `claude` (default) or `codex`.
Codex uses `codex exec --json --color never --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -m <model> -- <prompt>`;
context continues across turns via `codex exec resume <thread_id>` (thread id
captured from the `thread.started` event, stored on `Session.codexThread`).
Codex JSONL events (`thread.started`, `item.completed` with agent_message /
file_change / command_execution, `turn.completed`) map to the shared
`TranscriptItem` model in `CodexEvents`. Codex has no interactive permission
protocol — beams are externally sandboxed, so approvals are bypassed. Model
lists live in `SettingsView` (`claudeModels`, `codexModels`). Codex flag note:
it's `--color never`, NOT `--no-color`. Codex turns are slow (minutes).

## Persistent session mode (experimental)

`config.persistentSession` (or `BEAMSUI_PERSISTENT=1`) keeps ONE
`claude -p --input-format stream-json` process alive per session and feeds each
turn as a stream-json user message — verified a single process handles turns in
sequence with context preserved, removing per-turn tsh+claude startup.
`runTurnPersistent` starts it once; `result` clears per-turn state without
closing stdin; `endPersistent` tears it down. Codex always runs per-turn.

## Architecture

- `AppModel` (`@MainActor @Observable`) owns all state and actions; views are
  thin. Turn output arrives through `Shell.run(onStdoutLine:)` callbacks that
  hop to the main actor.
- `Shell` resolves binaries on an augmented PATH (login shell PATH +
  /usr/local/bin, Homebrew, ~/.tsh/bin) because Dock launches get a bare PATH.
- `BeamClient` protocol: `TshClient` (real) / `MockClient` (`BEAMSUI_MOCK=1`).
- Transcript model: stream-json lines → `TranscriptItem`s via
  `TranscriptItem.items(from:seq:)`; tool results attach to their tool card.
- Markdown: `MarkdownBlocks.parse` splits blocks; inline text goes through
  `AttributedString(markdown:)` with bare URLs linkified first.
- Go `time.Time` JSON has up to 9 fractional digits; `RFC3339.parse` trims to 3.

## Commands

```bash
Scripts/bundle.sh && open build/Beams.app
Scripts/test.sh
swift build
BEAMSUI_MOCK=1 .build/debug/Beams
```

## Working agreements (same as the Go app)

- Agent work happens in the beam, never locally; test turns cost money.
- Don't push to GitHub, create repos, or run `tsh login` for Paul unasked.
- Config is shared with the Go app; restore anything a test changes.
- Sentence-case labels ("Sync beam session", "Pull from beam").
