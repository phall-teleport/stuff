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
