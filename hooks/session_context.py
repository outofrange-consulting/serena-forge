#!/usr/bin/env python3
from __future__ import annotations

from hook_utils import cwd_from, emit_session_context, read_payload


def main() -> int:
    payload = read_payload()
    cwd = cwd_from(payload)
    if (cwd / ".serena").is_dir():
        onboard = "Current repo: Serena-onboarded (.serena/ present) — Serena tools are ready to use here."
    else:
        onboard = (
            "Current repo: NOT Serena-onboarded (no .serena/ folder). Serena's symbolic read/edit tools will not work here "
            "until onboarding. As soon as C# work is requested, propose running the serena-forge-setup skill; do not silently skip it."
        )

    context = f"""Serena-first protocol (serena-forge active).

Serena provides symbol-level read and edit tools for the CURRENT repository, backed by the Roslyn language server.

Read policy: native Read of .cs files is allowed, but prefer Serena for navigation: get_symbols_overview, then find_symbol with include_body: true only for the target. Use find_referencing_symbols instead of grep for impact analysis.

Write policy: native .cs edits are protected and ask for human consent. Prefer Serena symbolic edits: replace_symbol_body, insert_after_symbol, insert_before_symbol, rename_symbol, safe_delete_symbol, and create_text_file. Confirm native edits only as a deliberate human-approved exception.

Build safety net: after C# edits, serena-forge compiles touched project(s) with dotnet build at end of turn. Treat a red build as unfinished work.

Command safety: catastrophic commands are denied; recoverable destructive commands ask for consent; low-risk temp/generated cleanup is allowed.

{onboard}"""
    emit_session_context(context)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        raise SystemExit(0)
