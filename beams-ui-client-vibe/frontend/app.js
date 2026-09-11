/* Beams — frontend. Vanilla JS talking to the Go backend through Wails
   bindings (window.go.main.App) and events (window.runtime). */

const API = () => window.go.main.App;
const RT = () => window.runtime;

const S = {
  info: null,
  cfg: null,
  beams: [],
  sessions: [],
  current: null,          // session object
  busy: new Set(),        // session ids with a running turn
  tools: new Map(),       // tool_use_id -> element (current session only)
  panelOpen: true,
};

const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const short = (id) => (id || "").slice(0, 8);
const fmtUSD = (n) => "$" + (n || 0).toFixed(4);
const ago = (iso) => {
  const d = (Date.now() - new Date(iso).getTime()) / 1000;
  if (!isFinite(d)) return "";
  if (d < 60) return "now";
  if (d < 3600) return Math.floor(d / 60) + "m";
  if (d < 86400) return Math.floor(d / 3600) + "h";
  return Math.floor(d / 86400) + "d";
};

function toast(msg, kind = "info", ms = 4200) {
  const t = el("div", "toast " + kind, msg);
  $("toasts").appendChild(t);
  setTimeout(() => t.remove(), ms);
}
// toastHTML renders trusted markup (built with esc()) so a toast can carry a link.
function toastHTML(html, kind = "info", ms = 9000) {
  const t = el("div", "toast " + kind); t.innerHTML = html;
  $("toasts").appendChild(t);
  setTimeout(() => t.remove(), ms);
}

/* ---------------- published apps ---------------- */
function renderAppPill(sess) {
  const pill = $("head-app");
  const urls = (sess && sess.publishedUrls) || [];
  if (!urls.length) { pill.classList.add("hidden"); return; }
  const latest = urls[urls.length - 1];
  $("head-app-host").textContent = latest.replace(/^https:\/\//, "");
  pill.title = urls.length === 1 ? `Open ${latest}` : `Open ${latest}\n\nAlso published:\n${urls.slice(0, -1).join("\n")}`;
  pill.dataset.url = latest;
  pill.classList.remove("hidden");
}
const fail = (e) => { console.error(e); toast(String(e && e.message ? e.message : e), "err", 7000); };

/* ---------------- tiny markdown ---------------- */
function md(src) {
  const out = [];
  const lines = String(src).split("\n");
  let i = 0, para = [], list = null;
  const flushPara = () => { if (para.length) { out.push("<p>" + inline(para.join(" ")) + "</p>"); para = []; } };
  const flushList = () => { if (list) { out.push(`<${list.tag}>` + list.items.map((x) => "<li>" + inline(x) + "</li>").join("") + `</${list.tag}>`); list = null; } };
  while (i < lines.length) {
    const ln = lines[i];
    if (/^```/.test(ln)) {
      flushPara(); flushList();
      const lang = ln.slice(3).trim();
      const buf = [];
      i++;
      while (i < lines.length && !/^```/.test(lines[i])) buf.push(lines[i++]);
      i++;
      out.push(`<pre><code class="lang-${esc(lang)}">${esc(buf.join("\n"))}</code></pre>`);
      continue;
    }
    let m;
    if ((m = /^(#{1,3})\s+(.*)$/.exec(ln))) { flushPara(); flushList(); out.push(`<h${m[1].length}>${inline(m[2])}</h${m[1].length}>`); i++; continue; }
    if ((m = /^\s*[-*]\s+(.*)$/.exec(ln))) { flushPara(); if (!list || list.tag !== "ul") { flushList(); list = { tag: "ul", items: [] }; } list.items.push(m[1]); i++; continue; }
    if ((m = /^\s*\d+[.)]\s+(.*)$/.exec(ln))) { flushPara(); if (!list || list.tag !== "ol") { flushList(); list = { tag: "ol", items: [] }; } list.items.push(m[1]); i++; continue; }
    if (ln.trim() === "") { flushPara(); flushList(); i++; continue; }
    para.push(ln); i++;
  }
  flushPara(); flushList();
  return out.join("");
}
function inline(s) {
  return esc(s)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|\W)_([^_]+)_(?=\W|$)/g, "$1<em>$2</em>")
    .replace(/\[([^\]]+)\]\((https?:\/\/[^)]+)\)/g, '<a href="#" data-url="$2">$1</a>')
    // bare URLs (not already inside a markdown link) become clickable too
    // (a ">" prefix is allowed for <strong>/<em> wrappers, but not the "> that ends an <a> tag)
    .replace(/(^|[\s(]|(?<!")>)(https?:\/\/[^\s<>"')\]]+?)([.,;:!?]*)(?=$|[\s<)\]])/g, '$1<a href="#" data-url="$2">$2</a>$3');
}

/* ---------------- transcript rendering ---------------- */
const T = () => $("transcript");

function clearTranscript() {
  T().innerHTML = "";
  S.tools.clear();
}

function scrollBottom() {
  const t = T();
  const nearBottom = t.scrollHeight - t.scrollTop - t.clientHeight < 160;
  if (nearBottom) t.scrollTop = t.scrollHeight;
}

function addMsg(kind, gutter, bodyNode) {
  const m = el("div", "msg " + kind);
  const g = el("div", "gutter", gutter);
  const b = el("div", "body");
  if (typeof bodyNode === "string") b.innerHTML = bodyNode; else if (bodyNode) b.appendChild(bodyNode);
  m.append(g, b);
  removeThinking();
  T().appendChild(m);
  scrollBottom();
  return m;
}

function showThinking(label = "thinking") {
  removeThinking();
  const w = el("div", "msg system"); w.id = "thinking";
  w.append(el("div", "gutter", ""), (() => { const b = el("div", "body"); const t = el("span", "thinking"); t.append(el("span", "spin"), el("span", null, label + "…")); b.appendChild(t); return b; })());
  T().appendChild(w);
  scrollBottom();
}
const removeThinking = () => { const t = $("thinking"); if (t) t.remove(); };

function toolSummary(name, input) {
  if (!input || typeof input !== "object") return "";
  return input.description || input.command || input.file_path || input.pattern || input.query || input.url || input.prompt || Object.values(input).find((v) => typeof v === "string") || "";
}

function renderToolUse(blk) {
  const card = el("div", "tool");
  const head = el("div", "tool-head");
  head.append(el("span", "tname", blk.name), el("span", "tsum", toolSummary(blk.name, blk.input)), el("span", "tstate running", "●"));
  const body = el("div", "tool-body");
  body.append(el("div", "label", "input"));
  const pre = el("pre"); pre.textContent = JSON.stringify(blk.input, null, 2); body.appendChild(pre);
  card.append(head, body);
  head.onclick = () => card.classList.toggle("open");
  S.tools.set(blk.id, card);
  return card;
}

function attachToolResult(blk) {
  const card = S.tools.get(blk.tool_use_id);
  const text = Array.isArray(blk.content) ? blk.content.map((c) => c.text || "").join("\n") : String(blk.content ?? "");
  if (!card) {
    addMsg("stderr", "↳", document.createTextNode(text.slice(0, 4000)));
    return;
  }
  const st = card.querySelector(".tstate");
  st.className = "tstate " + (blk.is_error ? "err" : "ok");
  st.textContent = blk.is_error ? "✕" : "✓";
  const body = card.querySelector(".tool-body");
  body.append(el("div", "label", blk.is_error ? "error" : "result"));
  const pre = el("pre"); pre.textContent = text.length > 20000 ? text.slice(0, 20000) + "\n… (truncated)" : text;
  body.appendChild(pre);
}

function renderEvent(ev) {
  switch (ev.type) {
    case "beamsui.user":
      addMsg("user", "›", document.createTextNode(ev.text));
      break;
    case "system":
      if (ev.subtype === "init") {
        // Claude Code prints the session banner once; later turns resume silently.
        if (!S.initShown) addMsg("system", "◦", `session <span>${esc(short(ev.session_id))}</span> · ${esc(ev.model || "")} · ${esc(ev.cwd || "")} · ${esc(ev.permissionMode || "")}`);
        S.initShown = true;
        $("head-sub").textContent = `${ev.model || ""} · ${ev.cwd || ""}`;
      }
      break;
    case "assistant": {
      const blocks = (ev.message && ev.message.content) || [];
      for (const blk of blocks) {
        if (blk.type === "text" && blk.text.trim()) addMsg("assistant", "◈", md(blk.text));
        else if (blk.type === "tool_use") addMsg("assistant", "", renderToolUse(blk));
        else if (blk.type === "thinking" && blk.thinking) addMsg("system", "∴", esc(blk.thinking.slice(0, 600)));
      }
      break;
    }
    case "user": {
      const blocks = (ev.message && ev.message.content) || [];
      for (const blk of (Array.isArray(blocks) ? blocks : [])) if (blk.type === "tool_result") attachToolResult(blk);
      removeThinking();
      break;
    }
    case "result": {
      const ok = !ev.is_error;
      const secs = ((ev.duration_ms || 0) / 1000).toFixed(1);
      const m = addMsg("result" + (ok ? "" : " error"), ok ? "✓" : "✕",
        `${ok ? "done" : "error"} · ${ev.num_turns || 0} turns · ${secs}s · ${fmtUSD(ev.total_cost_usd)}${ok ? "" : " · " + esc((ev.result || "").slice(0, 300))}`);
      m.dataset.result = "1";
      break;
    }
    default:
      break;
  }
}

/* ---------------- sidebar ---------------- */
function renderBeams() {
  const ul = $("beam-list");
  ul.innerHTML = "";
  if (!S.beams.length) { ul.appendChild(el("li", "empty-li", "No sandboxes. Click ＋ to create one.")); return; }
  for (const b of S.beams) {
    const li = el("li");
    if (S.current && S.current.beamId === b.id) li.classList.add("active");
    const dot = el("span", "dot");
    const name = el("span", "name", b.name || b.id);
    const meta = el("span", "meta", (b.raw && b.raw.region) || b.state || "");
    const x = el("span", "x", "×"); x.title = "Delete beam";
    x.onclick = async (e) => {
      e.stopPropagation();
      if (!confirm(`Delete beam ${b.name}? This destroys the sandbox VM.`)) return;
      try { await API().DeleteBeam(b.id); toast(`Deleted ${b.name}`, "ok"); await loadBeams(); } catch (err) { fail(err); }
    };
    li.append(dot, name, meta, x);
    li.title = `id: ${b.id}\nowner: ${(b.raw && b.raw.owner) || ""}\nexpires: ${(b.raw && b.raw.expires) || ""}`;
    li.onclick = () => startSession(b);
    ul.appendChild(li);
  }
}

function renderSessions() {
  const ul = $("session-list");
  ul.innerHTML = "";
  if (!S.sessions.length) { ul.appendChild(el("li", "empty-li", "Sessions appear here.")); return; }
  for (const s of S.sessions) {
    const li = el("li", "session");
    if (S.current && S.current.id === s.id) li.classList.add("active");
    const row = el("div", "row");
    const dot = el("span", "dot" + (S.busy.has(s.id) ? " busy" : ""));
    const title = el("span", "title", s.title || "New session");
    const x = el("span", "x", "×"); x.title = "Delete session (local only)";
    x.onclick = async (e) => {
      e.stopPropagation();
      if (!confirm("Remove this session from the app? The beam is not touched.")) return;
      try { await API().DeleteSession(s.id); if (S.current && S.current.id === s.id) { S.current = null; showEmpty(); } await loadSessions(); } catch (err) { fail(err); }
    };
    row.append(dot, title, x);
    const meta = el("div", "meta", `${s.beamName} · ${s.turns} turns · ${fmtUSD(s.costUsd)} · ${ago(s.updated)}${s.lastSync ? " · synced" : ""}${(s.publishedUrls || []).length ? " · 🌐" : ""}`);
    li.append(row, meta);
    li.onclick = () => openSession(s);
    ul.appendChild(li);
  }
}

async function loadBeams() {
  try {
    const res = await API().ListBeams();
    S.beams = (res && res.beams) || [];
    renderBeams();
    if (res && res.errorKind) {
      if (res.errorKind === "auth" || res.errorKind === "notfound") { await checkTsh(); }
      else toast(res.error, "err", 8000);
      if (res.errorKind !== "auth") $("beam-list").innerHTML = `<li class="empty-li">${esc(res.errorKind === "notfound" ? "tsh not found" : "Couldn't list beams")}</li>`;
      else $("beam-list").innerHTML = `<li class="empty-li">Log in to Teleport to see your sandboxes.</li>`;
    } else hideAuthBanner();
  } catch (e) { fail(e); }
}

/* ---------------- Teleport login banner ---------------- */
function showAuthBanner(kind, status) {
  const b = $("auth-banner");
  b.classList.remove("hidden", "info");
  const title = $("auth-banner-title"), sub = $("auth-banner-sub");
  S.bannerState = { kind, status, at: Date.now() };
  if (kind === "pending") { // status is a progress string here, not a status object
    b.classList.add("info");
    title.textContent = "Waiting for Teleport login…";
    sub.textContent = status || "";
    return;
  }
  const canLogin = status && status.tshFound;
  $("btn-tsh-login").classList.toggle("hidden", !canLogin);
  $("btn-tsh-terminal").classList.toggle("hidden", !canLogin);
  $("tsh-user").parentElement.classList.toggle("hidden", !canLogin);
  if (canLogin) tshUser(); // prefill the username field
  if (kind === "notfound" || (status && !status.tshFound)) {
    title.textContent = "tsh not found";
    sub.textContent = (status && status.message) || "Install Teleport, or set the tsh path in Settings.";
  } else {
    title.textContent = `Not logged in to ${(status && status.proxy) || S.cfg.proxy || "Teleport"}`;
    sub.textContent = (status && status.message) || "";
  }
}
function hideAuthBanner() { $("auth-banner").classList.add("hidden"); }

// checkTsh refreshes the banner from tsh status; returns true when logged in.
async function checkTsh() {
  try {
    const st = await API().TshStatus();
    S.tsh = st;
    if (st.loggedIn) { hideAuthBanner(); return true; }
    showAuthBanner(st.tshFound ? "auth" : "notfound", st);
    return false;
  } catch (e) { fail(e); return false; }
}

let tshPoll = null;
// The username the banner will pass as --user; prefilled from settings or the macOS user.
function tshUser() {
  const el = $("tsh-user");
  if (!el.value.trim()) el.value = (S.cfg && S.cfg.teleportUser) || (S.info && S.info.osUser) || "";
  return el.value.trim();
}
async function refreshTshCmd() {
  try { S.tshCmd = await API().TshLoginCommand(tshUser()); } catch { /* mock */ }
  return S.tshCmd;
}
async function tshLogin() {
  const user = tshUser();
  if (!user) { toast("Enter the Teleport username to log in as.", "err"); $("tsh-user").focus(); return; }
  S.cfg.teleportUser = user;
  await refreshTshCmd();
  showAuthBanner("pending", `Starting: $ ${S.tshCmd}\nSSO clusters open your browser; password clusters open Terminal.`);
  $("btn-tsh-login").disabled = true;
  try { await API().TshLogin(user); } catch (e) { fail(e); $("btn-tsh-login").disabled = false; await checkTsh(); }
}
function startTshPoll() {
  stopTshPoll();
  let n = 0;
  tshPoll = setInterval(async () => {
    n++;
    if (await checkTsh()) { stopTshPoll(); toast(`Logged in to ${S.tsh.cluster} as ${S.tsh.user}`, "ok"); $("btn-tsh-login").disabled = false; await loadBeams(); }
    else if (n > 90) { stopTshPoll(); $("btn-tsh-login").disabled = false; }
    else if (!$("auth-banner").classList.contains("hidden")) showAuthBanner("pending", `Finish the login in Terminal, then come back. Checking every 3s…\n$ ${S.tshCmd || ""}`);
  }, 3000);
}
function stopTshPoll() { if (tshPoll) { clearInterval(tshPoll); tshPoll = null; } }
async function loadSessions() {
  try {
    S.sessions = (await API().ListSessions()) || [];
    renderSessions();
  } catch (e) { fail(e); }
}

/* ---------------- sessions ---------------- */
function showEmpty() {
  clearTranscript();
  const e = el("div", "empty");
  e.innerHTML = `<div class="empty-mark">◈</div><h2>Do all the things, inside a Beam</h2><p>Create or pick a sandbox on the left. Each session runs Claude Code (or another model choosable from Settings) in the beam, streams the conversation here, and can commit the transcript and memory to GitHub.</p>`;
  T().appendChild(e);
  $("composer").classList.add("hidden");
  $("head-title").textContent = "Pick a sandbox to start";
  $("head-sub").textContent = "";
  $("head-cost").textContent = "";
  $("btn-sync").title = "Open a session first";
  renderAppPill(null);
}

let starting = false;
async function startSession(beam) {
  if (starting) return;
  starting = true;
  try {
    // Reuse an untouched session on this beam instead of piling up empties.
    const empty = S.sessions.find((x) => x.beamId === beam.id && x.turns === 0 && !x.title && !S.busy.has(x.id));
    const s = empty || await API().NewSession(beam.id, beam.name || beam.id);
    await loadSessions();
    await openSession(s);
    probe(beam.id);
    $("prompt").focus();
  } catch (e) { fail(e); } finally { starting = false; }
}

async function probe(beamId) {
  try {
    const out = await API().ProbeBeam(beamId);
    const [user, home, ver] = out.split("\n");
    $("composer-hint").textContent = `${user}@${home} · ${ver || ""}`;
  } catch (e) {
    $("composer-hint").textContent = "probe failed: " + (e.message || e);
  }
}

async function openSession(s) {
  S.current = s;
  S.initShown = false;
  clearTranscript();
  $("composer").classList.remove("hidden");
  $("head-title").textContent = s.title || `Session on ${s.beamName}`;
  $("head-sub").textContent = `${s.beamName} · ${short(s.id)}`;
  $("head-cost").textContent = fmtUSD(s.costUsd);
  renderAppPill(s);
  renderBeams(); renderSessions();
  try {
    const lines = await API().LoadTranscript(s.id);
    for (const ln of lines) { try { renderEvent(JSON.parse(ln)); } catch { /* skip */ } }
    T().scrollTop = T().scrollHeight;
  } catch (e) { fail(e); }
  setBusyUI(S.busy.has(s.id));
  if (S.busy.has(s.id)) showThinking("working");
  await refreshMemory();
  renderGitHubPanel();
  $("sync-log").textContent = "";
}

function setBusyUI(busy) {
  $("btn-stop").classList.toggle("hidden", !busy);
  $("btn-send").classList.toggle("hidden", busy);
  $("prompt").disabled = false;
}

async function send() {
  const s = S.current;
  if (!s) return;
  const text = $("prompt").value.trim();
  if (!text || S.busy.has(s.id)) return;
  $("prompt").value = "";
  autosize();
  try {
    await API().SendPrompt(s.id, text);
    S.busy.add(s.id);
    setBusyUI(true);
    showThinking("thinking");
    if (!s.title) { s.title = text.split("\n")[0].slice(0, 80); $("head-title").textContent = s.title; }
    renderSessions();
  } catch (e) { fail(e); }
}

function autosize() {
  const p = $("prompt");
  p.style.height = "auto";
  p.style.height = Math.min(p.scrollHeight, 220) + "px";
}

/* ---------------- memory panel ---------------- */
async function refreshMemory() {
  if (!S.current) return;
  try { renderMemory((await API().ListMemory(S.current.id)) || []); } catch (e) { fail(e); }
}
function renderMemory(files) {
  const ul = $("memory-list");
  ul.innerHTML = "";
  $("memory-view").classList.add("hidden");
  if (!files.length) { ul.appendChild(el("li", "empty-li", "No memory pulled yet.")); return; }
  for (const f of files) {
    const li = el("li");
    li.append(el("span", "name", f.path), el("span", "meta", f.size + " B"));
    li.onclick = async () => {
      try {
        const txt = await API().ReadMemoryFile(S.current.id, f.path);
        const v = $("memory-view"); v.textContent = txt; v.classList.remove("hidden");
        [...ul.children].forEach((c) => c.classList.remove("active")); li.classList.add("active");
      } catch (e) { fail(e); }
    };
    ul.appendChild(li);
  }
}

/* ---------------- github panel ---------------- */
async function refreshGitHubAuth() {
  const dot = $("gh-auth-dot"), text = $("gh-auth-text");
  try {
    const st = await API().GitHubStatus();
    S.ghAuth = st;
    if (!st.installed) { dot.className = "dot err"; text.textContent = "GitHub CLI (gh) not installed — brew install gh"; }
    else if (st.loggedIn) { dot.className = "dot ok"; text.textContent = `Signed in to GitHub as ${st.user || "?"} (private repos OK)`; }
    else { dot.className = "dot err"; text.textContent = "Not signed in to GitHub"; }
    text.title = st.detail || "";
    $("btn-gh-login").classList.toggle("hidden", !st.installed || st.loggedIn);
    $("btn-gh-logout").classList.toggle("hidden", !st.loggedIn);
  } catch (e) { dot.className = "dot err"; text.textContent = "Could not check gh: " + (e.message || e); }
}
async function githubLogin() {
  $("gh-device").classList.remove("hidden");
  $("gh-code").textContent = "····-····";
  $("btn-gh-login").disabled = true;
  syncLog("Starting GitHub sign-in (browser device flow)…");
  try { await API().GitHubLogin(); } catch (e) { fail(e); $("gh-device").classList.add("hidden"); $("btn-gh-login").disabled = false; }
}
function onGhLog(line) {
  syncLog(line);
  const m = /\b([A-Z0-9]{4}-[A-Z0-9]{4})\b/.exec(line);
  if (m) $("gh-code").textContent = m[1];
}
async function onGhDone({ error, status }) {
  $("gh-device").classList.add("hidden");
  $("btn-gh-login").disabled = false;
  if (error) toast(error, "err", 8000); else toast(`Signed in to GitHub as ${status && status.user}`, "ok");
  await refreshGitHubAuth();
}
async function loadRepos(force = false) {
  if (S.repos && !force) return;
  const note = $("gh-repos-note"), btn = $("btn-gh-repos");
  btn.disabled = true; note.textContent = "loading…";
  try {
    S.repos = (await API().ListGitHubRepos()) || [];
    const dl = $("gh-repo-list");
    dl.innerHTML = "";
    for (const r of S.repos) { const o = document.createElement("option"); o.value = r.fullName; o.label = r.private ? "private" : "public"; dl.appendChild(o); }
    note.textContent = `${S.repos.length} repos accessible`;
  } catch (e) { note.textContent = "couldn't list repos"; fail(e); S.repos = null; }
  finally { btn.disabled = false; }
}
/* Branch dropdown: the repo's real branches plus a "New branch…" entry that
   reveals a name field. currentBranch() is what gets saved. */
function fillBranchSelect(names, want) {
  const sel = $("gh-branch-select");
  sel.innerHTML = "";
  for (const n of names) { const o = document.createElement("option"); o.value = n; o.textContent = n; sel.appendChild(o); }
  const nw = document.createElement("option"); nw.value = "__new__"; nw.textContent = "＋ New branch…"; sel.appendChild(nw);
  if (want && names.includes(want)) { sel.value = want; }
  else if (want) { sel.value = "__new__"; $("gh-branch-new").value = want; }
  else if (names.length) { sel.value = names.includes("main") ? "main" : names[0]; }
  else { sel.value = "__new__"; if (!$("gh-branch-new").value) $("gh-branch-new").value = "main"; }
  onBranchSelect();
}
function onBranchSelect() {
  const isNew = $("gh-branch-select").value === "__new__";
  $("gh-branch-new").classList.toggle("hidden", !isNew);
  if (isNew && document.activeElement === $("gh-branch-select")) $("gh-branch-new").focus();
}
function currentBranch() {
  const sel = $("gh-branch-select").value;
  return (sel === "__new__" ? $("gh-branch-new").value : sel).trim();
}
async function loadBranches(force = false) {
  const repo = $("gh-repo").value.trim();
  if (!repo.includes("/")) return;
  if (S.branchesFor === repo && !force) return;
  const want = S.branchesFor === repo ? currentBranch() : ((S.cfg.github.repo === repo && S.cfg.github.branch) || "");
  try {
    const names = (await API().ListGitHubBranches(repo)) || [];
    S.branches = names; S.branchesFor = repo;
    fillBranchSelect(names, want);
    if (!names.length) syncLog(`${repo} has no branches yet — the first sync will create one.`);
  } catch (e) { syncLog("branches: " + (e.message || e)); fillBranchSelect([], want); }
}
async function createRepo() {
  if (!(await saveGitHub())) return;
  const repo = S.cfg.github.repo;
  if (!repo) { toast("Set a repository (owner/name) first", "err"); return; }
  if (!confirm(`Create private repository ${repo} on GitHub?`)) return;
  try { const url = await API().CreateGitHubRepo(true); toast("Created " + repo, "ok"); syncLog("created " + url); } catch (e) { fail(e); }
}

function renderGitHubPanel() {
  const g = S.cfg.github || {};
  $("gh-repo").value = g.repo || "";
  if (S.branchesFor && S.branchesFor === g.repo) fillBranchSelect(S.branches || [], g.branch || "");
  else { fillBranchSelect([], g.branch || "main"); if (g.repo) loadBranches(); }
  $("gh-prefix").value = g.prefix || "beams";
  $("gh-autosync").checked = !!g.autoSync;
  $("btn-sync").title = S.current ? "Commit this session's transcript and memory" : "Open a session first";
  const last = $("gh-last");
  last.innerHTML = "";
  if (S.current && S.current.lastSync) {
    const a = el("a", null, "Last commit ↗"); a.href = "#"; a.dataset.url = S.current.lastSync;
    last.append("Last sync: ", a);
  } else last.textContent = "Not synced yet.";
}
async function saveGitHub() {
  const branch = currentBranch();
  if ($("gh-branch-select").value === "__new__") {
    if (!branch) { toast("Enter a name for the new branch.", "err"); $("gh-branch-new").focus(); return false; }
    if (!/^[A-Za-z0-9._\/-]+$/.test(branch) || branch.startsWith("-") || branch.includes("..") || branch.endsWith("/")) { toast(`"${branch}" isn't a valid branch name.`, "err"); return false; }
  }
  S.cfg.github = { repo: $("gh-repo").value.trim(), branch: branch || "main", prefix: $("gh-prefix").value.trim() || "beams", autoSync: $("gh-autosync").checked };
  try { await API().SaveConfig(S.cfg); toast("GitHub settings saved", "ok"); return true; } catch (e) { fail(e); return false; }
}
function syncLog(text) {
  const l = $("sync-log");
  l.textContent += (l.textContent ? "\n" : "") + text;
  l.scrollTop = l.scrollHeight;
}
async function syncNow() {
  if (!S.current) { toast("Open a session first — sync commits that session's transcript and memory.", "err", 6000); return; }
  if (!$("gh-repo").value.trim().includes("/")) { toast("Pick a repository (owner/name) first.", "err"); return; }
  if (!(await saveGitHub())) return;
  if ($("gh-branch-select").value === "__new__") syncLog(`Branch ${S.cfg.github.branch} doesn't exist yet — it will be created from the repo's default branch.`);
  $("btn-sync").disabled = true;
  syncLog("— sync started —");
  try {
    if (!((await API().ListMemory(S.current.id)) || []).length) { syncLog("Pulling memory from beam first"); await API().PullMemory(S.current.id); await refreshMemory(); }
    const res = await API().SyncToGitHub(S.current.id);
    if (res.committed) { toast("Pushed " + res.sha.slice(0, 8), "ok"); S.current.lastSync = res.url; renderGitHubPanel(); await loadSessions(); }
    else toast(res.message || "Nothing to commit");
  } catch (e) { fail(e); } finally { $("btn-sync").disabled = false; }
}

/* ---------------- settings modal ---------------- */
function openSettings() {
  const c = S.cfg;
  $("cfg-proxy").value = c.proxy || ""; $("cfg-tuser").value = c.teleportUser || ""; $("cfg-login").value = c.login || ""; $("cfg-tsh").value = c.tshBin || "tsh";
  $("cfg-workdir").value = c.workDir || "/home/beams/work"; $("cfg-perm").value = c.permissionMode || "bypass"; $("cfg-model").value = c.model || "";
  $("cfg-autoopen").checked = !c.disableAutoOpenApps;
  $("cfg-datadir").textContent = `Backend: ${S.info.backend}. Data: ${S.info.dataDir}`;
  $("modal").classList.remove("hidden");
}
async function saveSettings() {
  Object.assign(S.cfg, { proxy: $("cfg-proxy").value.trim(), teleportUser: $("cfg-tuser").value.trim(), login: $("cfg-login").value.trim(), tshBin: $("cfg-tsh").value.trim() || "tsh",
    workDir: $("cfg-workdir").value.trim() || "/home/beams/work", permissionMode: $("cfg-perm").value, model: $("cfg-model").value,
    disableAutoOpenApps: !$("cfg-autoopen").checked });
  try { await API().SaveConfig(S.cfg); S.info = await API().Info(); renderBackendChip(); $("modal").classList.add("hidden"); toast("Settings saved", "ok"); $("tsh-user").value = S.cfg.teleportUser || ""; await refreshTshCmd(); if (await checkTsh()) await loadBeams(); } catch (e) { fail(e); }
}
function renderBackendChip() {
  const c = $("backend-chip");
  c.textContent = S.info.backend === "mock" ? "mock" : (S.info.proxy || "tsh");
  c.className = "chip " + (S.info.backend === "mock" ? "warn" : "ok");
  c.title = S.info.backend === "mock" ? "BEAMSUI_MOCK=1 — simulated beams" : "tsh --proxy " + S.info.proxy;
}

/* ---------------- events from Go ---------------- */
function wireEvents() {
  RT().EventsOn("agent:event", ({ sessionId, line }) => {
    if (!S.current || sessionId !== S.current.id) return;
    let ev; try { ev = JSON.parse(line); } catch { return; }
    renderEvent(ev);
    if (ev.type !== "result") showThinking(ev.type === "assistant" && ev.message?.content?.some((b) => b.type === "tool_use") ? "running tool" : "thinking");
  });
  RT().EventsOn("agent:stderr", ({ sessionId, text }) => {
    if (!S.current || sessionId !== S.current.id) return;
    addMsg("stderr", "·", document.createTextNode(text));
  });
  RT().EventsOn("agent:done", ({ sessionId, error, session }) => {
    S.busy.delete(sessionId);
    if (session) {
      const i = S.sessions.findIndex((x) => x.id === session.id);
      if (i >= 0) S.sessions[i] = session;
      if (S.current && S.current.id === session.id) { S.current = session; $("head-cost").textContent = fmtUSD(session.costUsd); }
    }
    renderSessions();
    if (S.current && S.current.id === sessionId) {
      removeThinking();
      setBusyUI(false);
      if (error) addMsg("result error", "✕", esc(error));
      $("prompt").focus();
    }
    // A turn that died on credentials means "log in again": surface the banner.
    if (error && /not logged in|expired|no credentials|executable file not found|without a terminal|access denied|handshake failed/i.test(error)) checkTsh();
  });
  RT().EventsOn("app:published", ({ sessionId, url, opened, beam }) => {
    const i = S.sessions.findIndex((x) => x.id === sessionId);
    if (i >= 0) { S.sessions[i].publishedUrls = [...(S.sessions[i].publishedUrls || []), url]; }
    if (S.current && S.current.id === sessionId) { S.current.publishedUrls = [...(S.current.publishedUrls || []), url]; renderAppPill(S.current); }
    renderSessions();
    toastHTML(`🌐 ${esc(beam || "beam")} published an app${opened ? " — opened in your browser" : ""}:<br><a href="#" data-url="${esc(url)}">${esc(url)}</a>`, "ok", 12000);
  });
  RT().EventsOn("session:updated", (sess) => {
    if (!sess || !sess.id) return;
    const i = S.sessions.findIndex((x) => x.id === sess.id);
    if (i >= 0) S.sessions[i] = sess;
    if (S.current && S.current.id === sess.id) { S.current = sess; renderAppPill(sess); }
    renderSessions();
  });
  RT().EventsOn("memory:updated", ({ sessionId }) => { if (S.current && S.current.id === sessionId) refreshMemory(); });
  RT().EventsOn("sync:log", ({ sessionId, text }) => { if (S.current && S.current.id === sessionId) syncLog(text); });
  RT().EventsOn("sync:done", ({ sessionId, result }) => {
    if (S.current && S.current.id === sessionId && result && result.committed) { S.current.lastSync = result.url; renderGitHubPanel(); loadSessions(); }
  });
}

/* ---------------- boot ---------------- */
async function boot() {
  try {
    S.info = await API().Info();
    S.cfg = await API().GetConfig();
  } catch (e) { fail(e); return; }
  renderBackendChip();
  renderGitHubPanel();
  wireEvents();

  $("btn-refresh-beams").onclick = loadBeams;
  $("btn-new-beam").onclick = async () => {
    const b = $("btn-new-beam"); b.disabled = true; b.textContent = "…";
    toast("Creating beam…");
    try { const beam = await API().CreateBeam(); toast(`Beam ${beam.name} ready`, "ok"); await loadBeams(); startSession(beam); }
    catch (e) { fail(e); } finally { b.disabled = false; b.textContent = "＋"; }
  };
  $("btn-settings").onclick = openSettings;
  $("btn-cfg-cancel").onclick = () => $("modal").classList.add("hidden");
  $("btn-cfg-save").onclick = saveSettings;
  $("btn-send").onclick = send;
  $("btn-stop").onclick = () => S.current && API().StopTurn(S.current.id);
  $("head-app").onclick = () => { const u = $("head-app").dataset.url; if (u) API().OpenURL(u); };
  $("btn-toggle-panel").onclick = () => { S.panelOpen = !S.panelOpen; $("app").classList.toggle("panel-collapsed", !S.panelOpen); };
  $("btn-pull-memory").onclick = async () => { if (!S.current) return; try { const f = await API().PullMemory(S.current.id); renderMemory(f || []); toast(`Pulled ${(f || []).length} memory files`, "ok"); } catch (e) { fail(e); } };
  $("btn-restore-memory").onclick = async () => { if (!S.current) return; try { toast(await API().RestoreMemory(S.current.id), "ok"); } catch (e) { fail(e); } };
  $("btn-save-gh").onclick = saveGitHub;
  $("btn-sync").onclick = syncNow;
  $("btn-gh-login").onclick = githubLogin;
  $("btn-gh-cancel").onclick = () => API().GitHubLoginCancel();
  $("btn-gh-logout").onclick = async () => { if (!confirm("Sign the gh CLI out of github.com?")) return; try { await API().GitHubLogout(); } catch (e) { fail(e); } refreshGitHubAuth(); };
  $("btn-create-repo").onclick = createRepo;
  $("btn-gh-repos").onclick = () => loadRepos(true);
  $("gh-repo").addEventListener("change", () => loadBranches());
  $("gh-branch-select").addEventListener("change", onBranchSelect);
  $("gh-branch-new").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); saveGitHub(); } });
  $("gh-repo").addEventListener("focus", () => loadRepos());
  RT().EventsOn("gh:log", onGhLog);
  RT().EventsOn("gh:done", onGhDone);
  refreshGitHubAuth().then(() => { if (S.ghAuth && S.ghAuth.loggedIn) loadRepos(); });
  document.querySelectorAll(".tab").forEach((t) => t.onclick = () => {
    document.querySelectorAll(".tab").forEach((x) => x.classList.toggle("active", x === t));
    $("tab-memory").classList.toggle("hidden", t.dataset.tab !== "memory");
    $("tab-github").classList.toggle("hidden", t.dataset.tab !== "github");
  });

  const p = $("prompt");
  p.addEventListener("input", autosize);
  p.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); }
    if (e.key === "Escape" && S.current && S.busy.has(S.current.id)) API().StopTurn(S.current.id);
  });
  document.addEventListener("click", (e) => {
    const a = e.target.closest("a[data-url]");
    if (a) { e.preventDefault(); API().OpenURL(a.dataset.url); }
  });

  $("btn-tsh-login").onclick = tshLogin;
  $("btn-tsh-terminal").onclick = async () => {
    const user = tshUser();
    if (!user) { toast("Enter the Teleport username to log in as.", "err"); $("tsh-user").focus(); return; }
    S.cfg.teleportUser = user;
    await refreshTshCmd();
    try { await API().OpenTerminalLogin(user); showAuthBanner("pending", `Finish the login in Terminal.\n$ ${S.tshCmd || ""}`); startTshPoll(); } catch (e) { fail(e); }
  };
  $("tsh-user").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); tshLogin(); } });
  $("tsh-user").addEventListener("change", refreshTshCmd);
  $("btn-tsh-recheck").onclick = async () => { if (await checkTsh()) { toast("Logged in", "ok"); await loadBeams(); } };
  S.tshLog = [];
  RT().EventsOn("tsh:log", (line) => { S.tshLog.push(line); if (!$("auth-banner").classList.contains("hidden")) showAuthBanner("pending", line); });
  RT().EventsOn("tsh:done", async ({ error, needsTerminal, status, command }) => {
    S.lastTshDone = { error, needsTerminal, status, command };
    if (command) S.tshCmd = command;
    if (status && status.loggedIn) { stopTshPoll(); hideAuthBanner(); $("btn-tsh-login").disabled = false; toast(`Logged in to ${status.cluster} as ${status.user}`, "ok"); await loadBeams(); return; }
    if (needsTerminal) { showAuthBanner("pending", `This cluster uses password login, so Terminal was opened with:\n$ ${S.tshCmd || ""}\nFinish there; this screen updates by itself.`); startTshPoll(); return; }
    $("btn-tsh-login").disabled = false;
    if (error) toast(error, "err", 9000);
    await checkTsh();
  });
  await refreshTshCmd();

  await loadSessions();
  if (await checkTsh()) await loadBeams();
  else $("beam-list").innerHTML = `<li class="empty-li">Log in to Teleport to see your sandboxes.</li>`;
  // Mark sessions the backend still has running (e.g. after a frontend reload).
  for (const s of S.sessions) { try { if (await API().IsRunning(s.id)) S.busy.add(s.id); } catch { /* ignore */ } }
  renderSessions();
}

if (window.go && window.runtime) boot();
else window.addEventListener("load", () => setTimeout(boot, 50));
