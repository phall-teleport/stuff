// Package ghsync commits a session's transcript and pulled memory into a
// GitHub repository using the local git and gh CLIs (so it inherits the
// user's existing GitHub auth), and restores memory from that repo.
package ghsync

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/phall-teleport/beamsui/internal/store"
)

type Result struct {
	Committed bool   `json:"committed"`
	SHA       string `json:"sha"`
	URL       string `json:"url"`
	Branch    string `json:"branch"`
	Message   string `json:"message"`
}

type Logger func(string)

// Sync writes the session into <prefix>/sessions/<id>/ and the latest memory
// into <prefix>/memory/, commits, and pushes.
func Sync(ctx context.Context, cfg store.GitHubConfig, cacheDir string, sess store.Session, transcriptMD string, transcriptJSONL string, memoryDir string, log Logger) (Result, error) {
	if cfg.Repo == "" || !strings.Contains(cfg.Repo, "/") {
		return Result{}, errors.New("GitHub repo must be set as owner/name in settings")
	}
	branch := cfg.Branch
	if branch == "" {
		branch = "main"
	}
	prefix := strings.Trim(cfg.Prefix, "/")
	if prefix == "" {
		prefix = "beams"
	}

	if err := ensureClone(ctx, cfg.Repo, cacheDir, branch, log); err != nil {
		return Result{}, err
	}

	sessDir := filepath.Join(cacheDir, prefix, "sessions", sess.ID)
	if err := os.MkdirAll(sessDir, 0o755); err != nil {
		return Result{}, err
	}
	if err := os.WriteFile(filepath.Join(sessDir, "transcript.md"), []byte(transcriptMD), 0o644); err != nil {
		return Result{}, err
	}
	if transcriptJSONL != "" {
		if err := copyFile(transcriptJSONL, filepath.Join(sessDir, "transcript.jsonl")); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return Result{}, err
		}
	}
	if st, err := os.Stat(memoryDir); err == nil && st.IsDir() {
		dst := filepath.Join(cacheDir, prefix, "memory")
		log("Updating memory snapshot at " + filepath.Join(prefix, "memory"))
		if err := os.RemoveAll(dst); err != nil {
			return Result{}, err
		}
		if err := copyTree(memoryDir, dst); err != nil {
			return Result{}, err
		}
		// Keep a per-session copy too so history is reconstructible.
		if err := copyTree(memoryDir, filepath.Join(sessDir, "memory")); err != nil {
			return Result{}, err
		}
	}

	if _, err := git(ctx, cacheDir, "add", "-A", "--", prefix); err != nil {
		return Result{}, err
	}
	if out, _ := git(ctx, cacheDir, "status", "--porcelain", "--", prefix); strings.TrimSpace(out) == "" {
		log("Nothing new to commit.")
		return Result{Committed: false, Branch: branch, Message: "nothing to commit"}, nil
	}
	msg := fmt.Sprintf("beams: %s (%s, %d turns)", firstLine(sess.Title, "session "+sess.ID[:8]), sess.BeamName, sess.Turns)
	if _, err := git(ctx, cacheDir, "-c", "user.useConfigOnly=false", "commit", "-q", "-m", msg); err != nil {
		return Result{}, err
	}
	log("Pushing to " + cfg.Repo + "@" + branch)
	if _, err := git(ctx, cacheDir, "push", "-q", "-u", "origin", branch); err != nil {
		return Result{}, err
	}
	sha, _ := git(ctx, cacheDir, "rev-parse", "HEAD")
	sha = strings.TrimSpace(sha)
	return Result{
		Committed: true,
		SHA:       sha,
		URL:       fmt.Sprintf("https://github.com/%s/commit/%s", cfg.Repo, sha),
		Branch:    branch,
		Message:   msg,
	}, nil
}

// RestoreMemory pulls the repo and returns the path of <prefix>/memory, or ""
// if the repo has no snapshot yet.
func RestoreMemory(ctx context.Context, cfg store.GitHubConfig, cacheDir string, log Logger) (string, error) {
	if cfg.Repo == "" {
		return "", errors.New("GitHub repo must be set in settings")
	}
	branch := cfg.Branch
	if branch == "" {
		branch = "main"
	}
	if err := ensureClone(ctx, cfg.Repo, cacheDir, branch, log); err != nil {
		return "", err
	}
	prefix := strings.Trim(cfg.Prefix, "/")
	if prefix == "" {
		prefix = "beams"
	}
	dir := filepath.Join(cacheDir, prefix, "memory")
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return "", nil
	}
	return dir, nil
}

// AuthStatus describes the local gh CLI login state.
type AuthStatus struct {
	Installed bool   `json:"installed"`
	LoggedIn  bool   `json:"loggedIn"`
	User      string `json:"user"`
	Detail    string `json:"detail"`
}

// Status reports whether gh is installed and signed in to github.com.
func Status(ctx context.Context) AuthStatus {
	if _, err := exec.LookPath("gh"); err != nil {
		return AuthStatus{Detail: "GitHub CLI (gh) not found. Install with: brew install gh"}
	}
	c := exec.CommandContext(ctx, "gh", "auth", "status", "--hostname", "github.com")
	var out bytes.Buffer
	c.Stdout = &out
	c.Stderr = &out
	err := c.Run()
	text := out.String()
	st := AuthStatus{Installed: true, Detail: strings.TrimSpace(text)}
	if err != nil {
		return st
	}
	st.LoggedIn = true
	for _, ln := range strings.Split(text, "\n") {
		ln = strings.TrimSpace(ln)
		if i := strings.Index(ln, "account "); i >= 0 && strings.Contains(ln, "Logged in") {
			st.User = strings.Fields(ln[i+len("account "):])[0]
			break
		}
	}
	return st
}

// Login runs the gh browser device flow. The one-time code and URL are
// reported through log as gh prints them; the call returns once the user has
// finished in the browser (or ctx is cancelled).
func Login(ctx context.Context, log Logger) error {
	if _, err := exec.LookPath("gh"); err != nil {
		return errors.New("GitHub CLI (gh) not found. Install with: brew install gh")
	}
	c := exec.CommandContext(ctx, "gh", "auth", "login", "--hostname", "github.com", "--web", "--git-protocol", "https", "--scopes", "repo,read:org")
	c.Stdin = strings.NewReader("\n")
	c.Env = append(os.Environ(), "GH_PROMPT_DISABLED=1", "GIT_TERMINAL_PROMPT=0")
	pr, pw := io.Pipe()
	c.Stdout = pw
	c.Stderr = pw
	done := make(chan struct{})
	go func() {
		defer close(done)
		sc := bufio.NewScanner(pr)
		for sc.Scan() {
			if ln := strings.TrimSpace(sc.Text()); ln != "" {
				log(ln)
			}
		}
	}()
	err := c.Run()
	pw.Close()
	<-done
	if err != nil {
		return fmt.Errorf("gh auth login: %w", err)
	}
	return nil
}

// Repo is one repository the signed-in user can access.
type Repo struct {
	FullName string `json:"fullName"`
	Private  bool   `json:"private"`
	PushedAt string `json:"pushedAt"`
}

// ListRepos returns every repo the gh login can see (owned, collaborator,
// org member), most recently pushed first.
func ListRepos(ctx context.Context) ([]Repo, error) {
	out, err := run(ctx, "", "gh", "api", "--paginate",
		"user/repos?affiliation=owner,collaborator,organization_member&per_page=100&sort=pushed",
		"--jq", `.[] | [.full_name, (.private|tostring), .pushed_at] | @tsv`)
	if err != nil {
		return nil, err
	}
	repos := []Repo{}
	seen := map[string]bool{}
	for _, ln := range strings.Split(out, "\n") {
		f := strings.Split(strings.TrimSpace(ln), "\t")
		if len(f) < 2 || f[0] == "" || seen[f[0]] {
			continue
		}
		seen[f[0]] = true
		r := Repo{FullName: f[0], Private: f[1] == "true"}
		if len(f) > 2 {
			r.PushedAt = f[2]
		}
		repos = append(repos, r)
	}
	return repos, nil
}

// ListBranches returns the branch names of owner/name.
func ListBranches(ctx context.Context, repo string) ([]string, error) {
	if !strings.Contains(repo, "/") {
		return nil, errors.New("repo must be owner/name")
	}
	out, err := run(ctx, "", "gh", "api", "--paginate", "repos/"+repo+"/branches?per_page=100", "--jq", ".[].name")
	if err != nil {
		return nil, err
	}
	names := []string{}
	for _, ln := range strings.Split(out, "\n") {
		if ln = strings.TrimSpace(ln); ln != "" {
			names = append(names, ln)
		}
	}
	return names, nil
}

// Logout signs the gh CLI out of github.com.
func Logout(ctx context.Context) error {
	_, err := run(ctx, "", "gh", "auth", "logout", "--hostname", "github.com")
	return err
}

// CreateRepo creates owner/name on GitHub (private by default) so a first
// sync has somewhere to land.
func CreateRepo(ctx context.Context, repo string, private bool) (string, error) {
	if !strings.Contains(repo, "/") {
		return "", errors.New("repo must be owner/name")
	}
	vis := "--private"
	if !private {
		vis = "--public"
	}
	out, err := run(ctx, "", "gh", "repo", "create", repo, vis, "--description", "Beams sessions: Claude Code transcripts and memory")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(out), nil
}

// gitCred makes every git invocation use gh as the HTTPS credential helper,
// so private repos work with the gh login alone (no SSH keys required).
var gitCred = []string{"-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential"}

func ensureClone(ctx context.Context, repo, dir, branch string, log Logger) error {
	if _, err := os.Stat(filepath.Join(dir, ".git")); err != nil {
		log("Cloning " + repo)
		if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
			return err
		}
		url := "https://github.com/" + repo + ".git"
		if _, err := git(ctx, "", "clone", "--quiet", url, dir); err != nil {
			if strings.Contains(err.Error(), "not found") || strings.Contains(err.Error(), "Authentication failed") || strings.Contains(err.Error(), "could not read Username") {
				return fmt.Errorf("clone %s: repository not found or no access — sign in to GitHub in the panel, or create the repo (%w)", repo, err)
			}
			return fmt.Errorf("clone %s: %w", repo, err)
		}
	}
	log("Fetching origin")
	if _, err := git(ctx, dir, "fetch", "-q", "origin"); err != nil {
		return err
	}
	// Prefer the remote branch; otherwise create it from the repo's default
	// branch so a new sync branch starts from current history, not from
	// whatever the local cache last had checked out.
	if _, err := git(ctx, dir, "rev-parse", "--verify", "-q", "origin/"+branch); err == nil {
		if _, err := git(ctx, dir, "checkout", "-q", "-B", branch, "origin/"+branch); err != nil {
			return err
		}
		return nil
	}
	base := ""
	if head, err := git(ctx, dir, "symbolic-ref", "-q", "refs/remotes/origin/HEAD"); err == nil {
		base = strings.TrimSpace(head) // refs/remotes/origin/main
	} else if _, err := git(ctx, dir, "rev-parse", "--verify", "-q", "origin/main"); err == nil {
		base = "origin/main"
	} else if _, err := git(ctx, dir, "rev-parse", "--verify", "-q", "origin/master"); err == nil {
		base = "origin/master"
	}
	if base != "" {
		log("Creating branch " + branch + " from " + strings.TrimPrefix(base, "refs/remotes/"))
		_, err := git(ctx, dir, "checkout", "-q", "-B", branch, base)
		return err
	}
	log("Repository is empty; creating branch " + branch)
	_, err := git(ctx, dir, "checkout", "-q", "-B", branch)
	return err
}

func git(ctx context.Context, dir string, args ...string) (string, error) {
	return run(ctx, dir, "git", append(append([]string{}, gitCred...), args...)...)
}

func run(ctx context.Context, dir, bin string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	c := exec.CommandContext(ctx, bin, args...)
	c.Dir = dir
	c.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	var out, errb bytes.Buffer
	c.Stdout = &out
	c.Stderr = &errb
	if err := c.Run(); err != nil {
		return out.String(), fmt.Errorf("%s %s: %w: %s", bin, strings.Join(args, " "), err, strings.TrimSpace(errb.String()))
	}
	return out.String(), nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		return copyFile(p, target)
	})
}

func firstLine(s, fallback string) string {
	s = strings.TrimSpace(strings.SplitN(s, "\n", 2)[0])
	if s == "" {
		return fallback
	}
	if len(s) > 60 {
		s = s[:57] + "..."
	}
	return s
}
