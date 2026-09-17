# Xiaomi Responses tool-call reproduction

This is a redacted, ready-to-file upstream reproduction for the direct Codex
path. It is deliberately not used as a compatibility mechanism by m2c.

## Request

```json
{
  "model": "mimo-v2.5-pro",
  "input": "Use the available shell tool to obtain an unpredictable nonce. Return the exact nonce.",
  "tools": [
    {
      "type": "function",
      "name": "get_test_nonce",
      "description": "Return a fresh unpredictable nonce. The caller cannot predict it.",
      "parameters": {"type": "object", "properties": {}, "additionalProperties": false}
    }
  ],
  "reasoning": {"effort": "high"},
  "stream": true
}
```

The request was sent to the documented Token Plan `/v1/responses` endpoint.
Authentication headers and the API key are intentionally omitted.

## Observed response classes

The raw SSE stream contained `response.output_text.delta` content carrying
textual `<tool_call>` markup for some model/reasoning combinations. It did not
contain a structured Responses `function_call` event in those cases. Other
combinations emitted a structured first call but failed on the continuation
request, returning an unsupported continuation error.

| model | reasoning | result |
| --- | --- | --- |
| `mimo-v2.5` | high | textual tool markup |
| `mimo-v2.5` | none | structured first call; continuation failed |
| `mimo-v2.5-pro` | high | structured first call; continuation failed |
| `mimo-v2.5-pro` | none | textual tool markup |

The corresponding Codex capture sent usable function tools with full schemas;
the failure was not an empty or malformed Codex tool definition. The direct
path is therefore retained as an explicit experimental route only.

## Control

The same nonce-style task completed through OpenCode using the
`@ai-sdk/openai-compatible` provider and the isolated `m2c-mimo` runtime
configuration. OpenCode emitted structured `tool_use` JSONL events and the
worker executed the tool. No textual model output was parsed or executed.

## Minimal question for Xiaomi

For the Responses API, should a function tool call always be represented by a
structured `function_call`/tool event, and what is the supported continuation
request shape after that event? Please provide a minimal request/response
example for both `mimo-v2.5` and `mimo-v2.5-pro`.
