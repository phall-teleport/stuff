# Brief: connections

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 1.

```sh
A="Scripts/agent.sh connections Sources/ServerLife/Connections,Tests/ServerLifeTests/Connections"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter Connections · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/main/connections.js` (changed, +446/−13)
- `src/main/sshbin.js` (changed, +66/−3)
- `src/main/sshoptions.js` (NEW, +251/−0)
- `src/main/localmonitor.js` (NEW, +161/−0)
- `src/main/local.js` (changed, +35/−2)
- `src/main/authprobe.js` (unchanged — read for context)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- SSH options per host (0.16; sshoptions.js main side — building the `-o` list, validation).
- MFA answered mid-run (0.22), orphaned ssh master killed on connect timeout, a reconnect starts
  its own connection log, changed-host-key offers the fix, profile with no key → password.
- "access denied to `<login>` connecting" offers the fix; "Connect with tsh ssh" login replay fix (0.24).
- Too-many-auth-failures explainer for plain ssh, Unix-domain socket forwards (0.25).
- Expired-cluster connect fixes, login-then-connect (0.26); attaching to tmux on a logged-out
  cluster (0.25).
- **Live stats** (0.29) — the remote sampler in connections.js and `localmonitor.js` for local
  shells (0.34); Settings → "No background commands on servers" (`quietRemote`) honoured.
- One login at a time (0.39). `detectTeleportOnSsh` (0.32, detection side).
- Expose a `LiveStats` publisher sessions can subscribe to (sessions draws the bar, monitor.js).
