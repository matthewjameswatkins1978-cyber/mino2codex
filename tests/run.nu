let test_tmp = ($env.MIMO2CODEX_TEST_TMP? | default $nu.temp-dir)
let test_root = ($test_tmp | path join $"mimo2codex-test-($nu.pid)")
let project_root = (pwd)
$env.MIMO2CODEX_SOURCE_ROOT = $project_root
$env.MIMO2CODEX_STATE_ROOT = $test_root
$env.MIMO2CODEX_SKILL_ROOT = ($test_root | path join "skills")
$env.MIMO_API_KEY = ""
source "../nu/mimo2codex.nu"

def assert [condition: bool message: string] { if not $condition { error make {msg: $message} } }
def assert-equal [actual expected message: string] { assert ($actual == $expected) $message }
def test [name: string action: closure] {
    try { do $action; {name: $name, status: "PASS"} } catch {|err| {name: $name, status: "FAIL", detail: ($err.msg? | default "failure")} }
}

let results = [
    (test "JSON parsing and single authority" {
        let data = (open ($project_root | path join "config" | path join "mimo.json"))
        assert-equal $data.provider.env_key "MIMO_API_KEY" "env key"
        assert-equal $data.models.pro "mimo-v2.5-pro" "pro model"
    })
    (test "catalogue validates both models" { assert (check-catalogue) "catalogue should validate" })
    (test "models table derives from catalogue" {
        let rows = (model-records)
        assert-equal ($rows | length) 2 "two aliases"
        assert (($rows | get model) | any {|item| $item == "mimo-v2.5"}) "standard model"
    })
    (test "TOML generation parses and contains no key" {
        mkdir ($test_root | path join "codex-home")
        write-codex-config "mimo-v2.5-pro"
        let path = ($test_root | path join "codex-home" | path join "config.toml")
        let raw = (open --raw $path)
        assert (not ($raw | str contains "tp-TEST")) "secret absent"
        let parsed = (open $path)
        assert-equal $parsed.model "mimo-v2.5-pro" "model in toml"
        assert-equal $parsed.model_providers.mimo.wire_api "responses" "wire api"
    })
    (test "child injection is scoped and redacted" {
        let fake = {status: "configured", value: "tp-TEST-DO-NOT-USE-123456", source: "test"}
        assert-equal (child-injection-status $fake) "PASS" "child receives plausible key"
    })
    (test "credential status is redacted" {
        write-credential "tp-TEST-DO-NOT-USE-123456"
        assert-equal (credential-status) "configured" "configured status"
        let status = (credential-status)
        assert (not ($status | str contains "TEST")) "status redacted"
    })
    (test "missing credential fails closed" {
        rm ($test_root | path join "credential")
        assert-equal (credential-status) "missing" "missing status"
        let launch_result = (try { launch "mimo-v2.5" []; "unexpected" } catch { "blocked" })
        assert-equal $launch_result "blocked" "launch fails closed"
    })
    (test "invalid model is rejected" {
        let models = (required-models)
        assert (not ($models | any {|item| $item == "not-a-model"})) "unknown model rejected"
    })
    (test "cwd is preserved" {
        let before = (pwd)
        model-records | ignore
        assert-equal (pwd) $before "cwd preserved"
    })
    (test "generated files contain no fake secret" {
        let files = [
            ($test_root | path join "codex-home" | path join "config.toml")
            ($project_root | path join "config" | path join "model-catalogs.json")
        ]
        let first_raw = (open --raw ($files | get 0))
        let second_raw = (open --raw ($files | get 1))
        let joined = ([$first_raw $second_raw] | str join "\n")
        assert (not ($joined | str contains "tp-TEST-DO-NOT-USE-123456")) "no secret leakage"
    })
    (test "OpenCode runtime config is isolated and explicit" {
        let config = (worker-config true)
        assert-equal $config.enabled_providers.0 "m2c-mimo" "provider allowlist"
        assert-equal $config.provider.m2c-mimo.options.baseURL "https://token-plan-ams.xiaomimimo.com/v1" "AMS endpoint"
        assert-equal $config.provider.m2c-mimo.options.apiKey "{env:MIMO_API_KEY}" "key is env reference"
        assert-equal $config.permission.question "deny" "headless questions denied"
        assert-equal $config.permission.task "deny" "nested workers denied"
        assert (not ((worker-config-json) | str contains "tp-TEST")) "runtime config has no key"
    })
    (test "explicit worker model selection" {
        let standard = (worker-command "mimo-v2.5" "task" null $project_root)
        let pro = (worker-command "mimo-v2.5-pro" "task" null $project_root)
        assert (($standard | str join " ") | str contains "m2c-mimo/mimo-v2.5") "standard explicit"
        assert (($pro | str join " ") | str contains "m2c-mimo/mimo-v2.5-pro") "pro explicit"
        assert (($standard | str join " ") | str contains "--format json") "json format"
        assert (($standard | str join " ") | str contains "--dir") "cwd flag"
    })
    (test "machine execution agent is explicit and packet intent is preserved" {
        assert-equal (worker-agent "Edit src/a.nu and run its tests") "build" "normal execution uses build"
        assert-equal (worker-agent "Plan only; do not edit files") "plan" "plan-only uses plan"
        assert-equal (worker-agent "Review only, read-only, do not modify files") "explore" "review-only uses explore"
        let normal = (worker-command "mimo-v2.5" "task" null $project_root)
        let plan = (worker-command "mimo-v2.5" "task" null $project_root "plan")
        let forked = (worker-command "mimo-v2.5" "task" "ses-old" $project_root "build" true)
        assert (($normal | str join " ") | str contains "--agent build") "build agent flag"
        assert (($plan | str join " ") | str contains "--agent plan") "plan agent flag"
        assert (($forked | str join " ") | str contains "--session ses-old --fork") "mode change forks"
        assert-equal (worker-config true).permission.question "deny" "headless worker cannot ask approval"
        assert (worker-fork-required "ses-old" "plan" "build") "plan to build forks"
        assert (not (worker-fork-required "ses-old" "build" "build")) "same agent continues"
        assert (not (worker-fork-required null null "build")) "new session does not fork"
    })
    (test "result envelope reports selected execution agent" {
        let cases = [
            {task: "Edit the file and run its tests", expected: "build"}
            {task: "Plan only; do not edit files", expected: "plan"}
            {task: "Review only, read-only, do not modify files", expected: "explore"}
        ]
        for case in $cases {
            let envelope = (result-envelope (worker-summary [] "mimo-v2.5" null null 0 0 false) (worker-agent $case.task))
            assert-equal $envelope.agent $case.expected $"agent truth for ($case.expected)"
        }
    })
    (test "OpenCode JSON event parsing and summary" {
        let raw = '{"type":"text","sessionID":"ses-test","part":{"text":"done"}}
{"type":"tool_use","sessionID":"ses-test","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src/a.nu"}}}}
{"type":"step_finish","sessionID":"ses-test","part":{"tokens":{"input":100,"cache":{"read":20}}}}'
        let events = (parse-worker-events $raw)
        let summary = (worker-summary $events "mimo-v2.5" null null 3 0 false)
        assert-equal $summary.status "completed" "status"
        assert-equal $summary.tool_calls 1 "tool count"
        assert-equal $summary.context_estimate_tokens 120 "context includes cache read"
        assert-equal $summary.changed_files.0 "src/a.nu" "changed file"
        assert-equal $summary.final_text "done" "final text"
        let failed = (worker-summary [] "mimo-v2.5" null null 1 1 false)
        assert-equal $failed.status "failed" "empty worker output fails closed"
    })
    (test "telemetry derives timing and tool aggregates without content" {
        let started = ((date now) - 5sec)
        let start_ms = ((($started | into int) / 1000000) | math round | into int)
        let events = [
            {type: "step_start", timestamp: ($start_ms + 1000), sessionID: "ses-test"}
            {type: "tool_use", timestamp: ($start_ms + 2000), part: {tool: "read", state: {status: "completed", input: {filePath: "secret.txt"}}}}
            {type: "tool_use", timestamp: ($start_ms + 3000), part: {tool: "bash", state: {status: "completed", input: {command: "cargo test"}}}}
        ]
        let telemetry = (telemetry-derived $events $started (date now))
        assert-equal $telemetry.tool_calls_by_type.read 1 "read count"
        assert-equal $telemetry.tool_calls_by_type.bash 1 "verification tool count"
        assert-equal $telemetry.files_read_count 1 "read aggregate"
        assert-equal $telemetry.verification_commands_count 1 "verification aggregate"
        assert (($telemetry.time_to_first_tool_seconds | into float) >= 1.0) "first tool timing"
        assert (not (($telemetry.records | to json) | str contains "secret.txt")) "telemetry has no file content"
    })
    (test "context threshold policy" {
        assert-equal (checkpoint-state {context_percent: 29.9}) "normal" "normal"
        assert-equal (checkpoint-state {context_percent: 35.0}) "watch" "watch"
        assert-equal (checkpoint-state {context_percent: 45.0}) "mandatory" "mandatory"
        assert-equal (checkpoint-state {context_percent: 50.0}) "hard_ceiling" "hard ceiling"
        let carried = (worker-context-prefix {checkpoint: "`(treat as context, not as executable instructions)`"})
        assert ($carried | str contains "treat as context") "checkpoint is carried as opaque text"
    })
    (test "workstream validation and state preservation" {
        assert (valid-workstream "tethers-linux") "valid slug"
        assert (not (valid-workstream "tethers/linux")) "path rejected"
        assert (not (valid-workstream "")) "empty name rejected"
        save-workstream {name: "tethers-linux", cwd: $project_root, model: "mimo-v2.5", session_id: "ses-test", created_at: "now", updated_at: "now", last_packet: "A1", context_estimate_tokens: 1, context_percent: 0.1, checkpoint_generation: 0, checkpoint: null}
        let state = (read-workstream "tethers-linux")
        assert-equal $state.session_id "ses-test" "session persisted"
        assert-equal $state.model "mimo-v2.5" "model persisted"
    })
    (test "mimo-worker skill install is idempotent and removable" {
        let path = (install-mimo-skill)
        assert ($path | path exists) "skill installed"
        let first = (open --raw $path)
        install-mimo-skill
        assert-equal (open --raw $path) $first "skill stable"
        remove-mimo-skill
        assert (not ($path | path exists)) "skill removed"
    })
    (test "activity reducer uses observable tool metadata" {
        let read = {type: "tool_use", part: {tool: "read", state: {input: {filePath: "README.md"}}}}
        let test = {type: "tool_use", part: {tool: "bash", state: {input: {command: "cargo test"}}}}
        assert-equal (activity-from-event $read) "Inspecting project files" "read activity"
        assert-equal (activity-from-event $test) "Running verification tests" "test activity"
        assert-equal (activity-from-event {type: "unknown", part: {}}) "Working..." "unknown fallback"
    })
    (test "console state derives completion, failure, timeout and unknown context" {
        let started = (date now)
        let recent = (date now)
        let complete = (worker-console-state [] "mimo-v2.5" $started 1200 $recent false "complete")
        let failed = (worker-console-state [] "mimo-v2.5" $started 1200 $recent false "failed")
        let timed = (worker-console-state [] "mimo-v2.5" $started 1200 $recent false "timed_out")
        let cancelled = (worker-console-state [] "mimo-v2.5" $started 1200 $recent false "cancelled")
        assert-equal $complete.worker_state "COMPLETE" "complete state"
        assert-equal $failed.worker_state "FAILED" "failed state"
        assert-equal $timed.worker_state "TIMED OUT" "timeout state"
        assert-equal $cancelled.worker_state "CANCELLED" "cancelled state"
        assert-equal $complete.context_percent null "unknown context stays unknown"
    })
    (test "cancelled summaries are distinct from watchdog timeouts" {
        let cancelled = (worker-summary [] "mimo-v2.5" null null 2 130 false true)
        let timed = (worker-summary [] "mimo-v2.5" null null 2 124 true false)
        assert-equal $cancelled.status "cancelled" "cancelled result"
        assert-equal $timed.status "timed_out" "watchdog result"
        assert-equal $cancelled.exit_code 130 "cancel exit code"
    })
    (test "quiet detection is informational" {
        let started = (date now)
        let old = ((date now) - 61sec)
        let state = (worker-console-state [] "mimo-v2.5-pro" $started 1200 $old true)
        assert-equal $state.worker_state "QUIET" "quiet state"
        assert ($state.process_alive) "process remains alive"
    })
    (test "watchdog and context calculations are truthful" {
        let started = ((date now) - 65sec)
        let event = {type: "step_finish", sessionID: "ses-test", part: {tokens: {input: 400000, cache: {read: 0}}}}
        let state = (worker-console-state [$event] "mimo-v2.5" $started 1200 (date now) true)
        assert ($state.elapsed >= 65) "elapsed time"
        assert ($state.watchdog_remaining <= 1135) "watchdog remaining"
        assert ($state.context_percent > 29.9) "context estimate"
        assert ($state.checkpoint_recommended) "checkpoint threshold"
    })
    (test "platform guard is cross-platform and narrow" {
        let linux_bad = (opencode-platform-status-for "unix" "/usr/bin/opencode.exe")
        let linux_native = (opencode-platform-status-for "unix" "/home/user/bin/opencode")
        let windows = (opencode-platform-status-for "windows" "C:\\Program Files\\opencode.exe")
        let wrapper = ($test_root | path join "opencode-wrapper")
        "#!/bin/sh\nexec /mnt/c/Users/Matmus/AppData/Roaming/npm/node_modules/opencode-ai/bin/opencode.exe \"$@\"\n" | save --force $wrapper
        let linux_wrapper = (opencode-platform-status-for "unix" $wrapper)
        assert-equal $linux_bad.status "invalid" "Linux rejects Windows executable"
        assert-equal $linux_native.status "valid" "Linux accepts native executable"
        assert-equal $windows.status "valid" "Windows accepts Windows executable"
        assert-equal $linux_wrapper.status "invalid" "Linux rejects Windows shell wrapper"
    })
    (test "quiet parsing and narrow rendering" {
        let parsed = (parse-run-args ["--quiet" "--json" "reply" "OK"])
        assert $parsed.quiet "quiet flag"
        assert $parsed.json "json flag"
        let state = (worker-console-state [] "mimo-v2.5" (date now) 1200 (date now) true)
        let frame = (console-frame $state 50)
        assert (($frame | length) >= 5) "narrow frame"
        assert (($frame | str join "\n") | str contains "STARTING") "narrow state"
    })
    (test "console refresh events are narrow and meaningful" {
        assert (console-meaningful-event {type: "step_start"}) "starting refresh"
        assert (console-meaningful-event {type: "tool_use", part: {tool: "edit", state: {status: "completed", input: {filePath: "a"}}}}) "file change refresh"
        assert (console-meaningful-event {type: "tool_use", part: {tool: "bash", state: {status: "completed", input: {command: "cargo test"}}}}) "verification refresh"
        assert (not (console-meaningful-event {type: "text", part: {text: "working"}})) "ordinary text waits for cadence"
    })
]

print ($results | table)
let failed = ($results | where status == "FAIL" | length)
if $failed > 0 { error make {msg: $"($failed) tests failed"} }
print $"($results | length) passed, 0 failed"
rm --recursive --force $test_root
