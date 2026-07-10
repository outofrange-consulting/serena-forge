---
name: aspire-cli
description: .NET Aspire CLI commands for local development workflows. Use when running, debugging, or managing Aspire applications locally. Triggers: "aspire run", "aspire doctor", "aspire agent", "aspire mcp", "start aspire", "launch aspire", "check aspire", "aspire dashboard", "run the app locally". This skill covers the CLI tool, not Aspire orchestration patterns.
---

# .NET Aspire CLI

The `aspire` CLI is a **self-contained** tool (installed by `install-wsl.sh` into
`~/.aspire/bin`, on PATH via env.sh) — it does not need the .NET SDK itself, but
**running** an Aspire app does (the SDK + Docker, both installed by the setup).
Update it by re-running the installer or `curl -sSL https://aka.ms/aspire/get/install.sh | bash`.

## Core Commands

### Health Check
```bash
aspire doctor
```
Validates the local environment: Docker, .NET SDK, container runtime. Run this first if anything seems wrong.

### Run Application
```bash
aspire run --isolated
```
Starts the Aspire AppHost in isolated mode (no IDE attachment). Preferred for CLI-driven development.

- Opens the Aspire dashboard automatically
- Streams structured logs to the terminal
- Use `--project <path>` if not in the AppHost directory

### AI agent environment & MCP
```bash
aspire agent          # Manage AI agent environment configuration (per project)
aspire mcp            # Interact with MCP tools exposed by Aspire resources
```
`aspire agent` wires the current repo so an AI agent can drive Aspire; `aspire mcp`
exposes the Model Context Protocol tools of the running resources. Both operate on
a project/AppHost — there is no global install-time registration.

### OTEL Observability
```bash
aspire otel traces
aspire otel logs
```
Query OpenTelemetry traces and logs from running Aspire resources. Use these to verify behavior after code changes instead of asking the user to check.

### Resource Management
```bash
aspire wait <resource-name>
aspire start
aspire stop
```

## Verification Workflow

After any code change in an Aspire-managed project:

1. `aspire run --isolated` (or restart if already running)
2. `aspire wait <resource>` for dependent resources (databases, message brokers)
3. Trigger the use case via `curl` or test command
4. `aspire otel traces` to verify the operation completed
5. `aspire otel logs` if something looks wrong

**Never ask the user to verify** — you have full access to the running services.

## Common Issues

| Issue | Fix |
|-------|-----|
| `aspire: command not found` | Open a new shell (or `source ~/.config/claude-tools/env.sh`); the CLI lives in `~/.aspire/bin`. Re-run `install-wsl.sh` to (re)install. |
| Dashboard not opening | Check `ASPIRE_DASHBOARD_*` env vars (not `DOTNET_DASHBOARD_*`) |
| Resource not starting | `aspire doctor` first, then check Docker |
| HTTPS errors locally | Use `--no-https` or trust dev certs: `dotnet dev-certs https --trust` |
| Circular project references | Aspire 13+ does not tolerate these — restructure projects |
