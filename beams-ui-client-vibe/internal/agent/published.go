package agent

import (
	"regexp"
	"strings"
	"sync"
)

// Apps published from a beam with `tsh beams publish` are reachable at
// https://<beam-alias-port>.<cluster>. Anything on a subdomain of the
// configured proxy host is therefore a published app.

var (
	reMu   sync.Mutex
	reByHo = map[string]*regexp.Regexp{}
)

func publishedRe(proxyHost string) *regexp.Regexp {
	reMu.Lock()
	defer reMu.Unlock()
	if re, ok := reByHo[proxyHost]; ok {
		return re
	}
	re := regexp.MustCompile(`(?i)https://[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.` + regexp.QuoteMeta(proxyHost) + `(?::\d+)?(?:/[^\s"'<>\\)\]]*)?`)
	reByHo[proxyHost] = re
	return re
}

// hostOnly trims scheme, port and path from a proxy setting.
func hostOnly(u string) string {
	u = strings.TrimPrefix(strings.TrimPrefix(u, "https://"), "http://")
	if i := strings.IndexAny(u, ":/"); i >= 0 {
		u = u[:i]
	}
	return strings.ToLower(u)
}

// FindPublishedURLs returns the distinct published-app URLs mentioned in
// text (a raw stream-json line or plain output), in order of appearance.
func FindPublishedURLs(text, proxy string) []string {
	host := hostOnly(proxy)
	if host == "" {
		return nil
	}
	seen := map[string]bool{}
	var out []string
	for _, m := range publishedRe(host).FindAllString(text, -1) {
		m = strings.TrimRight(m, ".,;:")
		key := strings.ToLower(m)
		// Never treat the proxy's own web UI as an app.
		if strings.HasPrefix(key, "https://"+host) {
			continue
		}
		if !seen[key] {
			seen[key] = true
			out = append(out, m)
		}
	}
	return out
}
