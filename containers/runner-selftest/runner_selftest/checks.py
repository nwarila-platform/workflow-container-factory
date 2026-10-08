"""The runner isolation checks, kept independent so every probe can be tested on the host."""

import errno
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


@dataclass(frozen=True)
class Result:
    name: str
    detail: str | None = None

    @property
    def passed(self) -> bool:
        return self.detail is None


def user(getuid: Callable[[], int] = os.getuid, getgid: Callable[[], int] = os.getgid) -> Result:
    uid, gid = getuid(), getgid()
    detail = None if (uid, gid) == (65532, 65532) else f"expected uid/gid 65532/65532, got {uid}/{gid}"
    return Result("user", detail)


def _status_value(status: Path, key: str) -> str:
    for line in status.read_text(encoding="ascii").splitlines():
        name, separator, value = line.partition(":")
        if separator and name == key:
            return value.strip()
    raise ValueError(f"{key} is absent from {status}")


def capabilities(status: Path = Path("/proc/self/status")) -> Result:
    values = {key: _status_value(status, key) for key in ("CapEff", "CapBnd")}
    nonzero = [f"{key} is {value}" for key, value in values.items() if value != "0000000000000000"]
    return Result("capabilities", "; ".join(nonzero) or None)


def no_new_privileges(status: Path = Path("/proc/self/status")) -> Result:
    value = _status_value(status, "NoNewPrivs")
    detail = None if value == "1" else f"NoNewPrivs is {value}"
    return Result("no-new-privileges", detail)


def network(dev: Path = Path("/proc/net/dev")) -> Result:
    interfaces = []
    for line in dev.read_text(encoding="ascii").splitlines()[2:]:
        name, separator, _ = line.partition(":")
        if separator:
            interfaces.append(name.strip())
    unexpected = sorted(name for name in interfaces if name != "lo")
    detail = None if not unexpected else f"unexpected interfaces: {', '.join(unexpected)}"
    return Result("network", detail)


def _create_probe(path: Path) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(descriptor)
    path.unlink()


def read_only(name: str, directory: Path, create: Callable[[Path], None] = _create_probe) -> Result:
    probe = directory / ".runner-selftest-probe"
    try:
        create(probe)
    except OSError as error:
        if error.errno == errno.EROFS:
            return Result(name)
        return Result(name, f"expected EROFS, got {errno.errorcode.get(error.errno, error.errno)}")
    return Result(name, "probe creation succeeded")


def readable(name: str, directory: Path) -> Result:
    try:
        entries = list(directory.iterdir())
    except OSError as error:
        return Result(name, f"{type(error).__name__}: {error}")
    detail = None if entries else f"{directory} is empty"
    return Result(name, detail)


def scratch(
    name: str = "scratch",
    directory: Path = Path("/tmp"),
    mounts: Path = Path("/proc/self/mounts"),
) -> Result:
    probe = directory / ".runner-selftest-probe"
    try:
        probe.write_bytes(b"runner-selftest\n")
        if probe.read_bytes() != b"runner-selftest\n":
            return Result(name, f"{directory} probe contents changed")
        probe.unlink()
    except OSError as error:
        return Result(name, f"{directory} probe failed: {type(error).__name__}: {error}")
    finally:
        try:
            probe.unlink(missing_ok=True)
        except OSError:
            pass

    options = None
    for line in mounts.read_text(encoding="ascii").splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[1] == str(directory):
            options = set(fields[3].split(","))
    if options is None:
        return Result(name, f"{directory} has no mount entry")
    missing = sorted({"nosuid", "nodev", "noexec"} - options)
    detail = None if not missing else f"{directory} is missing mount options: {', '.join(missing)}"
    return Result(name, detail)


def run(workspace: Path, templates: list[tuple[str, Path]]) -> list[Result]:
    results = [
        user(),
        capabilities(),
        no_new_privileges(),
        network(),
        read_only("root read-only", Path("/")),
        readable("workspace readable", workspace),
        read_only("workspace read-only", workspace),
    ]
    for label, directory in templates:
        results.append(readable(f"template readable: {label}", directory))
        results.append(read_only(f"template read-only: {label}", directory))
    results.append(scratch())
    results.append(scratch("home scratch", Path("/home/nonroot")))
    return results
