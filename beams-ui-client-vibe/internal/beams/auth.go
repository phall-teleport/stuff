package beams

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// AugmentPath makes GUI launches behave like a terminal: macOS gives apps
// started from the Dock a minimal PATH, so tsh/gh under /usr/local/bin or
// Homebrew are invisible. We ask the login shell for its PATH and add the
// usual suspects as a fallback.
func AugmentPath() {
	home, _ := os.UserHomeDir()
	var parts []string
	if sh := os.Getenv("SHELL"); sh != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, sh, "-lc", "printf %s \"$PATH\"").Output()
		if err == nil {
			parts = append(parts, strings.Split(strings.TrimSpace(string(out)), ":")...)
		}
	}
	parts = append(parts,
		filepath.Join(home, ".tsh", "bin"), // managed tsh updates land here
		"/usr/local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin",
		filepath.Join(home, ".local", "bin"), filepath.Join(home, "go", "bin"),
	)
	parts = append(parts, strings.Split(os.Getenv("PATH"), ":")...)
	seen := map[string]bool{}
	var final []string
	for _, p := range parts {
		if p == "" || seen[p] {
			continue
		}
		seen[p] = true
		final = append(final, p)
	}
	os.Setenv("PATH", strings.Join(final, ":"))
}

// Status is the tsh login state for the configured proxy.
type Status struct {
	TshFound   bool   `json:"tshFound"`
	TshPath    string `json:"tshPath"`
	LoggedIn   bool   `json:"loggedIn"`
	Proxy      string `json:"proxy"`
	User       string `json:"user"`
	Cluster    string `json:"cluster"`
	ValidUntil string `json:"validUntil"`
	Message    string `json:"message"`
}

// Status inspects `tsh status -f json` without triggering a login.
func (t *TshClient) Status(ctx context.Context) Status {
	st := Status{Proxy: t.Proxy}
	path, err := exec.LookPath(t.Bin)
	if err != nil {
		st.Message = fmt.Sprintf("%q not found on PATH. Install Teleport (tsh) or set its path in Settings.", t.Bin)
		return st
	}
	st.TshFound, st.TshPath = true, path

	c := exec.CommandContext(ctx, path, "status", "-f", "json")
	c.Env = os.Environ()
	var out, errb bytes.Buffer
	c.Stdout, c.Stderr = &out, &errb
	_ = c.Run() // non-zero when nothing is logged in; we still parse what we get

	var parsed struct {
		Active   *profile  `json:"active"`
		Profiles []profile `json:"profiles"`
	}
	raw := out.Bytes()
	if i := bytes.IndexByte(raw, '{'); i >= 0 {
		raw = raw[i:]
	}
	if len(raw) == 0 || json.Unmarshal(raw, &parsed) != nil {
		st.Message = "Not logged in to Teleport."
		return st
	}
	var all []profile
	if parsed.Active != nil {
		all = append(all, *parsed.Active)
	}
	all = append(all, parsed.Profiles...)
	want := hostOnly(t.Proxy)
	var match *profile
	for i := range all {
		p := &all[i]
		if want == "" || strings.Contains(hostOnly(p.ProfileURL), want) || strings.Contains(p.Cluster, want) {
			match = p
			break
		}
	}
	if match == nil {
		st.Message = fmt.Sprintf("No tsh profile for %s yet.", t.Proxy)
		return st
	}
	st.User, st.Cluster, st.ValidUntil = match.Username, match.Cluster, match.ValidUntil
	if st.Proxy == "" {
		st.Proxy = hostOnly(match.ProfileURL)
	}
	if exp, err := time.Parse(time.RFC3339, match.ValidUntil); err == nil && time.Now().After(exp) {
		st.Message = fmt.Sprintf("Certificate for %s expired %s.", st.Cluster, exp.Local().Format("Jan 2 15:04"))
		return st
	}
	st.LoggedIn = true
	st.Message = fmt.Sprintf("Logged in to %s as %s", st.Cluster, st.User)
	return st
}

type profile struct {
	ProfileURL string `json:"profile_url"`
	Username   string `json:"username"`
	Cluster    string `json:"cluster"`
	ValidUntil string `json:"valid_until"`
}

func hostOnly(u string) string {
	u = strings.TrimPrefix(strings.TrimPrefix(u, "https://"), "http://")
	if i := strings.IndexAny(u, ":/"); i >= 0 {
		u = u[:i]
	}
	return u
}

// ErrNeedsTerminal means tsh wants an interactive password prompt.
var ErrNeedsTerminal = errors.New("tsh needs a terminal for this login")

// LoginCommand is the exact command a user would run by hand.
func (t *TshClient) LoginCommand(user string) string {
	cmd := t.Bin + " login --proxy=" + t.Proxy
	if user != "" {
		cmd += " --user=" + user
	}
	return cmd
}

// Login runs `tsh login` headlessly. SSO clusters open the browser and
// succeed; local-password clusters fail with ErrNeedsTerminal so the caller
// can hand off to Terminal.app.
func (t *TshClient) RunLogin(ctx context.Context, user string, log func(string)) error {
	if t.Proxy == "" {
		return errors.New("set the Teleport proxy in Settings first")
	}
	args := []string{"login", "--proxy=" + t.Proxy}
	if user != "" {
		args = append(args, "--user="+user)
	}
	c := exec.CommandContext(ctx, t.Bin, args...)
	c.Env = os.Environ()
	c.Stdin = strings.NewReader("")
	pr, pw := io.Pipe()
	c.Stdout, c.Stderr = pw, pw
	var tail []string
	done := make(chan struct{})
	go func() {
		defer close(done)
		sc := bufio.NewScanner(pr)
		for sc.Scan() {
			ln := strings.TrimSpace(stripANSI(sc.Text()))
			if ln == "" || strings.HasPrefix(ln, "Update progress") {
				continue
			}
			tail = append(tail, ln)
			if len(tail) > 20 {
				tail = tail[1:]
			}
			log(ln)
		}
	}()
	err := c.Run()
	pw.Close()
	<-done
	if err == nil {
		return nil
	}
	joined := strings.ToLower(strings.Join(tail, "\n"))
	if strings.Contains(joined, "without a terminal") || strings.Contains(joined, "not a terminal") || strings.Contains(joined, "password") {
		return ErrNeedsTerminal
	}
	return fmt.Errorf("tsh login failed: %s", strings.Join(tail, " / "))
}

// IsAuthError reports whether an error from tsh means "log in again".
func IsAuthError(err error) bool {
	if err == nil {
		return false
	}
	s := strings.ToLower(err.Error())
	for _, needle := range []string{
		"not logged in", "certificate has expired", "expired", "no credentials",
		"cannot perform password login", "without a terminal", "access denied",
		"please login", "relogin", "re-login", "x509", "ssh: handshake failed", "no such profile",
	} {
		if strings.Contains(s, needle) {
			return true
		}
	}
	return false
}

// IsNotFoundError reports whether tsh itself is missing.
func IsNotFoundError(err error) bool {
	return err != nil && strings.Contains(err.Error(), "executable file not found")
}

func stripANSI(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == 0x1b && i+1 < len(s) && s[i+1] == '[' {
			j := i + 2
			for j < len(s) && ((s[j] >= '0' && s[j] <= '9') || s[j] == ';') {
				j++
			}
			i = j
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}
