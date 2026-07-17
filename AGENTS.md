# serena-forge for Codex

This repository packages serena-forge for both Claude Code and Codex. When using
Codex on this repo or on a consuming .NET repository with serena-forge enabled:

- Prefer Serena's symbolic read tools for C#: `get_symbols_overview`, then
  `find_symbol` with `include_body: true` only for the target symbol.
- Do not mutate hand-authored `.cs` files with native patch/edit tools unless the user explicitly consents to the hook prompt. Use Serena symbolic
  write tools: `replace_symbol_body`, `insert_after_symbol`,
  `insert_before_symbol`, `rename_symbol`, `safe_delete_symbol`, and
  `create_text_file` for new C# source files.
- If Serena is not onboarded for the current repo, propose and run the
  `serena-forge-setup` skill before attempting C# edits.
- Treat an end-of-turn `dotnet build` failure as unfinished work; fix compiler
  errors before stopping.
- Do not work around destructive-command protections. If a blocked command is
  genuinely required, stop and ask the user to run or approve a safer sequence.
