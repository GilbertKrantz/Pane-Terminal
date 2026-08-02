#!/usr/bin/env python3
"""App-backed adapter for the P2 soak runner's argv-only driver protocol.

The driver launches the existing Pane workspace/PTY soak XCTest, streams its
samples back to ``run-soak.py``, and keeps all state in the runner-supplied
diagnostics directory. It is automated Pane evidence; visual review remains a
separate manual release gate.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import signal
import subprocess
import sys
import time
from typing import Any

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


def load_state(path: pathlib.Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise SystemExit(f"soak driver state is missing: {path}") from error


def write_state(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def process_is_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def command_start(arguments: argparse.Namespace) -> int:
    if arguments.tabs != 8 or arguments.background_tabs != 4 \
            or arguments.interactive_tabs != 2 or arguments.idle_tabs != 2:
        raise SystemExit("Pane soak driver requires the documented 8-tab topology")
    if arguments.duration_seconds <= 0 or arguments.interval_seconds <= 0:
        raise SystemExit("duration and interval must be positive")
    if arguments.state.exists():
        raise SystemExit(f"refusing to overwrite soak driver state: {arguments.state}")

    repository = pathlib.Path(__file__).resolve().parents[2]
    arguments.diagnostics_dir.mkdir(parents=True, exist_ok=True)
    log_path = arguments.diagnostics_dir / "pane-soak-driver.log"
    source_artifact = arguments.diagnostics_dir / "pane-backed-samples.jsonl"
    # The outer orchestrator begins its release-duration clock only after this
    # driver has observed the first Pane sample. Keep the inner run alive long
    # enough for its normal bounded cleanup to finish when the outer clock
    # expires.
    source_duration_seconds = arguments.duration_seconds + 2.0
    environment = os.environ.copy()
    environment.update({
        "PANE_RUN_PANE_SOAK": "1",
        "PANE_SOAK_DURATION_SECONDS": str(source_duration_seconds),
        "PANE_SOAK_INTERVAL_SECONDS": str(arguments.interval_seconds),
        "PANE_SOAK_ARTIFACT": str(source_artifact),
        "PANE_SOAK_DIAGNOSTICS_DIR": str(arguments.diagnostics_dir),
    })
    command = [
        "/usr/bin/env",
        "swift",
        "test",
        "--scratch-path",
        "/tmp/PaneSoakDriverBuild",
        "--filter",
        "PaneSoakRunnerTests/testPaneBackedSoakWhenExplicitlyEnabled",
    ]
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            command,
            cwd=repository,
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    state = {
        "actions": [],
        "artifact": str(arguments.artifact),
        "durationSeconds": arguments.duration_seconds,
        "sourceDurationSeconds": source_duration_seconds,
        "intervalSeconds": arguments.interval_seconds,
        "log": str(log_path),
        "pid": process.pid,
        "sourceArtifact": str(source_artifact),
    }
    write_state(arguments.state, state)

    deadline = time.monotonic() + 120.0
    while time.monotonic() < deadline:
        sample = last_sample(source_artifact)
        if sample is not None and not REQUIRED_SAMPLE_KEYS.difference(sample):
            return 0
        if not process_is_running(process.pid):
            raise SystemExit(f"Pane soak XCTest exited before readiness; see {log_path}")
        time.sleep(0.1)
    raise SystemExit(f"Pane soak XCTest did not write its first sample; see {log_path}")


def command_action(arguments: argparse.Namespace) -> int:
    state = load_state(arguments.state)
    if not process_is_running(int(state["pid"])):
        raise SystemExit(f"Pane soak XCTest is no longer running; see {state['log']}")
    state["actions"].append({"iteration": arguments.iteration, "name": arguments.name})
    write_state(arguments.state, state)
    return 0


def last_sample(path: pathlib.Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines:
        return None
    return json.loads(lines[-1])


def command_sample(arguments: argparse.Namespace) -> int:
    state = load_state(arguments.state)
    artifact = pathlib.Path(state["sourceArtifact"])
    deadline = time.monotonic() + 20.0
    while time.monotonic() < deadline:
        sample = last_sample(artifact)
        if sample is not None:
            missing = REQUIRED_SAMPLE_KEYS.difference(sample)
            if missing:
                raise SystemExit("Pane soak sample missing keys: " + ", ".join(sorted(missing)))
            print(json.dumps(sample, sort_keys=True))
            return 0
        if not process_is_running(int(state["pid"])):
            raise SystemExit(f"Pane soak XCTest exited before sampling; see {state['log']}")
        time.sleep(0.1)
    raise SystemExit(f"Pane soak XCTest did not write a sample; see {state['log']}")


def command_stop(arguments: argparse.Namespace) -> int:
    state = load_state(arguments.state)
    pid = int(state["pid"])
    deadline = time.monotonic() + arguments.timeout_seconds
    while process_is_running(pid) and time.monotonic() < deadline:
        time.sleep(0.05)
    if process_is_running(pid):
        os.killpg(pid, signal.SIGINT)
        grace_deadline = time.monotonic() + 2.0
        while process_is_running(pid) and time.monotonic() < grace_deadline:
            time.sleep(0.05)
    if process_is_running(pid):
        os.killpg(pid, signal.SIGTERM)
        raise SystemExit(f"Pane soak XCTest exceeded cleanup timeout; see {state['log']}")
    return 0


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subcommands = parser.add_subparsers(dest="command", required=True)

    def shared(subparser: argparse.ArgumentParser, *, include_artifact: bool) -> None:
        subparser.add_argument("--state", type=pathlib.Path, required=True)
        subparser.add_argument("--diagnostics-dir", type=pathlib.Path, required=True)
        if include_artifact:
            subparser.add_argument("--artifact", type=pathlib.Path, required=True)

    start = subcommands.add_parser("start")
    shared(start, include_artifact=True)
    start.add_argument("--tabs", type=int, required=True)
    start.add_argument("--background-tabs", type=int, required=True)
    start.add_argument("--interactive-tabs", type=int, required=True)
    start.add_argument("--idle-tabs", type=int, required=True)
    start.add_argument("--duration-seconds", type=float, required=True)
    start.add_argument("--interval-seconds", type=float, required=True)

    action = subcommands.add_parser("action")
    shared(action, include_artifact=True)
    action.add_argument("--name", required=True)
    action.add_argument("--iteration", type=int, required=True)

    sample = subcommands.add_parser("sample")
    shared(sample, include_artifact=True)
    sample.add_argument("--iteration", type=int, required=True)

    stop = subcommands.add_parser("stop")
    shared(stop, include_artifact=True)
    stop.add_argument("--timeout-seconds", type=float, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.command == "start":
        return command_start(arguments)
    if arguments.command == "action":
        return command_action(arguments)
    if arguments.command == "sample":
        return command_sample(arguments)
    return command_stop(arguments)


if __name__ == "__main__":
    raise SystemExit(main())
