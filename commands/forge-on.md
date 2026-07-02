---
name: forge-on
description: Re-enable serena-forge write enforcement in the current repo by removing the .serena-forge-off escape-hatch marker.
disable-model-invocation: true
user-invocable: true
allowed-tools: "Bash(rm -f .serena-forge-off) Bash(ls -la .serena-forge-off) Bash(test *)"
---

## Re-enable serena-forge enforcement

serena-forge blocks direct `Edit`/`Write`/`MultiEdit` on `.cs` files so that C# changes go through Serena's symbolic editing tools. The `.serena-forge-off` marker file in a repo's working directory is the anti-deadlock escape hatch: while it exists, enforcement is suspended for that repo. This command removes it so enforcement resumes.

### Steps

1. Remove the marker from the current working directory:

   ```bash
   rm -f .serena-forge-off
   ```

   `rm -f` is intentional — it succeeds silently whether or not the marker exists, so this is safe to run even if enforcement was already on.

2. Confirm to the user that serena-forge write enforcement is now **active** in this repo: direct `Edit`/`Write`/`MultiEdit` on `.cs` files will be denied and redirected to Serena's symbolic edit tools (`replace_symbol_body`, `insert_after_symbol`, `rename_symbol`, etc.). Native `Read` on `.cs` stays allowed.

### Important: environment override

If the environment variable `SERENA_FORGE_OFF=1` is set, enforcement stays **disabled globally regardless of this command** — the hook honours the env var before it ever checks for the marker file. Removing the marker will NOT re-enable enforcement in that case. If the user reports that enforcement is still off after running `/forge-on`, tell them to check for and unset `SERENA_FORGE_OFF` (e.g. it may be exported in their shell profile or session env); the marker file alone cannot override it.

### Related

- `/serena-forge:forge-off` — the inverse: writes the `.serena-forge-off` marker to suspend enforcement for the current repo (use when Serena's LSP is not ready, e.g. a large brownfield solution still initialising, or a non-.NET-10 project).
- serena-forge governs read/edit/refactor of symbols in the **current** repo; it does not replace codebase-memory-mcp, which remains the tool for the global multi-repo graph, architecture, complexity, and cross-service impact.
