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

## Grandchildren can hold the output pipe (git credential helper)

`Shell.run` waits for the stdout/stderr readers to hit EOF after the child
exits. A grandchild that inherits the pipe keeps its write end open, so EOF
never comes and Sync hangs (git spawns `gh auth git-credential`, which lingers).
`StreamReader.finish()`/`finishText()` are bounded (`waitBounded`): after a 3s
grace they close the read handle to force `availableData` to return. Git calls
in `GitHubSync` also pass `timeout:` (fetch/push 120s, gh api 30-60s). The git
fetch itself is fast (~0.4s) — the hang was purely the pipe-inheritance wait.

## tsh serializes on a credential lock

Concurrent `tsh` commands contend on a per-key file lock in `~/.tsh`; while one
holds it, others block (seen as `could not acquire lock for TLS credential`, or
just a hang). A pile of background `tsh` probes will freeze the app's
`beams ls`, leaving an empty sidebar with no error. `Shell.run` now takes a
`timeout:` and `TshClient` uses it (ls/status 30-45s, create 180s, rm 60s) so a
wedged call surfaces an error instead of hanging. Don't run many concurrent
`tsh` commands against the same profile.

## SSO logins without the `beams` SSH login (2026-09-24)

Beams need the SSH login `beams` (Settings' "Beam login" overrides). The
`beam-user` role grants it; `beam-admin` does NOT. An SSO identity lacking
beam-user can list/create beams but every exec is refused (`principal "beams"
not in the set of valid principals`, cert shows `-teleport-nologin-…`), and
because tsh also offered every key in the ssh-agent, each attempt logged a burst
of failed logins. Now: all tsh calls set `TELEPORT_USE_LOCAL_SSH_AGENT=false`
(`TshClient.env`); `TshStatus` parses `roles`/`logins`; `sshBlockedReason`
blocks in-beam actions up front (`sshAllowed()` gate) and `noteSSHFailure`
records a refusal so later clicks explain instead of reconnecting;
`SSHAccessBanner` offers "Log in again" (roles are fixed at login). Settings has
`--auth=<connector>` and `--mfa-mode=browser` for `tsh login`, shared by the
in-app login and the Terminal hand-off (`TshClient.loginArgs`). Settings only
re-checks tsh when proxy/tsh binary/beam login change, debounced.
Verified 2026-09-24: `tsh status -f json` exposes `active.logins` and
`active.roles`; exec works with the agent switch. Re-logging in via SAML after
beam-user was mapped gave `Logins: beams`. Not verified: that the switch removes
the extra failed-key audit entries (needs a failing login to observe).

## Agents: Claude Code and Codex

`config.agent` selects the CLI run in the beam: `claude` (default) or `codex`.
Codex uses `codex exec --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -m <model> -- <prompt>`;
context continues across turns via `codex exec resume <thread_id>` (thread id
captured from the `thread.started` event, stored on `Session.codexThread`).
Codex JSONL events (`thread.started`, `item.completed` with agent_message /
file_change / command_execution, `turn.completed`) map to the shared
`TranscriptItem` model in `CodexEvents`. Codex has no interactive permission
protocol — beams are externally sandboxed, so approvals are bypassed. Model
lists live in `SettingsView` (`claudeModels`, `codexModels`). Codex flag note:
pass NO color flag — `--no-color` doesn't exist and `codex exec resume` rejects
`--color` (plain `exec` accepts it). Codex turns are slow (minutes). With a bad
thread id, `exec resume` silently starts a new thread instead of erroring.
Codex reports tokens, not dollars: `turn.completed.usage` is the THREAD's
running total, so `Session.codexUsage` keeps the latest [input, cached, output]
per thread id and the UI shows tokens (`costShort`/`costLong`) instead of $0.
Older sessions are backfilled from the transcript at boot (off main).

## Sync commits generated files too

`syncNow` pulls the beam's working directory (`config.workDir`, default
`/home/beams/work`) via `AgentScripts.workspacePull` — a `tar czf -` that
excludes node_modules/.git/target/dist/build/.venv/__pycache__/.next — unpacks
it to `store.workspaceDir(id)`, and `GitHubSync.sync` copies it to
`<prefix>/sessions/<id>/workspace/`. So a commit now has transcript.{md,jsonl},
per-session + latest memory, AND the generated project files. The pull script
must be sent through `Shell.quote` (the app does this); passing it unquoted to
`tsh beams exec` breaks because tsh flattens argv and re-parses on the remote.

## Saving the work folder to the Mac (2026-09-30)

Inspector → Save locally (and Session → Save Work Folder, ⌘S / ⇧⌘S) runs
`AgentScripts.workspaceDownload` (like workspacePull but keeps .git, dist,
build; still skips dependency caches and `Secrets.excludedPatterns`) and
unpacks into a folder picked with NSOpenPanel (`AppModel+Files.swift`).
Merge, not mirror: same-named files are replaced, nothing is deleted. The
folder is remembered per session (`Session.localFolder`/`localSaved`, which
the Go app drops if it rewrites the session). bsdtar rejects `..`/absolute
entries (tested). Verified 2026-09-30: the generated script against a beam.

## Secrets never leave the beam (incident 2026-09-23)

Workspace sync once pushed a tbot identity, private keys and `.env` tokens into
the PUBLIC phall-teleport/stuff repo (the repo was deleted and recreated).
Transcripts leaked them too, because the agent `cat`ed those files. Now:
`workspacePull` tar-excludes `Secrets.excludedPatterns` (.env, *.pem, keys,
tbot outputs, nested `*/beams/sessions`); `pullWorkspace` runs
`Secrets.redactFiles`; `GitHubSync.sync` redacts transcript.md/.jsonl,
conversation files, memory and workspace before committing. Keep every path
to GitHub going through `Secrets`. Sync targets should be private repos.
Redaction must stay linear and off the main actor (beach ball 2026-09-30: a
workspace holding the whole teleport repo, 14.8k files, took 258s on the main
thread after every turn; the KEY=value rule's unanchored `[A-Za-z0-9_]*` was
quadratic on base64/minified runs — 11s for one 29 KB SVG). The rule is now
word-anchored with bounded quantifiers (26s total), `pullWorkspace` redacts in
`Task.detached`, and `redactIsFastOnLongRuns` guards it.

## Layout feedback loops (blank sidebar/inspector, missing composer)

Symptom: after clicking, the sidebar and inspector go blank and the composer
disappears; the app stays alive and idle. Cause: a layout feedback loop in the
split view; AppKit throws `_postWindowNeedsUpdateConstraints` during layout, the
app swallows it, and the window is left half laid out. Two triggers, found with
`Tests/BeamsTests/LayoutProbe.swift` (see its header):
- Window narrower than ~990pt with the inspector open → min width is now 1040.
- `ContinueBanner` with a second control in its row (Picker, Menu, or button +
  popover) at ~1000–1100pt → the banner has ONE button; beam choice is in
  `ContinueSheet`. Keep controls out of banners in the main column.
- `.fixedSize(horizontal: false, vertical: true)` on wrapping text in the
  main column (the empty-state feature list, 2026-09-30) → blank sidebar AND
  inspector even with no session open. Let the frame's maxWidth wrap it.
The probe doesn't always crash: a PNG with blank side panes IS the bug (don't
write it off as an offscreen artifact). `BEAMS_LAYOUT_PROBE="none|…"` renders
the empty state (no session).
Also never do disk I/O in a view body (`restorePlan` is cached, @ObservationIgnored).

## Picking up a previous session (from GitHub)

⌘O / the tray button on the Sessions header opens `OpenFromGitHubView`, which
lists `<prefix>/sessions/*` from the configured repo+branch (never hardcoded;
`GitHubSync.listRemoteSessions` → `scanSessions`). Titles come from `meta.json`
(written by sync since 2026-09-23) or, for older syncs, the transcript.md header
(`parseTranscriptHeader`). Importing copies transcript/memory/workspace/
conversation files into the local store; the session then shows
`ContinueBanner` because its beam is gone (`beamGone`: beams loaded and id
absent). "Continue here" (`continueSession`) restores workspace → workDir,
memory → ~/.claude, and the agent conversation, then rebinds beamId.

Conversation files make resume work across beams (verified 2026-09-23: copying
only `~/.claude/projects/-home-beams-work/<session-id>.jsonl` into a fresh beam
let `claude --resume` continue with full context). Sync saves it as
`claude-session.jsonl` (Codex: `codex-session.jsonl` + `Session.codexSessionRel`,
best-effort, unverified). The project folder is `ClaudePaths.projectSlug(workDir)`
(non-alphanumerics → "-"). Without a conversation file, `needsFreshStart` makes
the next turn use `--session-id` (resume would fail), writes the old transcript
to `<workDir>/.beams/previous-session.md`, and prefixes the first prompt with a
note pointing at it; any `result` clears the flag. `runTurn` refuses to run in a
gone beam and hands the prompt back.

## MCP servers (Settings → MCP servers, 2026-09-30)

`config.mcpServers` ([MCPServer], Services/MCP.swift) is handed to every turn:
Claude via `--mcp-config '<json>'`, Codex via `codex -c mcp_servers.<n>.…`
(Codex path unverified). Two kinds:
- `.teleport`: an MCP app in the Beams cluster (`tsh mcp ls -f json`). The beam
  runs `tsh mcp connect <app>` itself (stdio) with its delegated identity
  (`TELEPORT_IDENTITY_FILE` is set in `beams exec` shells; tsh 18.11 is there).
- `.laptop`: HTTP MCP on the Mac's 127.0.0.1:<port>. `prepareMCP` keeps one
  `tsh ssh -N -R p:127.0.0.1:p beams@<beam uuid>` per beam (`tsh beams ssh/exec`
  have no -R; beams are OpenSSH nodes named by `uuid` from `beams ls`), and
  optionally `tsh apps login` + `tsh proxy app --port p <app>` (another
  cluster via `proxyCluster`). The turn script waits for the ports with curl.
  Long-lived tsh children run under `Supervised.argv`, which kills them when
  the app's stdin pipe closes (quit or crash); stop them with `closeStdin()`.
  Commands run in that wrapper must `exec` the real program (a surviving
  grandchild holds the output pipe and keeps it alive).
- `Supervisor` (after prism's internal/tunnel) owns each proxy/tunnel:
  restart with backoff 1s→30s (reset after 30s up), HTTP health probe of a
  proxy's port every 10s (restart after 6 failures), and NO start while the
  cluster's login is expired (`loginWait` reads `TshStatus.profileExpiry`,
  every profile's valid_until from one `tsh status`). tsh started on an
  expired cert begins a login by itself, so output that looks like a login
  prompt stops the process and waits; `checkTsh` seeing new certs calls
  `mcpLoginsChanged` (restart running, resume waiting). While anything waits,
  `watchForLogin` re-checks `tsh status` every 30s. `tsh proxy app` gets
  `--browser=none` (`tsh ssh`/`apps login` don't have that flag).
Verified 2026-09-30: reverse tunnel + wait loop against a beam, no orphans;
Supervisor restart/backoff/login-wait/no-orphan behavior in tests.
Not verified: a real MCP app (super-grass has none), `tsh proxy app` on an
MCP app, Codex MCP flags. `tsh mcp ls` with an expired cert starts a browser
SSO login by itself, so `loadMCPApps` requires `tsh.loggedIn`.

## beam-init services (2026-10-02)

Beams created since 2026-10 run beam-init as PID 1 with `beamctl` (older
beams don't; `Beamctl.listScript` prints a marker instead). Sandbox context
menu → "Services and logs…" opens `ServicesWindow` (a `WindowGroup(id:
"services", for: String.self)` keyed by beam id): `beamctl --json list`
(`{"name": "Stopped" | {"Running": {"main_pid", "pty"}} | {"Exited": n} |
{"Error": "…"} …}`, see beam-init-api ServiceStatus), logs via
`beamctl logs <name> [--follow]` streamed through `tsh beams exec` (follow
replays the snapshot first; lines arrive live, verified), and
restart/stop/freeze/thaw from the row's context menu. Switching service or
closing the window terminates the follower (gen-checked so tsh's "context
canceled" isn't shown); no beamctl is left running in the beam. beamctl
0.1.0 panics with BrokenPipe when its reader goes away (harmless).
`CopyButton` / `.copyable(text)` (an overlay, never changes layout) is on code
and tool blocks, permission summaries, the GitHub device code, Settings'
login command and the logs pane.

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

`Scripts/bundle.sh` bumps `BUILD_NUMBER` (CFBundleVersion) on every successful
build and reads the marketing version from `VERSION`; both are committed. It
fails on compile errors instead of bundling a stale binary.

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
- Never relaunch the app while any `tsh … beams exec` process exists: those are
  Paul's running turns and die with the app. Gate the relaunch on the count
  (`ps -Ao command | grep -c '[t]sh --proxy.*beams exec'`), don't just print it.
- Sentence-case labels ("Sync beam session", "Pull from beam").
