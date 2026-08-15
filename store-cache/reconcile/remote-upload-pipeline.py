#!/usr/bin/env python3
"""Runs on a builder, fed over ssh stdin.

Streams `nix-store --dump-db` and queues every path the coordinator still
wants, so uploads start immediately instead of after a full store scan.
Prints `FOUND\tpath` when a wanted path is seen and `UPLOADED\tpath` once
Attic has it; the coordinator diffs the two to find what went missing.

Usage: remote-upload-pipeline.py JOBS CACHE WANTED_PATHS_FILE TAG
"""

from __future__ import annotations

import os
import queue
import subprocess
import sys
import threading

BATCH_SIZE = 24
HEARTBEAT_SECONDS = 20
# nix-store --dump-db emits, per path: path, hash, size, deriver, reference count, then that many references.
FIELDS_BEFORE_REFERENCE_COUNT = 3


def main() -> int:
    jobs = int(sys.argv[1])
    cache = sys.argv[2]
    wanted_file = sys.argv[3]
    tag = sys.argv[4] if len(sys.argv) > 4 else "builder"

    with open(wanted_file, encoding="utf-8") as file:
        wanted = {line.rstrip("\n") for line in file if line.strip()}

    with open("/etc/attic/attic-bin", encoding="utf-8") as file:
        attic_bin = file.read().strip()
    environment = {**os.environ, "XDG_CONFIG_HOME": "/etc"}

    pending: queue.Queue[str | None] = queue.Queue()
    output_lock = threading.Lock()
    counts = {"found": 0, "uploaded": 0}

    def push(batch: list[str]) -> None:
        # One process per batch: attic does a single bulk missing-paths query and streams the NARs, so per-path session overhead is amortised.
        result = subprocess.run(
            [attic_bin, "push", "--no-closure", "--jobs", "4", cache, *batch],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            with output_lock:
                for path in batch:
                    print(f"UPLOADED\t{path}", flush=True)
                    counts["uploaded"] += 1
            return
        if len(batch) > 1:
            for path in batch:
                push([path])
            return
        print(f"warning: failed to upload {batch[0]}", file=sys.stderr)
        print(result.stdout, file=sys.stderr, end="")
        print(result.stderr, file=sys.stderr, end="")

    def upload_worker() -> None:
        while True:
            first = pending.get()
            if first is None:
                pending.task_done()
                return
            batch = [first]
            while len(batch) < BATCH_SIZE:
                try:
                    item = pending.get_nowait()
                except queue.Empty:
                    break
                if item is None:
                    # Put the sentinel back for the other workers and upload what we have.
                    pending.task_done()
                    pending.put(None)
                    break
                batch.append(item)
            try:
                push(batch)
            finally:
                for _ in batch:
                    pending.task_done()

    workers = [threading.Thread(target=upload_worker) for _ in range(jobs)]
    for worker in workers:
        worker.start()

    # Uploads are silent, so without this a stalled pipeline looks identical to a slow one.
    stop_heartbeat = threading.Event()

    def heartbeat() -> None:
        while not stop_heartbeat.wait(HEARTBEAT_SECONDS):
            print(
                f"[{tag}] found {counts['found']}, uploaded {counts['uploaded']}, queued {pending.qsize()}",
                file=sys.stderr,
                flush=True,
            )

    threading.Thread(target=heartbeat, daemon=True).start()

    dump = subprocess.Popen(
        ["nix-store", "--dump-db"],
        stdout=subprocess.PIPE,
        stderr=sys.stderr,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    assert dump.stdout is not None

    ok = True
    try:
        while True:
            path = dump.stdout.readline()
            if path == "":
                break
            path = path.rstrip("\n")
            if path in wanted:
                counts["found"] += 1
                with output_lock:
                    print(f"FOUND\t{path}", flush=True)
                pending.put(path)
            for field in range(FIELDS_BEFORE_REFERENCE_COUNT + 1):
                line = dump.stdout.readline()
                if line == "":
                    raise EOFError(
                        f"truncated dump-db record for {path} at field {field}"
                    )
                if field == FIELDS_BEFORE_REFERENCE_COUNT:
                    references = int(line.strip())
            for _ in range(references):
                if dump.stdout.readline() == "":
                    raise EOFError(f"truncated references for {path}")
        ok = dump.wait() == 0
    except Exception as error:  # noqa: BLE001 - any parse failure invalidates the probe
        ok = False
        print(f"error: could not parse nix-store --dump-db: {error}", file=sys.stderr)
        dump.terminate()
        dump.wait()
    finally:
        for _ in workers:
            pending.put(None)
        pending.join()
        for worker in workers:
            worker.join()
        stop_heartbeat.set()
        try:
            os.unlink(wanted_file)
        except FileNotFoundError:
            pass

    print(
        f"[{tag}] probe found {counts['found']} wanted paths; {counts['uploaded']} uploads succeeded.",
        file=sys.stderr,
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
