# Brief: nettools

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 1.

```sh
A="Scripts/agent.sh nettools Sources/ServerLife/NetTools,Tests/ServerLifeTests/NetTools"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter NetTools · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/main/nettools.js` (changed, +535/−74)
- `src/renderer/js/nettools.js` (changed, +1035/−31)
- `src/main/decoders.js` (NEW, +601/−0)
- `src/main/sockets.js` (NEW, +246/−0)
- `src/renderer/js/keys.js` (changed, +82/−11)
- `src/main/sshkeys.js` (changed, +180/−46)
- `tests/decoders.test.mjs` (NEW, +139/−0)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- "Network and Certificate Tools" (0.18): subnet calculator, URL encode/decode, decoders for SSH
  certificate, JWT, SPIFFE SVID (decoders.js); Readable/Raw, summaries (0.19); Show in Finder and
  Browse… for decoders (0.20); latency to a node (0.18).
- A runnable, copyable command for every tool (0.23) — skip the Windows substitutes.
- DNS CAA/SOA/NAPTR, IP family for ping/traceroute/port check, STARTTLS, curl to a specific address,
  sockets panel (sockets.js) — `sockets`, PKCS#11 tokens, key dialog lists ssh_config hosts using a
  key, OpenSSH-v1 key passphrase detection fix, Recent dedupe (0.25).
- keys.js / sshkeys.js changes. Port tests/decoders.test.mjs.
