package agent

import (
	"reflect"
	"testing"
)

func TestFindPublishedURLs(t *testing.T) {
	line := `{"type":"assistant","message":{"content":[{"type":"text","text":"Your blackjack game is live in the browser:\n\n**https://mild-moon-7727.super-grass.beams.sh**\n\nDocs: https://super-grass.beams.sh/web/apps and https://MILD-MOON-7727.super-grass.beams.sh/play?x=1."}]}}`
	got := FindPublishedURLs(line, "super-grass.beams.sh:443")
	want := []string{
		"https://mild-moon-7727.super-grass.beams.sh",
		"https://MILD-MOON-7727.super-grass.beams.sh/play?x=1",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	if got := FindPublishedURLs("nothing here https://example.com", "super-grass.beams.sh"); len(got) != 0 {
		t.Fatalf("expected no matches, got %v", got)
	}
	if got := FindPublishedURLs("https://x.super-grass.beams.sh", ""); got != nil {
		t.Fatalf("empty proxy must match nothing, got %v", got)
	}
}
