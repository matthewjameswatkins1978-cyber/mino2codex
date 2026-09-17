# Context accounting

OpenCode 1.18.30 emits `step_finish` JSON events with `tokens.input`, `tokens.output`, `tokens.reasoning`, and separate `tokens.cache.read` / `tokens.cache.write` fields.

The live MiMo worker checks observed `tokens.input` and non-zero `tokens.cache.read`. `mimo2codex` therefore uses the conservative active-context estimate:

```text
context_estimate_tokens = tokens.input + tokens.cache.read
context_percent = context_estimate_tokens / 1,048,576 * 100
```

This is an operational estimate, not a claim that the provider exposes exact active-context accounting. Cumulative session totals are never summed.

Thresholds:

- 30%: recommend checkpointing.
- 35%: watch zone; finish the current packet.
- 45%: mandatory checkpoint before another substantive packet.
- 50%: hard ceiling; reject another substantive packet.

Checkpointing is explicit at a clean packet boundary. The short checkpoint is stored as workstream knowledge, the session ID is cleared, and the next packet starts a fresh OpenCode session with the checkpoint injected as context.
