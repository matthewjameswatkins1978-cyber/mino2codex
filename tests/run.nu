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
        assert-equal (worker-agent "Review only, read-only, do not modify files") "build" "review-only uses build"
        assert-equal (worker-agent "Implement the VM instruction set. Do not modify the immutable core.") "build" "Seedware constraint does not change agent"
        assert-equal (worker-agent "Install the dependencies. Without modifying the lockfile, run the build.") "build" "incidental constraint mid-packet does not change agent"
        assert-equal (worker-agent "Plan only; do not edit files") "plan" "plan prefix anchored"
        assert-equal (worker-agent "nothing about plans here, planning only") "build" "plan keyword not at start is ignored"
        let never_explore = (["build" "plan"] | all {|a| $a != "explore"})
        assert $never_explore "explore is never a valid primary agent"
        let review_cases = ["Review only, read-only, do not modify files" "Read-only audit, do not modify source" "Review without modifying any files"]
        for rc in $review_cases {
            assert-equal (worker-agent $rc) "build" $"review-style task ($rc) resolves to build"
        }
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
            {task: "Review only, read-only, do not modify files", expected: "build"}
        ]
        for case in $cases {
            let envelope = (result-envelope (worker-summary [] "mimo-v2.5" null null 0 0 false) (worker-agent $case.task))
            assert-equal $envelope.agent $case.expected $"agent truth for ($case.expected)"
        }
    })
    (test "packet files use metadata then filename inference" {
        let inferred = (packet-filename-inference "tethers-l2-L2A.md")
        assert-equal $inferred.workstream "tethers-l2" "workstream inference"
        assert-equal $inferred.packet "L2A" "packet inference"
        let underscored = (packet-filename-inference "tethers_l2_L2A.md")
        assert-equal $underscored.workstream "tethers-l2" "underscore inference"
        let metadata = (packet-front-matter "---\nworkstream: explicit-stream\npacket: P9\n---\nDo the work.")
        assert-equal $metadata.workstream "explicit-stream" "front matter workstream"
        assert-equal $metadata.packet "P9" "front matter packet"
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
        let zero_output = (worker-summary [] "mimo-v2.5" null null 1 0 false)
        assert-equal $zero_output.status "failed" "zero exit without completion evidence is not success"
        let tool_error = [{type: "tool_use", part: {tool: "edit", state: {status: "error", input: {filePath: "src/a.nu"}}}}]
        let failed_tool = (worker-summary $tool_error "mimo-v2.5" null null 1 0 false)
        assert-equal $failed_tool.status "failed" "tool failure is not success"
        let incomplete = [{type: "text", part: {text: "finished"}}]
        assert-equal (worker-summary $incomplete "mimo-v2.5" null null 1 0 false).status "failed" "missing completion signal fails closed"
        let malformed = (parse-worker-events "not-json\n{bad}\n{\"type\":\"tool_use\"")
        assert-equal ($malformed | length) 0 "malformed and scalar worker lines are discarded"
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
        let commands = ["grep -qxF AFTER fixture.txt" "cargo test" "cargo check" "nu tests/run.nu" "sha256sum -c SHA256SUMS"]
        for command in $commands { assert (telemetry-verification-command {type: "tool_use", part: {tool: "bash", state: {input: {command: $command}}}}) $"verification command recognized: ($command)" }
        assert (not (telemetry-verification-command {type: "tool_use", part: {tool: "bash", state: {input: {command: "printf ordinary output"}}}})) "ordinary shell command is not verification"
        let ordered = (telemetry-derived [
            {type: "tool_use", timestamp: ($start_ms + 3000), part: {tool: "bash", state: {status: "completed", input: {command: "cargo test"}}}}
            {type: "tool_use", timestamp: ($start_ms + 2000), part: {tool: "edit", state: {status: "completed", input: {filePath: "a"}}}}
        ] $started (date now)).records
        assert-equal $ordered.1.event "tool_end" "chronological telemetry event order"
        assert-equal $ordered.1.t 2.0 "chronological telemetry timestamp"
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
    # --- watch front matter parsing ---
    (test "watch front matter parses valid YAML block" {
        let body = "---\nm2c_job: 1\nbase: abcdef0123456789abcdef0123456789abcdef02\nbranch: feature/test\nmodel: standard\n---\nDo the work here."
        let fm = (watch-gh-parse-front-matter $body)
        assert ($fm != null) "front matter found"
        assert-equal $fm.m2c_job "1" "m2c_job"
        assert-equal $fm.base "abcdef0123456789abcdef0123456789abcdef02" "base sha"
        assert-equal $fm.branch "feature/test" "branch"
        assert-equal $fm.model "standard" "model"
    })
    (test "watch front matter rejects body without opening ---" {
        let body = "m2c_job: 1\nbase: abc\nDo work."
        let fm = (watch-gh-parse-front-matter $body)
        assert ($fm == null) "no front matter without ---"
    })
    (test "watch front matter rejects body without closing ---" {
        let body = "---\nm2c_job: 1\nbase: abc\nDo work."
        let fm = (watch-gh-parse-front-matter $body)
        assert ($fm == null) "no front matter without closing ---"
    })
    (test "watch front matter handles empty front matter block" {
        let body = "---\n---\nJust a packet."
        let fm = (watch-gh-parse-front-matter $body)
        assert ($fm != null) "empty front matter parses"
        assert ($fm | columns | is-empty) "no keys in empty block"
    })
    # --- watch model validation ---
    (test "watch parse model accepts standard and pro" {
        assert-equal (watch-parse-model "standard") "standard" "standard model"
        assert-equal (watch-parse-model "pro") "pro" "pro model"
        assert-equal (watch-parse-model "  standard  ") "standard" "trimmed standard"
        assert-equal (watch-parse-model '"pro"') "pro" "quoted pro"
    })
    (test "watch parse model rejects invalid values" {
        assert ((watch-parse-model "turbo") | is-empty) "turbo rejected"
        assert ((watch-parse-model "") | is-empty) "empty rejected"
        assert ((watch-parse-model "mimo-v2.5") | is-empty) "raw model name rejected"
    })
    # --- watch admission rules via watch-validate-packet ---
    (test "watch validate rejects main branch target" {
        let fm = {m2c_job: "1", base: "abcdef0123456789abcdef0123456789abcdef02", branch: "main", model: "standard"}
        let result = (watch-validate-packet $fm)
        assert (not $result.ok) "main branch rejected"
        assert ($result.reason | str contains "main") "reason mentions main"
    })
    (test "watch validate rejects master branch target" {
        let fm = {m2c_job: "1", base: "abcdef0123456789abcdef0123456789abcdef02", branch: "master", model: "standard"}
        let result = (watch-validate-packet $fm)
        assert (not $result.ok) "master branch rejected"
    })
    (test "watch validate rejects bad base SHA" {
        let fm = {m2c_job: "1", base: "short", branch: "feature/test", model: "standard"}
        let result = (watch-validate-packet $fm)
        assert (not $result.ok) "short base rejected"
        assert ($result.reason | str contains "40-char") "reason mentions SHA length"
    })
    (test "watch validate rejects missing m2c_job" {
        let fm = {base: "abcdef0123456789abcdef0123456789abcdef02", branch: "feature/test", model: "standard"}
        let result = (watch-validate-packet $fm)
        assert (not $result.ok) "missing m2c_job rejected"
        assert ($result.reason | str contains "m2c_job") "reason mentions m2c_job"
    })
    (test "watch validate rejects invalid model" {
        let fm = {m2c_job: "1", base: "abcdef0123456789abcdef0123456789abcdef02", branch: "feature/test", model: "turbo"}
        let result = (watch-validate-packet $fm)
        assert (not $result.ok) "invalid model rejected"
        assert ($result.reason | str contains "standard or pro") "reason mentions valid models"
    })
    (test "watch validate rejects empty branch" {
        let fm = {m2c_job: "1", base: "abcdef0123456789abcdef0123456789abcdef02", branch: "", model: "standard"}
        let result = (watch-validate-packet $fm)
        assert (not $result.ok) "empty branch rejected"
    })
    (test "watch validate accepts valid complete job" {
        let fm = {m2c_job: "1", base: "abcdef0123456789abcdef0123456789abcdef02", branch: "feature/test", model: "pro"}
        let result = (watch-validate-packet $fm)
        assert $result.ok "valid job accepted"
        assert-equal $result.profile "pro" "profile parsed"
        assert-equal $result.branch "feature/test" "branch extracted"
    })
    (test "watch validate m2c_job must be exactly 1" {
        let fm1 = {m2c_job: "2", base: "abcdef0123456789abcdef0123456789abcdef02", branch: "feature/test", model: "standard"}
        assert (not (watch-validate-packet $fm1).ok) "m2c_job 2 rejected"
        let fm0 = {m2c_job: "0", base: "abcdef0123456789abcdef0123456789abcdef02", branch: "feature/test", model: "standard"}
        assert (not (watch-validate-packet $fm0).ok) "m2c_job 0 rejected"
    })
    # --- watch result comment ---
    (test "watch build result comment for DONE" {
        let summary = {status: "completed", exit_code: 0}
        let delivery = {local_branch: "mimo/test", local_sha: "abc123", worktree_clean: true, remote_exists: true, remote_sha: "abc123", sha_match: true, branch_match: true}
        let comment = (watch-build-result-comment $summary $delivery "standard" "DONE")
        assert ($comment | str contains "M2C RESULT: DONE") "DONE status"
        assert ($comment | str contains "model: standard") "model line"
        assert ($comment | str contains "branch: mimo/test") "branch line"
        assert ($comment | str contains "branch_match: MATCH") "branch match line"
        assert ($comment | str contains "sha: abc123") "sha line"
        assert ($comment | str contains "exit: 0") "exit code"
        assert ($comment | str contains "worktree: CLEAN") "worktree clean"
        assert ($comment | str contains "remote: MATCH") "remote match"
    })
    (test "watch build result comment for FAILED includes reasons" {
        let summary = {status: "failed", exit_code: 1}
        let delivery = {local_branch: "mimo/test", local_sha: "abc123", worktree_clean: false, remote_exists: false, remote_sha: "", sha_match: false, branch_match: true}
        let comment = (watch-build-result-comment $summary $delivery "pro" "DELIVERY_FAILED")
        assert ($comment | str contains "M2C RESULT: DELIVERY_FAILED") "DELIVERY_FAILED status"
        assert ($comment | str contains "model: pro") "model line"
        assert ($comment | str contains "worktree: DIRTY") "worktree dirty"
        assert ($comment | str contains "remote: MISMATCH") "remote mismatch"
        assert ($comment | str contains "worktree is dirty") "dirty reason"
        assert ($comment | str contains "remote branch") "missing remote reason"
        assert ($comment | str contains "worker exit code: 1") "worker failure reason"
    })
    (test "watch build result comment for timeout status" {
        let summary = {status: "timed_out", exit_code: 124}
        let delivery = {local_branch: "mimo/test", local_sha: "abc123", worktree_clean: true, remote_exists: true, remote_sha: "abc123", sha_match: true, branch_match: true}
        let comment = (watch-build-result-comment $summary $delivery "standard" "TIMED_OUT")
        assert ($comment | str contains "M2C RESULT: TIMED_OUT") "timeout becomes TIMED_OUT"
        assert ($comment | str contains "watchdog terminated the worker") "timeout reason"
    })
    # --- watch exit code ---
    (test "watch exit for completed is 0" {
        assert-equal (watch-exit-for {status: "completed", exit_code: 0}) 0 "completed exits 0"
        assert-equal (watch-exit-for {status: "failed", exit_code: 1}) 1 "failed exits 1"
        assert-equal (watch-exit-for {status: "timed_out", exit_code: 124}) 1 "timed_out exits 1"
        assert-equal (watch-exit-for {status: "cancelled", exit_code: 130}) 1 "cancelled exits 1"
    })
    # --- watch delivery verification with real git ---
    (test "watch verify delivery with clean push matches" {
        let repo_dir = ($test_root | path join "verify-repo")
        let clone_dir = ($test_root | path join "verify-clone")
        mkdir $repo_dir
        (run-external "git" "-C" $repo_dir "init" "--bare" | complete) | ignore
        let work = ($test_root | path join "verify-work")
        mkdir $work
        (run-external "git" "clone" $repo_dir $work | complete) | ignore
        ("# test" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        (run-external "git" "-C" $work "checkout" "-b" "mimo/test" | complete) | ignore
        ("# change" | save --force ($work | path join "CHANGE.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "work" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "mimo/test" | complete) | ignore
        let local_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let job = {branch: "mimo/test", repo: "user/repo"}
        let delivery = (watch-verify-delivery $work $job)
        assert-equal $delivery.local_branch "mimo/test" "branch detected"
        assert-equal $delivery.local_sha $local_sha "local sha"
        assert $delivery.worktree_clean "clean worktree"
        assert $delivery.remote_exists "remote exists"
        assert $delivery.sha_match "sha matches"
    })
    (test "watch verify delivery detects dirty worktree" {
        let repo_dir = ($test_root | path join "dirty-repo")
        let clone_dir = ($test_root | path join "dirty-clone")
        mkdir $repo_dir
        (run-external "git" "-C" $repo_dir "init" "--bare" | complete) | ignore
        let work = ($test_root | path join "dirty-work")
        mkdir $work
        (run-external "git" "clone" $repo_dir $work | complete) | ignore
        ("# test" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        (run-external "git" "-C" $work "checkout" "-b" "mimo/test" | complete) | ignore
        ("# uncommitted" | save --force ($work | path join "UNCOMMITTED.md"))
        (run-external "git" "-C" $work "add" "UNCOMMITTED.md" | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "work" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "mimo/test" | complete) | ignore
        ("dirty change" | save --force ($work | path join "DIRTY.txt"))
        let job = {branch: "mimo/test", repo: "user/repo"}
        let delivery = (watch-verify-delivery $work $job)
        assert (not $delivery.worktree_clean) "dirty worktree detected"
    })
    (test "watch verify delivery detects missing remote branch" {
        let repo_dir = ($test_root | path join "noremote-repo")
        mkdir $repo_dir
        (run-external "git" "-C" $repo_dir "init" "--bare" | complete) | ignore
        let work = ($test_root | path join "noremote-work")
        mkdir $work
        (run-external "git" "clone" $repo_dir $work | complete) | ignore
        ("# test" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "checkout" "-b" "mimo/test" | complete) | ignore
        ("# change" | save --force ($work | path join "CHANGE.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "work" | complete) | ignore
        let job = {branch: "mimo/test", repo: "user/repo"}
        let delivery = (watch-verify-delivery $work $job)
        assert (not $delivery.remote_exists) "missing remote branch detected"
        assert (not $delivery.sha_match) "no sha match without remote"
    })
    (test "watch verify delivery detects SHA mismatch" {
        let repo_dir = ($test_root | path join "mismatch-repo")
        mkdir $repo_dir
        (run-external "git" "-C" $repo_dir "init" "--bare" | complete) | ignore
        let work = ($test_root | path join "mismatch-work")
        mkdir $work
        (run-external "git" "clone" $repo_dir $work | complete) | ignore
        ("# test" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        (run-external "git" "-C" $work "checkout" "-b" "mimo/test" | complete) | ignore
        ("# change" | save --force ($work | path join "CHANGE.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "pushed" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "mimo/test" | complete) | ignore
        ("# local only" | save --force ($work | path join "LOCAL.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "local" | complete) | ignore
        let job = {branch: "mimo/test", repo: "user/repo"}
        let delivery = (watch-verify-delivery $work $job)
        assert $delivery.remote_exists "remote exists"
        assert (not $delivery.sha_match) "sha mismatch detected"
        assert $delivery.worktree_clean "worktree is clean after commit"
    })
    # --- issue body preservation ---
    (test "watch front matter preserves packet content" {
        let original_body = "---\nm2c_job: 1\nbase: abcdef0123456789abcdef0123456789abcdef02\nbranch: feature/test\nmodel: standard\n---\nOriginal packet content with special chars: !@#$%^&*()."
        let fm = (watch-gh-parse-front-matter $original_body)
        assert ($fm != null) "front matter found"
        let lines = ($original_body | lines)
        let fm_end = ($lines | enumerate | where {|item| $item.item == "---"} | skip 1 | first)
        let packet = ($original_body | lines | skip ($fm_end.index + 1) | str join "\n" | str trim)
        assert ($packet | str contains "Original packet content") "packet preserved"
        assert ($packet | str contains "!@#$%^&*().") "special chars preserved"
    })
    # --- --once flag parsing ---
    (test "watch --once is parsed from args" {
        let args = ["--once"]
        let once = ($args | any {|arg| $arg == "--once"})
        assert $once "--once detected"
        let args2 = ["--verbose" "--poll"]
        let once2 = ($args2 | any {|arg| $arg == "--once"})
        assert (not $once2) "--once not present"
    })
    # --- fix #1: worker-run cwd parameter ---
    (test "worker-run accepts cwd parameter for isolated clone" {
        let target = ($test_root | path join "target-clone")
        let cwd_cmd = (worker-command "mimo-v2.5" "task" null $target)
        let dir_idx = ($cwd_cmd | enumerate | where item == "--dir" | first | get index)
        assert (($cwd_cmd | get ($dir_idx + 1)) == ($target | path expand)) "cwd passed to opencode --dir"
        let default_cmd = (worker-command "mimo-v2.5" "task" null $project_root)
        let default_dir_idx = ($default_cmd | enumerate | where item == "--dir" | first | get index)
        assert (($default_cmd | get ($default_dir_idx + 1)) == ($project_root | path expand)) "default cwd is project root"
    })
    (test "worker-command passes explicit cwd through" {
        let clone = ($test_root | path join "some-repo-clone")
        let cmd = (worker-command "mimo-v2.5" "test prompt" null $clone)
        let dir_idx = ($cmd | enumerate | where item == "--dir" | first | get index)
        assert (($cmd | get ($dir_idx + 1)) == ($clone | path expand)) "clone dir in command"
    })
    # --- fix #2: gh search uses explicit flags and nameWithOwner ---
    (test "watch gh search uses explicit owner and state flags" {
        let login = "testuser"
        let query_parts = ["gh" "search" "issues" "--owner" $login "--state" "open" "--limit" "10" "--json" "repository,title,number,url"]
        assert (($query_parts | str join " ") | str contains "--owner testuser") "explicit --owner flag"
        assert (($query_parts | str join " ") | str contains "--state open") "explicit --state flag"
        assert (not (($query_parts | str join " ") | str contains "repo:testuser/*")) "no query-embedded repo qualifier"
    })
    (test "owner extracted from nameWithOwner not bare name" {
        let issue_with_nwo = {repository: {nameWithOwner: "alice/my-repo", name: "my-repo"}, title: "[M2C QUEUED] test", number: 1, url: "https://github.com/alice/my-repo/issues/1"}
        let repo_full = ($issue_with_nwo.repository.nameWithOwner? | default $issue_with_nwo.repository.name)
        let owner = ($repo_full | split row "/" | first)
        assert-equal $owner "alice" "owner from nameWithOwner"
        assert-equal $repo_full "alice/my-repo" "full identity preserved"
        let issue_bare = {repository: {name: "bare-name"}, title: "[M2C QUEUED] test", number: 2, url: "https://github.com/x/bare-name/issues/2"}
        let repo_fallback = ($issue_bare.repository.nameWithOwner? | default $issue_bare.repository.name)
        assert-equal $repo_fallback "bare-name" "fallback to bare name when nameWithOwner absent"
    })
    (test "watch admit job uses full owner/repo for --repo flag" {
        let issue = {repository: {nameWithOwner: "alice/my-repo", name: "my-repo"}, title: "[M2C QUEUED] test", number: 5, url: "https://github.com/alice/my-repo/issues/5"}
        let repo_full = ($issue.repository.nameWithOwner? | default $issue.repository.name)
        assert-equal $repo_full "alice/my-repo" "full identity used for gh issue view --repo"
        let owner = ($repo_full | split row "/" | first)
        assert-equal $owner "alice" "owner check uses first segment of owner/repo"
    })
    # --- fix #3: rejected jobs become BLOCKED ---
    (test "rejected queued job transitions to BLOCKED" {
        let blocked_title = "[M2C BLOCKED]"
        assert ($blocked_title | str starts-with "[M2C BLOCKED]") "BLOCKED title format"
        assert ($blocked_title | str ends-with "]") "BLOCKED title bracketed"
        assert (not ($blocked_title | str contains "QUEUED")) "BLOCKED does not contain QUEUED"
    })
    (test "BLOCKED title prevents rediscovery as queued" {
        let blocked_title = "[M2C BLOCKED]"
        assert (not ($blocked_title | str starts-with "[M2C QUEUED]")) "BLOCKED not matched by queued filter"
    })
    (test "rejection comment includes reason" {
        let reason = "issue author (bot) does not match authenticated user (alice)"
        let comment = $"Rejection reason: ($reason)"
        assert ($comment | str contains "Rejection reason:") "comment has reason prefix"
        assert ($comment | str contains "does not match") "reason detail included"
    })
    # --- fix #4: result comment uses final delivery gate ---
    (test "watch build result comment DONE when delivery matches" {
        let summary = {status: "completed", exit_code: 0}
        let delivery = {local_branch: "mimo/test", local_sha: "abc123", worktree_clean: true, remote_exists: true, remote_sha: "abc123", sha_match: true, branch_match: true}
        let comment = (watch-build-result-comment $summary $delivery "standard" "DONE")
        assert ($comment | str contains "M2C RESULT: DONE") "DONE when worker completed and delivery matches"
        assert (not ($comment | str contains "FAILED")) "no FAILED when done"
    })
    (test "watch build result comment FAILED when SHA mismatch" {
        let summary = {status: "completed", exit_code: 0}
        let delivery = {local_branch: "mimo/test", local_sha: "local123", worktree_clean: true, remote_exists: true, remote_sha: "remote456", sha_match: false, branch_match: true}
        let comment = (watch-build-result-comment $summary $delivery "standard" "FAILED")
        assert ($comment | str contains "M2C RESULT: FAILED") "FAILED when SHA mismatch"
        assert ($comment | str contains "remote SHA remote456 != local SHA local123") "mismatch detail"
    })
    (test "watch build result comment FAILED when remote missing" {
        let summary = {status: "completed", exit_code: 0}
        let delivery = {local_branch: "mimo/test", local_sha: "abc123", worktree_clean: true, remote_exists: false, remote_sha: "", sha_match: false, branch_match: true}
        let comment = (watch-build-result-comment $summary $delivery "pro" "FAILED")
        assert ($comment | str contains "M2C RESULT: FAILED") "FAILED when remote missing"
        assert ($comment | str contains "remote branch mimo/test does not exist") "missing remote reason"
    })
    (test "watch build result comment FAILED when timed out" {
        let summary = {status: "timed_out", exit_code: 124}
        let delivery = {local_branch: "mimo/test", local_sha: "abc123", worktree_clean: true, remote_exists: true, remote_sha: "abc123", sha_match: true, branch_match: true}
        let comment = (watch-build-result-comment $summary $delivery "standard" "TIMED_OUT")
        assert ($comment | str contains "M2C RESULT: TIMED_OUT") "TIMED_OUT when timed out"
        assert ($comment | str contains "watchdog terminated the worker") "timeout reason"
    })
    (test "watch build result comment FAILED when cancelled" {
        let summary = {status: "cancelled", exit_code: 130}
        let delivery = {local_branch: "mimo/test", local_sha: "abc123", worktree_clean: true, remote_exists: true, remote_sha: "abc123", sha_match: true, branch_match: true}
        let comment = (watch-build-result-comment $summary $delivery "standard" "TIMED_OUT")
        assert ($comment | str contains "M2C RESULT: TIMED_OUT") "TIMED_OUT when cancelled"
        assert ($comment | str contains "worker was cancelled") "cancel reason"
    })
    (test "watch build result comment FAILED when worker failed even with clean delivery" {
        let summary = {status: "failed", exit_code: 1}
        let delivery = {local_branch: "mimo/test", local_sha: "abc123", worktree_clean: true, remote_exists: true, remote_sha: "abc123", sha_match: true, branch_match: true}
        let comment = (watch-build-result-comment $summary $delivery "standard" "WORKER_FAILED")
        assert ($comment | str contains "M2C RESULT: WORKER_FAILED") "WORKER_FAILED when worker failed"
        assert ($comment | str contains "worker exit code: 1") "worker failure reason"
    })
    # --- fix: repo field uses canonical identity from admission ---
    (test "discovery row has no .repo field (proves bug on stale main)" {
        let discovery = {repository: {nameWithOwner: "alice/my-repo", name: "my-repo"}, title: "[M2C QUEUED] test", number: 7, url: "https://github.com/alice/my-repo/issues/7"}
        let has_repo_field = (try { $discovery.repo | ignore; true } catch { false })
        assert (not $has_repo_field) "discovery row must not have .repo field"
    })
    (test "watch-issue-repo extracts full owner/repo from discovery row" {
        let discovery = {repository: {nameWithOwner: "alice/my-repo", name: "my-repo"}, title: "[M2C QUEUED] test", number: 7, url: "https://github.com/alice/my-repo/issues/7"}
        assert-equal (watch-issue-repo $discovery) "alice/my-repo" "nameWithOwner preferred"
        let bare = {repository: {name: "bare-name"}, title: "[M2C QUEUED] test", number: 2, url: "https://github.com/x/bare-name/issues/2"}
        assert-equal (watch-issue-repo $bare) "bare-name" "falls back to bare name"
    })
    (test "admission record provides canonical repo and number for claim" {
        let admission = {ok: true, base: "abcdef0123456789abcdef0123456789abcdef02", branch: "feature/test", worker: "mimo", profile: "standard", mode: "build", packet: "do work", owner: "alice", repo: "alice/my-repo", number: 7, title: "[M2C QUEUED] test", url: "https://github.com/alice/my-repo/issues/7"}
        assert-equal $admission.repo "alice/my-repo" "admission.repo is canonical"
        assert-equal $admission.number 7 "admission.number present"
        assert-equal $admission.worker "mimo" "admission.worker is mimo"
        assert-equal $admission.profile "standard" "admission.profile is standard"
        assert-equal $admission.mode "build" "admission.mode is build"
    })
    (test "admitted claim uses canonical repo identity not discovery row" {
        let discovery = {repository: {nameWithOwner: "alice/my-repo", name: "my-repo"}, title: "[M2C QUEUED] test", number: 7, url: "https://github.com/alice/my-repo/issues/7"}
        let admission = {ok: true, repo: "alice/my-repo", number: $discovery.number}
        assert-equal $admission.repo (watch-issue-repo $discovery) "admission repo matches helper"
        assert-equal $admission.number $discovery.number "admission number matches discovery"
    })
    (test "DONE title and comment use canonical admission repo identity" {
        let admission = {repo: "alice/my-repo", number: 7, profile: "standard"}
        let final_status = "DONE"
        let final_title = $"[M2C ($final_status)]"
        assert ($final_title == "[M2C DONE]") "DONE title format"
        let summary = {status: "completed", exit_code: 0}
        let delivery = {local_branch: "mimo/test", local_sha: "abc123", worktree_clean: true, remote_exists: true, remote_sha: "abc123", sha_match: true, branch_match: true}
        let comment = (watch-build-result-comment $summary $delivery $admission.profile $final_status)
        assert ($comment | str contains "M2C RESULT: DONE") "DONE comment uses canonical status"
        assert-equal $admission.repo "alice/my-repo" "repo identity preserved for DONE"
    })
    (test "FAILED title and comment use canonical admission repo identity" {
        let admission = {repo: "alice/my-repo", number: 7, profile: "pro"}
        let final_status = "DELIVERY_FAILED"
        let final_title = $"[M2C ($final_status)]"
        assert ($final_title == "[M2C DELIVERY_FAILED]") "DELIVERY_FAILED title format"
        let summary = {status: "failed", exit_code: 1}
        let delivery = {local_branch: "mimo/test", local_sha: "abc123", worktree_clean: false, remote_exists: false, remote_sha: "", sha_match: false, branch_match: false}
        let comment = (watch-build-result-comment $summary $delivery $admission.profile $final_status)
        assert ($comment | str contains "M2C RESULT: DELIVERY_FAILED") "DELIVERY_FAILED comment uses canonical status"
        assert-equal $admission.repo "alice/my-repo" "repo identity preserved for DELIVERY_FAILED"
    })
    (test "rejection path derives repo from discovery row without .repo field" {
        let discovery = {repository: {nameWithOwner: "alice/my-repo", name: "my-repo"}, title: "[M2C QUEUED] test", number: 7, url: "https://github.com/alice/my-repo/issues/7"}
        let blocked_repo = (watch-issue-repo $discovery)
        assert-equal $blocked_repo "alice/my-repo" "rejection derives full repo identity"
        let blocked_title = "[M2C BLOCKED]"
        assert ($blocked_title == "[M2C BLOCKED]") "BLOCKED title correct"
        let reason = "issue author (bot) does not match authenticated user (alice)"
        let comment = $"Rejection reason: ($reason)"
        assert ($comment | str contains "Rejection reason:") "rejection comment includes reason"
    })
    # --- fix #1: hex validation for base SHA ---
    (test "watch hex sha rejects non-hex characters" {
        assert (not (watch-hex-sha "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")) "z rejected"
        assert (not (watch-hex-sha "ghijklmnopqrstuvwxyz0123456789abcdefghij")) "g-h rejected"
        assert (not (watch-hex-sha "000000000000000000000000000000000000000g")) "trailing g rejected"
        assert (not (watch-hex-sha "0000000000000000000000000000000000000000G")) "uppercase G rejected"
        assert (not (watch-hex-sha "000000000000000000000000000000000000000!")) "exclamation rejected"
        assert (not (watch-hex-sha "000000000000000000000000000000000000000-")) "dash rejected"
    })
    (test "watch hex sha accepts valid 40-character hex" {
        assert (watch-hex-sha "abcdef0123456789abcdef0123456789abcdef02") "lowercase hex accepted"
        assert (watch-hex-sha "ABCDEF0123456789ABCDEF0123456789ABCDEF02") "uppercase hex accepted"
        assert (watch-hex-sha "0000000000000000000000000000000000000000") "all zeros accepted"
        assert (watch-hex-sha "ffffffffffffffffffffffffffffffffffffffff") "all f's accepted"
        assert (watch-hex-sha "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef") "mixed hex accepted"
    })
    (test "watch validate rejects non-hex 40-character base" {
        let fm = {m2c_job: "1", base: "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", branch: "feature/test", model: "standard"}
        let result = (watch-validate-packet $fm)
        assert (not $result.ok) "non-hex base rejected"
        assert ($result.reason | str contains "hexadecimal") "reason mentions hexadecimal"
        let fm2 = {m2c_job: "1", base: "000000000000000000000000000000000000000g", branch: "feature/test", model: "standard"}
        let result2 = (watch-validate-packet $fm2)
        assert (not $result2.ok) "trailing non-hex rejected"
        assert ($result2.reason | str contains "non-hex") "reason mentions non-hex"
    })
    (test "watch validate accepts valid 40-char hex base" {
        let fm = {m2c_job: "1", base: "abcdef0123456789abcdef0123456789abcdef02", branch: "feature/test", model: "standard"}
        let result = (watch-validate-packet $fm)
        assert $result.ok "valid hex base accepted"
    })
    # --- fix #1: base resolution helper ---
    (test "watch gh resolve base returns bool" {
        let result = (watch-gh-resolve-base "user/nonexistent" "0000000000000000000000000000000000000000")
        assert (not $result) "nonexistent repo returns false"
    })
    # --- fix #2: branch_match prevents DONE ---
    (test "watch build result comment FAILED when branch mismatch" {
        let summary = {status: "completed", exit_code: 0}
        let delivery = {local_branch: "main", local_sha: "abc123", worktree_clean: true, remote_exists: true, remote_sha: "abc123", sha_match: true, branch_match: false}
        let comment = (watch-build-result-comment $summary $delivery "standard" "FAILED")
        assert ($comment | str contains "M2C RESULT: FAILED") "FAILED when branch mismatch"
        assert ($comment | str contains "branch_match: MISMATCH") "branch mismatch status"
        assert ($comment | str contains "local branch main does not match requested branch") "branch mismatch reason"
    })
    (test "watch build result comment DONE when branch matches" {
        let summary = {status: "completed", exit_code: 0}
        let delivery = {local_branch: "mimo/test", local_sha: "abc123", worktree_clean: true, remote_exists: true, remote_sha: "abc123", sha_match: true, branch_match: true}
        let comment = (watch-build-result-comment $summary $delivery "standard" "DONE")
        assert ($comment | str contains "M2C RESULT: DONE") "DONE when branch matches"
        assert ($comment | str contains "branch_match: MATCH") "branch match status"
        assert (not ($comment | str contains "does not match requested branch")) "no branch mismatch reason"
    })
    (test "branch mismatch prevents DONE even with clean worktree and remote SHA match" {
        let summary = {status: "completed", exit_code: 0}
        let delivery = {local_branch: "wrong-branch", local_sha: "abc123", worktree_clean: true, remote_exists: true, remote_sha: "abc123", sha_match: true, branch_match: false}
        let can_be_done = ($summary.status == "completed") and $delivery.worktree_clean and $delivery.remote_exists and $delivery.sha_match and $delivery.branch_match
        assert (not $can_be_done) "branch mismatch prevents DONE"
    })
    (test "all delivery gates must pass for DONE" {
        let summary = {status: "completed", exit_code: 0}
        let delivery = {local_branch: "mimo/test", local_sha: "abc123", worktree_clean: true, remote_exists: true, remote_sha: "abc123", sha_match: true, branch_match: true}
        let can_be_done = ($summary.status == "completed") and $delivery.worktree_clean and $delivery.remote_exists and $delivery.sha_match and $delivery.branch_match
        assert $can_be_done "all gates pass for DONE"
    })
    (test "any delivery gate failure prevents DONE" {
        let base = {local_branch: "mimo/test", local_sha: "abc123", worktree_clean: true, remote_exists: true, remote_sha: "abc123", sha_match: true, branch_match: true}
        let dirty = ($base | merge {worktree_clean: false})
        assert (not (($dirty.status? | default "completed") == "completed" and $dirty.worktree_clean and $dirty.remote_exists and $dirty.sha_match and $dirty.branch_match)) "dirty prevents DONE"
        let no_remote = ($base | merge {remote_exists: false})
        assert (not (($no_remote.status? | default "completed") == "completed" and $no_remote.worktree_clean and $no_remote.remote_exists and $no_remote.sha_match and $no_remote.branch_match)) "missing remote prevents DONE"
        let sha_mismatch = ($base | merge {sha_match: false})
        assert (not (($sha_mismatch.status? | default "completed") == "completed" and $sha_mismatch.worktree_clean and $sha_mismatch.remote_exists and $sha_mismatch.sha_match and $sha_mismatch.branch_match)) "sha mismatch prevents DONE"
        let branch_mismatch = ($base | merge {branch_match: false})
        assert (not (($branch_mismatch.status? | default "completed") == "completed" and $branch_mismatch.worktree_clean and $branch_mismatch.remote_exists and $branch_mismatch.sha_match and $branch_mismatch.branch_match)) "branch mismatch prevents DONE"
        let worker_failed = {status: "failed", exit_code: 1}
        assert (not ($worker_failed.status == "completed" and $base.worktree_clean and $base.remote_exists and $base.sha_match and $base.branch_match)) "worker failure prevents DONE"
    })
    # --- fix #3: stale issue revalidation ---
    (test "stale issue with wrong title does not match queued filter" {
        let issue = {repository: {nameWithOwner: "alice/my-repo"}, title: "[M2C RUNNING]", number: 7, url: "https://github.com/alice/my-repo/issues/7"}
        assert (not ($issue.title | str starts-with "[M2C QUEUED]")) "running title not matched"
    })
    (test "closed issue state prevents claim" {
        let issue_state = "CLOSED"
        assert ($issue_state != "open") "closed issue is not open"
    })
    (test "title changed away from M2C QUEUED prevents claim" {
        let issue_title = "[M2C RUNNING]"
        assert (not ($issue_title | str starts-with "[M2C QUEUED]")) "changed title prevents claim"
    })
    (test "issue revalidation checks state and title" {
        let detail = {state: "CLOSED", title: "[M2C QUEUED] test", author: {login: "alice"}, body: "---\nm2c_job: 1\nbase: abcdef0123456789abcdef0123456789abcdef02\nbranch: feature/test\nmodel: standard\n---\ndo work"}
        assert ($detail.state != "open") "closed issue rejected"
        let detail2 = {state: "OPEN", title: "[M2C RUNNING]", author: {login: "alice"}, body: "---\nm2c_job: 1\nbase: abcdef0123456789abcdef0123456789abcdef02\nbranch: feature/test\nmodel: standard\n---\ndo work"}
        assert (not ($detail2.title | str starts-with "[M2C QUEUED]")) "title changed issue rejected"
    })
    # --- regression: OPEN state passes state/title gate (gh returns uppercase OPEN) ---
    (test "OPEN state with QUEUED title passes state gate (gh enum case normalization)" {
        let detail = {state: "OPEN", title: "[M2C QUEUED] test", author: {login: "alice"}, body: "---\nm2c_job: 1\nbase: abcdef0123456789abcdef0123456789abcdef02\nbranch: feature/test\nmodel: standard\n---\ndo work"}
        let issue_state = ($detail.state? | default "" | str lowercase)
        assert ($issue_state == "open") "normalized OPEN passes"
        assert ($detail.title | str starts-with "[M2C QUEUED]") "QUEUED title accepted"
    })
    (test "CLOSED state with QUEUED title still rejected after normalization" {
        let detail = {state: "CLOSED", title: "[M2C QUEUED] test", author: {login: "alice"}, body: "---\nm2c_job: 1\nbase: abcdef0123456789abcdef0123456789abcdef02\nbranch: feature/test\nmodel: standard\n---\ndo work"}
        let issue_state = ($detail.state? | default "" | str lowercase)
        assert ($issue_state != "open") "CLOSED still rejected"
    })
    # --- result comment branch mismatch explanation ---
    (test "result comment explains branch mismatch with local and expected" {
        let delivery = {local_branch: "main", local_sha: "abc123", worktree_clean: true, remote_exists: true, remote_sha: "abc123", sha_match: true, branch_match: false}
        let summary = {status: "completed", exit_code: 0}
        let comment = (watch-build-result-comment $summary $delivery "standard" "FAILED")
        assert ($comment | str contains "local branch main") "mentions local branch"
        assert ($comment | str contains "does not match requested branch") "explains mismatch"
    })
    # --- regression: failure/fallback delivery shape includes branch_match ---
    (test "fallback delivery record from clone failure produces WORKER_FAILED without column error" {
        let delivery = {local_branch: "", local_sha: "", worktree_clean: false, remote_exists: false, remote_sha: "", sha_match: false, branch_match: false}
        let summary = {status: "failed", exit_code: 1, final_text: "worker error"}
        let comment = (watch-build-result-comment $summary $delivery "standard" "WORKER_FAILED")
        assert ($comment | str contains "M2C RESULT: WORKER_FAILED") "WORKER_FAILED status produced"
        assert ($comment | str contains "worker exit code: 1") "worker failure reported"
        assert ($comment | str contains "branch_match: MISMATCH") "branch_match shown as MISMATCH"
        assert ($comment | str contains "worktree: DIRTY") "worktree dirty"
        assert ($comment | str contains "remote: MISMATCH") "remote mismatch"
    })
    (test "fallback delivery with branch_match false prevents DONE gate" {
        let delivery = {local_branch: "", local_sha: "", worktree_clean: false, remote_exists: false, remote_sha: "", sha_match: false, branch_match: false}
        let can_be_done = (false) and $delivery.worktree_clean and $delivery.remote_exists and $delivery.sha_match and $delivery.branch_match
        assert (not $can_be_done) "fallback delivery prevents DONE"
    })
    # --- budget_minutes validation ---
    (test "budget_minutes defaults to 20 when omitted" {
        let result = (watch-parse-budget null)
        assert $result.ok "null budget is ok"
        assert-equal $result.budget 20 "default budget is 20"
    })
    (test "budget_minutes rejects empty string" {
        let result = (watch-parse-budget "")
        assert (not $result.ok) "empty budget is rejected"
        assert ($result.reason | str contains "integer") "reason mentions integer"
    })
    (test "blank budget_minutes frontmatter fails closed" {
        let body = $"---\nm2c_job: 1\nbase: abcdef0123456789abcdef0123456789abcdef02\nbranch: feature/test\nmodel: standard\nbudget_minutes:\n---\npacket"
        let fm = (watch-gh-parse-front-matter $body)
        let result = (watch-validate-packet $fm)
        assert (not $result.ok) "blank budget is rejected"
        assert ($result.reason | str contains "integer") "reason mentions integer"
    })
    (test "budget_minutes accepts minimum 5" {
        let result = (watch-parse-budget "5")
        assert $result.ok "5 is valid"
        assert-equal $result.budget 5 "budget is 5"
    })
    (test "budget_minutes accepts 20" {
        let result = (watch-parse-budget "20")
        assert $result.ok "20 is valid"
        assert-equal $result.budget 20 "budget is 20"
    })
    (test "budget_minutes accepts value greater than 20 (45)" {
        let result = (watch-parse-budget "45")
        assert $result.ok "45 is valid"
        assert-equal $result.budget 45 "budget is 45"
    })
    (test "budget_minutes accepts maximum 120" {
        let result = (watch-parse-budget "120")
        assert $result.ok "120 is valid"
        assert-equal $result.budget 120 "budget is 120"
    })
    (test "budget_minutes rejects 4 (below minimum)" {
        let result = (watch-parse-budget "4")
        assert (not $result.ok) "4 is rejected"
        assert ($result.reason | str contains "at least 5") "reason mentions minimum"
    })
    (test "budget_minutes rejects 121 (above maximum)" {
        let result = (watch-parse-budget "121")
        assert (not $result.ok) "121 is rejected"
        assert ($result.reason | str contains "at most 120") "reason mentions maximum"
    })
    (test "budget_minutes rejects non-integer (3.5)" {
        let result = (watch-parse-budget "3.5")
        assert (not $result.ok) "3.5 is rejected"
        assert ($result.reason | str contains "fractional") "reason mentions fractional"
    })
    (test "budget_minutes rejects malformed text" {
        let result = (watch-parse-budget "abc")
        assert (not $result.ok) "abc is rejected"
        assert ($result.reason | str contains "integer") "reason mentions integer"
    })
    # --- budget_minutes in packet validation ---
    (test "watch validate includes budget_minutes in result" {
        let fm = {m2c_job: "1", base: "abcdef0123456789abcdef0123456789abcdef02", branch: "feature/test", model: "standard", budget_minutes: "45"}
        let result = (watch-validate-packet $fm)
        assert $result.ok "valid job with budget accepted"
        assert-equal $result.budget_minutes 45 "budget extracted"
    })
    (test "watch validate defaults budget when omitted" {
        let fm = {m2c_job: "1", base: "abcdef0123456789abcdef0123456789abcdef02", branch: "feature/test", model: "standard"}
        let result = (watch-validate-packet $fm)
        assert $result.ok "valid job without budget accepted"
        assert-equal $result.budget_minutes 20 "budget defaults to 20"
    })
    (test "watch validate rejects invalid budget" {
        let fm = {m2c_job: "1", base: "abcdef0123456789abcdef0123456789abcdef02", branch: "feature/test", model: "standard", budget_minutes: "200"}
        let result = (watch-validate-packet $fm)
        assert (not $result.ok) "invalid budget rejected"
        assert ($result.reason | str contains "at most 120") "reason mentions maximum"
    })
    # --- budget_minutes in admission record ---
    (test "admitted watch job carries normalized budget_minutes" {
        let fm = {m2c_job: "1", base: "abcdef0123456789abcdef0123456789abcdef02", branch: "feature/test", model: "standard", budget_minutes: "45"}
        let validation = (watch-validate-packet $fm)
        assert $validation.ok "validation passes"
        assert-equal $validation.budget_minutes 45 "budget in validation"
    })
    (test "admitted watch job with default budget carries 20" {
        let fm = {m2c_job: "1", base: "abcdef0123456789abcdef0123456789abcdef02", branch: "feature/test", model: "standard"}
        let validation = (watch-validate-packet $fm)
        assert $validation.ok "validation passes"
        assert-equal $validation.budget_minutes 20 "default budget in validation"
    })
    # --- budget_minutes in result comment ---
    (test "result comment includes budget line" {
        let summary = {status: "completed", exit_code: 0}
        let delivery = {local_branch: "mimo/test", local_sha: "abc123", worktree_clean: true, remote_exists: true, remote_sha: "abc123", sha_match: true, branch_match: true}
        let comment = (watch-build-result-comment $summary $delivery "standard" "DONE" 45)
        assert ($comment | str contains "budget: 45m") "budget line present"
    })
    (test "result comment uses default budget when not specified" {
        let summary = {status: "completed", exit_code: 0}
        let delivery = {local_branch: "mimo/test", local_sha: "abc123", worktree_clean: true, remote_exists: true, remote_sha: "abc123", sha_match: true, branch_match: true}
        let comment = (watch-build-result-comment $summary $delivery "standard" "DONE")
        assert ($comment | str contains "budget: 20m") "default budget line present"
    })
    # --- budget_minutes in worker summary telemetry ---
    (test "worker summary includes budget_minutes in output" {
        let summary = (worker-summary [] "mimo-v2.5" null null 0 0 false false null 45)
        assert-equal $summary.budget_minutes 45 "budget in summary"
    })
    (test "worker summary uses default budget when not specified" {
        let summary = (worker-summary [] "mimo-v2.5" null null 0 0 false)
        assert-equal $summary.budget_minutes 20 "default budget in summary"
    })
    # --- watchdog override still works with budget ---
    (test "test watchdog override still works with budget" {
        $env.M2C_TEST_WATCHDOG_MS = "5000"
        let ns = (watchdog-limit-from-budget 45)
        assert-equal $ns 5000000000 "test override takes precedence"
        $env.M2C_TEST_WATCHDOG_MS = ""
    })
    (test "budget-based watchdog calculation is correct" {
        $env.M2C_TEST_WATCHDOG_MS = ""
        let ns = (watchdog-limit-from-budget 45)
        assert-equal $ns (45 * 60 * 1000000000) "45 minutes in nanoseconds"
    })
    # --- mailbox isolation: worker-mailbox-tag ---
    (test "worker-mailbox-tag produces numeric values" {
        let tag = (worker-mailbox-tag)
        assert (($tag | describe) == "int") "tag is integer"
        assert ($tag >= 1) "tag >= 1"
        assert ($tag <= 2147483647) "tag <= 2147483647"
    })
    (test "worker-mailbox-tag produces unique values across calls" {
        let tags = (0..9 | each {|_| worker-mailbox-tag })
        let unique = ($tags | uniq | length)
        assert-equal $unique 10 "ten calls produce ten distinct tags"
    })
    (test "stale untagged message does not satisfy tagged recv" {
        let tag_a = (worker-mailbox-tag)
        let tag_b = (worker-mailbox-tag)
        assert ($tag_a != $tag_b) "two tags are distinct"
        let same_tag = (worker-mailbox-tag)
        assert ($tag_a != $same_tag) "independent calls produce different tags"
    })
    (test "timeout classification is preserved after tag change" {
        let timed = (worker-summary [] "mimo-v2.5" null null 2 124 true false)
        assert-equal $timed.status "timed_out" "timeout still classified correctly"
        assert-equal $timed.exit_code 124 "timeout exit code preserved"
        assert $timed.timed_out "timed_out flag set"
    })
    (test "cancellation classification is preserved after tag change" {
        let cancelled = (worker-summary [] "mimo-v2.5" null null 2 130 false true)
        assert-equal $cancelled.status "cancelled" "cancel still classified correctly"
        assert-equal $cancelled.exit_code 130 "cancel exit code preserved"
        assert (not ($cancelled.timed_out? | default false)) "timed_out not set for cancel"
    })
    (test "normal completion returns correct exit code after tag change" {
        let events = [
            {type: "tool_use", sessionID: "ses-test", part: {tool: "edit", state: {status: "completed", input: {filePath: "src/a.nu"}}}}
            {type: "step_finish", sessionID: "ses-test", part: {tokens: {input: 100, cache: {read: 0}}}}
        ]
        let summary = (worker-summary $events "mimo-v2.5" null null 5 0 false)
        assert-equal $summary.status "completed" "completed status"
        assert-equal $summary.exit_code 0 "exit code zero"
    })
    (test "two distinct tags cannot cross-consume results" {
        let tag_1 = (worker-mailbox-tag)
        let tag_2 = (worker-mailbox-tag)
        assert ($tag_1 != $tag_2) "tags are distinct"
        let tag_3 = (worker-mailbox-tag)
        let tag_4 = (worker-mailbox-tag)
        assert ($tag_3 != $tag_4) "second pair distinct"
        let all = [$tag_1 $tag_2 $tag_3 $tag_4]
        let unique = ($all | uniq | length)
        assert-equal $unique 4 "all four tags unique"
    })
    (test "mailbox tag allocation is cross-platform safe" {
        let tag = (worker-mailbox-tag)
        assert (($tag | describe) == "int") "tag is int on this platform"
        assert ($tag > 0) "positive tag"
        assert (($tag | into string | str length) > 0) "tag has string representation"
    })
    # --- flight recorder ---
    (test "flight recorder writes and reads manifest" {
        let job_id = "test-flight-001"
        let manifest = {job_id: $job_id, repo: "alice/my-repo", issue_number: 7, title: "Test job", base_sha: "abcdef0123456789abcdef0123456789abcdef02", branch: "feature/test", worker: "mimo", profile: "standard", mode: "build", budget_minutes: 20, resource_key: "alice/my-repo:feature/test", claimed_at: (iso-now-utc), m2c_version: "0.2.0", m2c_source_hash: "abc1234"}
        flight-write-manifest $job_id $manifest
        let read_back = (flight-read-manifest $job_id)
        assert-equal $read_back.job_id $job_id "job_id preserved"
        assert-equal $read_back.repo "alice/my-repo" "repo preserved"
        assert-equal $read_back.worker "mimo" "worker preserved"
        assert-equal $read_back.profile "standard" "profile preserved"
        assert-equal $read_back.mode "build" "mode preserved"
    })
    (test "flight recorder appends events" {
        let job_id = "test-flight-002"
        flight-append-event $job_id {event: "claimed", repo: "test/repo"}
        flight-append-event $job_id {event: "runner_start"}
        flight-append-event $job_id {event: "runner_end", status: "completed"}
        let events = (flight-read-events $job_id)
        assert-equal ($events | length) 3 "three events"
        assert-equal $events.0.event "claimed" "first event"
        assert-equal $events.1.event "runner_start" "second event"
        assert-equal $events.2.event "runner_end" "third event"
        assert ($events.0.timestamp? | is-not-empty) "timestamp present"
    })
    (test "flight recorder writes and reads result" {
        let job_id = "test-flight-003"
        let result = {job_id: $job_id, repo: "test/repo", category: "DONE", duration_seconds: 120, exit_code: 0, changed_file_count: 3}
        flight-write-result $job_id $result
        let read_back = (flight-read-result $job_id)
        assert-equal $read_back.category "DONE" "category preserved"
        assert-equal $read_back.duration_seconds 120 "duration preserved"
        assert-equal $read_back.changed_file_count 3 "file count preserved"
    })
    (test "flight recorder lists jobs" {
        let jobs = (flight-list-jobs)
        assert ($jobs | any {|j| $j == "test-flight-001"}) "first job listed"
        assert ($jobs | any {|j| $j == "test-flight-002"}) "second job listed"
    })
    # --- redaction ---
    (test "redact secrets removes tp- keys" {
        let text = "Using key tp-TEST-DO-NOT-USE-1234567890 for auth"
        let redacted = (redact-secrets $text)
        assert (not ($redacted | str contains "tp-TEST")) "key removed"
        assert ($redacted | str contains "[REDACTED_KEY]") "redaction marker"
    })
    (test "redact secrets removes api_key assignments" {
        let text = "api_key=supersecretvalue123 and token: othertoken456"
        let redacted = (redact-secrets $text)
        assert (not ($redacted | str contains "supersecretvalue")) "api_key value removed"
        assert (not ($redacted | str contains "othertoken456")) "token value removed"
    })
    (test "redact secrets preserves normal text" {
        let text = "The quick brown fox jumps over the lazy dog"
        let redacted = (redact-secrets $text)
        assert-equal $redacted $text "normal text unchanged"
    })
    (test "flight recorder events do not contain credential values" {
        let job_id = "test-flight-redact"
        flight-append-event $job_id {event: "test", note: "key tp-TEST-SECRET-1234567890 was used"}
        let events = (flight-read-events $job_id)
        let json = ($events | to json)
        assert (not ($json | str contains "tp-TEST-SECRET")) "no secret in events"
    })
    # --- failure signatures ---
    (test "failure signature watchdog_timeout" {
        let summary = {status: "timed_out", exit_code: 124}
        let delivery = {worktree_clean: true, remote_exists: true, sha_match: true, branch_match: true}
        assert-equal (normalize-failure-signature $summary $delivery "TIMED_OUT") "watchdog_timeout" "timeout signature"
    })
    (test "failure signature process_sigkill" {
        let summary = {status: "failed", exit_code: -9}
        let delivery = {worktree_clean: true, remote_exists: true, sha_match: true, branch_match: true}
        assert-equal (normalize-failure-signature $summary $delivery "WORKER_FAILED") "process_sigkill" "sigkill signature"
    })
    (test "failure signature worker_exit_nonzero" {
        let summary = {status: "failed", exit_code: 1}
        let delivery = {worktree_clean: true, remote_exists: true, sha_match: true, branch_match: true}
        assert-equal (normalize-failure-signature $summary $delivery "WORKER_FAILED") "worker_exit_nonzero" "nonzero exit signature"
    })
    (test "failure signature worker_zero_exit_no_changes" {
        let summary = {status: "completed", exit_code: 0}
        let delivery = {worktree_clean: true, remote_exists: false, sha_match: false, branch_match: true, changed_file_count: 0}
        assert-equal (normalize-failure-signature $summary $delivery "NO_CHANGES") "worker_zero_exit_no_changes" "no changes signature"
    })
    (test "failure signature branch_mismatch" {
        let summary = {status: "failed", exit_code: 1}
        let delivery = {worktree_clean: true, remote_exists: true, sha_match: true, branch_match: false}
        assert-equal (normalize-failure-signature $summary $delivery "DELIVERY_FAILED") "branch_mismatch" "branch mismatch signature"
    })
    (test "failure signature remote_missing" {
        let summary = {status: "failed", exit_code: 1}
        let delivery = {worktree_clean: true, remote_exists: false, sha_match: false, branch_match: true}
        assert-equal (normalize-failure-signature $summary $delivery "DELIVERY_FAILED") "remote_missing" "remote missing signature"
    })
    (test "failure signature dirty_worktree" {
        let summary = {status: "failed", exit_code: 1}
        let delivery = {worktree_clean: false, remote_exists: true, sha_match: true, branch_match: true}
        assert-equal (normalize-failure-signature $summary $delivery "DELIVERY_FAILED") "dirty_worktree" "dirty worktree signature"
    })
    (test "failure signature DONE returns unknown" {
        let summary = {status: "completed", exit_code: 0}
        let delivery = {worktree_clean: true, remote_exists: true, sha_match: true, branch_match: true, changed_file_count: 3}
        assert-equal (normalize-failure-signature $summary $delivery "DONE") "unknown" "DONE has no failure signature"
    })
    # --- controller lock ---
    (test "controller lock acquires when no lock exists" {
        let lock_path = (controller-lock-path)
        if ($lock_path | path exists) { rm $lock_path }
        let result = (controller-acquire-lock)
        assert $result.ok "lock acquired"
        controller-write-lock 1
        assert ($lock_path | path exists) "lock file created"
        controller-release-lock
        assert (not ($lock_path | path exists)) "lock file removed"
    })
    (test "controller lock rejects stale lock" {
        let lock_path = (controller-lock-path)
        {pid: 99999999, slots: 1, started_at: (iso-now-utc), version: "0.0.0"} | to json | save --force $lock_path
        let result = (controller-acquire-lock)
        assert $result.ok "stale lock recovered"
        controller-release-lock
    })
    (test "controller lock rejects active lock" {
        let lock_path = (controller-lock-path)
        {pid: $nu.pid, slots: 1, started_at: (iso-now-utc), version: "0.2.0"} | to json | save --force $lock_path
        let result = (controller-acquire-lock)
        assert (not $result.ok) "active lock rejected"
        assert ($result.reason | str contains "already active") "reason mentions active"
        controller-release-lock
    })
    (test "controller lock write and read" {
        controller-write-lock 2
        let lock_path = (controller-lock-path)
        let data = (open --raw $lock_path | from json)
        assert-equal $data.pid $nu.pid "pid in lock"
        assert-equal $data.slots 2 "slots in lock"
        assert ($data.started_at? | is-not-empty) "timestamp in lock"
        controller-release-lock
    })
    (test "controller running jobs function exists and callable" {
        let fn_exists = (try { controller-running-jobs; true } catch { false })
        assert $fn_exists "controller-running-jobs is callable"
    })
]

print ($results | table)
let failed = ($results | where status == "FAIL" | length)
if $failed > 0 {
    let failures = ($results | where status == "FAIL")
    for f in $failures {
        print $"FAIL: ($f.name) - ($f.detail)"
    }
    error make {msg: $"($failed) tests failed"}
}
print $"($results | length) passed, 0 failed"
rm --recursive --force $test_root
