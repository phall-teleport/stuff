// Package agent runs Claude Code inside a beam in print mode and streams its
// stream-json events back, one JSON object per line, the same protocol the
// Claude Code CLI itself uses for programmatic sessions.
package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"github.com/phall-teleport/beamsui/internal/beams"
)

// TurnOptions describes one prompt sent to a session.
type TurnOptions struct {
	SessionID      string // Claude Code session UUID; reused across turns
	Resume         bool   // false on the first turn (--session-id), true afterwards (--resume)
	WorkDir        string // cwd inside the beam, e.g. /home/beams/work
	Prompt         string
	PermissionMode string // "bypass" (default in a sandbox), "acceptEdits", "plan", "default"
	Model          string // optional --model override
	MaxTurns       int    // optional --max-turns
}

// Script renders the shell script executed inside the beam for one turn.
func Script(o TurnOptions) string {
	var b strings.Builder
	b.WriteString("set -e\n")
	b.WriteString("export PATH=\"$HOME/.local/bin:$PATH\"\n")
	b.WriteString(fmt.Sprintf("mkdir -p %s && cd %s\n", beams.ShellQuote(o.WorkDir), beams.ShellQuote(o.WorkDir)))
	b.WriteString("exec claude -p --verbose --output-format stream-json")
	if o.Resume {
		b.WriteString(" --resume " + o.SessionID)
	} else {
		b.WriteString(" --session-id " + o.SessionID)
	}
	switch o.PermissionMode {
	case "", "bypass", "bypassPermissions":
		b.WriteString(" --dangerously-skip-permissions")
	default:
		b.WriteString(" --permission-mode " + o.PermissionMode)
	}
	if o.Model != "" {
		b.WriteString(" --model " + beams.ShellQuote(o.Model))
	}
	if o.MaxTurns > 0 {
		b.WriteString(fmt.Sprintf(" --max-turns %d", o.MaxTurns))
	}
	b.WriteString(" -- " + beams.ShellQuote(o.Prompt))
	b.WriteString("\n")
	return b.String()
}

// Event is one parsed stream-json line. Raw is forwarded to the UI verbatim;
// the typed fields are what the Go side needs for bookkeeping.
type Event struct {
	Type      string          `json:"type"`
	Subtype   string          `json:"subtype,omitempty"`
	SessionID string          `json:"session_id,omitempty"`
	IsError   bool            `json:"is_error,omitempty"`
	CostUSD   float64         `json:"total_cost_usd,omitempty"`
	NumTurns  int             `json:"num_turns,omitempty"`
	Duration  int64           `json:"duration_ms,omitempty"`
	Result    string          `json:"result,omitempty"`
	Raw       json.RawMessage `json:"-"`
}

// Sink receives events and stderr text as they arrive.
type Sink interface {
	OnEvent(ev Event)
	OnStderr(line string)
}

// RunTurn executes one turn and blocks until Claude exits. Non-JSON stdout
// lines are surfaced through OnStderr so nothing is silently dropped.
func RunTurn(ctx context.Context, client beams.Client, beamID string, opts TurnOptions, sink Sink) error {
	pr, pw := io.Pipe()
	er, ew := io.Pipe()
	done := make(chan struct{})

	go func() {
		defer close(done)
		sc := bufio.NewScanner(pr)
		sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
		for sc.Scan() {
			line := bytes.TrimSpace(sc.Bytes())
			if len(line) == 0 {
				continue
			}
			if line[0] != '{' {
				sink.OnStderr(string(line))
				continue
			}
			var ev Event
			if err := json.Unmarshal(line, &ev); err != nil {
				sink.OnStderr(string(line))
				continue
			}
			ev.Raw = append([]byte(nil), line...)
			sink.OnEvent(ev)
		}
	}()
	go func() {
		sc := bufio.NewScanner(er)
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			if s := strings.TrimSpace(sc.Text()); s != "" {
				sink.OnStderr(s)
			}
		}
	}()

	err := client.Run(ctx, beamID, Script(opts), nil, pw, ew)
	pw.Close()
	ew.Close()
	<-done
	return err
}

// MemoryPullScript streams a gzip tarball of the beam's Claude memory
// (every projects/*/memory directory plus the global CLAUDE.md) to stdout.
const MemoryPullScript = `cd "$HOME/.claude" 2>/dev/null || exit 0
set -- $(find projects -type d -name memory 2>/dev/null)
[ -f CLAUDE.md ] && set -- "$@" CLAUDE.md
[ $# -eq 0 ] && exit 0
tar czf - "$@"`

// ProbeScript reports the beam's toolchain for the UI header.
const ProbeScript = `whoami; echo "$HOME"; command -v claude >/dev/null 2>&1 && claude --version || echo "claude: not installed"`
