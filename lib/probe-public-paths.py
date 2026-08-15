#!/usr/bin/env python3
"""Filter store paths down to those already available from a public cache.

Reads one store path per line on stdin, writes the publicly available ones to
stdout. Substituter URLs are given as arguments.

Unreachable substituters are dropped up front rather than counted as misses,
and any per-path error is treated as "not public": over-reporting a path as
public would delete it from the only cache that has it, while under-reporting
merely wastes some private storage until the next run.
"""

from __future__ import annotations

import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

TIMEOUT_SECONDS = 10
HEADERS = {"User-Agent": "nix-ci-probe-public-paths"}


def head(url: str) -> bool:
    request = urllib.request.Request(url, method="HEAD", headers=HEADERS)
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS):
            return True
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


def store_hash(path: str) -> str:
    return path.rsplit("/", 1)[-1].split("-", 1)[0]


def main() -> None:
    substituters = [url.rstrip("/") for url in sys.argv[1:]]
    paths = [line.strip() for line in sys.stdin if line.strip()]

    with ThreadPoolExecutor(max_workers=16) as pool:
        live = [
            url
            for url, ok in zip(
                substituters,
                pool.map(lambda url: head(f"{url}/nix-cache-info"), substituters),
                strict=True,
            )
            if ok
        ]

    def is_public(path: str) -> bool:
        return any(head(f"{url}/{store_hash(path)}.narinfo") for url in live)

    with ThreadPoolExecutor(max_workers=64) as pool:
        for path, public in zip(paths, pool.map(is_public, paths), strict=True):
            if public:
                print(path)

    print(
        f"Checked {len(paths)} paths against {len(live)} of "
        f"{len(substituters)} public substituters.",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
