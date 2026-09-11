package beams

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// A Dock-launched app sees only /usr/bin:/bin:/usr/sbin:/sbin. After
// AugmentPath, tsh under /usr/local/bin or Homebrew must be resolvable.
func TestAugmentPathFindsTsh(t *testing.T) {
	if _, err := os.Stat("/usr/local/bin/tsh"); err != nil {
		t.Skip("tsh not installed at /usr/local/bin on this machine")
	}
	t.Setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
	if _, err := exec.LookPath("tsh"); err == nil {
		t.Fatal("precondition: tsh should not be visible on the bare PATH")
	}
	AugmentPath()
	if _, err := exec.LookPath("tsh"); err != nil {
		t.Fatalf("tsh still not found after AugmentPath: PATH=%s", os.Getenv("PATH"))
	}
	if !strings.Contains(os.Getenv("PATH"), "/usr/local/bin") {
		t.Fatalf("expected /usr/local/bin in PATH, got %s", os.Getenv("PATH"))
	}
}

func TestIsAuthError(t *testing.T) {
	cases := map[string]bool{
		"ERROR: Not logged in.":                                        true,
		"failed to fetch TLS key: no credentials":                      true,
		"cannot perform password login without a terminal":            true,
		"x509: certificate has expired or is not yet valid":            true,
		"exec: \"tsh\": executable file not found in $PATH":            false,
		"unknown service teleport.beams.v1.BeamService":                false,
	}
	for msg, want := range cases {
		if got := IsAuthError(errString(msg)); got != want {
			t.Errorf("IsAuthError(%q) = %v, want %v", msg, got, want)
		}
	}
	if !IsNotFoundError(errString(`exec: "tsh": executable file not found in $PATH`)) {
		t.Error("IsNotFoundError should match the exec not-found message")
	}
}

func TestHostOnly(t *testing.T) {
	for in, want := range map[string]string{
		"https://super-grass.beams.sh:443": "super-grass.beams.sh",
		"super-grass.beams.sh":             "super-grass.beams.sh",
		"https://x.example.com/path":       "x.example.com",
	} {
		if got := hostOnly(in); got != want {
			t.Errorf("hostOnly(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestStripANSI(t *testing.T) {
	if got := stripANSI("\x1b[31mERROR: \x1b[0mNot logged in."); got != "ERROR: Not logged in." {
		t.Errorf("stripANSI = %q", got)
	}
}

type errString string

func (e errString) Error() string { return string(e) }
