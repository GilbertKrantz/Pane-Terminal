#!/usr/bin/env python3
"""Reproducible Pane P2 soak orchestration with bounded cleanup.

An app driver is required for release-gate evidence. Without one, this runner
uses eight isolated local PTYs to validate the sampling and cleanup machinery
without claiming that Pane's tab UI was exercised.
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
import datetime as dt
import fcntl
import json
import os
import pathlib
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import termios
from dataclasses import dataclass
from typing import Any


PRESET_SECONDS = {"2h": 2 * 60 * 60, "8h": 8 * 60 * 60}
REQUIRED_SAMPLE_KEYS = {
    "timestamp",
    "residentMemoryBytes",
    "virtualMemoryBytes",
    "threadCount",
    "fileDescriptorCount",
    "liveSessionCount",
    "livePTYCount",
    "completionTaskCount",
    "blockCount",
    "idleCPUPercent",
}
STOP_REQUESTED = threading.Event()


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def positive_integer(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def signal_stop(_signal_number: int, _frame: object) -> None:
    STOP_REQUESTED.set()


def write_json(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def append_json_line(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(payload, sort_keys=True, separators=(",", ":")))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def bounded_run(
    arguments: list[str],
    timeout: float,
    *,
    capture_output: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        arguments,
        check=True,
        capture_output=capture_output,
        text=True,
        timeout=timeout,
    )


@dataclass
class ManagedPTY:
    name: str
    process: subprocess.Popen[bytes]
    master_fd: int
    tail: collections.deque[bytes]
    reader: threading.Thread

    @classmethod
    def start(
        cls,
        name: str,
        arguments: list[str],
        environment: dict[str, str],
    ) -> "ManagedPTY":
        master_fd, slave_fd = pty.openpty()
        process = subprocess.Popen(
            arguments,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            env=environment,
            close_fds=True,
            preexec_fn=os.setsid,
        )
        os.close(slave_fd)
        tail: collections.deque[bytes] = collections.deque()
        instance = cls(
            name=name,
            process=process,
            master_fd=master_fd,
            tail=tail,
            reader=threading.Thread(),
        )
        instance.reader = threading.Thread(
            target=instance._drain,
            name=f"pane-soak-{name}",
            daemon=True,
        )
        instance.reader.start()
        return instance

    def _drain(self) -> None:
        retained = 0
        while self.process.poll() is None and not STOP_REQUESTED.is_set():
            try:
                readable, _, _ = select.select([self.master_fd], [], [], 0.25)
                if not readable:
                    continue
                chunk = os.read(self.master_fd, 4096)
                if not chunk:
                    break
            except OSError:
                break
            self.tail.append(chunk)
            retained += len(chunk)
            while retained > 65_536 and self.tail:
                retained -= len(self.tail.popleft())

    def send(self, value: bytes) -> None:
        if self.process.poll() is not None:
            raise RuntimeError(f"{self.name} exited unexpectedly")
        os.write(self.master_fd, value)

    def resize(self, columns: int, rows: int) -> None:
        dimensions = struct.pack("HHHH", rows, columns, 0, 0)
        fcntl.ioctl(self.master_fd, termios.TIOCSWINSZ, dimensions)

    def terminate(self) -> None:
        survived = False
        if self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            except PermissionError:
                self.process.terminate()
            try:
                self.process.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    self.process.kill()
                try:
                    self.process.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    survived = True
        try:
            os.close(self.master_fd)
        except OSError:
            pass
        self.reader.join(timeout=0.5)
        if survived:
            raise RuntimeError(f"{self.name} survived bounded SIGTERM/SIGKILL cleanup")

    def write_tail(self, directory: pathlib.Path) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        (directory / f"{self.name}.tail.log").write_bytes(b"".join(self.tail))


class FixtureTopology:
    """Eight local PTYs mirroring the release topology without Pane UI claims."""

    evidence_mode = "fixture-pty-fallback"
    release_gate_eligible = False

    def __init__(
        self,
        fixture: pathlib.Path,
        duration_seconds: int,
        diagnostics_directory: pathlib.Path,
    ) -> None:
        self.fixture = fixture
        self.duration_seconds = duration_seconds
        self.diagnostics_directory = diagnostics_directory
        self.temporary_home = tempfile.TemporaryDirectory(prefix="Pane-P2-Soak-")
        self.sessions: list[ManagedPTY] = []
        self.selected_index = 0
        self.block_count = 0

    def start(self) -> None:
        environment = {
            "HOME": self.temporary_home.name,
            "ZDOTDIR": self.temporary_home.name,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
        }
        for index in range(4):
            self.sessions.append(
                ManagedPTY.start(
                    f"background-{index + 1}",
                    [
                        str(self.fixture),
                        "progress",
                        "--count",
                        "100000000",
                        "--delay",
                        "1",
                    ],
                    environment,
                )
            )
        for index in range(2):
            self.sessions.append(
                ManagedPTY.start(
                    f"interactive-{index + 1}",
                    [
                        str(self.fixture),
                        "alternate-screen",
                        "--interactive",
                        "--action-timeout",
                        str(self.duration_seconds + 60),
                    ],
                    environment,
                )
            )
        for index in range(2):
            shell = ManagedPTY.start(
                f"idle-{index + 1}",
                ["/bin/zsh", "-f"],
                environment,
            )
            shell.send(b"PS1='PANE_SOAK_IDLE> '\n")
            self.sessions.append(shell)
        self._wait_until_ready()

    def _wait_until_ready(self) -> None:
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            if all(session.process.poll() is None for session in self.sessions):
                time.sleep(0.05)
                return
            time.sleep(0.05)
        raise RuntimeError("fixture topology did not become ready within five seconds")

    def exercise(self, iteration: int) -> list[str]:
        for session in self.sessions[6:8]:
            session.send(
                f"printf 'PANE_SOAK_MARKER_{iteration}_%s\\n' $$\n".encode("ascii")
            )
        for session in self.sessions[4:6]:
            session.send(b".")

        self.selected_index = (self.selected_index + 1) % len(self.sessions)
        columns = 80 + (iteration % 5) * 8
        rows = 24 + (iteration % 3) * 4
        for session in self.sessions:
            session.resize(columns, rows)

        self._temporary_tab(iteration)
        self.block_count += 3
        return [
            "marker",
            "switch",
            "temporary-tab-create-close",
            "autocomplete-probe-not-app-hosted",
            f"resize-{columns}x{rows}",
        ]

    def _temporary_tab(self, iteration: int) -> None:
        environment = {
            "HOME": self.temporary_home.name,
            "ZDOTDIR": self.temporary_home.name,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color",
        }
        temporary = ManagedPTY.start(
            f"temporary-{iteration}",
            ["/bin/zsh", "-f"],
            environment,
        )
        try:
            temporary.send(
                f"printf 'PANE_SOAK_TEMP_{iteration}\\n'; exit\n".encode("ascii")
            )
            temporary.process.wait(timeout=2.0)
        finally:
            temporary.terminate()

    def sample(self, iteration: int, actions: list[str]) -> dict[str, Any]:
        process_ids = [
            session.process.pid
            for session in self.sessions
            if session.process.poll() is None
        ]
        metrics = process_metrics(process_ids)
        return {
            "timestamp": utc_now(),
            "residentMemoryBytes": metrics["residentMemoryBytes"],
            "virtualMemoryBytes": metrics["virtualMemoryBytes"],
            "threadCount": metrics["threadCount"],
            "fileDescriptorCount": metrics["fileDescriptorCount"],
            "liveSessionCount": len(self.sessions),
            "livePTYCount": len(process_ids),
            "completionTaskCount": 0,
            "blockCount": self.block_count,
            "idleCPUPercent": metrics["cpuPercent"],
            "metricCollectionPartial": metrics["partial"],
            "iteration": iteration,
            "selectedFixtureSession": self.sessions[self.selected_index].name,
            "actions": actions,
            "evidenceMode": self.evidence_mode,
            "releaseGateEligible": self.release_gate_eligible,
        }

    def stop(self) -> None:
        for session in self.sessions[4:6]:
            if session.process.poll() is None:
                try:
                    session.send(b"\n")
                except (OSError, RuntimeError):
                    pass
        cleanup_error: Exception | None = None
        with concurrent.futures.ThreadPoolExecutor(
            max_workers=len(self.sessions)
        ) as pool:
            futures = [pool.submit(session.terminate) for session in self.sessions]
            completed, pending = concurrent.futures.wait(futures, timeout=2.0)
            if pending:
                cleanup_error = TimeoutError(
                    "fixture PTY cleanup exceeded two seconds"
                )
            for future in completed:
                try:
                    future.result()
                except Exception as error:
                    cleanup_error = cleanup_error or error
        for session in self.sessions:
            session.write_tail(self.diagnostics_directory)
        self.temporary_home.cleanup()
        if cleanup_error is not None:
            raise cleanup_error


class AppDriver:
    """Adapter for a future app-hosted driver with a narrow argv-only protocol."""

    evidence_mode = "pane-app-driver"
    release_gate_eligible = True

    def __init__(
        self,
        executable: pathlib.Path,
        state_path: pathlib.Path,
        diagnostics_directory: pathlib.Path,
    ) -> None:
        self.executable = executable
        self.state_path = state_path
        self.diagnostics_directory = diagnostics_directory

    def _base(self, command: str) -> list[str]:
        return [
            str(self.executable),
            command,
            "--state",
            str(self.state_path),
            "--diagnostics-dir",
            str(self.diagnostics_directory),
        ]

    def start(self) -> None:
        bounded_run(
            self._base("start")
            + [
                "--tabs",
                "8",
                "--background-tabs",
                "4",
                "--interactive-tabs",
                "2",
                "--idle-tabs",
                "2",
            ],
            20.0,
        )

    def exercise(self, iteration: int) -> list[str]:
        actions = [
            "marker",
            "switch",
            "temporary-tab",
            "autocomplete",
            "resize",
        ]
        for action in actions:
            bounded_run(
                self._base("action")
                + ["--name", action, "--iteration", str(iteration)],
                20.0,
            )
        return actions

    def sample(self, iteration: int, actions: list[str]) -> dict[str, Any]:
        result = bounded_run(
            self._base("sample") + ["--iteration", str(iteration)],
            20.0,
        )
        payload = json.loads(result.stdout)
        missing = REQUIRED_SAMPLE_KEYS.difference(payload)
        if missing:
            raise RuntimeError(
                "app driver sample is missing keys: " + ", ".join(sorted(missing))
            )
        payload.update(
            {
                "iteration": iteration,
                "actions": actions,
                "evidenceMode": self.evidence_mode,
                "releaseGateEligible": self.release_gate_eligible,
            }
        )
        return payload

    def stop(self) -> None:
        bounded_run(self._base("stop") + ["--timeout-seconds", "2"], 3.0)


def process_metrics(process_ids: list[int]) -> dict[str, int | float]:
    if not process_ids:
        return {
            "residentMemoryBytes": 0,
            "virtualMemoryBytes": 0,
            "threadCount": 0,
            "fileDescriptorCount": 0,
            "cpuPercent": 0.0,
            "partial": False,
        }
    pid_argument = ",".join(str(pid) for pid in process_ids)
    resident_kib = 0
    virtual_kib = 0
    cpu_percent = 0.0
    partial = False
    try:
        result = bounded_run(
            ["/bin/ps", "-o", "rss=,vsz=,%cpu=", "-p", pid_argument],
            5.0,
        )
        for line in result.stdout.splitlines():
            fields = line.split()
            if len(fields) >= 3:
                resident_kib += int(fields[0])
                virtual_kib += int(fields[1])
                cpu_percent += float(fields[2])
    except (subprocess.SubprocessError, OSError):
        partial = True

    file_descriptors = 0
    lsof = pathlib.Path("/usr/sbin/lsof")
    if lsof.exists():
        for process_id in process_ids:
            try:
                opened = bounded_run(
                    [str(lsof), "-n", "-P", "-p", str(process_id)],
                    5.0,
                )
                file_descriptors += max(0, len(opened.stdout.splitlines()) - 1)
            except (subprocess.SubprocessError, OSError):
                partial = True

    thread_count = 0
    for process_id in process_ids:
        try:
            threads = bounded_run(
                ["/bin/ps", "-M", "-p", str(process_id)],
                5.0,
            )
            thread_count += max(0, len(threads.stdout.splitlines()) - 1)
        except (subprocess.SubprocessError, OSError):
            thread_count += 1
            partial = True

    return {
        "residentMemoryBytes": resident_kib * 1024,
        "virtualMemoryBytes": virtual_kib * 1024,
        "threadCount": thread_count,
        "fileDescriptorCount": file_descriptors,
        "cpuPercent": round(cpu_percent, 3),
        "partial": partial,
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--preset",
        choices=sorted(PRESET_SECONDS),
        default=os.environ.get("PANE_SOAK_PRESET", "2h"),
    )
    parser.add_argument(
        "--duration-seconds",
        type=positive_integer,
        default=(
            positive_integer(os.environ["PANE_SOAK_SECONDS"])
            if "PANE_SOAK_SECONDS" in os.environ
            else None
        ),
    )
    parser.add_argument(
        "--interval-seconds",
        type=positive_integer,
        default=positive_integer(
            os.environ.get("PANE_SOAK_INTERVAL_SECONDS", "300")
        ),
    )
    parser.add_argument(
        "--artifact",
        type=pathlib.Path,
        default=pathlib.Path(
            os.environ.get(
                "PANE_SOAK_ARTIFACT",
                ".build/p2-artifacts/pane-soak.jsonl",
            )
        ),
    )
    parser.add_argument(
        "--diagnostics-dir",
        type=pathlib.Path,
        default=pathlib.Path(
            os.environ.get(
                "PANE_SOAK_DIAGNOSTICS_DIR",
                ".build/p2-artifacts/soak-diagnostics",
            )
        ),
    )
    parser.add_argument(
        "--driver",
        type=pathlib.Path,
        default=(
            pathlib.Path(os.environ["PANE_SOAK_DRIVER"])
            if os.environ.get("PANE_SOAK_DRIVER")
            else None
        ),
    )
    parser.add_argument(
        "--require-app-driver",
        action="store_true",
        help="fail instead of producing fixture-only, non-release evidence",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    repo_root = pathlib.Path(__file__).resolve().parents[2]
    os.chdir(repo_root)
    duration_seconds = (
        arguments.duration_seconds
        if arguments.duration_seconds is not None
        else PRESET_SECONDS[arguments.preset]
    )
    artifact = arguments.artifact.resolve()
    diagnostics_directory = arguments.diagnostics_dir.resolve()
    summary_path = artifact.with_suffix(artifact.suffix + ".summary.json")
    fixture = repo_root / "Tests/Compatibility/Fixtures/pane-fixture"

    driver_path = arguments.driver.resolve() if arguments.driver else None
    if driver_path is not None:
        if not driver_path.is_file() or not os.access(driver_path, os.X_OK):
            raise SystemExit(f"app driver is not executable: {driver_path}")
        driver: FixtureTopology | AppDriver = AppDriver(
            driver_path,
            diagnostics_directory / "driver-state.json",
            diagnostics_directory,
        )
    else:
        if arguments.require_app_driver:
            raise SystemExit(
                "PANE_SOAK_DRIVER is required for release-gate soak evidence"
            )
        if not fixture.is_file() or not os.access(fixture, os.X_OK):
            raise SystemExit(f"fixture is not executable: {fixture}")
        driver = FixtureTopology(
            fixture,
            duration_seconds,
            diagnostics_directory,
        )

    for handled_signal in (signal.SIGINT, signal.SIGTERM):
        signal.signal(handled_signal, signal_stop)

    artifact.parent.mkdir(parents=True, exist_ok=True)
    diagnostics_directory.mkdir(parents=True, exist_ok=True)
    for stale_path in (
        summary_path,
        diagnostics_directory / "failure.json",
    ):
        stale_path.unlink(missing_ok=True)
    artifact.write_text("", encoding="utf-8")
    started_at = utc_now()
    completed = False
    failure_stage: str | None = None
    cleanup_error: Exception | None = None
    sample_count = 0
    started_monotonic = time.monotonic()

    try:
        failure_stage = "startup"
        driver.start()
        deadline = started_monotonic + duration_seconds
        iteration = 0
        while time.monotonic() < deadline and not STOP_REQUESTED.is_set():
            failure_stage = f"exercise-{iteration}"
            actions = driver.exercise(iteration)
            failure_stage = f"sample-{iteration}"
            sample = driver.sample(iteration, actions)
            append_json_line(artifact, sample)
            sample_count += 1
            iteration += 1
            next_sample = min(
                deadline,
                started_monotonic + iteration * arguments.interval_seconds,
            )
            while time.monotonic() < next_sample and not STOP_REQUESTED.wait(1.0):
                pass
        completed = not STOP_REQUESTED.is_set() and time.monotonic() >= deadline
        failure_stage = None if completed else "interrupted"
    except Exception as error:
        failure_stage = failure_stage or "unknown"
        write_json(
            diagnostics_directory / "failure.json",
            {
                "errorType": type(error).__name__,
                "stage": failure_stage,
                "timestamp": utc_now(),
            },
        )
        raise
    finally:
        cleanup_started = time.monotonic()
        try:
            driver.stop()
        except Exception as error:
            cleanup_error = error
            completed = False
            if failure_stage is None:
                failure_stage = "cleanup"
            write_json(
                diagnostics_directory / "failure.json",
                {
                    "errorType": type(error).__name__,
                    "stage": "cleanup",
                    "timestamp": utc_now(),
                },
            )
        cleanup_duration = time.monotonic() - cleanup_started
        write_json(
            summary_path,
            {
                "artifact": str(artifact),
                "cleanupDurationSeconds": round(cleanup_duration, 3),
                "cleanupSucceeded": cleanup_error is None,
                "completed": completed,
                "durationSeconds": duration_seconds,
                "evidenceMode": driver.evidence_mode,
                "failureStage": failure_stage,
                "finishedAt": utc_now(),
                "intervalSeconds": arguments.interval_seconds,
                "releaseGateEligible": driver.release_gate_eligible,
                "sampleCount": sample_count,
                "startedAt": started_at,
                "topology": {
                    "backgroundTabs": 4,
                    "idleTabs": 2,
                    "interactiveTabs": 2,
                    "tabs": 8,
                },
            },
        )

    if cleanup_error is not None:
        print(
            f"soak cleanup failed: {type(cleanup_error).__name__}",
            file=sys.stderr,
        )
        return 1
    if not completed:
        return 130 if STOP_REQUESTED.is_set() else 1
    print(f"soak artifact: {artifact}")
    print(f"soak summary: {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
