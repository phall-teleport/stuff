# Beams — project memory for Claude Code

Beams is a macOS app (Go + Wails v2, vanilla JS frontend) that runs Claude Code
inside Teleport Beams sandbox VMs and persists each session's transcript and
Claude memory to GitHub. Read this before touching the code.

## What it does, in one pass

1. Sidebar lists beams from `tsh beams ls`; ＋ runs `tsh beams add`.
2. Clicking a beam opens a session. Each prompt runs, inside the beam via
   `tsh beams exec`, `claude -p --verbose --output-format stream-json` with
   `--session-id <uuid>` on the first turn and `--resume <uuid>` afterwards.
   The session UUID doubles as the Claude Code session id in the beam.
3. Every stream-json line is appended to
   `~/Library/Application Support/BeamsUI/sessions/<id>/transcript.jsonl`
   and streamed to the UI (assistant text, collapsible tool calls, result
   footer with cost).
4. Memory = `~/.claude/projects/*/memory` + `~/.claude/CLAUDE.md` in the beam,
   pulled as a tarball over exec stdout, restorable via tar over exec stdin.
5. GitHub sync commits `<prefix>/sessions/<id>/transcript.{md,jsonl}` and
   `<prefix>/memory/` using local `git` + `gh` (HTTPS, gh as credential helper).
6. Published-app URLs (`https://<beam>-<port>.<tenant>`) are detected in the
   stream, opened in the browser, and shown as a 🌐 pill in the header.

## Layout

```
main.go                  Wails bootstrap; embeds frontend/ (fs.Sub)
app.go                   every exported method = window.go.main.App.<Method>
internal/beams/          Client interface, TshClient (real), MockClient,
                         auth.go (PATH fix, tsh status/login, error classes)
internal/agent/          turn script builder, stream-json reader, published URL detector
internal/store/          config.json, sessions/<id>/{meta.json,transcript.jsonl,memory/}
internal/ghsync/         clone/commit/push, repo+branch listing, gh login/status
frontend/{index.html,style.css,app.js}   no bundler, no npm
build/appicon.svg        icon source; appicon.png is rendered from it (qlmanage)
.claude/launch.json      local only (gitignored): "beams-dev"/"beams-mock" dev-server
                         configs pointing at ~/go/bin/wails; recreate if missing
```

Wails events used: `agent:event`, `agent:stderr`, `agent:done`,
`memory:updated`, `sync:log`, `sync:done`, `gh:log`, `gh:done`, `tsh:log`,
`tsh:done`, `app:published`, `session:updated`.

## Commands

```bash
wails build                       # → build/bin/Beams.app
open build/bin/Beams.app
wails dev                         # dev server on :34115 + native window
BEAMSUI_MOCK=1 wails dev          # simulated beams, no cluster needed
go vet ./... && go test ./internal/...
```

Wails CLI lives at `~/go/bin/wails`. There is no frontend build step
(`frontend:install`/`frontend:build` are empty in wails.json).

## Environment facts (verified 2026-09-11)

- Beams only work on the `super-grass.beams.sh` tenant. That tenant uses
  local password login, so `tsh login` needs a terminal; the app hands off to
  Terminal.app via osascript and polls `tsh status`. Paul's username there is
  `paul`. `phall.cloud.gravitational.io` has no BeamService.
- Inside a beam: login `beams`, HOME `/home/beams`, Debian 12, Claude Code +
  Node + git preinstalled, Anthropic auth pre-wired through env
  (`ANTHROPIC_BASE_URL` → tenant proxy). Default model `claude-sonnet-5`.
  `skipDangerousModePermissionPrompt` is on, so `--dangerously-skip-permissions`
  is the sandbox default here. Work dir defaults to `/home/beams/work`.
- `tsh beams exec <id> -- sh -lc '<quoted script>'`: tsh joins args with
  spaces for the remote shell, so scripts are single-quoted (`ShellQuote`).
  stdin, stdout and `tsh beams scp` all work.
- `tsh beams ls -f json` rows: `id, uuid, owner, expires, requested_region, region`.
- GitHub: Paul's gh login is `phall-teleport`; sync was verified into the
  private repo `phall-teleport/beams-sessions`. His usual target is
  `phall-teleport/stuff` on `main`.

## Gotchas that already bit us

- **Stopping `wails dev` deletes `build/bin`.** Rebuild before `open`.
- **Dock-launched apps get a bare PATH** (`/usr/bin:/bin:...`), so `tsh`/`gh`
  are invisible. `beams.AugmentPath()` runs at startup (login shell PATH +
  /usr/local/bin, Homebrew, ~/.tsh/bin). Test in `auth_test.go`.
- **Go nil slices reach JS as `null`.** Return `[]T{}` from bound methods
  and guard with `|| []` in JS. A null memory list once broke Sync silently.
- **Wails rebuilds and restarts the dev app on any Go edit**, which can kill a
  turn running through it. Check `pgrep -f 'tsh.*beams exec'` before
  relaunching the built app too.
- **macOS 26 icons must be full-bleed.** Transparent margins get wrapped in
  the system's light squircle (white rim). Icon cache: `killall Dock`; the
  stubborn system cache needs `sudo rm -rf /Library/Caches/com.apple.iconservices.store`.
- `tsh status` prints `Not logged in.` (no JSON, exit 1) when logged out; the
  parser treats missing JSON as logged out.
- The browser tool's synthetic Return key doesn't fire the textarea keydown;
  real keyboards do. Test Enter via a dispatched KeyboardEvent if needed.
- Wails `frontend:dev:serverUrl: auto` errors without a watcher; leave it out.

## Working agreements

- The agent work happens **in the beam**, never locally. Don't run prompts
  through the app just to test unless needed — each turn costs real money.
- Don't push to GitHub, create repos, or run `tsh login` on Paul's behalf
  without saying so; those are outward-facing. Creating a scratch private
  repo for a sync test was fine once he asked to test.
- Paul's config lives in `~/Library/Application Support/BeamsUI/config.json`
  and is shared by the dev app and the built app. If a test changes it,
  restore it.
- Sentence-case button labels ("Sync beam session", "Pull from beam").
  Dark theme only; tokens are in `:root` of style.css.
