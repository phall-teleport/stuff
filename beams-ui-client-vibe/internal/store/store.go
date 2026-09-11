// Package store persists app config, sessions, transcripts and pulled memory
// under ~/Library/Application Support/BeamsUI.
package store

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

type GitHubConfig struct {
	Repo     string `json:"repo"`     // owner/name
	Branch   string `json:"branch"`   // e.g. main or beams-sessions
	Prefix   string `json:"prefix"`   // path inside the repo, e.g. beams
	AutoSync bool   `json:"autoSync"` // sync after every completed turn
}

type Config struct {
	TshBin         string       `json:"tshBin"`
	Proxy          string       `json:"proxy"`
	TeleportUser   string       `json:"teleportUser"` // optional --user for tsh login
	Login          string       `json:"login"`
	WorkDir        string       `json:"workDir"`
	PermissionMode string       `json:"permissionMode"`
	Model          string       `json:"model"`
	// DisableAutoOpenApps stops published beam apps from opening in the
	// browser automatically (they still show as a pill in the header).
	DisableAutoOpenApps bool         `json:"disableAutoOpenApps"`
	GitHub              GitHubConfig `json:"github"`
}

func DefaultConfig() Config {
	return Config{
		TshBin:         "tsh",
		Proxy:          "super-grass.beams.sh",
		WorkDir:        "/home/beams/work",
		PermissionMode: "bypass",
		GitHub:         GitHubConfig{Branch: "main", Prefix: "beams"},
	}
}

type Session struct {
	ID        string    `json:"id"` // also the Claude Code session UUID inside the beam
	BeamID    string    `json:"beamId"`
	BeamName  string    `json:"beamName"`
	Title     string    `json:"title"`
	Created   time.Time `json:"created"`
	Updated   time.Time `json:"updated"`
	Turns     int       `json:"turns"`
	CostUSD   float64   `json:"costUsd"`
	LastSync  string    `json:"lastSync"`  // commit URL
	LastError string    `json:"lastError"` // last failure message, if any
	// PublishedURLs are apps Claude published from the beam (tsh beams publish).
	PublishedURLs []string `json:"publishedUrls"`
}

type MemoryFile struct {
	Path string `json:"path"` // relative to the session memory dir
	Size int64  `json:"size"`
}

type Store struct {
	Root string
	mu   sync.Mutex
}

func Open() (*Store, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	root := filepath.Join(home, "Library", "Application Support", "BeamsUI")
	for _, d := range []string{"sessions", "repos"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			return nil, err
		}
	}
	return &Store{Root: root}, nil
}

// ---- config ----

func (s *Store) configPath() string { return filepath.Join(s.Root, "config.json") }

func (s *Store) LoadConfig() Config {
	cfg := DefaultConfig()
	b, err := os.ReadFile(s.configPath())
	if err != nil {
		return cfg
	}
	_ = json.Unmarshal(b, &cfg)
	if cfg.TshBin == "" {
		cfg.TshBin = "tsh"
	}
	if cfg.WorkDir == "" {
		cfg.WorkDir = "/home/beams/work"
	}
	return cfg
}

func (s *Store) SaveConfig(cfg Config) error {
	return writeJSON(s.configPath(), cfg, 0o600)
}

// ---- sessions ----

func (s *Store) SessionDir(id string) string { return filepath.Join(s.Root, "sessions", id) }
func (s *Store) MemoryDir(id string) string  { return filepath.Join(s.SessionDir(id), "memory") }
func (s *Store) TranscriptPath(id string) string {
	return filepath.Join(s.SessionDir(id), "transcript.jsonl")
}
func (s *Store) RepoCacheDir(repo string) string {
	return filepath.Join(s.Root, "repos", strings.ReplaceAll(repo, "/", "__"))
}

func (s *Store) SaveSession(sess Session) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := os.MkdirAll(s.SessionDir(sess.ID), 0o755); err != nil {
		return err
	}
	return writeJSON(filepath.Join(s.SessionDir(sess.ID), "meta.json"), sess, 0o644)
}

func (s *Store) LoadSession(id string) (Session, error) {
	var sess Session
	b, err := os.ReadFile(filepath.Join(s.SessionDir(id), "meta.json"))
	if err != nil {
		return sess, err
	}
	return sess, json.Unmarshal(b, &sess)
}

func (s *Store) ListSessions() ([]Session, error) {
	entries, err := os.ReadDir(filepath.Join(s.Root, "sessions"))
	if err != nil {
		return nil, err
	}
	out := []Session{}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if sess, err := s.LoadSession(e.Name()); err == nil {
			out = append(out, sess)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Updated.After(out[j].Updated) })
	return out, nil
}

func (s *Store) DeleteSession(id string) error {
	if id == "" || strings.Contains(id, "..") {
		return errors.New("invalid session id")
	}
	return os.RemoveAll(s.SessionDir(id))
}

// AppendTranscript appends one JSON line to the session transcript.
func (s *Store) AppendTranscript(id string, line []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := os.MkdirAll(s.SessionDir(id), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(s.TranscriptPath(id), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(append(append([]byte(nil), line...), '\n'))
	return err
}

// ReadTranscript returns the raw JSON lines of a session.
func (s *Store) ReadTranscript(id string) ([]json.RawMessage, error) {
	f, err := os.Open(s.TranscriptPath(id))
	if errors.Is(err, fs.ErrNotExist) {
		return []json.RawMessage{}, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []json.RawMessage
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	for sc.Scan() {
		if len(strings.TrimSpace(sc.Text())) == 0 {
			continue
		}
		out = append(out, json.RawMessage(append([]byte(nil), sc.Bytes()...)))
	}
	return out, sc.Err()
}

// ---- memory ----

func (s *Store) ListMemory(id string) ([]MemoryFile, error) {
	root := s.MemoryDir(id)
	out := []MemoryFile{} // never nil: the frontend gets [] rather than null
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return nil
			}
			return err
		}
		if d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		out = append(out, MemoryFile{Path: filepath.ToSlash(rel), Size: info.Size()})
		return nil
	})
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out, err
}

func (s *Store) ReadMemoryFile(id, rel string) (string, error) {
	if strings.Contains(rel, "..") {
		return "", errors.New("invalid path")
	}
	b, err := os.ReadFile(filepath.Join(s.MemoryDir(id), filepath.FromSlash(rel)))
	return string(b), err
}

// ---- rendering ----

// RenderMarkdown turns a transcript into a readable Markdown document for
// committing alongside the raw JSONL.
func (s *Store) RenderMarkdown(sess Session, lines []json.RawMessage) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n", firstNonEmpty(sess.Title, "Beam session"))
	fmt.Fprintf(&b, "- Session: `%s`\n- Beam: `%s`\n- Started: %s\n- Turns: %d\n- Cost: $%.4f\n\n---\n\n",
		sess.ID, sess.BeamName, sess.Created.Format(time.RFC3339), sess.Turns, sess.CostUSD)
	for _, raw := range lines {
		var ev struct {
			Type    string `json:"type"`
			Subtype string `json:"subtype"`
			Text    string `json:"text"`
			Message struct {
				Content json.RawMessage `json:"content"`
			} `json:"message"`
			Result   string  `json:"result"`
			IsError  bool    `json:"is_error"`
			Cost     float64 `json:"total_cost_usd"`
			Duration int64   `json:"duration_ms"`
		}
		if json.Unmarshal(raw, &ev) != nil {
			continue
		}
		switch ev.Type {
		case "beamsui.user":
			fmt.Fprintf(&b, "## You\n\n%s\n\n", ev.Text)
		case "assistant":
			var blocks []map[string]any
			if json.Unmarshal(ev.Message.Content, &blocks) != nil {
				continue
			}
			for _, blk := range blocks {
				switch blk["type"] {
				case "text":
					fmt.Fprintf(&b, "%s\n\n", blk["text"])
				case "tool_use":
					in, _ := json.MarshalIndent(blk["input"], "", "  ")
					fmt.Fprintf(&b, "<details><summary>Tool: %s</summary>\n\n```json\n%s\n```\n\n</details>\n\n", blk["name"], in)
				}
			}
		case "result":
			status := "done"
			if ev.IsError {
				status = "error"
			}
			fmt.Fprintf(&b, "_%s · %.1fs · $%.4f_\n\n---\n\n", status, float64(ev.Duration)/1000, ev.Cost)
		}
	}
	return b.String()
}

func firstNonEmpty(v ...string) string {
	for _, s := range v {
		if s != "" {
			return s
		}
	}
	return ""
}

func writeJSON(path string, v any, mode os.FileMode) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
