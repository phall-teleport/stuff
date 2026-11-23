# AI — the AI assistant panel (owner: ai)

A port of ai.js, aiclients.js and aiwaiting.js, plus the renderer half of
automation.js `type_text` / `read_output`, from 0.16.0 to 0.39.0. AI
assistants (Claude Code, Codex, Copilot CLI, OpenCode, Pi, Gemini CLI, or a
custom tool) run in a panel on the right of the window, each in its own
terminal, and are given ServerLife's own MCP tools.

## Files

| File | What it holds |
|---|---|
| `AIClients.swift` | `enum AIClients`, a port of aiclients.js. It covers the client table, `serverSpec` / `mcpFor` (each client's own way of getting MCP), `registerCommand` (Pi, Gemini), `splitWords`, `shq`, launchers (`withLauncher`, `knownLaunchers`, the prism/Codex recipe, `prismPort`), `launch`, `findOnPath`, `withToolPath` and `writeFiles`. It is pure, with no UI, and is unit-tested. |
| `AIService.swift` | `@MainActor enum AIService`, which ports main.js's `ai:*` handlers: `clients` (installed or not), `launch`, `check` (the readiness list with fixes), `preview` ("How it runs"), `register`, the `~/ServerLife AI` workdir with its AGENTS.md, and saved responses (`saveResponse`, `savedList` / `savedRead` / `savedDelete` / `savedReveal`). It also has the Store accessors for every `ai*` setting. |
| `AIWaiting.swift` | `looksLikeQuestion` and `screenTail`, from aiwaiting.js. |
| `AIWindow.swift` | `AISession` (one running assistant: a `SessionTermView` with a `PTYBackend`) and `AIWindow: WindowFeature` (per-window state). It handles sessions, show and hide, chips, question watching, the first message, askAi / askAbout, the save-response menus, rename and the key bar. It also holds `AIPrompts` (saved prompts plus the starters). |
| `AIOpen.swift` | `openAi` (check, then register, then launch, then offer "always"), `openAnother`, `checkAi`, `openAtStartup`, the assistants menu (`menuItems`: open, another, resume, how it runs, custom tools, launchers, saved prompts and responses), `describeHost` and `startupName`. |
| `AIDialogs.swift` | The dialogs: the check, registration, "How it runs", add/edit custom tool, edit prompt, New AI session (`openAiPrompt`) and Saved responses. |
| `AIPanel.swift` | `AIPanelView` (resizable; the width is kept in `aiPanelWidth`; focus follows the mouse when that is on), chips, the header buttons (☰ Prompts, ↓ Save, ⏎ Enter, +, ⟩) and the key bar (Esc ↑ ↓ ⏎ Enter). |
| `AITyping.swift` | `typeText` and `readOutput`, the MCP `type_text` / `read_output` verbs. Typing asks for approval in a sheet with a pane picker; the error strings are verbatim. |
| `AIMenu.swift` | `AIMenuItem` / `AIMenu`: menu descriptions that become an `NSMenu`. `AIMenu.append(items, to:)` lets another owner's menu include the AI items. |
| `AIFeature.swift` | `install()`: the slot, the actions and opening at startup. It also holds `AISidebarRow`, the "AI assistant" row of the Local group. |

## Slot

`Slots.rightPanel` / `Slots.rightPanelShown` are both assigned in
`AIFeature.install()`.

## Action ids registered

| id | args | does |
|---|---|---|
| `toggle-ai` | — | Shows or hides the panel. With nothing running, it opens the assistants menu (the ✦ button). |
| `ai-open` | `id` or `name` (client id), `prompt` | Opens that assistant. With no id, it shows the menu. |
| `ai-picker` | — | The assistants menu, at the mouse (profiles.js "AI assistant…"). |
| `ai-prompt` | — | The New AI session dialog (the AI row's double-click). |
| `ai-ask` | `text`, `source`/`title`, `send` Bool, `host` | "Ask the AI about this". The text is put into the assistant's input with where it came from, and is not sent. `send: true` sends it as it is (a saved prompt from search). With `host` and no text, the host is described (`the host <name> in ServerLife`). |
| `ai-pane-ask` | `paneId` | The pane-menu item "Ask the AI about this / about what is on screen". It sends the selection, or the last 60 lines, with `my session on <label>` or `my local shell` as the source. |
| `ai-type-request` | `verb` ("type_text" or "read_output"), `params` JSON, `reply` `(Result<JSON, Error>) -> Void` | Automation's typing verbs. `reply` is called asynchronously, after approval. |
| `ai-clients` | `fresh`, `reply` `(Any?)->Void` | Replies with `[JSON]` of `{id,name,vendor,available,custom}`. |
| `ai-saved-prompts` | `reply` | Replies with `[JSON]` of `{name,text}`. |
| `ai-saved-responses` | `reply` | Replies with `[JSON]` of `{title,file,path,size,mtime}`. |
| `ai-saved-open` | — | The Saved responses dialog. |
| `ai-prompt-save` | `text` | Save a prompt, pre-filled. |
| `ai-status` | `reply` | Replies with a JSON object `{running, waiting, shown, startup}`. |
| `ai-menu` | `menu` NSMenu, `row` Bool | Appends the assistants menu. With `row`, the AI row's extra items are added: Hide/Show the AI panel, Open at startup, and Check that a tool is ready. |
| `ai-sidebar-row` | `reply` | Replies with an `AnyView` of the "AI assistant" row (status dot, "N questions waiting" / "N running" / startup name, double-click for a new session, right-click for the menu). |

## Actions consumed

`open-local` and `send-text` (only through panes of their own), and
`settings`. The MCP bridge is `AutomationControl.binaryPath --mcp`, with
`SERVERLIFE_USER_DATA=AutomationControl.dataDir`.

## Not done, and why

- `AIFeature.install()` has to be called from `Features.installAll()`
  (App/Main.swift, owned by lead). Until it is, nothing in this directory is
  live.
- The sidebar's AI row is drawn by Sidebar, which has to add it to the
  Local group (between Local shell and SSH keys) using `ai-sidebar-row`.
- The pane-menu items "Ask the AI about this" and, in an AI pane, "Save the
  selection as a response…" / "Saved responses…" belong to Sessions' pane
  menu. The AI panel's own terminals already have them; ordinary panes need
  Sessions to call `ai-pane-ask`.
- The host context menu's "Ask the AI about this host" (sidebar.js:4635) is
  Sidebar's, through `ai-ask` with `host`.
- MCP `type_text` / `read_output` need Automation to add the verbs and
  forward them to `ai-type-request`.
- The Settings → AI section (index.js) is Misc's. It reads `ai-clients`.
- On Windows the client runs directly, with no shell; that path is not
  ported (macOS only).
