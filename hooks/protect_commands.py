#!/usr/bin/env python3
"""PreToolUse Bash guard with portable Python parsing.

Policy: deny catastrophic actions, ask for recoverable destructive actions, and
allow provably low-risk cleanup such as /tmp removal or generated build/source
artifacts.
"""
from __future__ import annotations

import os
import re
import shlex
from pathlib import Path

from hook_utils import cwd_from, emit_pretool, is_generated_path, read_payload, tool_input

ROOT_TARGETS = {"/", "/*"}
SQL_DROP_RE = re.compile(r"\bdrop\s+(table|database|schema|view|index)\b", re.I)
SQL_TRUNCATE_RE = re.compile(r"\btruncate\s+table\b", re.I)
SQL_DELETE_RE = re.compile(r"\bdelete\s+from\b", re.I)
SQL_UPDATE_RE = re.compile(r"\bupdate\b.+\bset\b", re.I | re.S)
SQL_WHERE_RE = re.compile(r"\bwhere\b", re.I)
FORK_BOMB_RE = re.compile(r"\(\)\s*\{[^}]*[a-z_:][\w:]*\s*\|\s*[a-z_:][\w:]*\s*&", re.I)
SEGMENT_SPLIT_RE = re.compile(r"[;&|]")
GENERATED_DIR_NAMES = {"bin", "obj", "generated", "gen", ".cache", "dist", "build", "coverage", "node_modules"}


def split_words(segment: str) -> list[str]:
    try:
        return shlex.split(segment, posix=(os.name != "nt"))
    except ValueError:
        return segment.split()


def is_recursive_rm(words: list[str]) -> bool:
    return any(w == "--recursive" or (w.startswith("-") and "r" in w.lower()) for w in words[1:])


def is_forced_rm(words: list[str]) -> bool:
    return any(w == "--force" or (w.startswith("-") and "f" in w.lower()) for w in words[1:])


def rm_targets(words: list[str]) -> list[str]:
    targets: list[str] = []
    for word in words[1:]:
        if word == "--":
            continue
        if word.startswith("-"):
            continue
        targets.append(word)
    return targets


def expands_home_root(target: str) -> bool:
    return target in {"~", "~/", "$HOME", "${HOME}"}


def is_catastrophic_target(target: str) -> bool:
    stripped = target.rstrip("\\/") or target
    return target in ROOT_TARGETS or stripped == "/" or expands_home_root(target)


def under_tmp(path: Path) -> bool:
    try:
        resolved = path.resolve(strict=False)
    except OSError:
        resolved = path.absolute()
    tmp_roots = [Path(os.environ.get("TMPDIR", "/tmp")), Path(os.environ.get("TEMP", "/tmp")), Path("/tmp"), Path("/var/tmp")]
    for root in tmp_roots:
        try:
            resolved.relative_to(root.resolve(strict=False))
            return True
        except Exception:
            pass
    return False


def low_risk_rm_target(target: str, cwd: Path) -> bool:
    if not target or target.startswith("~") or "$" in target:
        return False
    p = Path(target)
    if not p.is_absolute():
        if ".." in p.parts:
            return False
        p = cwd / p

    if under_tmp(p):
        return True

    normalized = str(p).replace("\\", "/").lower()
    if "/.git" in normalized or normalized.endswith("/.git"):
        return False
    if is_generated_path(normalized):
        return True
    parts = {part.lower() for part in p.parts}
    return bool(parts & GENERATED_DIR_NAMES)


def decision_for_rm(words: list[str], cwd: Path) -> tuple[str, str] | None:
    if not words or Path(words[0]).name != "rm":
        return None
    targets = rm_targets(words)
    recursive = is_recursive_rm(words)
    forced = is_forced_rm(words)

    if "--no-preserve-root" in words:
        return "deny", "serena-forge: rm with --no-preserve-root is catastrophic."
    if recursive and forced and any(is_catastrophic_target(t) for t in targets):
        return "deny", "serena-forge: refusing recursive forced delete of root/home."

    if targets and all(low_risk_rm_target(t, cwd) for t in targets):
        return None

    if recursive:
        return "ask", "serena-forge: recursive file deletion outside known low-risk temp/generated paths; confirm the target."
    if targets:
        return "ask", "serena-forge: file deletion outside known low-risk temp/generated paths; confirm the target."
    return None


def decision_for_words(words: list[str], segment: str, cwd: Path) -> tuple[str, str] | None:
    if not words:
        return None
    rm_decision = decision_for_rm(words, cwd)
    if rm_decision:
        return rm_decision

    if len(words) >= 3 and words[0] == "git" and words[1] == "push" and any(w in {"-f", "--force", "--force-with-lease"} for w in words[2:]):
        return "ask", "serena-forge: force push rewrites remote history; confirm."
    if len(words) >= 3 and words[:3] == ["git", "reset", "--hard"]:
        return "ask", "serena-forge: git reset --hard discards local changes; confirm."
    if len(words) >= 2 and words[:2] == ["git", "clean"] and any(w.startswith("-") and "f" in w for w in words[2:]):
        return "ask", "serena-forge: git clean -f deletes untracked files; confirm."
    if words[:4] == ["dotnet", "ef", "database", "drop"]:
        return "ask", "serena-forge: dotnet ef database drop destroys the database; confirm."

    if SQL_DROP_RE.search(segment):
        return "ask", "serena-forge: SQL DROP is destructive; confirm."
    if SQL_TRUNCATE_RE.search(segment):
        return "ask", "serena-forge: SQL TRUNCATE TABLE empties data; confirm."
    if SQL_DELETE_RE.search(segment) and not SQL_WHERE_RE.search(segment):
        return "ask", "serena-forge: DELETE without WHERE affects all rows; confirm."
    if SQL_UPDATE_RE.search(segment) and not SQL_WHERE_RE.search(segment):
        return "ask", "serena-forge: UPDATE without WHERE affects all rows; confirm."
    return None


def main() -> int:
    payload = read_payload()
    if payload.get("tool_name") != "Bash":
        return 0
    command = tool_input(payload).get("command")
    if not isinstance(command, str) or not command.strip():
        return 0

    if FORK_BOMB_RE.search(command):
        emit_pretool("deny", "serena-forge: fork bomb pattern detected.")
        return 0

    cwd = cwd_from(payload)
    for segment in SEGMENT_SPLIT_RE.split(command):
        words = split_words(segment)
        decision = decision_for_words(words, segment, cwd)
        if decision:
            emit_pretool(*decision)
            return 0
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        raise SystemExit(0)
