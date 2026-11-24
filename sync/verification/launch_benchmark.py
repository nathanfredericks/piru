#!/usr/bin/env python3
"""Measure fresh-process launch latency with 3,000 local doses on a disposable simulator."""

import argparse
import json
import math
import os
import plistlib
import selectors
import sqlite3
import statistics
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET
from datetime import date, datetime, timedelta
from datetime import time as day_time
from pathlib import Path


def run(*args, timeout=120):
    return subprocess.check_output(args, text=True, timeout=timeout).strip()


def sim(*args, **options):
    return run("xcrun", "simctl", *args, **options)


def fixture(last_day):
    start = datetime.combine(last_day, day_time(12)) - timedelta(hours=2999 * 4)
    return {
        "doseEntries": [
            {
                "substance": "Caffeine",
                "amount": 40,
                "unit": "mg",
                "route": "oral",
                "timestamp": (start + timedelta(hours=i * 4)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
            for i in range(3000)
        ],
        "dailyDoseItems": [],
        "substanceColors": [],
    }


def dose_count(store):
    with sqlite3.connect(store.as_uri() + "?mode=ro", uri=True) as db:
        return db.execute("SELECT count(*) FROM ZDOSEENTRY").fetchone()[0]


def wait_for_import(store):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if store.is_file():
            try:
                if dose_count(store) == 3000:
                    return
            except sqlite3.OperationalError:
                pass
        time.sleep(0.25)
    raise RuntimeError(
        "The fixture never reached 3,000 committed doses. Use a Debug simulator build."
    )


def launch_ms(xml, executable):
    root = ET.fromstring(xml)
    refs = {el.get("id"): el for el in root.iter() if el.get("id")}

    def cell(row, kind):
        el = row.find(kind)
        if el is None:
            raise ValueError(f"Missing Instruments column: {kind}")
        return refs[el.get("ref")] if el.get("ref") else el

    starts, ends, foreground = [], [], []
    for row in root.findall(".//row"):
        process = cell(row, "process").get("fmt", "")
        if process.split(" (")[0] != executable:
            continue
        phase = cell(row, "app-period")
        label = phase.get("fmt") or phase.text or ""
        start = int(cell(row, "start-time").text)
        if label == "Initializing - System Interface Initialization":
            starts.append(start)
        elif label == "Launching - Initial Frame Rendering":
            ends.append(start + int(cell(row, "duration").text))
        elif label.startswith("Foreground"):
            foreground.append(start)
    if (
        len(starts) != 1
        or len(ends) != 1
        or not foreground
        or not starts[0] < ends[0] <= max(foreground) + 1
    ):
        raise ValueError(
            "Trace lacks a complete dyld-to-first-frame interval. Inspect the saved trace."
        )
    return (ends[0] - starts[0]) / 1_000_000


def measure(device, bundle_id, binary, output, runs, launch_args):
    installed = sim("get_app_container", device, bundle_id, "app")
    samples = []
    for i in range(runs + 1):
        trace = output / ("warmup.trace" if i == 0 else f"launch-{i:02}.trace")
        # Instruments may leave the target running after recording.
        subprocess.run(
            ["xcrun", "simctl", "terminate", device, bundle_id], capture_output=True, timeout=30
        )
        run(
            "xcrun",
            "xctrace",
            "record",
            "--template",
            "App Launch",
            "--device",
            device,
            "--time-limit",
            "12s",
            "--output",
            str(trace),
            "--launch",
            "--",
            installed,
            *launch_args,
            timeout=180,
        )
        table = run(
            "xcrun",
            "xctrace",
            "export",
            "--input",
            str(trace),
            "--xpath",
            '/trace-toc/run[@number="1"]/data/table[@schema="life-cycle-period"]',
        )
        value = launch_ms(table, binary)
        if i:
            samples.append(value)
        print(f"{trace.name}: {value:.2f} ms", flush=True)
    return samples


def archive_active():
    processes = run("ps", "-Aww", "-o", "args=")
    for line in processes.splitlines():
        argv = line.split()
        if argv and Path(argv[0]).name == "xcodebuild" and "archive" in argv[1:]:
            return True
    return False


def measure_ready(device, bundle, output, runs, launch_args):
    # The root view's finishLaunching task calls the Debug fixture dispatcher
    # after the catalog, store and reminder passes. This measures that marker; an
    # unrecognized persona returns immediately without touching the seeded store.
    samples = []
    for i in range(runs + 1):
        name = f"launch-{i:02}" if i else "warmup"
        marker = f"benchmark-{uuid.uuid4().hex}"
        expected = f"DemoData: unknown persona '{marker}'".encode()
        subprocess.run(
            ["xcrun", "simctl", "terminate", device, bundle], capture_output=True, timeout=30
        )
        time.sleep(1)
        overlap = archive_active()
        load = os.getloadavg()
        start = time.monotonic_ns()
        command = [
            "xcrun",
            "simctl",
            "launch",
            "--console-pty",
            device,
            bundle,
            *launch_args,
            "-piruPersona",
            marker,
        ]
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as proc:
            try:
                captured = bytearray()
                with (
                    selectors.DefaultSelector() as selector,
                    (output / f"{name}.log").open("wb") as log,
                ):
                    selector.register(proc.stdout, selectors.EVENT_READ)
                    while expected not in captured:
                        remaining = 90 - (time.monotonic_ns() - start) / 1e9
                        if remaining <= 0 or not selector.select(remaining):
                            raise TimeoutError(f"Missing startup marker in {name}.log")
                        chunk = os.read(proc.stdout.fileno(), 8192)
                        if not chunk:
                            raise RuntimeError(f"Process stopped before the marker; see {name}.log")
                        log.write(chunk)
                        captured.extend(chunk)
                elapsed = (time.monotonic_ns() - start) / 1e6
                sim("io", device, "screenshot", str(output / f"{name}.png"))
                sample = {
                    "name": name,
                    "startupMarker_ms": elapsed,
                    "screenshotSaved_ms": (time.monotonic_ns() - start) / 1e6,
                    "hostLoadAverage": load,
                    "archiveObserved": overlap or archive_active(),
                }
                (output / f"{name}.json").write_text(json.dumps(sample, indent=2) + "\n")
                print(f"{name}: {elapsed:.2f} ms to startup marker; screenshot saved", flush=True)
                if i:
                    samples.append(elapsed)
            finally:
                subprocess.run(
                    ["xcrun", "simctl", "terminate", device, bundle],
                    capture_output=True,
                    timeout=30,
                )
                if proc.poll() is None:
                    proc.terminate()
    return samples


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--app", type=Path, required=True, help="Existing Debug iphonesimulator Piru.app"
    )
    parser.add_argument(
        "--like", required=True, help="Simulator UUID to match for device type and iOS runtime"
    )
    parser.add_argument(
        "--out", type=Path, required=True, help="New output directory for traces and result.json"
    )
    parser.add_argument(
        "--metric",
        choices=("ready", "instruments"),
        default="ready",
        help="Root startup task Debug marker with screenshot, or Instruments first-frame trace",
    )
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument(
        "--as-of",
        type=date.fromisoformat,
        default=date.today() - timedelta(days=1),
        help="Date of the last synthetic dose (YYYY-MM-DD; defaults to yesterday)",
    )
    args = parser.parse_args()
    if args.runs < 2:
        parser.error("--runs must be at least 2")
    app = args.app.resolve()
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info["CFBundleSupportedPlatforms"] != ["iPhoneSimulator"]:
        parser.error("--app must be a simulator build")
    reference = str(uuid.UUID(args.like)).upper()
    devices = json.loads(sim("list", "devices", "available", "-j"))["devices"]
    runtime, model = next(
        (rt, d["deviceTypeIdentifier"])
        for rt, group in devices.items()
        for d in group
        if d["udid"].upper() == reference
    )
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=False)
    bundle = info["CFBundleIdentifier"]
    device = sim("create", f"Piru Launch Benchmark {uuid.uuid4().hex[:8]}", model, runtime)
    try:
        print(f"Disposable simulator {device}; evidence in {output}", flush=True)
        (output / "device.txt").write_text(device + "\n")
        sim("boot", device)
        sim("bootstatus", device, "-b", timeout=240)
        sim("install", device, str(app))
        documents = Path(sim("get_app_container", device, bundle, "data")) / "Documents"
        documents.mkdir(exist_ok=True)
        seed = documents / "launch-fixture.json"
        seed.write_text(json.dumps(fixture(args.as_of)))
        launch_args = [
            "-hasCompletedOnboarding",
            "YES",
            "-install.firstBuild",
            "999999",
            "-AppNavigator.selectedTab",
            "journal",
            "-piruNoDemoData",
            "-discordPromptDismissedForever",
            "YES",
            "-AppleLanguages",
            "(en)",
        ]
        sim("launch", device, bundle, *launch_args, "-piruImportFile", seed.name)
        store = (
            Path(sim("get_app_container", device, bundle, info["PiruAppGroup"])) / "default.store"
        )
        wait_for_import(store)
        print("Verified 3,000 committed doses; starting warm-up", flush=True)
        if args.metric == "ready":
            samples = measure_ready(device, bundle, output, args.runs, launch_args)
            metric = "host simctl launch request to the Debug marker after the root startup task’s catalog, store and reminder passes (ms)"
        else:
            samples = measure(
                device, bundle, info["CFBundleExecutable"], output, args.runs, launch_args
            )
            metric = "dyld initialization to end of initial frame rendering (ms)"
        if dose_count(store) != 3000:
            raise RuntimeError("The dose count changed during measurement.")
        result = {
            "metric": metric,
            "deviceType": model,
            "runtime": runtime,
            "bundle": bundle,
            "build": info["CFBundleVersion"],
            "doseCount": 3000,
            "lastDoseDay": args.as_of.isoformat(),
            "sync": "unlinked",
            "samples_ms": samples,
            "median_ms": statistics.median(samples),
            "p95_ms": sorted(samples)[math.ceil(len(samples) * 0.95) - 1],
        }
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
    finally:
        try:
            sim("shutdown", device)
        finally:
            sim("delete", device)


if __name__ == "__main__":
    main()
