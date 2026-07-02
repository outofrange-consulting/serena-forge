---
name: serena-refactor
description: Edit and refactor C# symbols through Serena's LSP-backed symbolic write tools instead of raw text edits. Use for renaming a symbol, moving a class, replacing or inserting a method, or any structural change to a .cs file — because Edit/Write/MultiEdit on .cs are blocked plugin-wide and must be redirected to Serena.
when_to_use: "Trigger on: \"rename this symbol\", \"refactor\", \"edit this method\", \"move this class\", \"change this method's body\", \"add a method to this class\", \"delete this symbol\", or any request that modifies C# code. Also use whenever a native Edit/Write/MultiEdit on a .cs file was just denied — this is the sanctioned path."
allowed-tools: "Bash(git diff*) Bash(git status*) Read"
---

# serena-refactor — symbolic C# editing

Native `Edit`, `Write`, and `MultiEdit` on `.cs` files are **denied globally** by serena-forge (write-only enforcement, active in every repo). All C# code changes go through **Serena's symbolic write tools**, which edit by *symbol* (class / method / property) via the Roslyn LSP rather than by line-matching text. This keeps edits surgical and keeps Serena's index consistent.

## Workflow: locate → edit → verify

1. **Locate the symbol** (Serena read tools — see the `serena-navigate` skill):
   - `get_symbols_overview` on the file to see its top-level symbols.
   - `find_symbol` with the name path (e.g. `MyClass/DoWork`) to get the exact symbol; pass `include_body: true` when you need to read it before editing.
   - `find_referencing_symbols` before any rename/move/delete, so you know what depends on it.
2. **Edit** with the matching write tool (below).
3. **Verify** with `get_diagnostics_for_symbol` (or `get_diagnostics_for_file`) to confirm the edit compiles with no new errors — then **check the git diff** (see the CRLF pitfall — this step is not optional on a corporate repos).

> **Build safety net (automatic).** serena-forge queues the touched `.csproj` on every symbolic edit and runs one scoped `dotnet build --no-restore` at end of turn (`queue-build.sh` → `flush-build-queue.sh`, Stop hook). If it fails, the turn is blocked and the compiler errors are handed back to you — **fix them through Serena before finishing; a red build is unfinished work.** `get_diagnostics_*` is your fast in-loop check; the end-of-turn build is the real gate. For a wider guarantee, follow the build with the targeted tests of the modified slice (in VSA the per-slice test scope keeps this cheap). Opt out with `SERENA_FORGE_BUILD=0` only if the user asks.

## Verified Serena write tools

Use only these (confirmed present). Do **not** invent tool names.

| Tool | Use for |
|------|---------|
| `replace_symbol_body` | Replace the full body of one method/property/class you already located. The primary "edit this method" tool. |
| `insert_after_symbol` | Add a new symbol (method, property, nested type) immediately after an existing one. |
| `insert_before_symbol` | Add a new symbol immediately before an existing one (e.g. a new method above the target). |
| `rename_symbol` | Rename a symbol **and update every reference** via the LSP. This is the correct answer to "rename this symbol" — never hand-edit call sites. |
| `safe_delete_symbol` | Remove a symbol after checking references. Use for "delete this method/class". |

Fine-grained fallbacks also exist (`replace_lines`, `insert_at_line`, `delete_lines`, `replace_content`, `replace_in_files`, `create_text_file`). Prefer the symbol-level tools above; reach for line/content tools only when the change isn't a whole symbol (e.g. editing a `using` block or a region that isn't a symbol body).

### Recipes

**Edit a method body** — `find_symbol` (`include_body: true`) to read it, then `replace_symbol_body` with the new body. Don't `replace_lines` a method you can address by symbol.

**Add a method to a class** — `insert_after_symbol` (or `insert_before_symbol`) targeting a sibling method, passing the new method text.

**Rename a symbol** — `rename_symbol` on the definition. It rewrites references across the project through the LSP. Afterwards run `get_diagnostics_for_file` on the most-affected files.

**Move a class** — Serena has **no single "move" tool**. Compose it:
1. `find_symbol` (`include_body: true`) on the class to capture its full text.
2. Create/populate the destination: `create_text_file` for a brand-new file, or `insert_after_symbol` to drop it into an existing file. Add the correct `namespace` / `using` directives for the new location.
3. `safe_delete_symbol` to remove it from the origin file.
4. `find_referencing_symbols` (run in step 1, before deleting) tells you which files need `using`/namespace fixups; apply those with the symbolic or line tools.
5. `get_diagnostics_for_file` on origin, destination, and referencing files to confirm the move compiles.

## CRITICAL pitfall — the format hook rewrites your .cs at turn end (CRLF churn)

**A `dotnet format` hook runs over every `.cs` file Serena touches, and it will amplify a one-line symbolic edit into a whole-file CRLF/whitespace diff.** This is the single most common way a clean Serena refactor turns into an unreviewable, un-mergeable diff on a corporate repos.

Why it happens:
- The live formatting path is PostToolUse → `~/.claude/hooks/queue-format.sh` (enqueues the edited path to `<repo>/.claude/.format-queue`), then the **Stop hook** → `~/.claude/hooks/flush-format-queue.sh` runs `dotnet format <sln> --include <files> --no-restore` **once at end of turn**. (An older per-file variant, `~/.claude/hooks/dotnet-format.sh`, does the same for a single file.) Serena's symbolic edits are picked up by this hook just like a native edit would be.
- a corporate `.editorconfig` **forces CRLF**, but some source files — notably several `Program.cs` — are checked in as **LF**. `dotnet format` normalizes line endings for the whole included file, so your surgical change gets bundled with a CRLF re-write of every line in the file.

This is exactly what bit **a service** (`a local checkout`, a PR): `Program.cs` is LF on `develop`, `.editorconfig` demands CRLF, and the format hook polluted the diff.

**Always do this after a Serena edit to a .cs file:**

1. **Check the diff.**
   ```bash
   git diff --stat
   git diff -- path/to/File.cs
   ```
   If the only real change is your symbol but the diff shows the whole file changed (or `git diff --stat` shows a suspiciously large line count), the format hook rewrote line endings.

2. **If the diff is polluted, escape via `--no-verify` + `perl -i` reinsert:**
   - Commit your genuine change while bypassing the pre-commit reformat/hook chain:
     ```bash
     git commit --no-verify -m "refactor(scope): <ticket> <description>"
     ```
     (`--no-verify` also sidesteps the offline husky pre-commit/pre-push hooks in some repos, which fail with no network. Do **not** add npm/husky dependencies to work around them.)
   - Restore the intended LF lines that the formatter flipped:
     ```bash
     perl -i -pe 's/\r$//' path/to/Program.cs        # strip CR the formatter added back to LF
     ```
     Then re-inspect `git diff` until only your symbol change remains, and amend/commit.

   The goal is a diff that shows **only the symbol you changed** — reviewers (and CI line-ending checks) reject whole-file CRLF churn.

3. **Prefer to avoid the churn entirely** when the file is LF-on-disk: keep edits symbol-scoped, and after the turn's format flush, verify the file's line endings match what's committed before you stage.

## When Serena cannot make the edit

If Serena can't perform the change — the Roslyn LSP hasn't finished initializing (large brownfield solutions take up to ~30s for `projectInitializationComplete`), it timed out, the repo is `.NET 9` (Serena's Roslyn backend reliably trips a 10s BuildHost timeout — serena-forge is `.NET 10`-only), or the symbolic tools genuinely can't express the change — **do not attempt to work around the write block.** There is no bypass to reach for.

Instead:

1. If it looks like a warm-up delay, wait for the LSP to finish initializing and retry the symbolic edit once.
2. Otherwise, **stop and tell the user** exactly what failed (LSP unavailable / timed out / .NET 9 / change not expressible symbolically) and ask them to either fix Serena or disable the serena-forge hook. Do not fall back to native `Edit`/`Write` — the block is intentional.
