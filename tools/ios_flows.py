#!/usr/bin/env python3
"""Phase D2: run the iOS sample app on one simulator and check what the mock ingestion server receives.

Flows run here (they need simctl): fresh install and upgrade. Then the XCUITest suite
(ios/Example/UITests) runs the in-app flows: consent, identify and reset, opt-out, server errors,
offline queue with a kill and relaunch, cold and warm deep links, session rotation. Deep links go
through XCUIApplication.open, because simctl openurl stops at an "Open in …?" confirmation.

Heavy: boots one simulator and runs xcodebuild. Check memory first (see CLAUDE.md). The simulator
is shut down at the end unless --keep-booted is given, and the mock is stopped if this script
started it.

    python3 -I tools/ios_flows.py [--only-testing SfereExampleUITests/SampleAppFlowTests/testX] [--skip-ui-tests]
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXAMPLE = os.path.join(REPO, "ios", "Example")
PROJECT = os.path.join(EXAMPLE, "SfereExample.xcodeproj")
BUNDLE_ID = "io.sfere.example"
DEVICE_NAME = "Sfere Flows iPhone 16"
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-16"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
MOCK_PORT = int(os.environ.get("SFERE_MOCK_PORT", "4320"))
MOCK_URL = f"http://127.0.0.1:{MOCK_PORT}"
WORK_DIR = os.path.join(os.environ.get("TMPDIR", "/tmp"), "sfere-ios-flows")


def run(command, check=True, quiet=False):
    if not quiet:
        print("$", " ".join(command), flush=True)
    result = subprocess.run(command, text=True, capture_output=True)
    if check and result.returncode != 0:
        output = (result.stdout + result.stderr).splitlines()
        errors = [line for line in output if "error:" in line]
        sys.stderr.write("\n".join(errors[:30] or output[-40:]) + "\n")
        raise SystemExit(f"command failed ({result.returncode}): {' '.join(command)}")
    return result


def mock(path, body=None):
    request = urllib.request.Request(MOCK_URL + path, method="POST" if body is not None else "GET",
                                     data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.loads(response.read() or b"null")


def delivered_events():
    events = []
    for request in mock("/__events"):
        if "injectedStatus" not in request:
            events.extend((request.get("body") or {}).get("batch") or [])
    return events


def event_name(event):
    return event.get("event") or event.get("name") or event.get("type")


def wait_for(names, timeout=45):
    """Waits until every name in `names` was delivered; returns all delivered events. Events from app
    startup go out on the flush interval (30 s by default), not on flushAt, so the wait is longer."""
    deadline = time.time() + timeout
    while True:
        events = delivered_events()
        if set(names) <= {event_name(e) for e in events} or time.time() > deadline:
            return events
        time.sleep(1)


def find_or_create_device():
    devices = json.loads(run(["xcrun", "simctl", "list", "devices", "-j"], quiet=True).stdout)["devices"]
    for device in devices.get(RUNTIME, []):
        if device["name"] == DEVICE_NAME and device.get("isAvailable", True):
            return device["udid"]
    return run(["xcrun", "simctl", "create", DEVICE_NAME, DEVICE_TYPE, RUNTIME]).stdout.strip()


class Flows:
    def __init__(self, udid):
        self.udid = udid
        self.results = []

    def check(self, flow, condition, detail):
        self.results.append((flow, bool(condition), detail))
        print(("PASS" if condition else "FAIL"), flow, "-", detail, flush=True)

    def fresh_app(self, app_path):
        run(["xcrun", "simctl", "terminate", self.udid, BUNDLE_ID], check=False, quiet=True)
        run(["xcrun", "simctl", "uninstall", self.udid, BUNDLE_ID], check=False)
        mock("/__reset", {})
        run(["xcrun", "simctl", "install", self.udid, app_path])

    def fresh_install(self, app_path):
        self.fresh_app(app_path)
        run(["xcrun", "simctl", "launch", self.udid, BUNDLE_ID])
        events = wait_for(["app_installed", "app_opened"])
        names = [event_name(e) for e in events]
        installed = next((e for e in events if event_name(e) == "app_installed"), None)
        self.check("fresh install", installed and "app_opened" in names and names.index("app_installed") < names.index("app_opened"),
                   f"events in order: {names[:6]}")
        if installed:
            props = installed.get("properties", {})
            self.check("fresh install", props.get("version") == "0.1.0" and str(props.get("build")) == "1",
                       f"app_installed properties {props}")
            context = installed.get("context", {})
            self.check("fresh install", "id" not in context.get("device", {}), f"context.device has no id: {context.get('device')}")
            os.makedirs(WORK_DIR, exist_ok=True)
            with open(os.path.join(WORK_DIR, "ios-context.json"), "w") as handle:
                json.dump(context, handle, indent=2, sort_keys=True)
            print("  platform context saved to", os.path.join(WORK_DIR, "ios-context.json"))
        session_started = [e for e in events if event_name(e) == "session_started"]
        self.check("fresh install", session_started, f"session_started sent ({len(session_started)})")

    def upgrade(self, upgraded_app_path):
        run(["xcrun", "simctl", "terminate", self.udid, BUNDLE_ID], check=False, quiet=True)
        mock("/__reset", {})
        run(["xcrun", "simctl", "install", self.udid, upgraded_app_path])
        run(["xcrun", "simctl", "launch", self.udid, BUNDLE_ID])
        events = wait_for(["app_updated", "app_opened"])
        updated = next((e for e in events if event_name(e) == "app_updated"), None)
        props = (updated or {}).get("properties", {})
        self.check("upgrade", updated and props.get("previous_version") == "0.1.0" and props.get("version") == "0.1.1",
                   f"app_updated properties {props}")
        self.check("upgrade", "app_installed" not in [event_name(e) for e in events], "no app_installed on upgrade")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only-testing", action="append", default=[], help="passed to xcodebuild")
    parser.add_argument("--skip-ui-tests", action="store_true")
    parser.add_argument("--keep-booted", action="store_true")
    args = parser.parse_args()

    mock_ctl = os.path.join(REPO, "tools", "mock_ingest_ctl.sh")
    environment = dict(os.environ, SFERE_MOCK_PORT=str(MOCK_PORT))
    started_mock = subprocess.run([mock_ctl, "status"], env=environment, capture_output=True).returncode != 0
    if started_mock:
        subprocess.run([mock_ctl, "start"], env=environment, check=True)

    udid = find_or_create_device()
    flows = Flows(udid)
    ui_tests_passed = None
    try:
        run(["xcodegen", "generate", "--spec", os.path.join(EXAMPLE, "project.yml"), "--quiet"])
        destination = f"id={udid}"
        v1 = os.path.join(WORK_DIR, "DerivedData-v1")
        v2 = os.path.join(WORK_DIR, "DerivedData-v2")
        run(["xcodebuild", "build-for-testing", "-quiet", "-project", PROJECT, "-scheme", "SfereExample",
             "-destination", destination, "-derivedDataPath", v1])
        run(["xcodebuild", "build", "-quiet", "-project", PROJECT, "-scheme", "SfereExample", "-destination", destination,
             "-derivedDataPath", v2, "MARKETING_VERSION=0.1.1", "CURRENT_PROJECT_VERSION=2"])
        app_v1 = os.path.join(v1, "Build", "Products", "Debug-iphonesimulator", "SfereExample.app")
        app_v2 = os.path.join(v2, "Build", "Products", "Debug-iphonesimulator", "SfereExample.app")

        run(["xcrun", "simctl", "boot", udid], check=False)
        run(["xcrun", "simctl", "bootstatus", udid, "-b"], quiet=True)

        flows.fresh_install(app_v1)
        flows.upgrade(app_v2)

        if not args.skip_ui_tests:
            products = os.path.join(v1, "Build", "Products")
            xctestrun = next(os.path.join(products, f) for f in os.listdir(products) if f.endswith(".xctestrun"))
            result_bundle = os.path.join(WORK_DIR, f"ui-tests-{int(time.time())}.xcresult")
            command = ["xcodebuild", "test-without-building", "-xctestrun", xctestrun, "-destination", destination,
                       "-resultBundlePath", result_bundle]
            for test in args.only_testing:
                command += ["-only-testing", test]
            print("$", " ".join(command), flush=True)
            result = subprocess.run(command, text=True, capture_output=True)
            lines = [l for l in result.stdout.splitlines() if "Test Case" in l or "error:" in l or "Executed" in l]
            print("\n".join(lines[-60:]))
            ui_tests_passed = result.returncode == 0
            print("UI tests", "PASS" if ui_tests_passed else "FAIL", "- result bundle", result_bundle)
    finally:
        if not args.keep_booted:
            run(["xcrun", "simctl", "shutdown", udid], check=False)
        if started_mock:
            subprocess.run([mock_ctl, "stop"], env=environment)

    failed = [r for r in flows.results if not r[1]]
    ui_summary = {None: "skipped", True: "passed", False: "FAILED"}[ui_tests_passed]
    print(f"\nsimctl flows: {len(flows.results) - len(failed)}/{len(flows.results)} checks passed; UI tests {ui_summary}")
    return 0 if not failed and ui_tests_passed is not False else 1


if __name__ == "__main__":
    sys.exit(main())
