# Security model

The Token Plan key is captured with Nushell's suppressed-output input, validated only for non-empty `tp-` format, and stored outside the checkout in a dedicated credential file. On Unix the file is chmod 600; on Windows inheritance is removed and the current user is granted read/write where `icacls` is available. The key is never intentionally printed or included in generated configuration, snapshots, CI, or logs.

Environment precedence is explicit: a valid `MIMO_API_KEY` in the current environment wins; otherwise the private local credential is used. An invalid non-empty environment value is reported as invalid rather than silently replaced. Missing credentials fail closed. No provider fallback exists.

Worker runs inject an m2c-owned OpenCode configuration through `OPENCODE_CONFIG_CONTENT`; the configuration contains the literal `{env:MIMO_API_KEY}` reference, never the credential. The runtime selects only the `m2c-mimo` provider and an explicit MiMo model. Machine mode denies questions, nested subagents, web access, and external-directory access. OpenCode permissions are orchestration controls, not an OS sandbox.

OpenCode's text output is data. `m2c` never parses or executes textual `<tool_call>` markup or command-shaped JSON. Only OpenCode's structured tool events count as tool calls. Worker raw JSONL is kept in m2c-owned local job evidence and is not sent to normal machine consumers.
