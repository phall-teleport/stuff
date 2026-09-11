package beams

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"strings"
	"sync"
	"time"
)

// MockClient simulates a beams cluster so the UI can be developed and demoed
// without network access. Enable with BEAMSUI_MOCK=1.
type MockClient struct {
	mu    sync.Mutex
	beams []Beam
	n     int
}

func NewMock() *MockClient {
	m := &MockClient{}
	m.beams = []Beam{
		{ID: "mild-moon", Name: "mild-moon", State: "running", Created: time.Now().Add(-40 * time.Minute).UTC().Format(time.RFC3339),
			Raw: map[string]any{"owner": "paul.hall@goteleport.com", "region": "us-west-2"}},
	}
	return m
}

func (m *MockClient) Kind() string { return "mock" }

func (m *MockClient) List(ctx context.Context) ([]Beam, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Beam, len(m.beams))
	copy(out, m.beams)
	return out, nil
}

func (m *MockClient) Create(ctx context.Context) (Beam, error) {
	time.Sleep(1200 * time.Millisecond)
	m.mu.Lock()
	defer m.mu.Unlock()
	m.n++
	names := []string{"quiet-river", "bold-fox", "amber-sky", "calm-otter"}
	b := Beam{ID: names[m.n%len(names)], Name: names[m.n%len(names)], State: "running",
		Created: time.Now().UTC().Format(time.RFC3339),
		Raw:     map[string]any{"owner": "paul.hall@goteleport.com", "region": "us-west-2"}}
	m.beams = append(m.beams, b)
	return b, nil
}

func (m *MockClient) Delete(ctx context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i, b := range m.beams {
		if b.ID == id {
			m.beams = append(m.beams[:i], m.beams[i+1:]...)
			return nil
		}
	}
	return fmt.Errorf("beam %q not found", id)
}

func (m *MockClient) CopyTo(ctx context.Context, id, localPath, remotePath string, recursive bool) error {
	time.Sleep(300 * time.Millisecond)
	return nil
}

func (m *MockClient) CopyFrom(ctx context.Context, id, remotePath, localPath string, recursive bool) error {
	time.Sleep(300 * time.Millisecond)
	return nil
}

// Run recognises the scripts the app sends and fakes plausible output.
func (m *MockClient) Run(ctx context.Context, id string, script string, stdin io.Reader, stdout, stderr io.Writer) error {
	switch {
	case strings.Contains(script, "claude -p") || strings.Contains(script, "claude --print"):
		return m.fakeAgent(ctx, script, stdout)
	case strings.Contains(script, "tar czf -"):
		return m.fakeMemoryTar(stdout)
	default:
		fmt.Fprintf(stdout, "beams\n/home/beams\n2.1.258 (Claude Code)\n")
		return nil
	}
}

func (m *MockClient) fakeMemoryTar(w io.Writer) error {
	gz := gzip.NewWriter(w)
	tw := tar.NewWriter(gz)
	files := map[string]string{
		"CLAUDE.md": "# Beam sandbox\nRun `cat /etc/motd` for setup notes.\n",
		"projects/-home-beams-work/memory/MEMORY.md": "- [Repo layout](repo-layout.md) — where things live\n",
		"projects/-home-beams-work/memory/repo-layout.md": "---\nname: repo-layout\ndescription: Where the Go and frontend code live\nmetadata:\n  type: project\n---\n\nGo backend in internal/, vanilla frontend in frontend/.\n",
	}
	for name, body := range files {
		h := &tar.Header{Name: name, Mode: 0o644, Size: int64(len(body)), ModTime: time.Now()}
		if err := tw.WriteHeader(h); err != nil {
			return err
		}
		if _, err := tw.Write([]byte(body)); err != nil {
			return err
		}
	}
	if err := tw.Close(); err != nil {
		return err
	}
	return gz.Close()
}

func (m *MockClient) fakeAgent(ctx context.Context, script string, w io.Writer) error {
	sid := "mock-session"
	if i := strings.Index(script, "--session-id "); i >= 0 {
		sid = strings.Fields(script[i+len("--session-id "):])[0]
	} else if i := strings.Index(script, "--resume "); i >= 0 {
		sid = strings.Fields(script[i+len("--resume "):])[0]
	}
	emit := func(line string, delay time.Duration) error {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
		_, err := io.WriteString(w, strings.ReplaceAll(line, "SID", sid)+"\n")
		return err
	}
	steps := []struct {
		line  string
		delay time.Duration
	}{
		{`{"type":"system","subtype":"init","cwd":"/home/beams/work","session_id":"SID","model":"claude-sonnet-5","permissionMode":"bypassPermissions","tools":["Bash","Read","Edit","Write"]}`, 400 * time.Millisecond},
		{`{"type":"assistant","session_id":"SID","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"I'll take a look at the sandbox first."}]}}`, 900 * time.Millisecond},
		{`{"type":"assistant","session_id":"SID","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"ls -la ~ && cat /etc/motd | head -20","description":"List home and read the motd"}}]}}`, 700 * time.Millisecond},
		{`{"type":"user","session_id":"SID","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"total 44\ndrwxr-xr-x. 5 beams beams 4096 .\n-rw-r--r--. 1 beams beams 2068 AGENTS.md\ndrwxr-xr-x. 3 beams beams 4096 examples\n\nWelcome to your beam. This is an ephemeral sandbox VM."}]}}`, 1200 * time.Millisecond},
		{`{"type":"assistant","session_id":"SID","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"This beam is a Debian 12 sandbox with Claude Code, Node 24 and git preinstalled.\n\n**Home directory**\n- AGENTS.md with API and Teleport notes\n- examples/ with an OpenAI sample\n\nNothing else is running yet. Tell me what you'd like to build and I'll start in a work directory.\n\n` + "```bash\\nmkdir -p ~/work && cd ~/work\\n```" + `"}]}}`, 1500 * time.Millisecond},
		{`{"type":"result","subtype":"success","is_error":false,"duration_ms":4900,"duration_api_ms":4100,"num_turns":2,"session_id":"SID","total_cost_usd":0.0412,"usage":{"input_tokens":2678,"output_tokens":210},"result":"This beam is a Debian 12 sandbox with Claude Code, Node 24 and git preinstalled."}`, 300 * time.Millisecond},
	}
	for _, s := range steps {
		if err := emit(s.line, s.delay); err != nil {
			return err
		}
	}
	return nil
}
