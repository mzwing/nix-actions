#!/usr/bin/env python3
"""Plan the distributed build matrix.

Probes the binary caches for every candidate target, keeps the ones nobody can
fetch yet, and starts every configured builder in each active system's pool.
Invoked through plan-builds.sh, which supplies PROBE_CACHES.

Writes `targets`, `extra_systems`, `builders` and `has_builds` to GITHUB_OUTPUT.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from functools import partial
from pathlib import Path
from typing import Any

HTTP_TIMEOUT_SECONDS = 15
ID_PREFIX_PATTERN = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
# Cachix sits behind Cloudflare, which 403s urllib's default User-Agent.
USER_AGENT = "nix-ci-plan-builds"


def store_hash(store_path: str) -> str:
    """The hash part of /nix/store/<hash>-<name>."""
    return os.path.basename(store_path).split("-", maxsplit=1)[0]


def narinfo_status(store_path: str, cache: str) -> bool | None:
    """True: present; False: definitively absent; None: probe failed."""
    request = urllib.request.Request(
        f"{cache}/{store_hash(store_path)}.narinfo",
        method="HEAD",
        headers={"User-Agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS):
            return True
    except urllib.error.HTTPError as exc:
        return False if exc.code in (404, 410) else None
    except (urllib.error.URLError, TimeoutError):
        return None


def is_cached(store_path: str, caches: list[str]) -> bool:
    # Only a definitive 404 from every cache means missing. Cachix intermittently
    # 403/429s HEAD bursts from runner IPs; treating that as "missing" schedules
    # thousands of already-cached derivations for a full rebuild. Retry, and if a
    # probe stays inconclusive assume cached: a wrong "cached" merely defers the
    # push to the next run (self-healing), while a wrong "missing" wastes hours.
    for attempt in range(3):
        if attempt:
            time.sleep(2 * attempt)
        unknown = False
        for cache in caches:
            status = narinfo_status(store_path, cache)
            if status is True:
                return True
            if status is None:
                unknown = True
                break
        if not unknown:
            return False
    print(f"probe inconclusive, assuming cached: {store_path}", file=sys.stderr)
    return True


def load_builder_pools(path: Path) -> list[dict[str, Any]]:
    pools = json.loads(path.read_text(encoding="utf-8"))

    def fail(reason: str) -> None:
        sys.exit(f"Invalid {path} configuration: {reason}")

    if not isinstance(pools, list) or not pools:
        fail("expected a non-empty array")

    for pool in pools:
        for key in ("system", "runner"):
            if not isinstance(pool.get(key), str) or not pool[key]:
                fail(f"pool entries need a non-empty string '{key}': {pool!r}")
        id_prefix = pool.get("idPrefix")
        if not isinstance(id_prefix, str) or not ID_PREFIX_PATTERN.match(id_prefix):
            fail(f"'idPrefix' must match {ID_PREFIX_PATTERN.pattern}: {id_prefix!r}")
        for key in ("count", "maxJobs"):
            value = pool.get(key)
            if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
                fail(f"'{key}' must be a positive integer, got {value!r}")

    id_prefixes = [pool["idPrefix"] for pool in pools]
    if len(id_prefixes) != len(set(id_prefixes)):
        fail(f"duplicate 'idPrefix' values: {id_prefixes}")

    return pools


def main() -> None:
    all_targets: list[dict[str, Any]] = json.loads(os.environ["ALL_TARGETS"])
    extra_outputs: dict[str, list[str]] = json.loads(os.environ["EXTRA_OUTPUTS"])
    extra_name = os.environ["EXTRA_NAME"]
    primary_output = os.environ["PRIMARY_OUTPUT"]
    pools = load_builder_pools(Path(os.environ["BUILDERS_FILE"]))
    caches = os.environ["PROBE_CACHES"].split()

    # Target sets that distinguish outputs are planned on the primary one only.
    candidates = [
        target
        for target in all_targets
        if target.get("outputName", primary_output) == primary_output
    ]

    probe = partial(is_cached, caches=caches)
    extra_entries = [
        (system, path) for system, paths in extra_outputs.items() for path in paths
    ]
    with ThreadPoolExecutor() as executor:
        hits = executor.map(probe, (t["outputPath"] for t in candidates))
        targets = [t for t, hit in zip(candidates, hits, strict=True) if not hit]

        extra_hits = executor.map(probe, (path for _, path in extra_entries))
        extra_systems = sorted(
            {
                system
                for (system, _), hit in zip(extra_entries, extra_hits, strict=True)
                if not hit
            }
        )

    active_systems = sorted({t["system"] for t in targets} | set(extra_systems))
    missing = [s for s in active_systems if s not in {p["system"] for p in pools}]
    if missing:
        sys.exit(f"No builder pool configured for: {', '.join(missing)}")

    builders = {"include": []}
    for pool in pools:
        if pool["system"] not in active_systems:
            continue
        builders["include"] += [
            {
                "id": f"{pool['idPrefix']}-{index}",
                "runner": pool["runner"],
                "system": pool["system"],
                "maxJobs": pool["maxJobs"],
            }
            for index in range(1, pool["count"] + 1)
        ]

    if extra_entries:
        print(
            f"{extra_name}: rebuilding on {extra_systems or 'nothing'}", file=sys.stderr
        )

    outputs = {
        "builders": json.dumps(builders, separators=(",", ":")),
        "extra_systems": json.dumps(extra_systems, separators=(",", ":")),
        "has_builds": "true" if targets or extra_systems else "false",
        "targets": json.dumps(targets, separators=(",", ":")),
    }
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output_file:
        output_file.writelines(f"{key}={value}\n" for key, value in outputs.items())


if __name__ == "__main__":
    main()
