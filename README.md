# mimo2codex

`mimo2codex` gives Codex and local development workflows a simple way to delegate bounded work to Xiaomi MiMo without requiring a second agent station. `m2c` is the public interface; OpenCode is the current replaceable worker backend underneath it.

The worker uses Xiaomi's documented OpenCode/OpenAI-compatible integration at the Europe Token Plan endpoint. It does not use MiMo's unreliable Responses tool path for worker execution, and it never executes textual pseudo-tool calls.

Requirements: Nushell 0.115+, OpenAI Codex CLI for the experimental direct route, OpenCode 1.18+ for worker execution, and a Xiaomi MiMo Token Plan. Windows, Linux, and WSL are supported.

## Quick start

```text
git clone https://github.com/matthewjameswatkins1978-cyber/mino2codex
cd mino2codex
nu install.nu
```

Open a new Nushell session, then configure the local credential:

```text
m2c setup
m2c doctor
m2c
```

If OpenCode is missing, `m2c setup` reports the detected state and the Nu-native installation command to use: `npm install -g opencode-ai`.

## Public commands

```text
m2c                         interactive Pro worker
m2c standard                interactive standard worker
m2c pro                     interactive Pro worker
m2c run "bounded task"      machine worker, default Pro
m2c standard run "task"     machine standard worker
m2c pro run --json "task"   machine Pro worker with JSON envelope
m2c run --workstream NAME --packet A1 --json "task"
m2c standard run --quiet --json "task"
m2c models
m2c doctor [--live]
m2c key status|replace|remove
m2c checkpoint --workstream NAME
m2c watch                   watch GitHub (one job, then return)
m2c watch --stay            persistent watcher, continues after jobs finish
m2c watch --check           one non-waiting poll, exit if no jobs
m2c watch --once            backward-compatible alias for --check
m2c status                  show m2c status and recent jobs
m2c inspect <job-id>        show flight recorder timeline for a job
m2c version
m2c uninstall
```

Every machine run explicitly selects `m2c-mimo/mimo-v2.5` or `m2c-mimo/mimo-v2.5-pro`, passes the current directory with `--dir`, and uses `--format json`. Normal output is a small stable envelope containing status, provider, model, session, packet, tool counts, context estimate, exit code, and final text. Raw OpenCode events remain local job evidence.

Interactive machine runs also show a small live worker console on stderr. It refreshes on a three-second heartbeat from locally cached OpenCode events and process state: selected model, coarse activity, elapsed/watchdog time, tool counts, failures, context estimate, changed-file count, and quiet/final state. `--quiet` suppresses the console. stdout remains a clean JSON envelope for `m2c ... --json | jq .`; the console makes no provider or model calls and consumes no additional context tokens.

Machine workers explicitly select OpenCode's `build` agent, so ordinary `run` packets are execution-capable and do not inherit the user's interactive plan mode. Packets that start with explicit plan-only or planning-only intent use `plan`; everything else uses `build`. If a workstream changes agent mode, m2c forks the prior session before continuing so useful context is retained without carrying an accidental mode across packets.

Packet files are supported with `m2c packet FILE`, `m2c standard packet FILE`, or `m2c pro packet FILE`. Front matter can provide `workstream`, `packet`, and `directory`; explicit flags win, then front matter, then filename inference. Run telemetry is privacy-safe and documented in [`docs/TELEMETRY.md`](docs/TELEMETRY.md).

## Workstreams and context

Use a workstream for related bounded packets. State is kept outside the repository and records only orchestration metadata: cwd, model, OpenCode session ID, packet, timestamps, context estimate, and checkpoint generation. A cwd or model mismatch fails; m2c never silently switches models or reuses a missing session.

Direct workstream packets should normally target 10–15 minutes. Direct `m2c run` / packet execution still uses the 20-minute worker budget by default. GitHub Watch jobs may request an explicit `budget_minutes` from 5 to 120 minutes; if omitted, Watch defaults to 20. Invalid or out-of-range Watch budgets fail closed before claim. The worker watchdog is implemented with Nushell jobs and reports `status: "timed_out"` when the admitted budget is exhausted. A 30% context estimate recommends checkpointing, 35% is a watch zone, 45% requires `m2c checkpoint`, and 50% rejects another substantive packet. Checkpointing preserves a short knowledge summary and starts the next packet with a fresh OpenCode session.

The current usage estimate is `tokens.input + tokens.cache.read`, based on OpenCode's step-finish events. It is an estimate, not a claim of exact provider context accounting; see `docs/CONTEXT_ACCOUNTING.md`.

## GitHub Watch

`m2c watch` polls GitHub for open issues owned by the authenticated user whose title begins with `[M2C QUEUED]`. By default, `m2c watch` processes one eligible job and returns to Nushell. Use `m2c watch --stay` for the persistent watcher that continues polling after jobs finish. Use `m2c watch --check` for one non-waiting poll that exits cleanly if no jobs are found. `m2c watch --once` is preserved as a backward-compatible alias for `--check`.

A single-controller lock prevents multiple watchers from running simultaneously. If a second controller starts, it exits with a message identifying the active controller's PID.

A Watch issue uses frontmatter followed by the bounded worker packet:

```yaml
---
m2c_job: 1
base: <exact 40-character commit SHA>
branch: <non-main worker branch>
model: standard
budget_minutes: 45
---
```

`model` must be `standard` or `pro`. `budget_minutes` is optional, defaults to 20, accepts only integer values from 5 through 120 inclusive, and fails closed when present but invalid. Before claiming a job, m2c revalidates the live issue, owner, title/state, base SHA, branch and packet. Completion still requires the requested branch, a clean worktree, a remote branch, and matching local/remote SHA. Worker prose is evidence; these delivery facts are checked mechanically by m2c.

### Result categories

m2c uses deterministic result categories derived from process/Git/GitHub truth:

- **DONE**: worker completed and all delivery gates pass.
- **BLOCKED**: admission refused before execution.
- **WORKER_FAILED**: worker process exit indicates execution failure.
- **TIMED_OUT**: watchdog ended the worker.
- **NO_CHANGES**: worker completed but produced no delivered change.
- **DELIVERY_FAILED**: work exists but branch/remote/SHA/worktree delivery gates fail.
- **INTERNAL_ERROR**: m2c/controller/runner itself failed unexpectedly.

Issue titles preserve the original descriptive title across all transitions: `[M2C DONE] Resolve R1-A2 preparation identity binding`.

### Flight recorder

Every watched job produces privacy-safe, append-only local artifacts in `jobs/<job-id>/`:

- `manifest.json`: written at claim time with job metadata
- `events.jsonl`: append-only lifecycle events
- `result.json`: written after finalization

Use `m2c inspect <job-id>` to view a compact timeline. Use `m2c status` to see recent jobs and aggregate statistics.

Credentials, API keys, environment secrets, and raw provider payloads are never recorded in flight logs.

## Configuration and security

Each worker run injects an m2c-owned `OPENCODE_CONFIG_CONTENT` at runtime. It contains only the unique `m2c-mimo` provider, both supported models, the AMS endpoint, the provider allowlist, and bounded worker permissions. The API key remains in the existing local credential file and is referenced through `{env:MIMO_API_KEY}`; it is never serialized into runtime JSON, TOML, logs, or the repository.

The m2c skill is installed only in `CODEX_HOME/skills/mimo-worker/SKILL.md` (or the normal `~/.codex/skills` location when `CODEX_HOME` is unset). It does not modify global `AGENTS.md` or unrelated skills. `m2c uninstall` removes only that skill directory and m2c-owned state.

OpenCode is not an OS sandbox. Its worker policy allows normal project work, denies questions and nested subagents in machine mode, denies web access and external-directory access, and fails closed when the worker cannot complete. No provider fallback is configured.

## Direct Codex route

The original direct MiMo Responses integration remains available explicitly:

```text
m2c codex
m2c codex standard
m2c codex pro
```

It is labelled **EXPERIMENTAL / KNOWN UPSTREAM TOOL-USE ISSUE**. Plain inference works, but the captured MiMo Responses path can emit textual `<tool_call>` markup instead of a structured function call, so m2c never parses or executes that text.

## Development

```text
nu tests/run.nu
```

The test suite is offline and uses fake credentials. Live worker checks are explicit with `m2c doctor --live`; they use the real locally stored credential without printing it. The project is unofficial and is not affiliated with Xiaomi or OpenAI. The upstream repository retains its historical name `mino2codex`; the product and code use `mimo2codex`.
