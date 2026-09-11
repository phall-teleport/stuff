package beams

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

// TshClient drives the real `tsh beams` CLI.
type TshClient struct {
	Bin   string // path to tsh; "tsh" resolves via PATH
	Proxy string // optional --proxy override, e.g. super-grass.beams.sh
	Login string // optional -l login inside the beam (default: cluster default, "beams")
}

func NewTsh(bin, proxy, login string) *TshClient {
	if bin == "" {
		bin = "tsh"
	}
	return &TshClient{Bin: bin, Proxy: proxy, Login: login}
}

func (t *TshClient) Kind() string { return "tsh" }

// args builds a tsh argv with the global flags placed before the subcommand.
func (t *TshClient) args(sub ...string) []string {
	var a []string
	if t.Proxy != "" {
		a = append(a, "--proxy="+t.Proxy)
	}
	if t.Login != "" {
		a = append(a, "--login="+t.Login)
	}
	return append(a, sub...)
}

func (t *TshClient) cmd(ctx context.Context, sub ...string) *exec.Cmd {
	c := exec.CommandContext(ctx, t.Bin, t.args(sub...)...)
	c.Env = os.Environ()
	return c
}

func (t *TshClient) runJSON(ctx context.Context, out any, sub ...string) error {
	c := t.cmd(ctx, sub...)
	var stdout, stderr bytes.Buffer
	c.Stdout = &stdout
	c.Stderr = &stderr
	if err := c.Run(); err != nil {
		return fmt.Errorf("tsh %s: %w: %s", strings.Join(sub, " "), err, strings.TrimSpace(stderr.String()))
	}
	// tsh sometimes prints a login banner before the JSON; skip to the first bracket.
	raw := stdout.Bytes()
	if i := bytes.IndexAny(raw, "[{"); i > 0 {
		raw = raw[i:]
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("parse tsh %s output: %w", strings.Join(sub, " "), err)
	}
	return nil
}

func (t *TshClient) List(ctx context.Context) ([]Beam, error) {
	var rows []map[string]any
	if err := t.runJSON(ctx, &rows, "beams", "ls", "-f", "json"); err != nil {
		return nil, err
	}
	out := make([]Beam, 0, len(rows))
	for _, r := range rows {
		out = append(out, fromRaw(r))
	}
	return out, nil
}

func (t *TshClient) Create(ctx context.Context) (Beam, error) {
	var raw map[string]any
	if err := t.runJSON(ctx, &raw, "beams", "add", "-f", "json", "--no-console"); err != nil {
		return Beam{}, err
	}
	return fromRaw(raw), nil
}

func (t *TshClient) Delete(ctx context.Context, id string) error {
	c := t.cmd(ctx, "beams", "rm", id)
	var stderr bytes.Buffer
	c.Stderr = &stderr
	if err := c.Run(); err != nil {
		return fmt.Errorf("tsh beams rm %s: %w: %s", id, err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

// Run executes `sh -lc <script>` inside the beam. tsh joins the remaining
// args with spaces and hands them to the remote shell, so the script is
// single-quoted to arrive intact.
func (t *TshClient) Run(ctx context.Context, id string, script string, stdin io.Reader, stdout, stderr io.Writer) error {
	c := t.cmd(ctx, "beams", "exec", id, "--", "sh", "-lc", ShellQuote(script))
	c.Stdin = stdin
	c.Stdout = stdout
	c.Stderr = stderr
	return c.Run()
}

func (t *TshClient) CopyTo(ctx context.Context, id, localPath, remotePath string, recursive bool) error {
	return t.scp(ctx, localPath, id+":"+remotePath, recursive)
}

func (t *TshClient) CopyFrom(ctx context.Context, id, remotePath, localPath string, recursive bool) error {
	return t.scp(ctx, id+":"+remotePath, localPath, recursive)
}

func (t *TshClient) scp(ctx context.Context, src, dst string, recursive bool) error {
	sub := []string{"beams", "scp", "-q"}
	if recursive {
		sub = append(sub, "-r")
	}
	sub = append(sub, src, dst)
	c := t.cmd(ctx, sub...)
	var stderr bytes.Buffer
	c.Stderr = &stderr
	if err := c.Run(); err != nil {
		return fmt.Errorf("tsh beams scp %s %s: %w: %s", src, dst, err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

// fromRaw maps the `tsh beams ls` JSON (id, uuid, owner, expires, region…)
// onto Beam, tolerating field names from other server versions.
func fromRaw(r map[string]any) Beam {
	get := func(keys ...string) string {
		for _, k := range keys {
			if v, ok := r[k]; ok && v != nil {
				if s, ok := v.(string); ok && s != "" {
					return s
				}
			}
		}
		return ""
	}
	b := Beam{
		ID:      get("id", "name", "uuid"),
		Name:    get("alias", "name", "id"),
		State:   get("state", "status", "phase"),
		Created: get("created", "created_at", "expires"),
		Raw:     r,
	}
	if b.State == "" {
		b.State = "running"
	}
	return b
}
