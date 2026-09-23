#!/usr/bin/env python3
"""Offline tests for the package's Python helpers. Run with `make test`."""
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "Teleport Beams.bbpackage", "Contents", "Resources", "lib")
sys.path.insert(0, LIB)

import activity  # noqa: E402
import beams_json  # noqa: E402
import ssh_config  # noqa: E402


def run(script, args, stdin=""):
    proc = subprocess.run(
        [sys.executable, os.path.join(LIB, script), *args],
        input=stdin, capture_output=True, text=True, check=True,
    )
    return proc.stdout


class SshConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "config")

    def tearDown(self):
        self.tmp.cleanup()

    def ensure(self, beam_id, tsh_config="", uuid="1111-2222"):
        return run("ssh_config.py", [
            "ensure", "--id", beam_id, "--uuid", uuid, "--cluster", "c.beams.sh", "--proxy", "c.beams.sh:443",
            "--username", "me@example.com", "--tsh", "/usr/local/bin/tsh", "--config", self.path,
        ], stdin=tsh_config).strip()

    def read(self):
        with open(self.path) as fh:
            return fh.read()

    def test_insert_before_first_host_keeps_globals_global(self):
        with open(self.path, "w") as fh:
            fh.write("ServerAliveInterval 60\n\n# my host\nHost *.c.beams.sh !c.beams.sh\n    Port 3022\n")
        alias = self.ensure("robust-shadow")
        self.assertEqual(alias, "bbedit--robust-shadow.c.beams.sh")
        cfg = self.read()
        self.assertLess(cfg.index("ServerAliveInterval"), cfg.index(ssh_config.MARKER_START))
        self.assertLess(cfg.index(ssh_config.MARKER_END), cfg.index("# my host"))
        self.assertIn("ProxyCommand \"/usr/local/bin/tsh\" proxy ssh --cluster=c.beams.sh --proxy=c.beams.sh:443 "
                      "%r@teleport.internal/beams/alias=robust-shadow", cfg)
        self.assertIn('IdentityFile "' + os.path.expanduser("~/.tsh/keys/c.beams.sh/me@example.com") + '"', cfg)
        self.assertIn('UserKnownHostsFile "' + os.path.expanduser("~/.tsh/known_hosts") + '"', cfg)
        self.assertIn("HostName 1111-2222.c.beams.sh", cfg)
        self.assertNotIn("StrictHostKeyChecking", cfg)
        self.assertTrue(os.path.exists(self.path + ".teleport-beams-bbedit.bak"))
        self.assertEqual(oct(os.stat(self.path).st_mode & 0o777), "0o600")

    def test_identity_from_tsh_config(self):
        tsh = ('Host *.c.beams.sh c.beams.sh\n    UserKnownHostsFile "/k/kh"\n    IdentityFile "/k/id"\n'
               '    CertificateFile "/k/cert.pub"\nHost *.other\n    IdentityFile "/wrong"\n')
        self.ensure("a", tsh)
        cfg = self.read()
        self.assertIn('IdentityFile "/k/id"', cfg)
        self.assertIn('CertificateFile "/k/cert.pub"', cfg)
        self.assertIn('UserKnownHostsFile "/k/kh"', cfg)
        self.assertNotIn("/wrong", cfg)

    def test_without_uuid_falls_back_to_id_hostname(self):
        self.ensure("a", uuid="")
        self.assertIn("HostName a.c.beams.sh", self.read())

    def test_multiple_beams_remove_prune_idempotent(self):
        self.ensure("a")
        self.ensure("b")
        before = self.read()
        self.ensure("b")
        self.assertEqual(before, self.read(), "re-ensuring an unchanged beam must not rewrite")
        self.assertEqual(before.count(ssh_config.MARKER_START), 1)
        listed = run("ssh_config.py", ["list", "--config", self.path]).split()
        self.assertEqual(listed, ["a", "b"])
        removed = run("ssh_config.py", ["prune", "--keep", "b", "--config", self.path]).split()
        self.assertEqual(removed, ["a"])
        run("ssh_config.py", ["remove", "--id", "b", "--config", self.path])
        cfg = self.read()
        self.assertNotIn(ssh_config.MARKER_START, cfg)
        self.assertNotIn("bbedit--", cfg)

    def test_empty_file_and_no_hosts(self):
        self.ensure("x")
        cfg = self.read()
        self.assertTrue(cfg.startswith(ssh_config.MARKER_START))
        self.assertTrue(cfg.endswith(ssh_config.MARKER_END + "\n"))


class BeamsJsonTests(unittest.TestCase):
    def test_profile(self):
        status = json.dumps({"active": {"profile_url": "https://c.beams.sh:443", "username": "u", "cluster": "c.beams.sh", "valid_until": "t"}})
        out = run("beams_json.py", ["profile"], stdin=status)
        self.assertIn("BEAMS_CLUSTER=c.beams.sh", out)
        self.assertIn("BEAMS_PROXY=c.beams.sh:443", out)

    def test_profile_prefers_beams_cluster_over_active(self):
        status = json.dumps({
            "active": {"profile_url": "https://other.example.com:443", "username": "a", "cluster": "other.example.com"},
            "profiles": [
                {"profile_url": "https://c.beams.sh:443", "username": "u", "cluster": "c.beams.sh"},
                {"profile_url": "https://d.beams.sh:443", "username": "v", "cluster": "d.beams.sh"},
            ],
        })
        out = run("beams_json.py", ["profile"], stdin=status)
        self.assertIn("BEAMS_CLUSTER=c.beams.sh", out)
        out = run("beams_json.py", ["profile", "d.beams.sh"], stdin=status)
        self.assertIn("BEAMS_CLUSTER=d.beams.sh", out)
        self.assertIn("BEAMS_PROXY=d.beams.sh:443", out)
        out = run("beams_json.py", ["profile", "missing.beams.sh"], stdin=status)
        self.assertIn("BEAMS_CLUSTER=c.beams.sh", out, "unknown preferred cluster falls back to a *.beams.sh profile")

    def test_beams_and_menu(self):
        beams = json.dumps([{"id": "a", "uuid": "u-a", "expires": "2999-01-01T00:00:00Z", "url": "", "owner": "o", "region": "us-west-2"},
                            {"id": "b", "expires": "2000-01-01T00:00:00Z", "url": "https://b", "owner": "o"}])
        tsv = run("beams_json.py", ["beams"], stdin=beams)
        self.assertEqual(tsv.splitlines()[0].split("\t"), ["a", "2999-01-01T00:00:00Z", "", "o", "us-west-2", "u-a"])
        menu = run("beams_json.py", ["menu", "b"], stdin=tsv).splitlines()
        self.assertTrue(menu[0].startswith("a  —  expires in "))
        self.assertIn("published", menu[1])
        self.assertIn("current", menu[1])
        self.assertIn("expired", menu[1])
        self.assertEqual(menu[1].split()[0], "b")

    def test_expires_go_nanoseconds(self):
        self.assertNotEqual(beams_json.expires_in("2026-09-16T18:16:09.896689354Z"), "?")


class ActivityTests(unittest.TestCase):
    def test_parse_dedupes_usage_and_matches_tool_results(self):
        lines = [
            json.dumps({"type": "user", "timestamp": "2026-01-01T00:00:00Z", "sessionId": "s", "cwd": "/home/beams/work",
                        "message": {"role": "user", "content": [{"type": "text", "text": "do the thing"}]}}),
            json.dumps({"type": "assistant", "timestamp": "2026-01-01T00:00:01Z",
                        "message": {"id": "m1", "model": "claude-opus-5", "usage": {"input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 20},
                                    "content": [{"type": "text", "text": "ok"}]}}),
            json.dumps({"type": "assistant", "timestamp": "2026-01-01T00:00:02Z",
                        "message": {"id": "m1", "model": "claude-opus-5", "usage": {"input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 20},
                                    "content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}}]}}),
            json.dumps({"type": "user", "timestamp": "2026-01-01T00:00:03Z", "toolUseResult": {},
                        "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "boom", "is_error": True}]}}),
        ]
        s = activity.parse(lines)
        self.assertEqual((s["tokens_in"], s["tokens_out"], s["cache_read"], s["cache_write"]), (10, 5, 100, 20))
        self.assertEqual(s["messages"], 2)
        self.assertEqual(s["tool_calls"][0]["ok"], False)
        kinds = [e[1] for e in s["events"]]
        self.assertEqual(kinds, ["user", "assistant", "tool", "error"])
        md = activity.render(s, "beam", "/p", 10, 10)
        self.assertIn("| Model | claude-opus-5 |", md)
        self.assertIn("✗ **Bash** ls", md)


if __name__ == "__main__":
    unittest.main(verbosity=1)
