# Architecture

`m2c` is the stable control surface. Nushell owns model selection, credential injection, runtime configuration, workstream state, timeout policy, JSON event parsing, and the result envelope. OpenCode is the replaceable execution engine for both MiMo and Meta backends.

## Worker backends

m2c supports multiple worker backends through a normalized worker contract. The controller dispatches to backends via `worker-dispatch` and remains completely backend-neutral.

### MiMo (default)

```text
coordinating Codex/Lucy
        |
        v
m2c run --model/packet/workstream
        |
        v
OpenCode run --format json --dir <cwd>
        |
        v
m2c-mimo / Xiaomi OpenAI-compatible endpoint
```

Each run injects `OPENCODE_CONFIG_CONTENT` containing only the m2c-owned `m2c-mimo` provider, both supported MiMo models, the AMS endpoint, a provider allowlist, and machine-mode permissions. The model is always explicit; there is no provider fallback or implicit OpenCode model.

### Meta Muse Spark

```text
coordinating Codex/Lucy
        |
        v
m2c meta run --profile contributor
        |
        v
OpenCode run --format json --dir <cwd>
        |
        v
m2c-meta / Meta OpenAI-compatible endpoint
```

Meta backend uses `MODEL_API_KEY` for authentication and `https://api.meta.ai/v1` as the base URL. The contributor profile maps to `muse-spark-1.3-contributor` with `reasoning_effort=high`.

## Credential isolation

Each backend has its own credential source:
- **MiMo**: `MIMO_API_KEY` or stored credential file (`credential`)
- **Meta**: `MODEL_API_KEY` or stored credential file (`meta-credential`)

Credentials are never committed, logged, echoed, or serialized. Doctor/status output reports configured/missing but never prints the key. Flight recorder records only backend/model identity and safe operational metadata.

## Backend identity

Jobs are identified by worker and profile:
- `worker: mimo, profile: standard` → MiMo v2.5
- `worker: mimo, profile: pro` → MiMo v2.5 Pro
- `worker: meta, profile: contributor` → Meta Muse Spark 1.3 Contributor

Unknown profiles fail closed. No automatic routing occurs.

## OpenCode JSONL format

OpenCode JSONL is an implementation format. m2c parses it into a small stable envelope and retains raw events only as local job evidence. Textual pseudo-tool calls are never parsed or executed.

## Workstreams

Workstream state lives outside repositories. It records cwd, model, OpenCode session ID, packet, timestamps, context estimate, checkpoint generation, and an intentional checkpoint. Cwd/model mismatch fails closed. A checkpoint clears the session ID; the next packet starts a fresh session with the checkpoint injected as context.

## Direct Codex path

The original direct MiMo Responses path remains available as `m2c codex [standard|pro]` for inference experiments and future upstream regression testing. It is explicitly experimental because MiMo Responses tool behaviour is currently incompatible with reliable Codex execution. It is not the worker backend.

## Installation

`nu install.nu` installs the Nushell module, static provider data, and autoload wrapper under Nushell's platform-aware data/autoload directories. `m2c setup` generates the MiMo configuration and installs the `mimo-worker` skill. `m2c meta setup` generates the Meta configuration and installs the `meta-worker` skill. No global `AGENTS.md` is modified.

## Contributor tier guardrail

`muse-spark-1.3-contributor` is a distinct profile, not just an alias for standard Muse Spark. It is a different service tier and is surfaced as its own profile in receipts and stats. m2c does no automatic routing; jobs must explicitly request `worker: meta`.
