"""Run BOTH live data generators together for a ClickPipes demo.

Starts, as child processes:
  - simulate_cdc.py     -> continuous Postgres CDC traffic into Aurora
  - kinesis_producer.py -> continuous clickstream events into Kinesis

Both stream until you press Ctrl-C, then both are shut down cleanly. If either
one exits on its own (e.g. a connection error), the other is stopped too — so
the demo fails loudly instead of half-running. Each child's output is inherited,
so you see both streams live in this terminal.

    uv run run_generators.py
    uv run run_generators.py --cdc-sleep 0.5 --kinesis-rate 25
"""
from __future__ import annotations

import argparse
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def stop(procs: list[tuple[str, subprocess.Popen]]) -> None:
    """Stop any still-running child: SIGINT (graceful) -> terminate -> kill."""
    for _, p in procs:
        if p.poll() is None:
            p.send_signal(signal.SIGINT)
    for name, p in procs:
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            print(f"  '{name}' didn't stop in time — terminating.")
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Run simulate_cdc.py and kinesis_producer.py together until Ctrl-C."
    )
    ap.add_argument("--cdc-sleep", type=float, default=1.0, help="seconds between CDC mutations")
    ap.add_argument("--kinesis-rate", type=int, default=10, help="Kinesis events per second")
    args = ap.parse_args()

    # sys.executable is the venv interpreter (this runs under `uv run`), so the
    # children have all dependencies without spawning another `uv run`.
    specs = [
        ("cdc", [sys.executable, "simulate_cdc.py", "--sleep", str(args.cdc_sleep)]),
        ("kinesis", [sys.executable, "kinesis_producer.py", "--rate", str(args.kinesis_rate)]),
    ]

    print("Starting live generators (Ctrl-C to stop both)...")
    procs: list[tuple[str, subprocess.Popen]] = []
    for name, cmd in specs:
        print(f"  -> {name}: {' '.join(cmd[1:])}")
        procs.append((name, subprocess.Popen(cmd, cwd=HERE)))

    exit_code = 0
    try:
        while True:
            for name, p in procs:
                rc = p.poll()
                if rc is not None:
                    print(f"\n'{name}' exited early (code {rc}); stopping the other generator.")
                    exit_code = rc or 1
                    raise SystemExit  # fall through to stop() in finally
            time.sleep(0.5)
    except KeyboardInterrupt:
        print("\nCtrl-C received — stopping generators...")
    except SystemExit:
        pass
    finally:
        stop(procs)

    print("Both generators stopped.")
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
