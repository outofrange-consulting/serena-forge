#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path

from hook_utils import cwd_from, is_cs_path, queue_path_for, read_payload, tool_input


def main() -> int:
    if os.environ.get("SERENA_FORGE_BUILD", "1") == "0":
        return 0
    payload = read_payload()
    cwd = cwd_from(payload)
    ti = tool_input(payload)
    rel = ti.get("relative_path") or ti.get("file_path")
    if not isinstance(rel, str) or not rel:
        return 0
    path = Path(rel)
    if not path.is_absolute():
        path = cwd / path
    if not is_cs_path(path):
        return 0

    try:
        cwd_resolved = cwd.resolve(strict=False)
    except OSError:
        cwd_resolved = cwd.absolute()

    proj = None
    for directory in [path.parent, *path.parent.parents]:
        for candidate in directory.glob("*.csproj"):
            if candidate.is_file():
                proj = candidate
                break
        if proj or directory == cwd_resolved or directory == cwd:
            break
    if not proj:
        return 0

    queue = queue_path_for(cwd)
    try:
        queue.parent.mkdir(parents=True, exist_ok=True)
        with queue.open("a", encoding="utf-8") as fh:
            fh.write(str(proj) + "\n")
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        raise SystemExit(0)
