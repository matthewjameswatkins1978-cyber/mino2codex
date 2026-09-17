source "../../nu/mimo2codex.nu"
let request = ($in | from json)
let decision = (match $request.case_id {
    "build-agent" => {action: "dispatch", choice_id: (if (worker-agent "Edit the file and run its tests") == "build" { "build" } else { "wrong" }), reason_codes: ["explicit_build"]}
    "plan-agent" => {action: "dispatch", choice_id: (if (worker-agent "Plan only; do not edit files") == "plan" { "plan" } else { "wrong" }), reason_codes: ["explicit_plan"]}
    "explore-agent" => {action: "dispatch", choice_id: (if (worker-agent "Review only, read-only, do not modify files") == "build" { "build" } else { "wrong" }), reason_codes: ["explicit_review"]}
    "same-mode" => {action: "reuse", choice_id: (if (not (worker-fork-required "ses-old" "build" "build")) { "reuse" } else { "wrong" }), reason_codes: ["compatible_mode"]}
    "mode-change" => {action: "fork", choice_id: (if (worker-fork-required "ses-old" "plan" "build") { "fork" } else { "wrong" }), reason_codes: ["incompatible_mode"]}
    "zero-exit-no-evidence" => {action: "reject", choice_id: (if (worker-summary [] "mimo-v2.5" null null 1 0 false).status == "failed" { "fail" } else { "wrong" }), reason_codes: ["missing_evidence"]}
    "zero-exit-tool-failure" => {action: "reject", choice_id: (if (worker-summary [{type:"tool_use",part:{tool:"edit",state:{status:"error"}}}] "mimo-v2.5" null null 1 0 false).status == "failed" { "fail" } else { "wrong" }), reason_codes: ["tool_failure"]}
    "malformed-scalar" => {action: "discard", choice_id: (if ((parse-worker-events "not-json\n") | length) == 0 { "discard" } else { "wrong" }), reason_codes: ["malformed_event"]}
    "linux-windows-exe" => {action: "reject", choice_id: (if (opencode-platform-status-for "unix" "/usr/bin/opencode.exe").status == "invalid" { "reject" } else { "wrong" }), reason_codes: ["platform_boundary"]}
    "context-ceiling" => {action: "reject", choice_id: (if (checkpoint-state {context_percent: 50.0}) == "hard_ceiling" { "ceiling" } else { "wrong" }), reason_codes: ["context_ceiling"]}
    "unknown-context" => {action: "withhold-pass", choice_id: (if (worker-summary [] "mimo-v2.5" null null 1 1 false).context_percent == null { "unknown" } else { "wrong" }), reason_codes: ["unknown_evidence"]}
    "grep-verification" => {action: "record", choice_id: (if (telemetry-verification-command {type: "tool_use", part: {tool: "bash", state: {input: {command: "grep -qxF AFTER fixture.txt"}}}}) { "recognized" } else { "wrong" }), reason_codes: ["verification_activity"]}
    "telemetry-order" => {action: "record", choice_id: (if (let started = (date now); let ms = ((($started | into int) / 1000000) | math round | into int); let rows = (telemetry-derived [{type: "tool_use", timestamp: ($ms + 3000), part: {tool: "bash", state: {status: "completed", input: {command: "cargo test"}}}} {type: "tool_use", timestamp: ($ms + 2000), part: {tool: "edit", state: {status: "completed", input: {filePath: "a"}}}}] $started ($started + 4sec)).records; $rows.1.t == 2.0) { "ordered" } else { "wrong" }), reason_codes: ["chronological"]}
    "live-cancel-proof" => {action: "preserve-state", choice_id: (if (worker-summary [] "mimo-v2.5" null null 1 130 false true).status == "cancelled" { "cancelled" } else { "wrong" }), reason_codes: ["live_cancel_evidence"]}
    "live-timeout-proof" => {action: "preserve-state", choice_id: (if (worker-summary [] "mimo-v2.5" null null 1 124 true false).status == "timed_out" { "timed_out" } else { "wrong" }), reason_codes: ["live_timeout_evidence"]}
    _ => {action: "reject", choice_id: "wrong", reason_codes: ["unknown_case"]}
})
$decision | insert case_id $request.case_id | insert schema "telltail.decision.v1" | to json -r
