package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/wailsapp/wails/v2/pkg/runtime"

	"github.com/phall-teleport/beamsui/internal/agent"
	"github.com/phall-teleport/beamsui/internal/beams"
	"github.com/phall-teleport/beamsui/internal/ghsync"
	"github.com/phall-teleport/beamsui/internal/store"
)

// App is the Wails-bound backend. Every exported method is callable from the
// frontend as window.go.main.App.<Method>.
type App struct {
	ctx    context.Context
	st     *store.Store
	client beams.Client
	cfg    store.Config

	mu      sync.Mutex
	running map[string]context.CancelFunc // sessionID -> cancel for the active turn
}

func NewApp() *App { return &App{running: map[string]context.CancelFunc{}} }

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	beams.AugmentPath() // Dock launches get a bare PATH; find tsh/gh anyway
	st, err := store.Open()
	if err != nil {
		runtime.LogFatalf(ctx, "open store: %v", err)
	}
	a.st = st
	a.cfg = st.LoadConfig()
	a.buildClient()
}

func (a *App) buildClient() {
	if os.Getenv("BEAMSUI_MOCK") == "1" {
		a.client = beams.NewMock()
		return
	}
	a.client = beams.NewTsh(a.cfg.TshBin, a.cfg.Proxy, a.cfg.Login)
}

// ---------- info & config ----------

type Info struct {
	Backend string `json:"backend"`
	Proxy   string `json:"proxy"`
	Version string `json:"version"`
	DataDir string `json:"dataDir"`
	OSUser  string `json:"osUser"` // default Teleport username when none is configured
}

func (a *App) Info() Info {
	return Info{Backend: a.client.Kind(), Proxy: a.cfg.Proxy, Version: "0.1.0", DataDir: a.st.Root, OSUser: os.Getenv("USER")}
}

func (a *App) GetConfig() store.Config { return a.cfg }

func (a *App) SaveConfig(cfg store.Config) error {
	if err := a.st.SaveConfig(cfg); err != nil {
		return err
	}
	a.cfg = cfg
	a.buildClient()
	return nil
}

// ---------- beams ----------

// BeamsResult carries the list plus a classified error so the UI can show a
// login prompt instead of a raw tsh message.
type BeamsResult struct {
	Beams     []beams.Beam `json:"beams"`
	Error     string       `json:"error"`
	ErrorKind string       `json:"errorKind"` // "", "auth", "notfound", "other"
}

func classify(err error) string {
	switch {
	case err == nil:
		return ""
	case beams.IsNotFoundError(err):
		return "notfound"
	case beams.IsAuthError(err):
		return "auth"
	default:
		return "other"
	}
}

func (a *App) ListBeams() BeamsResult {
	ctx, cancel := context.WithTimeout(a.ctx, 60*time.Second)
	defer cancel()
	list, err := a.client.List(ctx)
	if list == nil {
		list = []beams.Beam{}
	}
	res := BeamsResult{Beams: list, ErrorKind: classify(err)}
	if err != nil {
		res.Error = err.Error()
	}
	return res
}

// ---------- Teleport login ----------

func (a *App) tsh() *beams.TshClient {
	if t, ok := a.client.(*beams.TshClient); ok {
		return t
	}
	return beams.NewTsh(a.cfg.TshBin, a.cfg.Proxy, a.cfg.Login)
}

// TshStatus reports whether tsh is present and logged in to the configured proxy.
func (a *App) TshStatus() beams.Status {
	if a.client.Kind() == "mock" {
		return beams.Status{TshFound: true, LoggedIn: true, Proxy: "mock", User: "mock", Cluster: "mock", Message: "Mock backend"}
	}
	ctx, cancel := context.WithTimeout(a.ctx, 20*time.Second)
	defer cancel()
	return a.tsh().Status(ctx)
}

// rememberUser persists the Teleport username the user typed into the banner
// so the next login and the Settings dialog show it.
func (a *App) rememberUser(user string) string {
	user = strings.TrimSpace(user)
	if user == "" {
		return a.cfg.TeleportUser
	}
	if user != a.cfg.TeleportUser {
		a.cfg.TeleportUser = user
		_ = a.st.SaveConfig(a.cfg)
	}
	return user
}

// TshLoginCommand is what the user would type by hand.
func (a *App) TshLoginCommand(user string) string {
	if strings.TrimSpace(user) == "" {
		user = a.cfg.TeleportUser
	}
	return a.tsh().LoginCommand(strings.TrimSpace(user))
}

// TshLogin runs tsh login in the background as the given user. Output
// arrives on tsh:log; tsh:done carries {error, needsTerminal, status}. When
// a terminal is required (local password auth), Terminal.app is opened.
func (a *App) TshLogin(user string) error {
	user = a.rememberUser(user)
	a.mu.Lock()
	if _, busy := a.running["__tsh_login"]; busy {
		a.mu.Unlock()
		return errors.New("a Teleport login is already in progress")
	}
	ctx, cancel := context.WithTimeout(a.ctx, 5*time.Minute)
	a.running["__tsh_login"] = cancel
	a.mu.Unlock()
	go func() {
		defer func() {
			cancel()
			a.mu.Lock()
			delete(a.running, "__tsh_login")
			a.mu.Unlock()
		}()
		err := a.tsh().RunLogin(ctx, user, func(s string) { runtime.EventsEmit(a.ctx, "tsh:log", s) })
		needsTerminal := errors.Is(err, beams.ErrNeedsTerminal)
		msg := ""
		if err != nil && !needsTerminal {
			msg = err.Error()
		}
		if needsTerminal {
			if terr := a.OpenTerminalLogin(user); terr != nil {
				msg = "This cluster needs a password prompt. Run in a terminal: " + a.TshLoginCommand(user)
			}
		}
		runtime.EventsEmit(a.ctx, "tsh:done", map[string]any{"error": msg, "needsTerminal": needsTerminal, "status": a.TshStatus(), "command": a.TshLoginCommand(user)})
	}()
	return nil
}

// OpenTerminalLogin opens Terminal.app running the tsh login command so the
// password prompt happens where it belongs.
func (a *App) OpenTerminalLogin(user string) error {
	user = a.rememberUser(user)
	cmd := a.TshLoginCommand(user)
	script := fmt.Sprintf(`tell application "Terminal"
	activate
	do script %q
end tell`, cmd)
	ctx, cancel := context.WithTimeout(a.ctx, 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "osascript", "-e", script).CombinedOutput()
	if err != nil {
		return fmt.Errorf("open Terminal: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (a *App) CreateBeam() (beams.Beam, error) {
	ctx, cancel := context.WithTimeout(a.ctx, 3*time.Minute)
	defer cancel()
	return a.client.Create(ctx)
}

func (a *App) DeleteBeam(id string) error {
	ctx, cancel := context.WithTimeout(a.ctx, 60*time.Second)
	defer cancel()
	return a.client.Delete(ctx, id)
}

// ProbeBeam returns "user / home / claude version" for the header.
func (a *App) ProbeBeam(id string) (string, error) {
	ctx, cancel := context.WithTimeout(a.ctx, 60*time.Second)
	defer cancel()
	var out, errb bytes.Buffer
	if err := a.client.Run(ctx, id, agent.ProbeScript, nil, &out, &errb); err != nil {
		return "", fmt.Errorf("%w: %s", err, strings.TrimSpace(errb.String()))
	}
	return strings.TrimSpace(out.String()), nil
}

// ---------- sessions ----------

func (a *App) ListSessions() ([]store.Session, error) { return a.st.ListSessions() }

func (a *App) NewSession(beamID, beamName string) (store.Session, error) {
	now := time.Now()
	sess := store.Session{ID: uuid.NewString(), BeamID: beamID, BeamName: beamName, Created: now, Updated: now}
	return sess, a.st.SaveSession(sess)
}

func (a *App) DeleteSession(id string) error {
	a.StopTurn(id)
	return a.st.DeleteSession(id)
}

// LoadTranscript returns the raw JSON lines for a session, oldest first.
func (a *App) LoadTranscript(id string) ([]string, error) {
	raw, err := a.st.ReadTranscript(id)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(raw))
	for _, r := range raw {
		out = append(out, string(r))
	}
	a.backfillPublished(id, out)
	return out, nil
}

// backfillPublished fills PublishedURLs for sessions recorded before URL
// detection existed. It never auto-opens; it only records.
func (a *App) backfillPublished(id string, lines []string) {
	sess, err := a.st.LoadSession(id)
	if err != nil || len(sess.PublishedURLs) > 0 {
		return
	}
	seen := map[string]bool{}
	for _, ln := range lines {
		for _, u := range agent.FindPublishedURLs(ln, a.cfg.Proxy) {
			if !seen[strings.ToLower(u)] {
				seen[strings.ToLower(u)] = true
				sess.PublishedURLs = append(sess.PublishedURLs, u)
			}
		}
	}
	if len(sess.PublishedURLs) > 0 {
		_ = a.st.SaveSession(sess)
		runtime.EventsEmit(a.ctx, "session:updated", sess)
	}
}

func (a *App) IsRunning(id string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	_, ok := a.running[id]
	return ok
}

type agentEvent struct {
	SessionID string `json:"sessionId"`
	Line      string `json:"line,omitempty"`
	Text      string `json:"text,omitempty"`
	Error     string `json:"error,omitempty"`
}

type sink struct {
	a   *App
	sid string
}

func (s sink) OnEvent(ev agent.Event) {
	_ = s.a.st.AppendTranscript(s.sid, ev.Raw)
	runtime.EventsEmit(s.a.ctx, "agent:event", agentEvent{SessionID: s.sid, Line: string(ev.Raw)})
	if ev.Type == "assistant" || ev.Type == "user" {
		s.a.notePublished(s.sid, string(ev.Raw))
	}
	if ev.Type == "result" {
		if sess, err := s.a.st.LoadSession(s.sid); err == nil {
			sess.Turns++
			sess.CostUSD += ev.CostUSD
			sess.Updated = time.Now()
			if ev.IsError {
				sess.LastError = firstLine(ev.Result)
			} else {
				sess.LastError = ""
			}
			_ = s.a.st.SaveSession(sess)
		}
	}
}

// notePublished records any published-app URL that appears in a stream line,
// tells the UI, and (unless disabled) hands the URL to the default browser.
func (a *App) notePublished(sessionID, raw string) {
	urls := agent.FindPublishedURLs(raw, a.cfg.Proxy)
	if len(urls) == 0 {
		return
	}
	sess, err := a.st.LoadSession(sessionID)
	if err != nil {
		return
	}
	known := map[string]bool{}
	for _, u := range sess.PublishedURLs {
		known[strings.ToLower(u)] = true
	}
	for _, u := range urls {
		if known[strings.ToLower(u)] {
			continue
		}
		known[strings.ToLower(u)] = true
		sess.PublishedURLs = append(sess.PublishedURLs, u)
		opened := false
		if !a.cfg.DisableAutoOpenApps {
			runtime.BrowserOpenURL(a.ctx, u)
			opened = true
		}
		runtime.EventsEmit(a.ctx, "app:published", map[string]any{
			"sessionId": sessionID, "url": u, "opened": opened, "sessionTitle": sess.Title, "beam": sess.BeamName,
		})
	}
	_ = a.st.SaveSession(sess)
}

func (s sink) OnStderr(line string) {
	runtime.EventsEmit(s.a.ctx, "agent:stderr", agentEvent{SessionID: s.sid, Text: line})
}

// SendPrompt starts a turn asynchronously. Progress arrives via events:
// agent:event (one stream-json line), agent:stderr, agent:done.
func (a *App) SendPrompt(sessionID, prompt string) error {
	prompt = strings.TrimSpace(prompt)
	if prompt == "" {
		return errors.New("empty prompt")
	}
	sess, err := a.st.LoadSession(sessionID)
	if err != nil {
		return err
	}
	a.mu.Lock()
	if _, busy := a.running[sessionID]; busy {
		a.mu.Unlock()
		return errors.New("a turn is already running in this session")
	}
	ctx, cancel := context.WithCancel(a.ctx)
	a.running[sessionID] = cancel
	a.mu.Unlock()

	if sess.Title == "" {
		sess.Title = firstLine(prompt)
	}
	sess.Updated = time.Now()
	_ = a.st.SaveSession(sess)

	// Record the prompt in the transcript with our own event type so reloads
	// show the user's side of the conversation.
	userLine, _ := json.Marshal(map[string]any{"type": "beamsui.user", "text": prompt, "ts": time.Now().Format(time.RFC3339)})
	_ = a.st.AppendTranscript(sessionID, userLine)
	runtime.EventsEmit(a.ctx, "agent:event", agentEvent{SessionID: sessionID, Line: string(userLine)})

	opts := agent.TurnOptions{
		SessionID:      sessionID,
		Resume:         sess.Turns > 0,
		WorkDir:        a.cfg.WorkDir,
		Prompt:         prompt,
		PermissionMode: a.cfg.PermissionMode,
		Model:          a.cfg.Model,
	}
	go func() {
		defer func() {
			a.mu.Lock()
			delete(a.running, sessionID)
			a.mu.Unlock()
		}()
		err := agent.RunTurn(ctx, a.client, sess.BeamID, opts, sink{a: a, sid: sessionID})
		msg := ""
		if err != nil && !errors.Is(ctx.Err(), context.Canceled) {
			msg = err.Error()
		} else if ctx.Err() != nil {
			msg = "stopped"
		}
		cancel()
		final, _ := a.st.LoadSession(sessionID)
		runtime.EventsEmit(a.ctx, "agent:done", map[string]any{"sessionId": sessionID, "error": msg, "session": final})

		if msg == "" && a.cfg.GitHub.AutoSync {
			if _, err := a.PullMemory(sessionID); err != nil {
				a.syncLog(sessionID, "memory pull failed: "+err.Error())
			}
			if _, err := a.SyncToGitHub(sessionID); err != nil {
				a.syncLog(sessionID, "auto-sync failed: "+err.Error())
			}
		}
	}()
	return nil
}

func (a *App) StopTurn(sessionID string) {
	a.mu.Lock()
	cancel, ok := a.running[sessionID]
	a.mu.Unlock()
	if ok {
		cancel()
	}
}

// ---------- memory ----------

// PullMemory snapshots ~/.claude memory from the beam into the local session dir.
func (a *App) PullMemory(sessionID string) ([]store.MemoryFile, error) {
	sess, err := a.st.LoadSession(sessionID)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(a.ctx, 2*time.Minute)
	defer cancel()
	var out, errb bytes.Buffer
	if err := a.client.Run(ctx, sess.BeamID, agent.MemoryPullScript, nil, &out, &errb); err != nil {
		return nil, fmt.Errorf("pull memory: %w: %s", err, strings.TrimSpace(errb.String()))
	}
	dst := a.st.MemoryDir(sessionID)
	if out.Len() > 0 {
		if err := os.RemoveAll(dst); err != nil {
			return nil, err
		}
		if err := untarGz(&out, dst); err != nil {
			return nil, fmt.Errorf("unpack memory: %w", err)
		}
	}
	files, err := a.st.ListMemory(sessionID)
	if err != nil {
		return nil, err
	}
	runtime.EventsEmit(a.ctx, "memory:updated", map[string]any{"sessionId": sessionID, "count": len(files)})
	return files, nil
}

func (a *App) ListMemory(sessionID string) ([]store.MemoryFile, error) {
	return a.st.ListMemory(sessionID)
}

func (a *App) ReadMemoryFile(sessionID, rel string) (string, error) {
	return a.st.ReadMemoryFile(sessionID, rel)
}

// RestoreMemory fetches the latest memory snapshot from GitHub and unpacks it
// into the beam's ~/.claude, so a fresh sandbox starts with what earlier
// sessions learned.
func (a *App) RestoreMemory(sessionID string) (string, error) {
	sess, err := a.st.LoadSession(sessionID)
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(a.ctx, 3*time.Minute)
	defer cancel()
	dir, err := ghsync.RestoreMemory(ctx, a.cfg.GitHub, a.st.RepoCacheDir(a.cfg.GitHub.Repo), func(s string) { a.syncLog(sessionID, s) })
	if err != nil {
		return "", err
	}
	if dir == "" {
		return "no memory snapshot in repo yet", nil
	}
	var buf bytes.Buffer
	n, err := tarGzDir(dir, &buf)
	if err != nil {
		return "", err
	}
	if n == 0 {
		return "memory snapshot is empty", nil
	}
	var errb bytes.Buffer
	if err := a.client.Run(ctx, sess.BeamID, `mkdir -p "$HOME/.claude" && tar xzf - -C "$HOME/.claude"`, &buf, io.Discard, &errb); err != nil {
		return "", fmt.Errorf("restore memory: %w: %s", err, strings.TrimSpace(errb.String()))
	}
	return fmt.Sprintf("restored %d files into %s", n, sess.BeamName), nil
}

// ---------- GitHub ----------

func (a *App) syncLog(sessionID, msg string) {
	runtime.EventsEmit(a.ctx, "sync:log", map[string]any{"sessionId": sessionID, "text": msg})
}

func (a *App) SyncToGitHub(sessionID string) (ghsync.Result, error) {
	sess, err := a.st.LoadSession(sessionID)
	if err != nil {
		return ghsync.Result{}, err
	}
	lines, err := a.st.ReadTranscript(sessionID)
	if err != nil {
		return ghsync.Result{}, err
	}
	md := a.st.RenderMarkdown(sess, lines)
	ctx, cancel := context.WithTimeout(a.ctx, 5*time.Minute)
	defer cancel()
	res, err := ghsync.Sync(ctx, a.cfg.GitHub, a.st.RepoCacheDir(a.cfg.GitHub.Repo), sess, md,
		a.st.TranscriptPath(sessionID), a.st.MemoryDir(sessionID), func(s string) { a.syncLog(sessionID, s) })
	if err != nil {
		a.syncLog(sessionID, "error: "+err.Error())
		return res, err
	}
	if res.Committed {
		sess.LastSync = res.URL
		_ = a.st.SaveSession(sess)
		a.syncLog(sessionID, "committed "+res.SHA[:8]+" → "+res.URL)
	}
	runtime.EventsEmit(a.ctx, "sync:done", map[string]any{"sessionId": sessionID, "result": res})
	return res, nil
}

// GitHubStatus reports the local gh CLI sign-in state.
func (a *App) GitHubStatus() ghsync.AuthStatus {
	ctx, cancel := context.WithTimeout(a.ctx, 20*time.Second)
	defer cancel()
	return ghsync.Status(ctx)
}

// GitHubLogin starts the gh browser device flow. Progress (including the
// one-time code) arrives on gh:log; gh:done fires with the final status.
func (a *App) GitHubLogin() error {
	a.mu.Lock()
	if _, busy := a.running["__gh_login"]; busy {
		a.mu.Unlock()
		return errors.New("a GitHub sign-in is already in progress")
	}
	ctx, cancel := context.WithTimeout(a.ctx, 10*time.Minute)
	a.running["__gh_login"] = cancel
	a.mu.Unlock()
	go func() {
		defer func() {
			cancel()
			a.mu.Lock()
			delete(a.running, "__gh_login")
			a.mu.Unlock()
		}()
		err := ghsync.Login(ctx, func(s string) { runtime.EventsEmit(a.ctx, "gh:log", s) })
		msg := ""
		if err != nil {
			msg = err.Error()
		}
		runtime.EventsEmit(a.ctx, "gh:done", map[string]any{"error": msg, "status": ghsync.Status(a.ctx)})
	}()
	return nil
}

func (a *App) GitHubLoginCancel() {
	a.mu.Lock()
	cancel, ok := a.running["__gh_login"]
	a.mu.Unlock()
	if ok {
		cancel()
	}
}

func (a *App) GitHubLogout() error {
	ctx, cancel := context.WithTimeout(a.ctx, 20*time.Second)
	defer cancel()
	return ghsync.Logout(ctx)
}

// ListGitHubRepos returns every repo the gh login can access.
func (a *App) ListGitHubRepos() ([]ghsync.Repo, error) {
	ctx, cancel := context.WithTimeout(a.ctx, 3*time.Minute)
	defer cancel()
	return ghsync.ListRepos(ctx)
}

// ListGitHubBranches returns the branches of owner/name.
func (a *App) ListGitHubBranches(repo string) ([]string, error) {
	ctx, cancel := context.WithTimeout(a.ctx, 60*time.Second)
	defer cancel()
	return ghsync.ListBranches(ctx, repo)
}

// CreateGitHubRepo creates the configured repo (private) on GitHub.
func (a *App) CreateGitHubRepo(private bool) (string, error) {
	ctx, cancel := context.WithTimeout(a.ctx, 60*time.Second)
	defer cancel()
	return ghsync.CreateRepo(ctx, a.cfg.GitHub.Repo, private)
}

func (a *App) OpenURL(u string) {
	if strings.HasPrefix(u, "https://") {
		runtime.BrowserOpenURL(a.ctx, u)
	}
}

// ---------- helpers ----------

func firstLine(s string) string {
	s = strings.TrimSpace(strings.SplitN(strings.TrimSpace(s), "\n", 2)[0])
	if len(s) > 80 {
		s = s[:77] + "..."
	}
	return s
}

func untarGz(r io.Reader, dst string) error {
	gz, err := gzip.NewReader(r)
	if err != nil {
		return err
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		clean := filepath.Clean(h.Name)
		if strings.HasPrefix(clean, "..") || filepath.IsAbs(clean) {
			continue
		}
		target := filepath.Join(dst, clean)
		switch h.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			f, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
			if err != nil {
				return err
			}
			if _, err := io.Copy(f, tr); err != nil {
				f.Close()
				return err
			}
			f.Close()
		}
	}
}

// tarGzDir packs dir (whose layout mirrors ~/.claude) and returns the file count.
func tarGzDir(dir string, w io.Writer) (int, error) {
	gz := gzip.NewWriter(w)
	tw := tar.NewWriter(gz)
	n := 0
	err := filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		rel, _ := filepath.Rel(dir, p)
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		h := &tar.Header{Name: filepath.ToSlash(rel), Mode: 0o644, Size: int64(len(b)), ModTime: info.ModTime()}
		if err := tw.WriteHeader(h); err != nil {
			return err
		}
		if _, err := tw.Write(b); err != nil {
			return err
		}
		n++
		return nil
	})
	if err != nil {
		return 0, err
	}
	if err := tw.Close(); err != nil {
		return 0, err
	}
	return n, gz.Close()
}
