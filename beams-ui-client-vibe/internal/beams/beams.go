// Package beams wraps the Teleport `tsh beams` CLI so the rest of the app can
// list, create, exec into, copy files to/from, and delete beam sandboxes.
package beams

import (
	"context"
	"io"
	"strings"
)

// Beam is a normalised view of a beam instance as reported by `tsh beams ls`.
// Raw keeps whatever the server returned so the UI can show extra detail.
type Beam struct {
	ID      string         `json:"id"`
	Name    string         `json:"name"`
	State   string         `json:"state"`
	Created string         `json:"created"`
	Raw     map[string]any `json:"raw"`
}

// Client is the surface the app depends on. TshClient is the real thing;
// MockClient lets the UI run without a beams-enabled cluster.
type Client interface {
	// List returns the beams visible to the current user.
	List(ctx context.Context) ([]Beam, error)
	// Create starts a new beam and returns it without attaching a console.
	Create(ctx context.Context) (Beam, error)
	// Delete removes a beam.
	Delete(ctx context.Context, id string) error
	// Run executes a shell script inside the beam, wiring stdin/stdout/stderr.
	// It blocks until the remote process exits or ctx is cancelled.
	Run(ctx context.Context, id string, script string, stdin io.Reader, stdout, stderr io.Writer) error
	// CopyTo copies a local file or directory into the beam.
	CopyTo(ctx context.Context, id, localPath, remotePath string, recursive bool) error
	// CopyFrom copies a file or directory out of the beam.
	CopyFrom(ctx context.Context, id, remotePath, localPath string, recursive bool) error
	// Kind is "tsh" or "mock", surfaced in the UI.
	Kind() string
}

// ShellQuote wraps s in single quotes so it survives the remote shell.
func ShellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
