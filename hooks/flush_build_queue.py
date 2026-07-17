#!/usr/bin/env python3
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

from hook_utils import cwd_from, emit_stop_block, queue_path_for, read_payload


def build_failure_policy(cwd: Path) -> str:
    """Return block or warn for failed end-of-turn builds.

    TDD workflows intentionally spend time in the red phase. Keep the default
    safety gate for normal sessions, but let TDD/Superpowers sessions report the
    failure without trapping the turn.
    """
    explicit = os.environ.get("SERENA_FORGE_BUILD_ON_FAIL", "").lower()
    if explicit in {"block", "warn"}:
        return explicit
    if os.environ.get("SERENA_FORGE_TDD", "0") == "1":
        return "warn"
    if any(key.startswith("SUPERPOWERS") for key in os.environ):
        return "warn"
    if (cwd / ".superpowers").exists() or (cwd / "superpowers.md").exists():
        return "warn"
    return "block"


def main() -> int:
    if os.environ.get("SERENA_FORGE_BUILD", "1") == "0":
        return 0
    payload = read_payload()
    cwd = cwd_from(payload)
    queue = queue_path_for(cwd)
    try:
        if not queue.is_file() or queue.stat().st_size == 0:
            return 0
        projects: list[str] = []
        seen: set[str] = set()
        for line in queue.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = line.strip()
            if line and line not in seen:
                seen.add(line)
                projects.append(line)
    finally:
        try:
            queue.unlink()
        except OSError:
            pass

    if not projects or shutil.which("dotnet") is None:
        return 0

    failures: list[str] = []
    for project in projects:
        if not os.path.isfile(project):
            continue
        proc = subprocess.run(
            ["dotnet", "build", project, "--no-restore", "--nologo", "-clp:NoSummary"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if proc.returncode != 0:
            lines = [line for line in proc.stdout.splitlines() if "error" in line.lower()]
            if not lines:
                lines = proc.stdout.splitlines()[-40:]
            failures.append("Project: " + project + "\n" + "\n".join(lines[:40]))

    if not failures:
        return 0

    reason = (
        "serena-forge build validation FAILED after your C# edits. The touched project(s) do not compile. "
        "Fix these compiler errors through Serena's symbolic tools before finishing.\n\n"
        + "\n\n".join(failures)
    )
    policy = build_failure_policy(cwd)
    if policy == "warn" or payload.get("stop_hook_active") is True:
        print(reason, file=sys.stderr)
        return 0
    emit_stop_block(reason)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        raise SystemExit(0)
