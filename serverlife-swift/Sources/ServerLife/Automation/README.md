# Automation — control socket, MCP bridge, S3, AWS

Owner: **automation**. Ports `src/main/control.js`, `src/renderer/js/automation.js`,
main.js `CONTROL_VERBS` / `control:*` / `s3:*` / `aws:*`, `mcp/serverlife-mcp.mjs`
(as `ServerLife --mcp`), `src/main/s3.js`, `src/main/awscreds.js`,
`src/main/awsproxy.js` and `src/renderer/js/s3.js`. Resources/MCP.md is the
protocol spec and is followed as written (paths differ: see below).

## Files

| File | What |
|---|---|
| `AutomationFeature.swift` | `install()`: actions, S3 list load, control socket start, quit teardown |
| `Control/ControlServer.swift` | the Unix socket (0600, in the per-user temp dir), token file (0600), auth, NDJSON, 1 MB line cap |
| `Control/ControlKube.swift` | main-side read-only kube verbs: list_kube_resource_types, list_kube_resources, get_kube_resource, describe_kube_resource (`resolveKubeContext`/`resolveKubeType`) |
| `Control/ControlVerbs.swift` | main-side verbs: status, list_hosts (beams, kube clusters, profile hostnames), list_clusters, login_command, list_layouts, list_beams, list_forwards, open_forward, list_requests, run_request, sync_preview, sync_apply; `targetConnection` |
| `Control/AutomationWindow.swift` | window-side verbs (automation.js): list_sessions, search, open_session(s), list_tmux, close_session (asks first), get/set_settings, load/save_layout, list/run_macro (waits, returns output), type_text, read_output, focus_window; `findHost` (beams by name/UUID/`beam-<uuid>`), `openOne` (kube clusters, beams, `tab`), `kubeClusterNamed`; `AutoHostPrefs` |
| `Control/AutomationControl.swift` | `control:status/setEnabled/rotateToken`, activity line, `mcpCommand` |
| `Control/AutomationHooks.swift` | extension point for fleet (macros) |
| `Control/MCPBridge.swift`, `MCPTools.swift` | `ServerLife --mcp` (JSON-RPC over stdio; the 30 tools copied verbatim from the original's TOOLS array) |
| `S3/SigV4.swift` | Signature V4 (tested against AWS's published S3 vectors) |
| `S3/S3Target.swift` | pure s3.js: storage classes, credentials, endpoints/URIs, prefixes, XML, errors |
| `S3/S3HTTP.swift`, `S3/S3Client.swift` | URLSession exchange (no redirects, streamed uploads, tunnel + CA pinning; downloads to a file go through `/usr/bin/curl --raw` so a Content-Encoded object is saved byte for byte — URLSession always decodes); list/prefixInfo/head/download/upload/remove/copy/listBuckets/bucketRegion/test; 301 region retry |
| `S3/AWSCreds.swift`, `S3/AWSProxy.swift` | ~/.aws profiles (CLI `export-credentials`, static-key fallback); `tsh proxy aws` per app, apps/roles/login/logout |
| `S3/S3Secrets.swift` | stored keys sealed with AES-GCM, key in the login Keychain; refused without one |
| `S3/S3Service.swift` | `S3Service.shared`: targets (no secrets), save/delete, `usable`, every `s3:*` / `aws:*` handler, relays |
| `S3/S3FileSource.swift` | a bucket as a `FileSource` |
| `S3/S3UI.swift`, `S3Editor.swift`, `S3UIBase.swift` | manager, register/edit, browse buckets, storage-class picker, *Saved → S3* tab view, explorer helpers |
| `_AutomationDataStandIn.swift` | store.js stand-ins (s3Targets, layouts, forwardFavorites, netRequests, tshLogins, profiles), prefixed `auto…` |

## Action ids

| id | does | args |
|---|---|---|
| `s3` (menu) | S3 buckets manager | — |
| `s3-register` | Register / edit dialog | `target` JSON (a record from `S3Service.shared.targets`) to edit |
| `s3-reload` | re-read `s3Targets` (after a backup import) | — |
| `automation-status` | `control:status` | `reply: (JSON) -> Void` → `{running, socketPath, tokenFile, token, clients, enabled, mcpCommand, bridge, verbs}` |
| `automation-toggle` | `control:setEnabled` | `enabled` Bool, `reply` (status fields or `{error}`) |
| `automation-rotate` | `control:rotateToken` (restarts a running socket) | `reply` → `{token}` |
| `automation-copy-command` | copies the `claude mcp add` line (`what` "mcp") or the binary path ("bridge"), status "Copied" | `what` |

Actions this **performs** that others own: `explorer-show-source` (explorer —
please register: args `source` "s3:<targetId>"; point the focused pane's explorer
at it, opening a local shell first if none, as sidebar.js `openS3InExplorer`),
`tmux-open` (consoles; args `login`, `session`), and for 0.39:
`search-data` (misc; `query`, `limit`, `kinds`, `reply`), `ai-type-request`
(ai; `verb` "type_text"/"read_output", `params` JSON incl. `_client`,
`reply: (Result<JSON, Error>) -> Void` — the approval dialog is ai's), and
`kube-browser` (kube-ui — please accept args `context` JSON (a
`Kube.listContexts` entry), `contextName`, `title`: open the cluster browser
in a tab of its own). Each unregistered id answers "… is not available to
automation in this build yet." Settings writes go through misc's
`SettingsDialog.apply` + `MiscHooks.settingsSaved`, the Save path.

## For the explorer (Files/Explorer)

- Sources: `S3Service.shared.sources: [S3FileSource]` (one per bucket, same order
  as `targets`; observe `S3Service.shared.generation` or append to `onChange`).
  Paths are key prefixes ("" = bucket root); entry paths are full keys;
  `extra["storageClass"]`. `capabilities` is empty; unsupported calls throw messages.
- `S3UI.contextMenu(owner, targetId:, entry:, selection:, prefix:, open:, copyToPane:, info:, refresh:) -> [CtxItem]`
  is `_s3ContextMenu` (feed it to `CtxMenu.show`).
- `S3UI.transfer(owner, from: .local/.s3(id:)/.remote(connId:), to:, entries:, destDir:)` is
  `s3Transfer` (storage-class prompt, relays, toasts); returns true when the
  destination should refresh. Copy-to-pane's picker stays yours.
- `S3UI.info(targetId:, entry:) -> [(label, value)]` is `_s3Info`;
  `download/upload/retier/delete` are `_s3Download/_s3Upload/_s3Retier/_s3Delete`;
  `pickStorageClass(owner, target:, current:)`.
- The original hides Sync, Details, search and the 3D view for a bucket.

## For the sidebar

`S3SavedTab(window:, filter:)` is *Saved → S3* (`renderS3Tab` + `s3Row`: empty
state, Buckets group, Register…/Manage…, row tooltip, double-click to browse,
the row's context menu). `S3UI.rowMenu(owner, t)` gives the menu as `CtxItem`s if
you draw rows yourself. The `s3Targets` reload the original did on sidebar
refresh is `S3Service.shared.reload()`.

## For fleet

Set `AutomationHooks.listMacros` (every macro incl. built-ins, as state.macros)
and `AutomationHooks.runMacro(window, macro, all)` (`sendMacro`). Until then
`list_macros` / `run_macro` answer "… is not available to automation in this build yet."

## Behaviour notes

- Off until Settings turns it on (`settings.controlSocket`). Socket:
  `<per-user temp dir>/serverlife-<sha256(dataDir+uid)[0:16]>.sock` (the temp dir is
  asked of the system, `confstr(_CS_DARWIN_USER_TEMP_DIR)`, so a shell with another
  TMPDIR still finds it). Token: `<dataDir>/control-token`, 64 hex, 0600. Every
  accepted call, the start/stop and denials show as "Automation: …" for 5 s.
- `ServerLife --mcp` finds the app by `SERVERLIFE_USER_DATA`, else `--data-dir`,
  else `~/Library/Application Support/ServerLife-Swift`; `SERVERLIFE_SOCKET`,
  `SERVERLIFE_TOKEN` override. One connection per call; calls are answered
  concurrently; never starts NSApplication or reads the Store.
- `mcpCommand` is `claude mcp add serverlife -- "<binary>" --mcp`, plus
  `-e SERVERLIFE_USER_DATA=…` when the app runs on a non-default data dir.
- Window verbs go to the focused window with the original's timeouts (60/120/300 s;
  search 30 s, type_text 300 s).
- The MCP bridge keeps `clientInfo.name` from `initialize` (≤ 60 chars) and sends
  it as `_client` on every call, so the typing prompt can name the assistant.
- `tsh proxy aws` runs with the cluster's own tsh variables (`TshEnv.vars(home:proxy:)`),
  as awsproxy.js's `tshEnv(home, proxy)`.

## Differences / not done

- Resources/MCP.md is rewritten for this port (`ServerLife --mcp`, ServerLife-Swift paths).
  The 0.39 text for the lead to copy is at the end of this file.
- A split opened by `open_session` on a saved profile is not tagged with the
  profile id (`SplitOptions` has no `profileId`; sessions — please add one).
- Paths: data dir is ServerLife-Swift, so the socket hash differs from the
  Electron app's and the two never collide; MCP.md's `node …mjs` lines read
  `"…/ServerLife" --mcp` here.
- `enc:` secrets from the Electron app (Chromium safeStorage) cannot be opened;
  such a bucket says to enter its key again.
- `s3:list` kept profile/app/role (the original dropped them, so editing a
  profile or Teleport bucket forgot its choice). A blank secret on a stored
  bucket is used for *Test* in the editor too.
- A bucket registered with a prefix: listings no longer join the prefix twice
  when opening a folder (`S3Pure.listingBase`).
- `open_session` throws "Could not open X." when the connection could not be
  created (the original reported success with the host name).
- tmux opens through `tmux-open` (fire and forget): the answer carries the
  session name asked for, not one read back.
- No original tests covered these files; Swift tests: SigV4 vectors, pure S3,
  AWS parsing, socket auth/rotation/permissions, MCP protocol, the `--mcp`
  binary end to end.

## Resources/MCP.md for 0.39 (lead: copy everything between the marker lines verbatim)

This is upstream's 0.39 MCP.md with the same port changes as the current
Resources/MCP.md (bridge = `ServerLife --mcp`, ServerLife-Swift paths, no
Windows/Linux rows).

<!-- BEGIN MCP.md -->
# Driving ServerLife from an agent (MCP)

ServerLife can be driven by another program through the [Model Context
Protocol](https://modelcontextprotocol.io). The work it is good for is the
repetitive part: *open the six servers I need for this upgrade*, *load the
layout I use on call*, *which clusters am I logged into and when do the
certificates expire*.

It is **off until you turn it on**, and what it can do is a fixed list — there
is no verb that runs a command of the caller's choosing. See
[What it cannot do](#what-it-cannot-do).

---

## Contents

- [Turning it on](#turning-it-on)
- [Registering with Claude Code](#registering-with-claude-code)
- [Other MCP clients](#other-mcp-clients)
- [The tools](#the-tools)
- [Worked examples](#worked-examples)
- [What it cannot do](#what-it-cannot-do)
- [How it works](#how-it-works)
- [Writing your own client](#writing-your-own-client)
- [Troubleshooting](#troubleshooting)

---

## Turning it on

**Settings → Local automation (MCP) → Allow local automation.**

Turning it on opens a socket that programs running as you can connect to: a
socket in your own temporary directory, mode `0600`.

Every connection has to present a token kept in the app's settings directory,
readable only by you. Each accepted call appears in the status bar as it
happens, so automation is never the one thing that happens quietly.

The same panel has:

- **Copy `claude mcp add`** — the exact line to register with Claude Code.
- **Copy bridge path** — the app's own binary, which is also the MCP server
  (`ServerLife --mcp`), for any other client.
- **New token** — revokes access immediately; re-register anything that was
  using it.

Turning the setting off stops the socket. Nothing else is affected.

---

## Registering with Claude Code

With the setting on, press *Copy `claude mcp add`* and run what it gives you:

```sh
claude mcp add serverlife -- "/Applications/ServerLife.app/Contents/MacOS/ServerLife" --mcp
```

The MCP server is the app's own binary run with `--mcp`: no Node, nothing else
to install. It never opens a window; it only relays to the running app. If the
app runs with a non-default settings directory (`--data-dir`), the copied line
also carries `-e SERVERLIFE_USER_DATA=…`.

The command carries no secret: the bridge finds the running app and reads the
token itself. Check it registered with:

```sh
claude mcp list
```

Then ask for something: *"which ServerLife hosts have env=prod?"*

To remove it again: `claude mcp remove serverlife`.

---

## Other MCP clients

Any client that spawns a stdio MCP server works. Point it at the binary with
`--mcp`:

```json
{
  "mcpServers": {
    "serverlife": {
      "command": "/Applications/ServerLife.app/Contents/MacOS/ServerLife",
      "args": ["--mcp"]
    }
  }
}
```

Three environment variables override discovery, which is mostly useful for
testing or a non-standard install:

| Variable | For |
| --- | --- |
| `SERVERLIFE_USER_DATA` | The settings directory to read the token from (default `~/Library/Application Support/ServerLife-Swift`) |
| `SERVERLIFE_SOCKET` | The socket path or pipe name directly |
| `SERVERLIFE_TOKEN` | The token itself, instead of reading the file |

---

## The tools

### Reading

| Tool | Returns |
| --- | --- |
| `serverlife_status` | Version, platform, whether `tsh` and `ssh` were found, and every logged-in cluster |
| `serverlife_list_hosts` | Teleport nodes with labels and available logins, ssh_config aliases (with the config file each came from), saved profiles, and Kubernetes clusters (`kind: "kube"` — logged in or available, never a requestable-only one, which needs an access request first). Each host also carries whether it is starred, the username set for it, and whether the agent is forwarded to it. Takes `query` (substring over names, clusters and labels) and `limit` |
| `serverlife_list_sessions` | What is open, per tab: pane kinds, hosts and connection state |
| `serverlife_list_layouts` | Saved layouts, with how many tabs and panes each holds |
| `serverlife_list_clusters` | Teleport profiles — user, roles, logins, expiry, tsh home — plus clusters saved for re-login |
| `serverlife_login_command` | The `tsh login` line for a cluster, `TELEPORT_HOME` included where it matters. Returns it; **does not run it** |
| `serverlife_search` | Everything in ServerLife matching some words — hosts, profiles, clusters, beams, tabs, macros, snippets, layouts, multi-exec runs, AI prompts and responses — the same search as the box at the top of the window |
| `serverlife_list_macros` | The macros you have saved, with the command each runs |
| `serverlife_list_beams` | Beams — ephemeral sandbox VMs — on every cluster that runs the service, with region and expiry. Takes `proxy` to limit to one cluster |
| `serverlife_sync_preview` | What a folder synchronisation *would* do between this machine and a server or a beam: every upload, download and deletion, with its reason. Changes nothing |
| `serverlife_list_forwards` | The tunnels open right now, and the ones saved as favourites — listen address, destination and host for each |
| `serverlife_list_requests` | The HTTP requests saved in Network and certificate tools, with the method and URL of each |
| `serverlife_read_output` | The last lines a terminal pane shows — the focused pane unless `tab` and `pane` (indexes from `list_sessions`) are given. Takes `lines` (default 80, at most 1000). Returns whatever the session displayed |
| `serverlife_list_tmux` | What tmux has running on a host — whether it is installed there at all, and each session with its window count and whether something is attached. Dials the host to ask. Takes `host` or `beam` (one required), `cluster`, `login` |

### tmux

A session opened with `tmux: true` runs inside tmux on the host, so it
outlives the window that opened it: the caller can go away — or be restarted —
and `serverlife_open_session` on the same host and session name later picks up
where it was left, scrollback and all. `tmuxSession` names which one; without
it the host's own setting decides, as it does in the app.

Left unset, `tmux` follows that same per-host setting rather than forcing a
plain session. An agent opening a set of hosts to work on is exactly when
losing the work to a dropped connection costs the most, so a host the user has
told the app to always open in tmux is not quietly downgraded by automation.

`serverlife_list_tmux` is the question to ask first: it says whether tmux is
installed there and what is already running, which is how a caller decides to
resume rather than start a second session beside the first.

**A beam is named like a host.** Its name (`fleet-aura`), its UUID or the
`beam-<uuid>` node it registers as all open it — through `tsh beams`, the way
the Beams list does, tmux included. `beam` takes the name instead of `host`, as
`serverlife_sync_apply` does, or `true`/`false` to say which is meant. A beam
only ever matches its exact name: when an ordinary host has exactly the same
name, the call is refused and names both until `beam` says which.
`serverlife_list_hosts` lists beams by name, and marks each `beam-<uuid>` node
with the beam it is.

Hosts that ask for MFA per session cannot use it, and say so rather than
failing obscurely: such a node is dialled with `tsh ssh` and an approval each
time, which is not a thing a session you attach to and detach from can do.

### Acting

| Tool | Does | Arguments |
| --- | --- | --- |
| `serverlife_open_session` | Opens one session — a Kubernetes cluster named as `host` opens its cluster browser tab instead (logging in first if it was only available), and ignores `login`/`filesOnly`/`tmux`/`tmuxSession` | `host` or `beam` (one required), `login`, `cluster`, `filesOnly`, `split` (`right`/`down`, not available for a Kubernetes cluster), `tab` (which open tab to split, by `list_sessions` index), `tmux`, `tmuxSession` |
| `serverlife_open_sessions` | Opens a set, in order | `sessions` (array of the above), `stopOnError` |
| `serverlife_close_session` | Closes a tab — **asks first if it's still live** | `index` or `title`, or `all: true` |
| `serverlife_get_settings` | Every app setting as it is right now | — |
| `serverlife_set_settings` | Changes one or more settings, the keys `serverlife_get_settings` returns | `patch` (required, `{ key: value }`) |
| `serverlife_load_layout` | Opens a saved layout, replacing what is open | `name` or `id` |
| `serverlife_save_layout` | Saves what is open now | `name` (required) |
| `serverlife_run_macro` | Runs one of **your** saved macros in the focused session | `name` (required), `allPanes`, `waitSeconds` (wait, then return what it printed) |
| `serverlife_type_into_session` | Pastes text into a session, and presses Enter if asked — **with your approval** | `text` (required), `enter`, `tab`, `pane` |
| `serverlife_open_forward` | Opens one of **your** saved tunnels, dialling its host first if needed | `name` or `id` |
| `serverlife_run_request` | Runs one of **your** saved HTTP requests and returns status, timing and body | `name` or `id`, `limit` |
| `serverlife_sync_apply` | Synchronises a folder with a server or a beam | `local` + `remote` (required), `host` **or** `beam`, `cluster`, `login`, `direction` (`up`/`down`/`both`), `compare` (`both`/`size`/`time`), `delete` |

**About synchronising.** `local` and `remote` are absolute paths; `host` is a
Teleport node or an ssh_config alias and `beam` is a beam name, so the same
tool covers a server and a sandbox. The connection is made the way the window
would make it — including the login it remembers for that host, which is
usually the difference between reading the files and "permission denied" — and
transfers appear in the app's own transfer queue.

Two things are deliberate:

- **Nothing is deleted unless `delete: true`.** Without it a sync only copies,
  which is the safe reading of an instruction that did not mention deleting.
- **Only what the preview lists is ever removed.** A folder is removed only
  after it is found to be empty, so a file that the walk never saw — one added
  since, or one the sync ignores — is never taken along with it.

Call `serverlife_sync_preview` first and show the person what it will do.

`host` is named the way a person would: a Teleport node hostname, an
`ssh_config` alias, a saved profile's name, a Kubernetes cluster name, or
`local` for a local shell. An unambiguous partial match is accepted; an
ambiguous one comes back listing the candidates, which is usually what you
want an agent to see.

### KubeLife

KubeLife — the optional Kubernetes module, see
[GUIDE.md](GUIDE.md#kubelife) — is named like a host, the same way a beam
already is, rather than a parallel set of kube-only tools:

- **`serverlife_list_hosts`** lists a kube cluster too (`kind: "kube"`,
  with `loggedIn` saying which) — logged in, or available but not yet
  logged in. A cluster you could only *request* access to is left out:
  that is a mutating action this interface still does not offer.
- **`serverlife_open_session`**, given a kube cluster's name as `host`,
  opens its cluster browser tab — logging in first if it was only
  available — instead of a terminal. `login`, `filesOnly`, `tmux` and
  `tmuxSession` mean nothing for one and are ignored; `split` is refused,
  since a cluster browser always opens its own tab through this
  interface.

What's *inside* an already-logged-in cluster, all read-only (no apply,
delete, scale or exec — the same deliberately conservative line every
other verb here holds):

| Tool | Returns | Arguments |
| --- | --- | --- |
| `serverlife_list_kube_resource_types` | Every resource kind the cluster actually has — `kubectl api-resources` under the hood, CRDs included | `cluster` (required) |
| `serverlife_list_kube_resources` | Resources of one kind, trimmed to name, namespace, status and age | `cluster`, `kind` (both required), `namespace`, `selector` (`-l` syntax), `limit` (default 100) |
| `serverlife_get_kube_resource` | One resource's own YAML | `cluster`, `kind`, `name` (all required), `namespace` |
| `serverlife_describe_kube_resource` | `kubectl describe` for one resource — conditions and recent events | `cluster`, `kind`, `name` (all required), `namespace` |

`cluster` takes either name `serverlife_list_hosts` shows a kube entry
as, or its exact kubeconfig context name — ambiguous ones say so, naming
every context they could mean. All four need the cluster already logged
in: there is no Machine ID here, and none planned for this interface —
log in first with `serverlife_open_session`.

`serverlife_get_settings`/`serverlife_set_settings`, being generic over
every setting, already cover `kubeEnabled` (on by default) too —
`serverlife_set_settings({ patch: { kubeEnabled: false } })` turns
KubeLife off, applying immediately the same way a cursor change does.

---

## Worked examples

**Set up for a piece of work.** One call, one pane per host:

```json
{
  "name": "serverlife_open_sessions",
  "arguments": {
    "sessions": [
      { "host": "db-1", "login": "ubuntu" },
      { "host": "db-2", "login": "ubuntu" },
      { "host": "lb-1", "split": "right" },
      { "host": "local" }
    ]
  }
}
```

A host that fails does not stop the rest; the result says which ones opened and
why the others did not:

```json
{
  "opened": 3,
  "failed": 1,
  "results": [
    { "ok": true, "host": "db-1 (prod)" },
    { "ok": true, "host": "db-2 (prod)" },
    { "ok": true, "host": "lb-1 (prod)" },
    { "ok": false, "host": "local", "error": "..." }
  ]
}
```

**Open a server with its file browser and no terminal**, beside what you are
looking at:

```json
{ "name": "serverlife_open_session",
  "arguments": { "host": "backup-1", "filesOnly": true, "split": "right" } }
```

**Open two servers side by side in one tab** — naming the tab to split
rather than counting on it still being focused:

```json
{ "name": "serverlife_open_session", "arguments": { "host": "web-1" } }
{ "name": "serverlife_list_sessions" }
{ "name": "serverlife_open_session",
  "arguments": { "host": "web-2", "split": "right", "tab": 0 } }
```

**Keep the arrangement**, then bring it back tomorrow:

```json
{ "name": "serverlife_save_layout", "arguments": { "name": "upgrade" } }
{ "name": "serverlife_load_layout", "arguments": { "name": "upgrade" } }
```

**Find what needs a fresh login**, then get the command to paste:

```json
{ "name": "serverlife_list_clusters" }
{ "name": "serverlife_login_command", "arguments": { "cluster": "prod" } }
```

**Switch the terminal cursor to a block**, as the Settings dialog's own Save
button would:

```json
{ "name": "serverlife_set_settings",
  "arguments": { "patch": { "cursorStyle": "block" } } }
```

**Open a Kubernetes cluster and check why a pod is crash-looping**, without
ever touching a terminal:

```json
{ "name": "serverlife_open_session", "arguments": { "host": "prod-eks" } }
{ "name": "serverlife_list_kube_resources",
  "arguments": { "cluster": "prod-eks", "kind": "Pod", "namespace": "checkout" } }
{ "name": "serverlife_describe_kube_resource",
  "arguments": { "cluster": "prod-eks", "kind": "Pod", "name": "checkout-7d9f8-x2z9p", "namespace": "checkout" } }
```

---

## What it cannot do

Deliberately, and this is the point:

- **No commands behind your back.** `serverlife_run_macro` runs a macro *you*
  wrote and can read. `serverlife_type_into_session` is the one way an agent
  can put its own text into a terminal, and by default you are shown the text
  and the pane and asked — *Don't allow*, *Paste only* or *Paste and run*.
  Settings → *Assistants typing into sessions* can make that *Allow without
  asking*, or *Never*, which refuses every call.
- **Output, not files.** `serverlife_read_output` returns the last lines a pane
  shows — which can be anything the session displayed — and nothing more.
- **No file transfers**, no reading remote or local files.
- **No credentials.** It cannot read your S3 secrets, SSH keys or Teleport
  certificates. `login_command` composes a command; it never runs one.
- **No new hosts.** It opens what is already in your inventory; it cannot add
  servers, write `~/.ssh/config`, or register buckets.
- **Kubernetes is read-only.** It can open a cluster and look at what's in
  it — no apply, delete, scale or exec. No Machine ID either: everything
  here runs as whatever is already logged in.

If you want any of that, it should be a deliberate decision with its own
setting — ask for it rather than assuming a future version added it quietly.

---

## How it works

```
MCP client (Claude Code)
  │  JSON-RPC over stdio
  ▼
ServerLife --mcp                the bridge: translates, decides nothing
  │  newline-delimited JSON over a local socket, token in the first line
  ▼
ServerLife (the running app)    checks the token, allows only known verbs
  │  for anything about tabs and panes
  ▼
The window                      opens, closes and arranges sessions
```

The bridge holds no policy: the app owns the token check and the verb list, so
editing the script grants nothing. Reads that need no window (clusters, tool
paths, layouts) are answered by the app directly; anything about tabs or panes
is asked of the focused window, because that is where they exist.

Each call opens its own connection, so a restarted app — or one started after
the client — is picked up without restarting anything.

---

## Writing your own client

You do not need MCP. The socket protocol is one JSON object per line, and the
first line must carry the token:

```sh
TOKEN=$(cat ~/Library/Application\ Support/ServerLife-Swift/control-token)
SOCK=$(ls "$(getconf DARWIN_USER_TEMP_DIR)"serverlife-*.sock | head -1)

printf '{"token":"%s","client":"my-script","verb":"list_hosts","params":{"query":"prod"}}\n' "$TOKEN" \
  | nc -U "$SOCK" -w 5
```

`-w 5` matters: without it `nc` exits when its stdin closes and you lose any
reply that took a moment — which is every verb that has to ask `tsh` or the
window something.

Anything with a socket library is steadier than `nc`:

```python
import json, socket
sock = socket.socket(socket.AF_UNIX)
sock.connect(SOCK)
sock.sendall((json.dumps({"token": TOKEN, "client": "my-script",
                          "verb": "open_sessions",
                          "params": {"sessions": [{"host": "db-1"}]}}) + "\n").encode())
buf = b""
while b"\n" not in buf:
    buf += sock.recv(65536)
print(json.loads(buf.split(b"\n")[0]))
```

The reply is a single line: `{"ok":true,"data":{…}}` or
`{"ok":false,"error":"…"}`. Verb names are the tool names without the
`serverlife_` prefix; parameters are identical. A bad token ends the
connection, and one request over 1 MB is refused.

---

## Troubleshooting

**"ServerLife is not listening."** The app is not running, or *Local automation*
is off. Both are worth checking in that order.

**"unauthorized."** The token changed — someone pressed *New token*, or the
settings directory was replaced. Re-register the client, or clear
`SERVERLIFE_TOKEN` if you set it by hand.

**"ServerLife has no control token yet."** The setting has never been turned on;
the token is created when it is.

**"No ServerLife window is open."** The app is running with every window closed
(macOS keeps the process alive). Open a window; reads that do not need one still
work.

**"No session is focused to run it in."** `run_macro` needs a session with a
live terminal. Open one first, or pass `allPanes` once a tab is focused.

**A host is not found.** Names come from the live inventory — call
`serverlife_list_hosts` and use what it returns. If a cluster's certificate has
expired its nodes are not listed at all; `serverlife_list_clusters` says so.

**Nothing appears in the status bar.** Activity is only shown for accepted
calls. A rejected token is logged as a denial instead.
<!-- END MCP.md -->
