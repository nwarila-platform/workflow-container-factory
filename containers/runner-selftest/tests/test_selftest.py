"""Unit tests for runner isolation checks and command-line errors."""

import contextlib
import errno
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from runner_selftest import __main__ as command_line
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
        for uid, gid in ((0, 65532), (65532, 0)):
            with self.subTest(uid=uid, gid=gid):
                self.assertEqual(
                    checks.user(lambda: uid, lambda: gid).detail,
                    f"expected uid/gid 65532/65532, got {uid}/{gid}",
                )

    def test_capabilities_require_every_set_to_be_zero(self):
        status = self.write(
            "status",
            "CapInh:\t0000000000000000\n"
            "CapPrm:\t0000000000000000\n"
            "CapEff:\t0000000000000000\n"
            "CapBnd:\t0000000000000000\n"
            "CapAmb:\t0000000000000000\n",
        )
        self.assertTrue(checks.capabilities(status).passed)
        for capability_set in ("CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"):
            with self.subTest(capability_set=capability_set):
                contents = status.read_text().replace(
                    f"{capability_set}:\t0000000000000000",
                    f"{capability_set}:\t0000000000000001",
                )
                status.write_text(contents)
                self.assertEqual(
                    checks.capabilities(status).detail,
                    f"{capability_set} is 0000000000000001",
                )
                status.write_text(contents.replace("0000000000000001", "0000000000000000"))

    def test_no_new_privileges_requires_one(self):
        status = self.write("status", "NoNewPrivs:\t1\n")
        self.assertTrue(checks.no_new_privileges(status).passed)
        status.write_text("NoNewPrivs:\t0\n")
        self.assertEqual(checks.no_new_privileges(status).detail, "NoNewPrivs is 0")

    def test_a_status_field_that_is_absent_is_an_error_not_a_pass(self):
        status = self.write(
            "status",
            "CapInh:\t0000000000000000\n"
            "CapPrm:\t0000000000000000\n"
            "CapEff:\t0000000000000000\n",
        )
        with self.assertRaisesRegex(ValueError, "^CapBnd is absent from "):
            checks.capabilities(status)
        with self.assertRaisesRegex(ValueError, "^NoNewPrivs is absent from "):
            checks.no_new_privileges(status)

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
        self.assertEqual(checks.read_only("mount read-only", self.root).detail, "probe creation succeeded")
        self.assertEqual(list(self.root.iterdir()), [])

    def test_readable_requires_a_directory_with_an_entry(self):
        missing = self.root / "missing"
        self.assertEqual(
            checks.readable("workspace readable", missing).detail,
            f"FileNotFoundError: [Errno {errno.ENOENT}] No such file or directory: '{missing}'",
        )
        self.assertEqual(checks.readable("workspace readable", self.root).detail, f"{self.root} is empty")
        self.write("README", "present\n")
        self.assertTrue(checks.readable("workspace readable", self.root).passed)

    def test_readable_stops_after_the_first_entry(self):
        entries = mock.MagicMock()
        entries.__enter__.return_value = entries
        entries.__next__.side_effect = [mock.sentinel.entry, AssertionError("read twice")]
        with mock.patch.object(checks.os, "scandir", return_value=entries):
            self.assertTrue(checks.readable("workspace readable", self.root).passed)
        entries.__next__.assert_called_once_with()

    def test_scratch_writes_reads_and_removes_a_probe(self):
        mounts = self.write("mounts", f"tmpfs {self.root} tmpfs rw,nosuid,nodev,noexec 0 0\n")
        self.assertTrue(checks.scratch("scratch", self.root, mounts).passed)

    def test_scratch_requires_a_writable_directory(self):
        mounts = self.write("mounts", f"tmpfs {self.root} tmpfs rw,nosuid,nodev,noexec 0 0\n")
        with mock.patch.object(
            tempfile,
            "NamedTemporaryFile",
            side_effect=PermissionError(errno.EACCES, "denied"),
        ):
            result = checks.scratch("scratch", self.root, mounts)
        self.assertEqual(
            result.detail,
            f"{self.root} probe failed: PermissionError: [Errno {errno.EACCES}] denied",
        )

    def test_scratch_requires_a_mount_entry(self):
        mounts = self.write("mounts", "tmpfs /somewhere-else tmpfs rw,nosuid,nodev,noexec 0 0\n")
        self.assertEqual(
            checks.scratch("scratch", self.root, mounts).detail,
            f"{self.root} has no mount entry",
        )

    def test_scratch_requires_each_mount_option(self):
        for option in ("nosuid", "nodev", "noexec"):
            with self.subTest(option=option):
                options = {"rw", "nosuid", "nodev", "noexec"} - {option}
                mounts = self.write("mounts", f"tmpfs {self.root} tmpfs {','.join(sorted(options))} 0 0\n")
                self.assertEqual(
                    checks.scratch("scratch", self.root, mounts).detail,
                    f"{self.root} is missing mount options: {option}",
                )

    def test_scratch_judges_the_last_mount_on_its_directory(self):
        mounts = self.write(
            "mounts",
            f"tmpfs {self.root} tmpfs rw,nosuid,nodev 0 0\n"
            f"tmpfs {self.root} tmpfs rw,nosuid,nodev,noexec 0 0\n",
        )
        self.assertTrue(checks.scratch("scratch", self.root, mounts).passed)
        mounts.write_text(
            f"tmpfs {self.root} tmpfs rw,nosuid,nodev,noexec 0 0\n"
            f"tmpfs {self.root} tmpfs rw,nosuid,nodev 0 0\n"
        )
        self.assertEqual(
            checks.scratch("scratch", self.root, mounts).detail,
            f"{self.root} is missing mount options: noexec",
        )

    def test_probes_preserve_the_old_fixed_probe_name(self):
        mounts = self.write("mounts", f"tmpfs {self.root} tmpfs rw,nosuid,nodev,noexec 0 0\n")
        fixed_probe = self.write(".runner-selftest-probe", "keep me\n")
        self.assertEqual(
            checks.read_only("mount read-only", self.root).detail,
            "probe creation succeeded",
        )
        self.assertTrue(checks.scratch("scratch", self.root, mounts).passed)
        self.assertEqual(fixed_probe.read_text(), "keep me\n")

    def test_scratch_rejects_changed_probe_contents(self):
        mounts = self.write("mounts", f"tmpfs {self.root} tmpfs rw,nosuid,nodev,noexec 0 0\n")
        probe = mock.MagicMock()
        probe.__enter__.return_value = probe
        probe.read.return_value = b"changed\n"
        with mock.patch.object(tempfile, "NamedTemporaryFile", return_value=probe):
            result = checks.scratch("scratch", self.root, mounts)
        self.assertEqual(result.detail, f"{self.root} probe contents changed")

    def test_run_checks_both_scratch_mounts(self):
        with mock.patch.multiple(
            checks,
            user=mock.DEFAULT,
            capabilities=mock.DEFAULT,
            no_new_privileges=mock.DEFAULT,
            network=mock.DEFAULT,
            read_only=mock.DEFAULT,
            readable=mock.DEFAULT,
            scratch=mock.DEFAULT,
        ) as probes:
            for probe in probes.values():
                probe.return_value = checks.Result("stub")
            checks.run(self.root, [])

        self.assertEqual(
            probes["scratch"].call_args_list,
            [mock.call("scratch", Path("/tmp")), mock.call("home scratch", Path("/home/nonroot"))],
        )

    def test_wrong_arguments_are_usage_errors_without_a_report(self):
        for arguments, message in (
            ([], "the following arguments are required: --workspace, --template"),
            (["--workspace", "."], "the following arguments are required: --template"),
            (["--workspace", ".", "--template", "no-owner=."], "expected OWNER/REPO=DIRECTORY"),
            (["--workspace", ".", "--template", "acme/template"], "expected OWNER/REPO=DIRECTORY"),
            (["--workspace", ".", "--template", "acme/template="], "expected OWNER/REPO=DIRECTORY"),
            (["--workspace", ".", "--template", "acme/template=.", "--format", "json"], "invalid choice: 'json'"),
            (["--work", ".", "--template", "acme/template=."], "the following arguments are required: --workspace"),
        ):
            with self.subTest(arguments=arguments):
                done = subprocess.run(
                    [sys.executable, "-m", "runner_selftest", *arguments], cwd=PROJECT,
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual((done.returncode, done.stdout), (2, ""))
                self.assertIn(message, done.stderr)

    def test_a_check_that_cannot_run_exits_2_instead_of_reporting_a_failure(self):
        arguments = ["runner-selftest", "--workspace", str(self.root), "--template", f"acme/template={self.root}"]
        error = ValueError("CapBnd is absent from /proc/self/status")
        with tempfile.TemporaryFile(mode="w+") as stderr:
            with (
                mock.patch.object(sys, "argv", arguments),
                mock.patch.object(command_line, "run", side_effect=error),
                contextlib.redirect_stderr(stderr),
            ):
                status = command_line.main()
            stderr.seek(0)
            diagnostic = stderr.read()
        self.assertEqual(
            (status, diagnostic),
            (2, "runner-selftest: error: ValueError: CapBnd is absent from /proc/self/status\n"),
        )

    @unittest.skipUnless(Path("/dev/full").exists(), "/dev/full is unavailable")
    def test_a_report_that_cannot_be_written_exits_2(self):
        arguments = [
            sys.executable,
            "-m",
            "runner_selftest",
            "--workspace",
            str(self.root),
            "--template",
            f"acme/template={self.root}",
        ]
        with Path("/dev/full").open("w") as full:
            done = subprocess.run(
                arguments,
                cwd=PROJECT,
                stdout=full,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
        self.assertEqual(done.returncode, 2)
        self.assertIn("runner-selftest: error: OSError", done.stderr)

    @unittest.skipUnless(Path("/dev/full").exists(), "/dev/full is unavailable")
    def test_an_error_that_cannot_be_written_exits_2(self):
        arguments = [
            sys.executable,
            "-m",
            "runner_selftest",
            "--workspace",
            str(self.root / "missing"),
            "--template",
            f"acme/template={self.root}",
        ]
        with Path("/dev/full").open("w") as full:
            done = subprocess.run(
                arguments,
                cwd=PROJECT,
                stdout=full,
                stderr=full,
                text=True,
                check=False,
            )
        self.assertEqual(done.returncode, 2)


if __name__ == "__main__":
    unittest.main()
