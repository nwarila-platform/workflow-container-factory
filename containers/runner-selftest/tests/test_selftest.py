"""Unit tests for every runner isolation probe and the command line."""

import errno
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from runner_selftest import checks

PROJECT = Path(__file__).resolve().parent.parent


class SelftestTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)

    def write(self, name, content):
        path = self.root / name
        path.write_text(content)
        return path

    def test_user_requires_the_fixed_uid_and_gid(self):
        self.assertTrue(checks.user(lambda: 65532, lambda: 65532).passed)
        self.assertEqual(checks.user(lambda: 1, lambda: 2).detail, "expected uid/gid 65532/65532, got 1/2")

    def test_capabilities_require_a_zero_effective_set(self):
        status = self.write("status", "CapEff:\t0000000000000000\nNoNewPrivs:\t1\n")
        self.assertTrue(checks.capabilities(status).passed)
        status.write_text("CapEff:\t0000000000000001\n")
        self.assertEqual(checks.capabilities(status).detail, "CapEff is 0000000000000001")

    def test_no_new_privileges_requires_one(self):
        status = self.write("status", "NoNewPrivs:\t1\n")
        self.assertTrue(checks.no_new_privileges(status).passed)
        status.write_text("NoNewPrivs:\t0\n")
        self.assertEqual(checks.no_new_privileges(status).detail, "NoNewPrivs is 0")

    def test_network_allows_only_loopback(self):
        heading = "Inter-| Receive\n face |bytes\n"
        dev = self.write("dev", heading + " lo: 0\n")
        self.assertTrue(checks.network(dev).passed)
        dev.write_text(heading + " lo: 0\n eth0: 0\n")
        self.assertEqual(checks.network(dev).detail, "unexpected interfaces: eth0")

    def test_read_only_requires_erofs(self):
        def erofs(_path):
            raise OSError(errno.EROFS, "read-only")

        def eacces(_path):
            raise OSError(errno.EACCES, "denied")

        self.assertTrue(checks.read_only("mount read-only", self.root, erofs).passed)
        self.assertEqual(checks.read_only("mount read-only", self.root, eacces).detail, "expected EROFS, got EACCES")
        self.assertEqual(checks.read_only("mount read-only", self.root, lambda _path: None).detail, "probe creation succeeded")

    def test_workspace_and_template_readability_require_an_entry(self):
        self.assertIn("is empty", checks.readable("workspace readable", self.root).detail)
        self.write("README", "present\n")
        self.assertTrue(checks.readable("template readable: acme/template", self.root).passed)

    def test_scratch_writes_reads_removes_and_checks_mount_options(self):
        mounts = self.write("mounts", f"tmpfs {self.root} tmpfs rw,nosuid,nodev,noexec 0 0\n")
        self.assertTrue(checks.scratch(self.root, mounts).passed)
        self.assertFalse((self.root / ".runner-selftest-probe").exists())
        mounts.write_text(f"tmpfs {self.root} tmpfs rw,nosuid,nodev 0 0\n")
        self.assertEqual(checks.scratch(self.root, mounts).detail, "missing mount options: noexec")

    def test_wrong_arguments_are_usage_errors_without_a_report(self):
        done = subprocess.run(
            [sys.executable, "-m", "runner_selftest"], cwd=PROJECT,
            capture_output=True, text=True, check=False,
        )
        self.assertEqual((done.returncode, done.stdout), (2, ""))
        self.assertIn("--workspace, --template", done.stderr)


if __name__ == "__main__":
    unittest.main()
