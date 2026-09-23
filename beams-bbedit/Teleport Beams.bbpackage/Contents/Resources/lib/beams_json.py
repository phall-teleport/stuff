#!/usr/bin/env python3
"""Small JSON helpers for the Teleport Beams BBEdit package.

Subcommands (JSON on stdin unless noted):
  profile [PREF]   tsh status --format=json  -> shell assignments for eval
                   (PREF = preferred cluster; otherwise prefers *.beams.sh)
  beams            tsh beams ls -f json      -> TSV: id, expires, url, owner, region, uuid
  menu CURRENT     TSV on stdin              -> one display line per beam
  expires ISO      (no stdin)                -> "3h 12m" style remaining time
"""
import json
import shlex
import sys
from datetime import datetime, timezone
from urllib.parse import urlparse


def parse_time(value):
    if not value:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    # Trim fractional seconds beyond microseconds (Go emits nanoseconds).
    if "." in text:
        head, tail = text.split(".", 1)
        frac = ""
        rest = ""
        for i, ch in enumerate(tail):
            if ch.isdigit():
                frac += ch
            else:
                rest = tail[i:]
                break
        text = f"{head}.{frac[:6]}{rest}"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def expires_in(value):
    dt = parse_time(value)
    if dt is None:
        return "?"
    remaining = int((dt - datetime.now(timezone.utc)).total_seconds() // 60)
    if remaining <= 0:
        return "expired"
    if remaining >= 60:
        return f"{remaining // 60}h {remaining % 60}m"
    return f"{remaining}m"


def choose_profile(data, preferred=""):
    """Pick the Beams profile: the preferred cluster if logged in, else the
    active profile when it looks like a Beams cluster, else the first
    *.beams.sh profile, else whatever is active."""
    candidates = []
    if data.get("active"):
        candidates.append(data["active"])
    candidates += [p for p in (data.get("profiles") or []) if isinstance(p, dict)]
    if preferred:
        for p in candidates:
            if p.get("cluster") == preferred or urlparse(p.get("profile_url", "")).hostname == preferred.split(":")[0]:
                return p
    for p in candidates:
        if str(p.get("cluster", "")).endswith(".beams.sh"):
            return p
    return candidates[0] if candidates else {}


def cmd_profile(preferred=""):
    data = json.load(sys.stdin)
    active = choose_profile(data, preferred)
    cluster = active.get("cluster", "")
    username = active.get("username", "")
    url = active.get("profile_url", "")
    parsed = urlparse(url) if url else None
    proxy = parsed.netloc if parsed and parsed.netloc else (f"{cluster}:443" if cluster else "")
    print(f"BEAMS_CLUSTER={shlex.quote(cluster)}")
    print(f"BEAMS_USERNAME={shlex.quote(username)}")
    print(f"BEAMS_PROXY={shlex.quote(proxy)}")
    print(f"BEAMS_VALID_UNTIL={shlex.quote(active.get('valid_until', ''))}")


def cmd_beams():
    raw = sys.stdin.read().strip()
    data = json.loads(raw) if raw else []
    if not isinstance(data, list):
        return
    for beam in data:
        fields = [
            str(beam.get("id", "")),
            str(beam.get("expires", "")),
            str(beam.get("url", "") or ""),
            str(beam.get("owner", "") or ""),
            str(beam.get("region", "") or beam.get("requested_region", "") or ""),
            str(beam.get("uuid", "") or ""),
        ]
        print("\t".join(f.replace("\t", " ") for f in fields))


def cmd_menu(current):
    for line in sys.stdin.read().splitlines():
        if not line.strip():
            continue
        parts = (line.split("\t") + [""] * 6)[:6]
        beam_id, expires, url, _owner, region, _uuid = parts
        bits = [f"expires in {expires_in(expires)}"]
        if url:
            bits.append("published")
        if region:
            bits.append(region)
        if current and beam_id == current:
            bits.append("current")
        print(f"{beam_id}  —  " + " · ".join(bits))


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd = argv[1]
    if cmd == "profile":
        cmd_profile(argv[2] if len(argv) > 2 else "")
    elif cmd == "beams":
        cmd_beams()
    elif cmd == "menu":
        cmd_menu(argv[2] if len(argv) > 2 else "")
    elif cmd == "expires":
        print(expires_in(argv[2] if len(argv) > 2 else ""))
    else:
        sys.exit(f"unknown subcommand: {cmd}")


if __name__ == "__main__":
    main(sys.argv)
