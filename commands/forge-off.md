---
name: forge-off
description: Temporarily disable serena-forge enforcement in the current repo by creating a .serena-forge-off marker. Anti-deadlock escape hatch for when Serena's LSP is not ready, the repo is .NET 9 (unsupported), or you must make an emergency native edit.
disable-model-invocation: true
user-invocable: true
allowed-tools: "Bash(touch *) Bash(ls *)"
---

## Disable serena-forge (escape hatch)

serena-forge normally DENIES native `Edit`/`Write`/`MultiEdit` on `.cs` files and
redirects you to Serena's symbolic editing tools. This command turns that
enforcement OFF for the current working directory by dropping a marker file that
the PreToolUse guard checks on every call and fails open when it sees.

Native `Read` on `.cs` is never blocked — only writes — so this switch is only
needed when you must *edit* C# without going through Serena.

### When to use this

Use it deliberately, only when Serena genuinely can't do the job right now:

- **LSP not ready** — Serena's Roslyn language server can wait up to ~30s for
  `workspace/projectInitializationComplete` on a large brownfield solution. If it
  hasn't finished initializing (or the MCP server isn't running), symbolic edits
  will fail. Rather than deadlock, flip enforcement off, make the edit natively,
  then flip it back on once the LSP is up.
- **.NET 9 repo** — Serena's Roslyn backend requires **.NET 10+**. On a .NET 9
  project it throws `System.TimeoutException` (10s BuildHost timeout) and symbolic
  edits never land. serena-forge should refuse .NET 9 during onboarding; if you're
  stuck editing a .NET 9 repo, this is the escape hatch.
- **Emergency native edit** — a one-off change where routing through Serena's
  symbol tools is impractical (e.g. Serena is down, or the change spans raw text
  that has no symbol to target).

### What it does NOT change

- **codebase-memory-mcp stays in place.** serena-forge does not replace cbm.
  Keep using cbm for the global multi-repo graph, architecture, complexity, and
  cross-service impact/Cypher/dead-code queries. Serena owns read/edit/refactor of
  symbols in the *current* repo. Turning serena-forge off does not touch cbm.
- **Destructive-command and secret-path guards stay active** — this only relaxes
  the `.cs` write redirect, nothing else.

### The escape hatch is scoped to this directory

The marker lives in the current working directory. It disables enforcement for
work rooted here, not globally. (There is also an env alternative:
`SERENA_FORGE_OFF=1` in the environment disables enforcement for the whole
session, regardless of cwd.)

## Do this

Create the marker in the current working directory:

```
touch .serena-forge-off
```

Then confirm to the user, in plain language:

- serena-forge enforcement is now **OFF** for this directory (`.serena-forge-off`
  is present) — native `.cs` edits will be allowed.
- Remind them this is temporary: re-enable with `rm .serena-forge-off` (or
  `/forge-on` if available) as soon as Serena is usable again.
- If the reason was a formatting collision, note the CRLF caveat: a native `.cs`
  edit still gets reformatted at end of turn by the `flush-format-queue.sh`
  `dotnet format` pass (a corporate `.editorconfig` forces CRLF), so re-check the diff
  and, if it's polluted, commit with `--no-verify` and reinsert the surgical change
  via `perl -i`.
