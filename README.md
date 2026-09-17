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
m2c pro                    interactive Pro worker
m2c run "bounded task"      machine worker, default Pro
m2c standard run "task"    machine standard worker
m2c pro run --json "task"  machine Pro worker with JSON envelope
m2c run --workstream NAME --packet A1 --json "task"
m2c standard run --quiet --json "task"
m2c models
m2c doctor [--live]
m2c key status|replace|remove
m2c checkpoint --workstream NAME
m2c version
m2c uninstall
```

Every machine run explicitly selects `m2c-mimo/mimo-v2.5` or `m2c-mimo/mimo-v2.5-pro`, passes the current directory with `--dir`, and uses `--format json`. Normal output is a small stable envelope containing status, provider, model, session, packet, tool counts, context estimate, exit code, and final text. Raw OpenCode events remain local job evidence.

Interactive machine runs also show a small live worker console on stderr. It refreshes on a three-second heartbeat from locally cached OpenCode events and process state: selected model, coarse activity, elapsed/watchdog time, tool counts, failures, context estimate, changed-file count, and quiet/final state. `--quiet` suppresses the console. stdout remains a clean JSON envelope for `m2c ... --json | jq .`; the console makes no provider or model calls and consumes no additional context tokens.

## Workstreams and context

Use a workstream for related bounded packets. State is kept outside the repository and records only orchestration metadata: cwd, model, OpenCode session ID, packet, timestamps, context estimate, and checkpoint generation. A cwd or model mismatch fails; m2c never silently switches models or reuses a missing session.

Packets should target 10–15 minutes and must not be deliberately larger than 20 minutes. The worker watchdog is implemented with Nushell jobs and kills the worker job at the 20-minute ceiling, returning `status: "timed_out"`. A 30% context estimate recommends checkpointing, 35% is a watch zone, 45% requires `m2c checkpoint`, and 50% rejects another substantive packet. Checkpointing preserves a short knowledge summary and starts the next packet with a fresh OpenCode session.

The current usage estimate is `tokens.input + tokens.cache.read`, based on OpenCode's step-finish events. It is an estimate, not a claim of exact provider context accounting; see `docs/CONTEXT_ACCOUNTING.md`.

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
