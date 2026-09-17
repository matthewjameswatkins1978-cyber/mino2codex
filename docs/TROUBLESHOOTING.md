# Troubleshooting

Start with `m2c doctor`. It is offline by default. Use `m2c doctor --live` only when you explicitly want a provider request. If the credential is missing or invalid, run `m2c setup` or `m2c key replace`; the launcher never falls back to OpenAI. If `m2c` is not found immediately after installation, open a new Nushell session so the user autoload directory is read.

Before treating a provider as release-ready, run a real Codex task that requires shell/tool use. A textual `<tool_call>` or JSON tool request is not proof that Codex executed the tool; it indicates an unverified provider compatibility path and must remain a release blocker.
