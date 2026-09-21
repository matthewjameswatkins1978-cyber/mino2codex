# Architecture

`m2c` is the stable control surface. Nushell owns model selection, credential injection, runtime configuration, workstream state, timeout policy, JSON event parsing, and the result envelope. OpenCode is the replaceable MiMo execution engine.

## Worker path

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

Each run injects `OPENCODE_CONFIG_CONTENT` containing only the m2c-owned `m2c-mimo` provider, the three explicit MiMo profiles (Flash, Pro, and opt-in UltraSpeed), the AMS endpoint, a provider allowlist, and machine-mode permissions. The model is always explicit; there is no provider fallback or implicit OpenCode model.

OpenCode JSONL is an implementation format. m2c parses it into a small stable envelope and retains raw events only as local job evidence. Textual pseudo-tool calls are never parsed or executed.

## Workstreams

Workstream state lives outside repositories. It records cwd, model, OpenCode session ID, packet, timestamps, context estimate, checkpoint generation, and an intentional checkpoint. Cwd/model mismatch fails closed. A checkpoint clears the session ID; the next packet starts a fresh session with the checkpoint injected as context.

## Direct Codex path

The original direct MiMo Responses path remains available as `m2c codex [standard|pro]` for inference experiments and future upstream regression testing. It is explicitly experimental because MiMo Responses tool behaviour is currently incompatible with reliable Codex execution. It is not the worker backend.

## Installation

`nu install.nu` installs the Nushell module, static provider data, and autoload wrapper under Nushell's platform-aware data/autoload directories. `m2c setup` generates the direct-Codex files, detects OpenCode, and installs only the m2c-owned `mimo-worker` skill under the normal Codex skills directory (or the test override). No global `AGENTS.md` is modified.
