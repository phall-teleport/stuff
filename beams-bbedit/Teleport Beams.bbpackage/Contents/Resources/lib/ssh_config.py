#!/usr/bin/env python3
"""Manage the Teleport Beams host aliases in ~/.ssh/config.

BBEdit's SFTP browser drives /usr/bin/ssh, which reads ~/.ssh/config, so a
per-beam Host alias with a `tsh proxy ssh` ProxyCommand is enough to let
BBEdit open sftp://beams@<alias>/... URLs directly.

All aliases live inside one marker-delimited region. Each beam gets a
self-contained block: identity pinned to the cluster (so ssh does not burn
MaxAuthTries offering every certificate in the agent), HostName set to the
beam's <uuid>.<cluster> so the Teleport-signed host certificate validates
against the @cert-authority entry in tsh's known_hosts. The region is inserted
before the first Host/Match/Include line so that specific aliases win over
any `Host *.<cluster>` wildcard tsh may have generated.

Usage:
  ssh_config.py ensure --id ID --uuid UUID --cluster C --proxy HOST:PORT
                       --username U --tsh /path/to/tsh [--user beams]
                       [--prefix bbedit--] [--known-hosts FILE] [--config ~/.ssh/config]
        Reads `tsh config --proxy C` output on stdin (may be empty) to pick
        up IdentityFile/CertificateFile/UserKnownHostsFile paths. Prints the alias.
  ssh_config.py remove --id ID [--prefix ...] [--config ...]
  ssh_config.py prune --keep ID1,ID2,... [--prefix ...] [--config ...]
        Removes blocks for beams not in --keep. Prints removed ids.
  ssh_config.py list [--prefix ...] [--config ...]
"""
import argparse
import os
import re
import shutil
import sys
import tempfile

MARKER_START = "# BEGIN Teleport Beams (BBEdit) — managed, do not edit by hand"
MARKER_END = "# END Teleport Beams (BBEdit)"


def read_config(path):
    if not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def write_config(path, content):
    directory = os.path.dirname(path)
    if not os.path.isdir(directory):
        os.makedirs(directory, mode=0o700, exist_ok=True)
    if os.path.exists(path):
        backup = path + ".teleport-beams-bbedit.bak"
        shutil.copyfile(path, backup)
        os.chmod(backup, 0o600)
    fd, tmp = tempfile.mkstemp(prefix="config.teleport-beams.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def split_region(config):
    """Return (before, blocks, after). blocks is {beam_id: block_text}."""
    lines = config.split("\n")
    try:
        start = lines.index(MARKER_START)
        end = lines.index(MARKER_END, start)
    except ValueError:
        return config, {}, None
    before = "\n".join(lines[:start])
    after = "\n".join(lines[end + 1:])
    region = lines[start + 1:end]
    blocks = {}
    current_id = None
    current = []
    for line in region:
        m = re.match(r"^Host\s+(\S+)\s*(#\s*beam:(\S+))?", line)
        if m:
            if current_id is not None:
                blocks[current_id] = "\n".join(current).rstrip("\n")
            current_id = m.group(3) or m.group(1)
            current = [line]
        elif current_id is not None:
            current.append(line)
    if current_id is not None:
        blocks[current_id] = "\n".join(current).rstrip("\n")
    return before, blocks, after


def join_region(before, blocks, after):
    if not blocks:
        # Drop the region entirely.
        if after is None:
            return before
        combined = before.rstrip("\n")
        tail = after.lstrip("\n")
        if combined and tail:
            return combined + "\n\n" + tail + ("" if tail.endswith("\n") else "\n")
        return (combined + "\n") if combined else tail

    region = [MARKER_START]
    for beam_id in sorted(blocks):
        region.append(blocks[beam_id])
        region.append("")
    region[-1] = MARKER_END
    region_text = "\n".join(region)

    if after is None:
        # First insertion: place before the first Host/Match/Include line so
        # our specific aliases take precedence over cluster wildcards, while
        # leaving any leading global options global.
        lines = before.split("\n")
        idx = next(
            (i for i, l in enumerate(lines) if re.match(r"^\s*(Host|Match|Include)\b", l, re.I)),
            None,
        )
        if idx is None:
            head = before.rstrip("\n")
            return (head + "\n\n" if head else "") + region_text + "\n"
        # Keep a comment line that immediately precedes the Host line attached to it.
        while idx > 0 and lines[idx - 1].strip().startswith("#"):
            idx -= 1
        head = "\n".join(lines[:idx]).rstrip("\n")
        tail = "\n".join(lines[idx:])
        return (head + "\n\n" if head else "") + region_text + "\n\n" + tail

    head = before.rstrip("\n")
    tail = after.lstrip("\n")
    out = (head + "\n\n" if head else "") + region_text
    if tail:
        out += "\n\n" + tail
    if not out.endswith("\n"):
        out += "\n"
    return out


def tsh_paths(tsh_config, cluster, username):
    """IdentityFile/CertificateFile/UserKnownHostsFile from `tsh config` output,
    falling back to tsh's default locations."""
    identity = cert = known_hosts = None
    in_block = False
    for line in tsh_config.split("\n"):
        if line.startswith("Host "):
            in_block = cluster in line
            continue
        if not in_block:
            continue
        for key in ("IdentityFile", "CertificateFile", "UserKnownHostsFile"):
            m = re.match(rf'^\s*{key}\s+"?([^"]+)"?\s*$', line)
            if m:
                if key == "IdentityFile":
                    identity = m.group(1)
                elif key == "CertificateFile":
                    cert = m.group(1)
                else:
                    known_hosts = m.group(1)
    home = os.path.expanduser("~")
    if not identity and username:
        identity = os.path.join(home, ".tsh", "keys", cluster, username)
    if not cert and username:
        cert = os.path.join(home, ".tsh", "keys", cluster, f"{username}-ssh", f"{cluster}-cert.pub")
    if not known_hosts:
        known_hosts = os.path.join(home, ".tsh", "known_hosts")
    return identity, cert, known_hosts


def build_block(args, identity, cert, known_hosts):
    alias = f"{args.prefix}{args.id}.{args.cluster}"
    # The beam presents a host certificate signed by the cluster's host CA whose
    # principal is <uuid>.<cluster>, so HostName must be the UUID form for ssh to
    # validate it against the @cert-authority entry in tsh's known_hosts. That gives
    # real verification and no prompt — BBEdit forces -oStrictHostKeyChecking=ask on
    # the command line, so anything that is not verifiable would be asked about on
    # every connection. Without a UUID we fall back to the id hostname (prompts).
    hostname = f"{args.uuid}.{args.cluster}" if args.uuid else f"{args.id}.{args.cluster}"
    lines = [
        f"Host {alias} # beam:{args.id}",
        f"    HostName {hostname}",
        f"    User {args.user}",
        "    IdentitiesOnly yes",
    ]
    if identity:
        lines.append(f'    IdentityFile "{identity}"')
    if cert:
        lines.append(f'    CertificateFile "{cert}"')
    lines += [
        f'    UserKnownHostsFile "{known_hosts}"',
        "    LogLevel ERROR",
        f'    ProxyCommand "{args.tsh}" proxy ssh --cluster={args.cluster} --proxy={args.proxy} '
        f"%r@teleport.internal/beams/alias={args.id}",
    ]
    return alias, "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["ensure", "remove", "prune", "list"])
    parser.add_argument("--id")
    parser.add_argument("--cluster")
    parser.add_argument("--proxy")
    parser.add_argument("--username", default="")
    parser.add_argument("--tsh", default="tsh")
    parser.add_argument("--user", default="beams")
    parser.add_argument("--prefix", default="bbedit--")
    parser.add_argument("--keep", default="")
    parser.add_argument("--uuid", default="", help="beam UUID (the host certificate's principal is <uuid>.<cluster>)")
    parser.add_argument("--known-hosts", default="", help="override UserKnownHostsFile (default: tsh's, which holds the cluster host CA)")
    parser.add_argument("--config", default=os.path.expanduser("~/.ssh/config"))
    args = parser.parse_args()

    config = read_config(args.config)
    before, blocks, after = split_region(config)

    if args.command == "list":
        for beam_id in sorted(blocks):
            print(beam_id)
        return

    if args.command == "ensure":
        for name in ("id", "cluster", "proxy"):
            if not getattr(args, name):
                parser.error(f"--{name} is required for ensure")
        tsh_config = sys.stdin.read() if not sys.stdin.isatty() else ""
        identity, cert, known_hosts = tsh_paths(tsh_config, args.cluster, args.username)
        if args.known_hosts:
            known_hosts = args.known_hosts
        alias, block = build_block(args, identity, cert, known_hosts)
        if blocks.get(args.id) != block:
            blocks[args.id] = block
            write_config(args.config, join_region(before, blocks, after))
        print(alias)
        return

    if args.command == "remove":
        if not args.id:
            parser.error("--id is required for remove")
        if args.id in blocks:
            del blocks[args.id]
            write_config(args.config, join_region(before, blocks, after))
            print(args.id)
        return

    if args.command == "prune":
        keep = {k for k in args.keep.split(",") if k}
        removed = [k for k in blocks if k not in keep]
        if removed:
            for k in removed:
                del blocks[k]
            write_config(args.config, join_region(before, blocks, after))
        for k in removed:
            print(k)


if __name__ == "__main__":
    main()
