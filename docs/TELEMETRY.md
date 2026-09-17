# m2c run telemetry

Each worker run records a small event journal under the m2c state directory at
`runs/<job-id>/events.jsonl`. The final JSON envelope also includes the derived
telemetry fields and the journal path.

Measured values are based on observed OpenCode events and local process timing:

- `time_to_first_provider_event_seconds` is the elapsed time until the first provider event.
- `time_to_first_tool_seconds` and `time_to_first_successful_tool_seconds` use observed structured tool events.
- `time_to_first_file_read_seconds` and `time_to_first_change_seconds` count observed read and edit/write/patch tools.
- `time_to_first_verification_seconds` counts an observed shell verification command.
- `provider_wait_seconds` is the first-provider-event delay; it is not a provider-internal latency measurement.
- `tool_execution_seconds` and `longest_provider_silence_seconds` are derived from the timestamps available in the event stream, so they are estimates when OpenCode omits event timestamps.
- Tool counts, failures, and file/verification counts are classifications of observed structured events, not a scan of the worker transcript.

Telemetry intentionally excludes prompt text, tool arguments, file contents,
credentials, and provider responses. Missing evidence is represented as `null`
or zero; m2c does not infer a successful action from prose in the final reply.

## Packet files

`m2c packet FILE`, `m2c standard packet FILE`, and `m2c pro packet FILE` read a
local UTF-8 packet and then use the normal machine-worker path. Optional
front-matter keys are `workstream`, `packet`, and `directory`. Explicit command
flags take precedence, followed by front matter, followed by filename inference
for names such as `tethers-l2-L2A.md`. The receipt is written to stderr so the
JSON result on stdout remains machine-readable.
