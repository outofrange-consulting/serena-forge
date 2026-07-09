---
name: datadog
description: Query and operate Datadog from the shell with the `pup` CLI — logs, APM traces & spans, metrics, monitors & alerts, incidents, SLOs, dashboards, security signals, on-call, downtimes, the live debugger and symbol database. Use whenever the user mentions Datadog, DD, `pup`, observability, traces/tracing, a span, APM, logs or log search, a monitor or alert, an incident, metrics, an SLO/SLI or error budget, a dashboard, latency / p95 / p99, error rate, throughput, a service map or service dependencies, a crashloop / CrashLoopBackOff / restart loop, OTEL / OpenTelemetry, a live-debugger probe, symbol search, security signals, on-call or downtime, or asks why a service is failing, erroring, or slow in production. Reads and writes; OAuth token (~1h). The org is on the EU site (datadoghq.eu).
---

# Datadog via `pup`

`pup` is Datadog's CLI (installed at `~/.local/bin/pup` by `install-wsl.sh`). One
CLI for the whole Datadog surface — reads **and** writes. Prefer it over the web
UI; never ask the user to "check a dashboard" — query it yourself and report back.

## Site & auth (already wired by install-wsl.sh)

- **The org is on the EU site.** `DD_SITE=datadoghq.eu` is exported in env.sh, so
  every `pup` call targets EU automatically. Only pass `--site datadoghq.eu` on a
  single call if the env got lost.
- OAuth token, **~1h TTL**. Check once per session: `pup auth status`. On a
  `401`/`403` mid-task: `pup auth refresh` first (no browser); if that fails,
  `pup auth login` (browser OAuth — the browser cookie auto-completes the flow).
- Don't retry a failing command blindly — re-auth, then retry once.

## Output discipline (token diet)

Always narrow: pass a `--query` and a `--from <window>`. **`--from` wants a bare
window — `1h` / `12h` / `7d` — NOT `now-12h`.** The traces API on EU is
rate-limited (HTTP 429): widen `--from` and stop polling rather than hammering it.
Ask for JSON with a projection when you consume values, not raw dumps.

## Quick reference

| Task | Command |
|---|---|
| Search error logs | `pup logs search --query "status:error service:<svc>" --from 1h` |
| Aggregate / tail logs | `pup logs search --query "<q>" --from 15m` |
| Find slow traces | `pup traces search --query "@duration:>500000000" --from 1h` |
| Aggregate traces | `pup traces aggregate --query "<q>" --from 12h` |
| List / show monitors | `pup monitors list` · `pup monitors show <id>` |
| Create downtime (mute) | `pup downtime create --file downtime.json` |
| List incidents | `pup incidents list` |
| Query a metric | `pup metrics query --query "avg:trace.<op>.duration{service:<svc>}" --from 1h` |
| Hosts / infra | `pup infrastructure hosts list` |
| SLOs | `pup slos list` |
| Security signals | `pup security signals list --query "*" --from 24h` |
| On-call teams | `pup on-call teams list` |
| Live-debugger probe | `pup debugger probes create --service <svc> --env prod --probe-location "Ns.Class:Method"` |
| Probe-able methods | `pup symdb search --service <svc> --query <Class> --view probe-locations` |
| Auth | `pup auth status` · `pup auth refresh` · `pup auth login` |

Run any subcommand with `--help` for its flags; `pup --help` lists the full surface.

## Common investigations

- **"Why is `<svc>` crashlooping / restarting / erroring?"** — logs first
  (`pup logs search --query "service:<svc> status:error" --from 1h`), then the
  failing trace (`pup traces search --query "service:<svc> @error:true" --from 1h`).
  For the exact runtime argument/variable values, find the method with
  `pup symdb search` then drop a live probe with `pup debugger probes create`.
- **"Is it latency or errors?"** — `pup monitors list` for what's firing, then
  `pup metrics query` for the p99 / error-rate metric over `--from 1h`.
- **OTEL vs native tracer** — discriminate on the span attribute
  `otel.library.name`: filter `@otel.library.name:*` in a `pup traces` query
  (present ⇒ OpenTelemetry instrumentation, absent ⇒ native `dd-trace`).

## Notes

- Writes (monitor mutations, downtimes, live probes, incident updates) are
  externally visible — confirm the target with the user before firing.
- This single skill replaces the per-surface `dd-*` skills; it drives the `pup`
  CLI directly across logs, APM, metrics, monitors, incidents, SLOs, security,
  on-call, the live debugger and the symbol database.
