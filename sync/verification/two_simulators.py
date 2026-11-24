"""Run the two-device encrypted sync test against an isolated local Worker."""

import argparse
import os
import plistlib
import re
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def launch_device(plan, device_id, role, rendezvous, logs):
    with plan.open("rb") as source:
        config = plistlib.load(source)
    targets = (
        [t for c in config["TestConfigurations"] for t in c["TestTargets"]]
        if "TestConfigurations" in config
        else [t for t in config.values() if isinstance(t, dict) and "TestBundlePath" in t]
    )
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(
            PIRU_SYNC_RENDEZVOUS=rendezvous, PIRU_SYNC_ROLE=role
        )
    # Keep __TESTROOT__ relative to the original build products.
    with tempfile.NamedTemporaryFile(dir=plan.parent, suffix=".xctestrun", delete=False) as f:
        plistlib.dump(config, f)
        testplan = Path(f.name)
    try:
        proc = subprocess.Popen(
            [
                "xcodebuild",
                "test-without-building",
                "-xctestrun",
                str(testplan),
                "-destination",
                f"id={device_id}",
                "-parallel-testing-enabled",
                "NO",
                "-only-testing:PiruTests/ProfileSyncSimulatorTests",
                "-resultBundlePath",
                str(logs / f"{role}.xcresult"),
            ],
            stdout=(logs / f"{role}.log").open("w"),
            stderr=subprocess.STDOUT,
        )
    except BaseException:
        testplan.unlink()
        raise
    return proc, testplan


def run(plan, devices, logs):
    logs.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temp:
        ready = Path(temp) / "control"
        relay = subprocess.Popen(
            ["node", "test/simulator-relay.mjs", str(ready)],
            cwd=ROOT / "sync/worker",
            stdout=(logs / "relay.log").open("w"),
            stderr=subprocess.STDOUT,
        )
        clients = []
        try:
            started = time.monotonic()
            while not ready.exists():
                if relay.poll() is not None or time.monotonic() - started > 60:
                    raise RuntimeError(f"Relay startup failed. See {logs / 'relay.log'}")
                time.sleep(0.2)
            for index, device in enumerate(devices):
                role = ("A", "B")[index]
                clients.append(launch_device(plan, device, role, ready.read_text(), logs))
            while any(p.poll() is None for p, _ in clients) or relay.poll() is None:
                if any(p.poll() not in (None, 0) for p in [relay, *(p for p, _ in clients)]):
                    raise RuntimeError(f"A participant failed. See {logs}")
                if time.monotonic() - started > 480:
                    raise TimeoutError(f"Verification timed out. See {logs}")
                time.sleep(0.5)
            if relay.returncode or any(p.returncode for p, _ in clients):
                raise RuntimeError(f"Verification failed. See {logs}")
            for role in ("A", "B"):
                if not re.search(
                    r"Test run with 1 test (?:in [0-9]+ suites? )?passed",
                    (logs / f"{role}.log").read_text(),
                ):
                    raise RuntimeError(f"Missing Swift Testing result for {role}")
            if "SDK observed both simulator edits" not in (logs / "relay.log").read_text():
                raise RuntimeError("Missing SDK verification")
            print(f"Both simulator hosts and the SDK passed. Results in {logs}")
        finally:
            for p in [relay, *(p for p, _ in clients)]:
                if p.poll() is None:
                    p.terminate()
            for _, plan_copy in clients:
                plan_copy.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("simulators", nargs=2)
    parser.add_argument("--logs", type=Path, required=True)
    args = parser.parse_args()
    if len(set(args.simulators)) != 2:
        parser.error("Select two different simulators")
    os.umask(0o077)
    run(args.plan.resolve(), args.simulators, args.logs.resolve())
