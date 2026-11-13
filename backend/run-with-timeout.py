#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Bound a test command and its descendants, even when async cancellation cannot unwind a deadlock."""
import os
import signal
import subprocess
import sys


def main():
    seconds = int(os.environ.get("FORM_TEST_TIMEOUT_SECONDS", "900"))
    if seconds < 1 or len(sys.argv) < 2:
        raise SystemExit("FORM_TEST_TIMEOUT_SECONDS muss positiv sein; Testbefehl fehlt.")
    process = subprocess.Popen(sys.argv[1:], start_new_session=True)
    try:
        return process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        print(f"FEHLER: Testlauf nach {seconds}s abgebrochen (FORM_TEST_TIMEOUT_SECONDS).",
              file=sys.stderr, flush=True)
        # Kill the process group: terminating only swift leaves the XCTest runner alive.
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        return 124
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        raise


if __name__ == "__main__":
    sys.exit(main())
