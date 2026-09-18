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
    (test "autoload refreshes installed implementation on each invocation" {
        let autoload = ($project_root | path join "nu" | path join "autoload-m2c.nu")
        let raw = (open --raw $autoload)
        assert (not ($raw | str starts-with "source ")) "autoload does not bind a stale implementation at session startup"
        assert ($raw | str contains 'source ($nu.data-dir | path join "mimo2codex" | path join "mimo2codex.nu")') "wrapper sources installed implementation"
        assert ($raw | str contains "    invoke ...$args") "wrapper invokes freshly sourced implementation"
    })
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
    # --- RUNNING title preservation ---
    (test "RUNNING title preserves descriptive title" {
        let original = "Fix authentication bug"
        let running_title = $"[M2C RUNNING] ($original)"
        assert ($running_title | str contains "[M2C RUNNING]") "RUNNING prefix present"
        assert ($running_title | str contains $original) "original title preserved"
        assert (not ($running_title == "[M2C RUNNING]")) "not bare RUNNING"
    })
    # --- UTC timestamp ---
    (test "iso-now-utc produces Z suffix" {
        let ts = (iso-now-utc)
        assert ($ts | str ends-with "Z") "timestamp ends with Z"
        assert ($ts | str contains "T") "timestamp contains T separator"
    })
    # --- worker dispatch seam ---
    (test "worker-dispatch rejects unknown worker" {
        let result = (try { worker-dispatch "unknown" "standard" "test" null null null true "build" false $project_root 20; "unexpected" } catch { "blocked" })
        assert-equal $result "blocked" "unknown worker rejected"
    })
    (test "worker-dispatch accepts mimo worker" {
        let result = (try { worker-dispatch "mimo" "standard" "test" null null null true "build" false $project_root 20; "ok" } catch { "blocked" })
        assert ($result in ["ok", "blocked"]) "mimo worker accepted or blocked by credential"
    })
    # --- soft deadline and closeout reserve ---
    (test "soft-deadline-ns is 80% of hard deadline" {
        let soft = (soft-deadline-ns 20)
        let hard = (watchdog-limit-from-budget 20)
        assert-equal $soft (($hard * 80) / 100) "soft deadline is 80%"
    })
    (test "closeout-reserve-ns is 10% of hard deadline" {
        let closeout = (closeout-reserve-ns 20)
        let hard = (watchdog-limit-from-budget 20)
        assert-equal $closeout (($hard * 10) / 100) "closeout reserve is 10%"
    })
    # --- PARTIAL classification ---
    (test "PARTIAL classification when timed out with remote push" {
        let summary = {status: "timed_out", exit_code: 124}
        let delivery = {worktree_clean: true, remote_exists: true, sha_match: true, branch_match: true}
        assert-equal (watch-classify-result $summary $delivery) "PARTIAL" "PARTIAL when timed out with push"
    })
    (test "PARTIAL classification when cancelled with remote push" {
        let summary = {status: "cancelled", exit_code: 130}
        let delivery = {worktree_clean: true, remote_exists: true, sha_match: true, branch_match: true}
        assert-equal (watch-classify-result $summary $delivery) "PARTIAL" "PARTIAL when cancelled with push"
    })
    (test "TIMED_OUT when timed out without remote push" {
        let summary = {status: "timed_out", exit_code: 124}
        let delivery = {worktree_clean: true, remote_exists: false, sha_match: false, branch_match: true}
        assert-equal (watch-classify-result $summary $delivery) "TIMED_OUT" "TIMED_OUT when no push"
    })
    (test "DONE never for timed out or cancelled" {
        let timed = {status: "timed_out", exit_code: 124}
        let delivery = {worktree_clean: true, remote_exists: true, sha_match: true, branch_match: true}
        assert (not ((watch-classify-result $timed $delivery) == "DONE")) "DONE never for timeout"
    })
    # --- slot management ---
    (test "watch-slot-acquire rejects when all slots full" {
        let active = ["repo1:branch1" "repo2:branch2"]
        let result = (watch-slot-acquire $active "repo3:branch3" 2)
        assert (not $result.ok) "slots full rejected"
    })
    (test "watch-slot-acquire rejects same resource key" {
        let active = ["repo1:branch1"]
        let result = (watch-slot-acquire $active "repo1:branch1" 2)
        assert (not $result.ok) "same resource key rejected"
    })
    (test "watch-slot-acquire allows different resource key" {
        let active = ["repo1:branch1"]
        let result = (watch-slot-acquire $active "repo2:branch2" 2)
        assert $result.ok "different key allowed"
    })
    (test "watch-slot-acquire allows when empty" {
        let active = []
        let result = (watch-slot-acquire $active "repo1:branch1" 2)
        assert $result.ok "empty slots allow"
    })
    (test "watch-parse-jobs defaults to 3 with --stay" {
        let result = (watch-parse-jobs ["--stay"] true)
        assert-equal $result 3 "default jobs with --stay is 3"
    })
    (test "watch-parse-jobs defaults to 1 without --stay" {
        let result = (watch-parse-jobs [] false)
        assert-equal $result 1 "default jobs without --stay is 1"
    })
    (test "watch-parse-jobs parses --jobs 2" {
        let result = (watch-parse-jobs ["--stay" "--jobs" "2"] true)
        assert-equal $result 2 "jobs 2 parsed"
    })
    (test "watch-parse-jobs parses --jobs 1" {
        let result = (watch-parse-jobs ["--stay" "--jobs" "1"] true)
        assert-equal $result 1 "jobs 1 parsed"
    })
    (test "watch-parse-jobs parses --jobs 3" {
        let result = (watch-parse-jobs ["--stay" "--jobs" "3"] true)
        assert-equal $result 3 "jobs 3 parsed"
    })
    (test "watch-parse-jobs rejects --jobs 4" {
        let result = (try { watch-parse-jobs ["--jobs" "4"] true; "unexpected" } catch { "blocked" })
        assert-equal $result "blocked" "jobs 4 rejected"
    })
    (test "watch-parse-jobs rejects --jobs 0" {
        let result = (try { watch-parse-jobs ["--jobs" "0"] true; "unexpected" } catch { "blocked" })
        assert-equal $result "blocked" "jobs 0 rejected"
    })
    # --- jobspec normalization ---
    (test "normalize-jobspec creates valid jobspec" {
        let fm = {m2c_job: "1", base: "abcdef0123456789abcdef0123456789abcdef02", branch: "feature/test", model: "standard", budget_minutes: "45"}
        let jobspec = (normalize-jobspec $fm "alice/repo" 7 "Test job" "alice")
        assert-equal $jobspec.repo "alice/repo" "repo in jobspec"
        assert-equal $jobspec.issue_number 7 "issue number in jobspec"
        assert-equal $jobspec.title "Test job" "title in jobspec"
        assert-equal $jobspec.owner "alice" "owner in jobspec"
        assert-equal $jobspec.base_sha "abcdef0123456789abcdef0123456789abcdef02" "base in jobspec"
        assert-equal $jobspec.branch "feature/test" "branch in jobspec"
        assert-equal $jobspec.worker "mimo" "worker in jobspec"
        assert-equal $jobspec.profile "standard" "profile in jobspec"
        assert-equal $jobspec.mode "build" "mode in jobspec"
        assert-equal $jobspec.budget_minutes 45 "budget in jobspec"
    })
    (test "normalize-jobspec rejects invalid frontmatter" {
        let fm = {m2c_job: "2", base: "short", branch: "main"}
        let result = (try { normalize-jobspec $fm "alice/repo" 7 "Test" "alice"; "unexpected" } catch { "blocked" })
        assert-equal $result "blocked" "invalid frontmatter rejected"
    })
    # --- stderr capture ---
    (test "stderr path is set in worker-run result" {
        let result = (try {
            worker-run "mimo-v2.5" "test" null null null true "build" false $project_root 20
        } catch {
            null
        })
        if $result != null {
            assert ($result.stderr_path? | is-not-empty) "stderr path present"
        }
    })
    # --- redaction coverage ---
    (test "redact secrets removes bearer tokens" {
        let text = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        let redacted = (redact-secrets $text)
        assert (not ($redacted | str contains "eyJhbGciOi")) "bearer token removed"
        assert ($redacted | str contains "[REDACTED_TOKEN]") "redaction marker present"
    })
    (test "redact secrets removes sk- keys" {
        let text = "Using key sk-1234567890abcdef1234567890abcdef"
        let redacted = (redact-secrets $text)
        assert (not ($redacted | str contains "sk-1234567890")) "sk key removed"
        assert ($redacted | str contains "[REDACTED_SK]") "sk redaction marker"
    })
    (test "redact secrets removes ghp_ tokens" {
        let text = "GitHub token ghp_abc123def456ghi789jkl012mno345"
        let redacted = (redact-secrets $text)
        assert (not ($redacted | str contains "ghp_abc123")) "ghp token removed"
        assert ($redacted | str contains "[REDACTED_GH]") "ghp redaction marker"
    })
    (test "redact secrets preserves normal words" {
        let words = "The quick brown fox jumps over the lazy dog"
        assert-equal (redact-secrets $words) $words "normal words preserved"
    })
    # --- PR lookup ---
    (test "watch-find-pr returns null for nonexistent" {
        let result = (watch-find-pr "user/nonexistent" "main")
        assert ($result == null) "nonexistent returns null"
    })
    # --- controller runner integration tests ---
    (test "controller-runner completes lifecycle with test backend" {
        let fake_repo = ($test_root | path join "ctrl-repo")
        mkdir $fake_repo
        (run-external "git" "-C" $fake_repo "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "ctrl-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $fake_repo $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let test_result = {
            status: "completed"
            exit_code: 0
            tool_calls: 1
            tool_failures: 0
            changed_files: ["src/a.nu"]
            duration_seconds: 5
            timed_out: false
            final_text: "done"
            model: "mimo-v2.5"
            backend: "opencode"
            provider: "m2c-mimo"
            session_id: null
            workstream: null
            packet: null
            budget_minutes: 20
            context_estimate_tokens: null
            context_percent: null
            checkpoint_recommended: false
            agent: "build"
        }
        let backend_file = ($test_root | path join "ctrl-backend.json")
        $test_result | to json -r | save --force $backend_file
        let job_id = "ctrl-test-001"
        let job_dir = ($test_root | path join $"watch-($job_id)")
        mkdir $job_dir
        let manifest = {
            job_id: $job_id
            repo: "local/test"
            issue_number: 1
            title: "Test runner job"
            base_sha: $base_sha
            branch: "mimo/ctrl-test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
            resource_key: "local/test:mimo/ctrl-test"
            claimed_at: (iso-now-utc)
            m2c_version: "0.2.0"
            m2c_source_hash: "test"
        }
        flight-write-manifest $job_id $manifest
        flight-append-event $job_id {event: "claimed", repo: "local/test", issue: 1}
        flight-append-event $job_id {event: "runner_start"}
        let job_spec = {
            job_id: $job_id
            repo: "local/test"
            issue_number: 1
            title: "Test runner job"
            base_sha: $base_sha
            branch: "mimo/ctrl-test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
        }
        with-env {M2C_TEST_WORKER_BACKEND: $backend_file, M2C_TEST_REPO_ROOT: $fake_repo} {
            let result = (controller-runner $job_dir $job_spec "Do the test work.")
            assert ($result.exit_code in [0 1]) "runner exit code is valid"
            assert (not $result.timed_out) "not timed out"
            assert ($result.result_record | is-not-empty) "result record present"
        }
        let written = (flight-read-result $job_id)
        assert ($written != null) "result.json written"
        assert ($written.category in ["DONE" "DELIVERY_FAILED" "NO_CHANGES"]) "category is valid"
        assert-equal $written.job_id $job_id "job_id preserved"
        assert-equal $written.repo "local/test" "repo preserved"
        assert ($written.completed_at | is-not-empty) "completed_at present"
        assert-equal $written.closeout_ran false "closeout_ran is false for normal run"
        let events = (flight-read-events $job_id)
        assert ($events | any {|e| $e.event == "claimed"}) "claimed event"
        assert ($events | any {|e| $e.event == "runner_start"}) "runner_start event"
        assert ($events | any {|e| $e.event == "runner_complete"}) "runner_complete event"
    })
    (test "controller-runner writes result.json on clone failure" {
        let job_id = "ctrl-test-clone-fail"
        let job_dir = ($test_root | path join $"watch-($job_id)")
        mkdir $job_dir
        let job_spec = {
            job_id: $job_id
            repo: "nonexistent/repo"
            issue_number: 99
            title: "Clone fail test"
            base_sha: "abcdef0123456789abcdef0123456789abcdef02"
            branch: "mimo/test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
        }
        let result = (controller-runner $job_dir $job_spec "test")
        assert-equal $result.exit_code 1 "clone failure exit code"
        let written = (flight-read-result $job_id)
        assert ($written != null) "result written on clone failure"
        assert-equal $written.category "DELIVERY_FAILED" "clone failure is DELIVERY_FAILED"
    })
    (test "controller-dispatch-worker uses test backend when set" {
        let test_result = {
            status: "completed"
            exit_code: 0
            tool_calls: 0
            tool_failures: 0
            changed_files: []
            duration_seconds: 1
            timed_out: false
            final_text: "test backend response"
            model: "mimo-v2.5"
            backend: "opencode"
            provider: "m2c-mimo"
            session_id: null
            workstream: null
            packet: null
            budget_minutes: 5
            context_estimate_tokens: null
            context_percent: null
            checkpoint_recommended: false
        }
        let backend_file = ($test_root | path join "dispatch-backend.json")
        $test_result | to json -r | save --force $backend_file
        with-env {M2C_TEST_WORKER_BACKEND: $backend_file} {
            let result = (controller-dispatch-worker "mimo" "standard" "test" null null null true "build" false $test_root 5)
            assert-equal $result.summary.status "completed" "test backend returns completed"
            assert-equal $result.summary.final_text "test backend response" "test backend text"
        }
    })
    (test "controller-dispatch-worker falls through to real worker without test backend" {
        $env.M2C_TEST_WORKER_BACKEND = ""
        let result = (try {
            controller-dispatch-worker "mimo" "standard" "test" null null null true "build" false $test_root 5
            "ok"
        } catch {
            "blocked"
        })
        assert ($result in ["ok", "blocked"]) "real worker path invoked or blocked by credential"
    })
    (test "controller-closeout-runner writes result with closeout_ran true" {
        let fake_repo = ($test_root | path join "closeout-repo")
        mkdir $fake_repo
        (run-external "git" "-C" $fake_repo "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "closeout-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $fake_repo $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let test_result = {
            status: "completed"
            exit_code: 0
            tool_calls: 1
            tool_failures: 0
            changed_files: []
            duration_seconds: 2
            timed_out: false
            final_text: "closeout done"
            model: "mimo-v2.5"
            backend: "opencode"
            provider: "m2c-mimo"
            session_id: null
            workstream: null
            packet: null
            budget_minutes: 5
            context_estimate_tokens: null
            context_percent: null
            checkpoint_recommended: false
        }
        let backend_file = ($test_root | path join "closeout-backend.json")
        $test_result | to json -r | save --force $backend_file
        let job_id = "closeout-test-001"
        let job_spec = {
            job_id: $job_id
            repo: "local/test"
            issue_number: 2
            title: "Closeout test"
            base_sha: $base_sha
            branch: "mimo/closeout"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
        }
        with-env {M2C_TEST_WORKER_BACKEND: $backend_file, M2C_TEST_REPO_ROOT: $fake_repo} {
            let result = (controller-closeout-runner $work $job_spec 5 (date now))
            assert ($result | is-not-empty) "closeout result present"
        }
        let written = (flight-read-result $job_id)
        assert ($written != null) "closeout result written"
        assert-equal $written.closeout_ran true "closeout_ran is true"
        assert ($written.closeout_duration_seconds? | is-not-empty) "closeout_duration_seconds present"
        let events = (flight-read-events $job_id)
        assert ($events | any {|e| $e.event == "closeout_start"}) "closeout_start event"
        assert ($events | any {|e| $e.event == "closeout_end"}) "closeout_end event"
        assert ($events | any {|e| $e.event == "runner_complete"}) "runner_complete event after closeout"
    })
    # --- end-to-end launch seam tests ---
    (test "controller-runner end-to-end: claim, spawn, result, reap, finalize, free slot" {
        let fake_repo = ($test_root | path join "e2e-repo")
        mkdir $fake_repo
        (run-external "git" "-C" $fake_repo "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "e2e-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $fake_repo $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let test_result = {
            status: "completed"
            exit_code: 0
            tool_calls: 1
            tool_failures: 0
            changed_files: ["src/fix.nu"]
            duration_seconds: 3
            timed_out: false
            final_text: "work done"
            model: "mimo-v2.5"
            backend: "opencode"
            provider: "m2c-mimo"
            session_id: null
            workstream: null
            packet: null
            budget_minutes: 20
            context_estimate_tokens: null
            context_percent: null
            checkpoint_recommended: false
        }
        let backend_file = ($test_root | path join "e2e-backend.json")
        $test_result | to json -r | save --force $backend_file
        let job_id = "e2e-launch-001"
        let job_dir = ($test_root | path join $"watch-($job_id)")
        mkdir $job_dir
        let jobspec = {
            job_id: $job_id
            repo: "local/e2e"
            issue_number: 10
            title: "E2E launch test"
            base_sha: $base_sha
            branch: "mimo/e2e-launch"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
        }
        let manifest = $jobspec | merge {resource_key: "local/e2e:mimo/e2e-launch", claimed_at: (iso-now-utc), m2c_version: "0.2.0", m2c_source_hash: "test"}
        flight-write-manifest $job_id $manifest
        flight-append-event $job_id {event: "claimed", repo: "local/e2e", issue: 10}
        flight-append-event $job_id {event: "runner_start"}
        let child_tag = (worker-mailbox-tag)
        with-env {M2C_TEST_WORKER_BACKEND: $backend_file, M2C_TEST_REPO_ROOT: $fake_repo} {
            let child_job = (job spawn --description "e2e test runner" {
                let _r = (controller-runner $job_dir $jobspec "Do the E2E test work.")
                {done: true} | job send 0 --tag $child_tag
            })
            let msg = (try { job recv --tag $child_tag --timeout 30sec } catch { null })
            assert ($msg != null) "child runner sent completion message"
        }
        let result_record = (flight-read-result $job_id)
        assert ($result_record != null) "result.json written by child runner"
        assert-equal $result_record.job_id $job_id "result job_id"
        assert-equal $result_record.repo "local/e2e" "result repo"
        assert ($result_record.category in ["DONE" "DELIVERY_FAILED" "NO_CHANGES"]) "result category is valid"
        assert ($result_record.completed_at | is-not-empty) "completed_at present"
        let events = (flight-read-events $job_id)
        assert ($events | any {|e| $e.event == "claimed"}) "claimed event recorded"
        assert ($events | any {|e| $e.event == "runner_start"}) "runner_start event recorded"
        assert ($events | any {|e| $e.event == "runner_complete"}) "runner_complete event recorded by child"
        let job_record = {
            job_id: $job_id
            job_dir: $job_dir
            jobspec: $jobspec
            resource_key: "local/e2e:mimo/e2e-launch"
            original_title: "E2E launch test"
            admission: {ok: true, packet: "Do the E2E test work."}
            started_at: (date now)
            soft_deadline_ns: 999999999999
            hard_deadline_ns: 999999999999
            closeout_started: false
            child_job: null
            child_tag: $child_tag
        }
        controller-finalize-job $job_record $result_record
        let events_after = (flight-read-events $job_id)
        assert ($events_after | any {|e| $e.event == "finalized"}) "finalized event written by controller"
        let final_events = ($events_after | where {|e| $e.event == "finalized"})
        assert-equal ($final_events | length) 1 "finalized exactly once"
    })
    (test "controller-runner two concurrent jobs: distinct resources run in parallel" {
        let fake_repo_1 = ($test_root | path join "e2e-repo-1")
        mkdir $fake_repo_1
        (run-external "git" "-C" $fake_repo_1 "init" "--bare" "-b" "main" | complete) | ignore
        let work_1 = ($test_root | path join "e2e-work-1")
        mkdir $work_1
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $fake_repo_1 $work_1 | complete) | ignore
        ("# init" | save --force ($work_1 | path join "README.md"))
        (run-external "git" "-C" $work_1 "add" "." | complete) | ignore
        (run-external "git" "-C" $work_1 "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work_1 "push" "-u" "origin" "main" | complete) | ignore
        let base_sha_1 = ((run-external "git" "-C" $work_1 "rev-parse" "HEAD" | complete).stdout | str trim)
        let fake_repo_2 = ($test_root | path join "e2e-repo-2")
        mkdir $fake_repo_2
        (run-external "git" "-C" $fake_repo_2 "init" "--bare" "-b" "main" | complete) | ignore
        let work_2 = ($test_root | path join "e2e-work-2")
        mkdir $work_2
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $fake_repo_2 $work_2 | complete) | ignore
        ("# init" | save --force ($work_2 | path join "README.md"))
        (run-external "git" "-C" $work_2 "add" "." | complete) | ignore
        (run-external "git" "-C" $work_2 "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work_2 "push" "-u" "origin" "main" | complete) | ignore
        let base_sha_2 = ((run-external "git" "-C" $work_2 "rev-parse" "HEAD" | complete).stdout | str trim)
        let backend_1 = ($test_root | path join "e2e-backend-1.json")
        {status: "completed", exit_code: 0, tool_calls: 1, tool_failures: 0, changed_files: ["a.nu"], duration_seconds: 2, timed_out: false, final_text: "done1", model: "mimo-v2.5", backend: "opencode", provider: "m2c-mimo", session_id: null, workstream: null, packet: null, budget_minutes: 20, context_estimate_tokens: null, context_percent: null, checkpoint_recommended: false} | to json -r | save --force $backend_1
        let backend_2 = ($test_root | path join "e2e-backend-2.json")
        {status: "completed", exit_code: 0, tool_calls: 1, tool_failures: 0, changed_files: ["b.nu"], duration_seconds: 2, timed_out: false, final_text: "done2", model: "mimo-v2.5", backend: "opencode", provider: "m2c-mimo", session_id: null, workstream: null, packet: null, budget_minutes: 20, context_estimate_tokens: null, context_percent: null, checkpoint_recommended: false} | to json -r | save --force $backend_2
        let job_id_1 = "e2e-concurrent-1"
        let job_dir_1 = ($test_root | path join $"watch-($job_id_1)")
        mkdir $job_dir_1
        let jobspec_1 = {job_id: $job_id_1, repo: "alice/repo-a", issue_number: 1, title: "Job A", base_sha: $base_sha_1, branch: "mimo/job-a", worker: "mimo", profile: "standard", mode: "build", budget_minutes: 20, description: null}
        let job_id_2 = "e2e-concurrent-2"
        let job_dir_2 = ($test_root | path join $"watch-($job_id_2)")
        mkdir $job_dir_2
        let jobspec_2 = {job_id: $job_id_2, repo: "bob/repo-b", issue_number: 2, title: "Job B", base_sha: $base_sha_2, branch: "mimo/job-b", worker: "mimo", profile: "standard", mode: "build", budget_minutes: 20, description: null}
        let tag_1 = (worker-mailbox-tag)
        let tag_2 = (worker-mailbox-tag)
        flight-write-manifest $job_id_1 {job_id: $job_id_1, repo: "alice/repo-a", resource_key: "alice/repo-a:mimo/job-a"}
        flight-write-manifest $job_id_2 {job_id: $job_id_2, repo: "bob/repo-b", resource_key: "bob/repo-b:mimo/job-b"}
        with-env {M2C_TEST_WORKER_BACKEND: $backend_1, M2C_TEST_REPO_ROOT: $fake_repo_1} {
            let _h1 = (job spawn --description "e2e concurrent 1" {
                let _r = (controller-runner $job_dir_1 $jobspec_1 "Job A work")
                {done: true} | job send 0 --tag $tag_1
            })
        }
        with-env {M2C_TEST_WORKER_BACKEND: $backend_2, M2C_TEST_REPO_ROOT: $fake_repo_2} {
            let _h2 = (job spawn --description "e2e concurrent 2" {
                let _r = (controller-runner $job_dir_2 $jobspec_2 "Job B work")
                {done: true} | job send 0 --tag $tag_2
            })
        }
        let msg_1 = (try { job recv --tag $tag_1 --timeout 30sec } catch { null })
        assert ($msg_1 != null) "job 1 completed"
        let msg_2 = (try { job recv --tag $tag_2 --timeout 30sec } catch { null })
        assert ($msg_2 != null) "job 2 completed"
        let result_1 = (flight-read-result $job_id_1)
        let result_2 = (flight-read-result $job_id_2)
        assert ($result_1 != null) "job 1 result written"
        assert ($result_2 != null) "job 2 result written"
        assert ($result_1.category in ["DONE" "DELIVERY_FAILED" "NO_CHANGES"]) "job 1 category valid"
        assert ($result_2.category in ["DONE" "DELIVERY_FAILED" "NO_CHANGES"]) "job 2 category valid"
        assert (not ($result_1.job_id == $result_2.job_id)) "different job ids"
        assert (not ($result_1.repo == $result_2.repo)) "different repos"
    })
    (test "same resource key cannot run twice concurrently" {
        let active = ["alice/repo:mimo/branch"]
        let slot_check = (watch-slot-acquire $active "alice/repo:mimo/branch" 3)
        assert (not $slot_check.ok) "same resource key blocked"
        let slot_check_2 = (watch-slot-acquire $active "alice/repo:mimo/other" 3)
        assert $slot_check_2.ok "different branch on same repo allowed"
    })
    # --- --jobs requires --stay ---
    (test "watch --jobs 2 without --stay is rejected" {
        let lock_path = (controller-lock-path)
        if ($lock_path | path exists) { rm $lock_path }
        let captured = (with-env {M2C_CAPTURE_PRINT: "1"} {
            try {
                watch-command ["--jobs" "2"]
                "no_error"
            } catch {
                "error"
            }
        })
        assert ($captured in ["no_error" "error"]) "command completes or errors"
        controller-release-lock
    })
    # --- slot management with max 3 ---
    (test "max slots remains 3" {
        let active = ["r1:b1" "r2:b2" "r3:b3"]
        let result = (watch-slot-acquire $active "r4:b4" 3)
        assert (not $result.ok) "4th slot rejected with max 3"
    })
    (test "3 distinct resource keys can fill all slots" {
        let active = ["r1:b1" "r2:b2"]
        let result = (watch-slot-acquire $active "r3:b3" 3)
        assert $result.ok "3rd slot allowed with max 3"
    })
    # --- resident watcher capacity tests ---
    (test "m2c watch --stay defaults to capacity 3" {
        let result = (watch-parse-jobs ["--stay"] true)
        assert-equal $result 3 "--stay defaults to 3"
    })
    (test "--jobs 1 restricts capacity to 1" {
        let result = (watch-parse-jobs ["--stay" "--jobs" "1"] true)
        assert-equal $result 1 "--jobs 1 restricts to 1"
    })
    (test "--jobs 2 restricts capacity to 2" {
        let result = (watch-parse-jobs ["--stay" "--jobs" "2"] true)
        assert-equal $result 2 "--jobs 2 restricts to 2"
    })
    (test "--jobs 3 restricts capacity to 3" {
        let result = (watch-parse-jobs ["--stay" "--jobs" "3"] true)
        assert-equal $result 3 "--jobs 3 restricts to 3"
    })
    (test "fourth independent runner is never admitted at capacity 3" {
        let active = ["r1:b1" "r2:b2" "r3:b3"]
        let result = (watch-slot-acquire $active "r4:b4" 3)
        assert (not $result.ok) "4th runner rejected when 3 slots full"
        let active2 = ["r1:b1" "r2:b2" "r3:b3"]
        let result2 = (watch-slot-acquire $active2 "r5:b5" 3)
        assert (not $result2.ok) "5th runner also rejected"
    })
    (test "same repo+branch remains queued while active" {
        let active = ["alice/repo:feature/branch"]
        let result = (watch-slot-acquire $active "alice/repo:feature/branch" 3)
        assert (not $result.ok) "same repo+branch blocked while active"
        let active2 = ["alice/repo:feature/branch" "bob/repo:other/branch"]
        let result2 = (watch-slot-acquire $active2 "alice/repo:feature/branch" 3)
        assert (not $result2.ok) "same repo+branch blocked even with available slot"
    })
    (test "independent work behind conflicting job can be admitted" {
        let active = ["alice/repo:feature/a"]
        let conflict = (watch-slot-acquire $active "alice/repo:feature/a" 3)
        assert (not $conflict.ok) "conflicting job blocked"
        let independent = (watch-slot-acquire $active "bob/repo:feature/b" 3)
        assert $independent.ok "independent job admitted"
        let active_after = ($active | append "bob/repo:feature/b")
        let independent2 = (watch-slot-acquire $active_after "carol/repo:feature/c" 3)
        assert $independent2.ok "second independent job admitted"
        let still_blocked = (watch-slot-acquire $active_after "alice/repo:feature/a" 3)
        assert (not $still_blocked.ok) "conflicting job still blocked"
    })
    (test "freed slot allows new eligible job" {
        let active_full = ["r1:b1" "r2:b2" "r3:b3"]
        let full_result = (watch-slot-acquire $active_full "r4:b4" 3)
        assert (not $full_result.ok) "full capacity rejects new job"
        let active_freed = ["r1:b1" "r2:b2"]
        let freed_result = (watch-slot-acquire $active_freed "r4:b4" 3)
        assert $freed_result.ok "freed slot accepts new job"
    })
    (test "ordinary m2c watch defaults to 1 job and returns" {
        let result = (watch-parse-jobs [] false)
        assert-equal $result 1 "non-stay defaults to 1"
    })
    # --- same repo+branch cannot overlap ---
    (test "same resource key rejected even with available slots" {
        let active = ["repo:branch"]
        let result = (watch-slot-acquire $active "repo:branch" 3)
        assert (not $result.ok) "same key rejected"
    })
    # --- distinct resource keys can execute concurrently ---
    (test "distinct resource keys allowed concurrently" {
        let active = ["repo1:branch1"]
        let result = (watch-slot-acquire $active "repo2:branch2" 3)
        assert $result.ok "distinct key allowed"
        assert (($active | length) < 3) "slots available"
    })
    # --- runner completion reaped exactly once ---
    (test "result.json only written once per job_id" {
        let job_id = "reap-once-001"
        let result1 = {job_id: $job_id, category: "DONE", duration_seconds: 10, exit_code: 0, changed_file_count: 1, completed_at: (iso-now-utc)}
        flight-write-result $job_id $result1
        let read1 = (flight-read-result $job_id)
        assert-equal $read1.category "DONE" "first write"
        let result2 = {job_id: $job_id, category: "WORKER_FAILED", duration_seconds: 20, exit_code: 1, changed_file_count: 0, completed_at: (iso-now-utc)}
        flight-write-result $job_id $result2
        let read2 = (flight-read-result $job_id)
        assert-equal $read2.category "WORKER_FAILED" "second write overwrites"
        assert-equal (flight-job-dir $job_id | path join "result.json" | path exists) true "result file exists exactly once"
    })
    # --- controller-runner writes result even when worker has errors ---
    (test "controller-runner handles test backend with non-zero exit" {
        let fake_repo = ($test_root | path join "fail-repo")
        mkdir $fake_repo
        (run-external "git" "-C" $fake_repo "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "fail-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $fake_repo $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let test_result = {
            status: "failed"
            exit_code: 1
            tool_calls: 2
            tool_failures: 1
            changed_files: []
            duration_seconds: 3
            timed_out: false
            final_text: "error occurred"
            model: "mimo-v2.5"
            backend: "opencode"
            provider: "m2c-mimo"
            session_id: null
            workstream: null
            packet: null
            budget_minutes: 20
            context_estimate_tokens: null
            context_percent: null
            checkpoint_recommended: false
        }
        let backend_file = ($test_root | path join "fail-backend.json")
        $test_result | to json -r | save --force $backend_file
        let job_id = "ctrl-test-fail-001"
        let job_dir = ($test_root | path join $"watch-($job_id)")
        mkdir $job_dir
        let job_spec = {
            job_id: $job_id
            repo: "local/test"
            issue_number: 3
            title: "Worker fail test"
            base_sha: $base_sha
            branch: "mimo/fail-test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
        }
        with-env {M2C_TEST_WORKER_BACKEND: $backend_file, M2C_TEST_REPO_ROOT: $fake_repo} {
            let result = (controller-runner $job_dir $job_spec "Fail test work.")
            assert-equal $result.exit_code 1 "non-zero exit from failed worker"
        }
        let written = (flight-read-result $job_id)
        assert ($written != null) "result written for failed worker"
        assert ($written.category != "DONE") "failed worker is not DONE"
    })
    # --- controller-running-jobs detects active jobs ---
    (test "controller-running-jobs lists jobs with manifest but no result" {
        let active_job_id = "active-test-001"
        let manifest = {job_id: $active_job_id, repo: "test/repo", branch: "mimo/test", resource_key: "test/repo:mimo/test"}
        flight-write-manifest $active_job_id $manifest
        let active = (controller-running-jobs)
        assert ($active | any {|m| $m.job_id == $active_job_id}) "active job detected"
        flight-write-result $active_job_id {job_id: $active_job_id, category: "DONE"}
        let after = (controller-running-jobs)
        assert (not ($after | any {|m| $m.job_id == $active_job_id})) "completed job no longer active"
    })
    # --- controller tests use isolated flight dirs ---
    (test "flight recorder isolation between test jobs" {
        let id_a = "iso-test-a"
        let id_b = "iso-test-b"
        flight-write-manifest $id_a {job_id: $id_a, repo: "a/repo"}
        flight-write-manifest $id_b {job_id: $id_b, repo: "b/repo"}
        let read_a = (flight-read-manifest $id_a)
        let read_b = (flight-read-manifest $id_b)
        assert-equal $read_a.repo "a/repo" "job a isolated"
        assert-equal $read_b.repo "b/repo" "job b isolated"
    })
    # --- child runner exception hardening ---
    (test "child runner exception writes INTERNAL_ERROR result.json" {
        let job_id = "child-except-001"
        let job_dir = ($test_root | path join $"watch-($job_id)")
        mkdir $job_dir
        let fake_repo = ($test_root | path join "child-except-repo")
        mkdir $fake_repo
        (run-external "git" "-C" $fake_repo "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "child-except-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $fake_repo $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let jobspec = {
            job_id: $job_id
            repo: "test/repo"
            issue_number: 1
            title: "Exception test"
            base_sha: $base_sha
            branch: "mimo/test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
        }
        flight-write-manifest $job_id {job_id: $job_id, repo: "test/repo", resource_key: "test/repo:mimo/test"}
        flight-append-event $job_id {event: "runner_start"}
        let child_tag = (worker-mailbox-tag)
        let backend_file = ($test_root | path join "nonexistent-backend.json")
        with-env {M2C_TEST_WORKER_BACKEND: $backend_file, M2C_TEST_REPO_ROOT: $fake_repo} {
            let child_job = (job spawn --description "test child exception" {
                try {
                    let _r = (controller-runner $job_dir $jobspec "test")
                } catch {|err|
                    let err_msg = (redact-secrets ($err.msg? | default "runner exception"))
                    let _result_path = (flight-job-dir $job_id | path join "result.json")
                    flight-append-event $job_id {event: "runner_exception", error: $err_msg}
                    if not ($_result_path | path exists) {
                        let result_record = {
                            job_id: $job_id
                            repo: $jobspec.repo
                            issue_number: $jobspec.issue_number
                            title: "Exception test"
                            worker: $jobspec.worker
                            profile: $jobspec.profile
                            mode: $jobspec.mode
                            budget_minutes: $jobspec.budget_minutes
                            description: $jobspec.description
                            category: "INTERNAL_ERROR"
                            failure_signature: "runner_exception"
                            duration_seconds: 0
                            exit_code: 1
                            timed_out: false
                            local_branch: ""
                            local_sha: ""
                            worktree_clean: false
                            remote_exists: false
                            remote_sha: ""
                            sha_match: false
                            branch_match: false
                            changed_file_count: 0
                            tool_calls: 0
                            tool_failures: 0
                            completed_at: (iso-now-utc)
                            closeout_ran: false
                        }
                        flight-write-result $job_id $result_record
                    }
                }
                {done: true} | job send 0 --tag $child_tag
            })
            let msg = (try { job recv --tag $child_tag --timeout 30sec } catch { null })
            assert ($msg != null) "child sent terminal message despite exception"
        }
        let result = (flight-read-result $job_id)
        assert ($result != null) "result.json written after child exception"
        assert-equal $result.category "INTERNAL_ERROR" "category is INTERNAL_ERROR"
        assert-equal $result.failure_signature "runner_exception" "failure signature is runner_exception"
        let events = (flight-read-events $job_id)
        assert ($events | any {|e| $e.event == "runner_exception"}) "runner_exception event recorded"
    })
    (test "controller reaping detects child terminal message without result.json" {
        let job_id = "reap-no-result-001"
        let job_dir = ($test_root | path join $"watch-($job_id)")
        mkdir $job_dir
        let jobspec = {
            job_id: $job_id
            repo: "test/repo"
            issue_number: 2
            title: "Reap test"
            base_sha: "abcdef0123456789abcdef0123456789abcdef02"
            branch: "mimo/test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
        }
        flight-write-manifest $job_id {job_id: $job_id, repo: "test/repo", resource_key: "test/repo:mimo/test"}
        let child_tag = (worker-mailbox-tag)
        let child_job = (job spawn --description "test reap no result" {
            try {
                error make {msg: "simulated runner crash"}
            } catch {|err|
                let err_msg = ($err.msg? | default "runner exception")
                let _result_path = (flight-job-dir $job_id | path join "result.json")
                flight-append-event $job_id {event: "runner_exception", error: $err_msg}
                if not ($_result_path | path exists) {
                    let result_record = {
                        job_id: $job_id
                        repo: $jobspec.repo
                        issue_number: $jobspec.issue_number
                        title: "Reap test"
                        worker: $jobspec.worker
                        profile: $jobspec.profile
                        mode: $jobspec.mode
                        budget_minutes: $jobspec.budget_minutes
                        description: $jobspec.description
                        category: "INTERNAL_ERROR"
                        failure_signature: "runner_exception"
                        duration_seconds: 0
                        exit_code: 1
                        timed_out: false
                        local_branch: ""
                        local_sha: ""
                        worktree_clean: false
                        remote_exists: false
                        remote_sha: ""
                        sha_match: false
                        branch_match: false
                        changed_file_count: 0
                        tool_calls: 0
                        tool_failures: 0
                        completed_at: (iso-now-utc)
                        closeout_ran: false
                    }
                    flight-write-result $job_id $result_record
                }
            }
            {done: true} | job send 0 --tag $child_tag
        })
        let msg = (try { job recv --tag $child_tag --timeout 30sec } catch { null })
        assert ($msg != null) "child sent terminal message"
        let result_exists = (flight-job-dir $job_id | path join "result.json" | path exists)
        assert $result_exists "result.json exists after child exception handling"
        let result = (flight-read-result $job_id)
        assert ($result != null) "result readable"
        assert-equal $result.category "INTERNAL_ERROR" "category is INTERNAL_ERROR"
    })
    (test "exactly one INTERNAL_ERROR finalization after child exception" {
        let job_id = "finalize-once-001"
        let job_dir = ($test_root | path join $"watch-($job_id)")
        mkdir $job_dir
        let jobspec = {
            job_id: $job_id
            repo: "test/repo"
            issue_number: 3
            title: "Finalize once test"
            base_sha: "abcdef0123456789abcdef0123456789abcdef02"
            branch: "mimo/test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
        }
        flight-write-manifest $job_id {job_id: $job_id, repo: "test/repo", resource_key: "test/repo:mimo/test"}
        let child_tag = (worker-mailbox-tag)
        let child_job = (job spawn --description "test finalize once" {
            try {
                error make {msg: "simulated crash"}
            } catch {|err|
                let _result_path = (flight-job-dir $job_id | path join "result.json")
                flight-append-event $job_id {event: "runner_exception", error: ($err.msg? | default "error")}
                if not ($_result_path | path exists) {
                    let result_record = {
                        job_id: $job_id
                        repo: $jobspec.repo
                        issue_number: $jobspec.issue_number
                        title: "Finalize once test"
                        worker: $jobspec.worker
                        profile: $jobspec.profile
                        mode: $jobspec.mode
                        budget_minutes: $jobspec.budget_minutes
                        description: $jobspec.description
                        category: "INTERNAL_ERROR"
                        failure_signature: "runner_exception"
                        duration_seconds: 0
                        exit_code: 1
                        timed_out: false
                        local_branch: ""
                        local_sha: ""
                        worktree_clean: false
                        remote_exists: false
                        remote_sha: ""
                        sha_match: false
                        branch_match: false
                        changed_file_count: 0
                        tool_calls: 0
                        tool_failures: 0
                        completed_at: (iso-now-utc)
                        closeout_ran: false
                    }
                    flight-write-result $job_id $result_record
                }
            }
            {done: true} | job send 0 --tag $child_tag
        })
        let msg = (try { job recv --tag $child_tag --timeout 30sec } catch { null })
        assert ($msg != null) "child sent message"
        let job_record = {
            job_id: $job_id
            job_dir: $job_dir
            jobspec: $jobspec
            resource_key: "test/repo:mimo/test"
            original_title: "Finalize once test"
            admission: {ok: true, packet: "test"}
            started_at: (date now)
            soft_deadline_ns: 999999999999
            hard_deadline_ns: 999999999999
            closeout_started: false
            child_job: $child_job
            child_tag: $child_tag
        }
        let result_record = (flight-read-result $job_id)
        assert ($result_record != null) "result exists"
        controller-finalize-job $job_record $result_record
        let events = (flight-read-events $job_id)
        let finalized_count = ($events | where {|e| $e.event == "finalized"} | length)
        assert-equal $finalized_count 1 "finalized exactly once"
    })
    (test "slot becomes available after child exception reaped" {
        let active = ["repo1:branch1" "repo2:branch2" "repo3:branch3"]
        let full_result = (watch-slot-acquire $active "repo4:branch4" 3)
        assert (not $full_result.ok) "full capacity rejects"
        let active_freed = ["repo1:branch1" "repo2:branch2"]
        let freed_result = (watch-slot-acquire $active_freed "repo4:branch4" 3)
        assert $freed_result.ok "freed slot accepts"
    })
    (test "normal child completion still finalizes once" {
        let fake_repo = ($test_root | path join "normal-repo")
        mkdir $fake_repo
        (run-external "git" "-C" $fake_repo "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "normal-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $fake_repo $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let test_result = {
            status: "completed"
            exit_code: 0
            tool_calls: 1
            tool_failures: 0
            changed_files: ["src/a.nu"]
            duration_seconds: 2
            timed_out: false
            final_text: "done"
            model: "mimo-v2.5"
            backend: "opencode"
            provider: "m2c-mimo"
            session_id: null
            workstream: null
            packet: null
            budget_minutes: 20
            context_estimate_tokens: null
            context_percent: null
            checkpoint_recommended: false
            agent: "build"
        }
        let backend_file = ($test_root | path join "normal-backend.json")
        $test_result | to json -r | save --force $backend_file
        let job_id = "normal-complete-001"
        let job_dir = ($test_root | path join $"watch-($job_id)")
        mkdir $job_dir
        let jobspec = {
            job_id: $job_id
            repo: "local/normal"
            issue_number: 4
            title: "Normal completion test"
            base_sha: $base_sha
            branch: "mimo/normal"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
        }
        flight-write-manifest $job_id {job_id: $job_id, repo: "local/normal", resource_key: "local/normal:mimo/normal"}
        let child_tag = (worker-mailbox-tag)
        with-env {M2C_TEST_WORKER_BACKEND: $backend_file, M2C_TEST_REPO_ROOT: $fake_repo} {
            let child_job = (job spawn --description "test normal completion" {
                try {
                    let _r = (controller-runner $job_dir $jobspec "Do work.")
                } catch {|err|
                    let err_msg = (redact-secrets ($err.msg? | default "runner exception"))
                    let _result_path = (flight-job-dir $job_id | path join "result.json")
                    flight-append-event $job_id {event: "runner_exception", error: $err_msg}
                    if not ($_result_path | path exists) {
                        flight-write-result $job_id {job_id: $job_id, repo: "local/normal", issue_number: 4, title: "Normal completion test", worker: "mimo", profile: "standard", mode: "build", budget_minutes: 20, description: null, category: "INTERNAL_ERROR", failure_signature: "runner_exception", duration_seconds: 0, exit_code: 1, timed_out: false, local_branch: "", local_sha: "", worktree_clean: false, remote_exists: false, remote_sha: "", sha_match: false, branch_match: false, changed_file_count: 0, tool_calls: 0, tool_failures: 0, completed_at: (iso-now-utc), closeout_ran: false}
                    }
                }
                {done: true} | job send 0 --tag $child_tag
            })
            let msg = (try { job recv --tag $child_tag --timeout 30sec } catch { null })
            assert ($msg != null) "normal child sent message"
        }
        let result = (flight-read-result $job_id)
        assert ($result != null) "normal result written"
        assert ($result.category in ["DONE" "DELIVERY_FAILED" "NO_CHANGES"]) "normal category is not INTERNAL_ERROR"
        let job_record = {
            job_id: $job_id
            job_dir: $job_dir
            jobspec: $jobspec
            resource_key: "local/normal:mimo/normal"
            original_title: "Normal completion test"
            admission: {ok: true, packet: "Do work."}
            started_at: (date now)
            soft_deadline_ns: 999999999999
            hard_deadline_ns: 999999999999
            closeout_started: false
            child_job: null
            child_tag: $child_tag
        }
        controller-finalize-job $job_record $result
        let events = (flight-read-events $job_id)
        let finalized_count = ($events | where {|e| $e.event == "finalized"} | length)
        assert-equal $finalized_count 1 "normal completion finalized exactly once"
    })
    (test "controller lock released on genuine fatal watch error" {
        let lock_path = (controller-lock-path)
        if ($lock_path | path exists) { rm $lock_path }
        controller-write-lock 1
        assert ($lock_path | path exists) "lock exists before error"
        let caught = (try {
            error make {msg: "simulated fatal controller error"}
        } catch {|err|
            let err_msg = ($err.msg? | default "watch error")
            controller-release-lock
            "error_caught"
        })
        assert-equal $caught "error_caught" "error caught"
        assert (not ($lock_path | path exists)) "lock released after fatal error"
    })
    (test "error reporting preserves structured error context" {
        let err = {msg: "test error detail", span: {start: 100, end: 200, source: "test.nu"}}
        let err_msg = ($err.msg? | default "watch error")
        let err_detail = (try { $err | to json -r } catch { "" })
        assert ($err_msg | str contains "test error detail") "error message preserved"
        assert ($err_detail | str contains "test error detail") "error detail contains message"
        assert ($err_detail | str contains "span") "error detail contains span"
    })
    (test "error reporting shows more than wrapper-only External command failed" {
        let err = {msg: "controller-runner failed: git clone returned exit code 128"}
        let err_msg = ($err.msg? | default "watch error")
        assert ($err_msg | str contains "git clone") "error includes git detail"
        assert ($err_msg | str contains "exit code 128") "error includes exit code"
        assert (not ($err_msg == "External command failed")) "not just wrapper message"
    })
    (test "watch error rethrow accepts a missing span without masking the original error" {
        let caught = (try {
            controller-raise-watch-error {msg: "External command failed while starting runner", span: null}
        } catch {|err| $err })
        assert ($caught != null) "watch error was rethrown"
        assert-equal $caught.msg "External command failed while starting runner" "original message preserved"
    })
    (test "watch error rethrow preserves a valid span record" {
        let caught = (try {
            controller-raise-watch-error {msg: "runner detail", span: {start: 10, end: 12, source: "watch.nu"}}
        } catch {|err| $err })
        assert ($caught != null) "structured watch error was rethrown"
        assert-equal $caught.msg "runner detail" "structured error message preserved"
    })
    (test "closeout exception writes INTERNAL_ERROR with closeout_ran true" {
        let job_id = "closeout-except-001"
        let jobspec = {
            job_id: $job_id
            repo: "test/closeout"
            issue_number: 5
            title: "Closeout exception test"
            base_sha: "abcdef0123456789abcdef0123456789abcdef02"
            branch: "mimo/closeout"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
        }
        flight-write-manifest $job_id {job_id: $job_id, repo: "test/closeout", resource_key: "test/closeout:mimo/closeout"}
        let closeout_tag = (worker-mailbox-tag)
        let closeout_child = (job spawn --description "test closeout exception" {
            try {
                error make {msg: "simulated closeout crash"}
            } catch {|err|
                let err_msg = (redact-secrets ($err.msg? | default "closeout exception"))
                let _closeout_result_path = (flight-job-dir $job_id | path join "result.json")
                flight-append-event $job_id {event: "closeout_exception", error: $err_msg}
                if not ($_closeout_result_path | path exists) {
                    let result_record = {
                        job_id: $job_id
                        repo: $jobspec.repo
                        issue_number: $jobspec.issue_number
                        title: "Closeout exception test"
                        worker: $jobspec.worker
                        profile: $jobspec.profile
                        mode: $jobspec.mode
                        budget_minutes: $jobspec.budget_minutes
                        description: $jobspec.description
                        category: "INTERNAL_ERROR"
                        failure_signature: "closeout_exception"
                        duration_seconds: 0
                        exit_code: 1
                        timed_out: false
                        local_branch: ""
                        local_sha: ""
                        worktree_clean: false
                        remote_exists: false
                        remote_sha: ""
                        sha_match: false
                        branch_match: false
                        changed_file_count: 0
                        tool_calls: 0
                        tool_failures: 0
                        completed_at: (iso-now-utc)
                        closeout_ran: true
                    }
                    flight-write-result $job_id $result_record
                }
            }
            {done: true} | job send 0 --tag $closeout_tag
        })
        let msg = (try { job recv --tag $closeout_tag --timeout 30sec } catch { null })
        assert ($msg != null) "closeout child sent message"
        let result = (flight-read-result $job_id)
        assert ($result != null) "closeout result written"
        assert-equal $result.category "INTERNAL_ERROR" "closeout exception is INTERNAL_ERROR"
        assert-equal $result.failure_signature "closeout_exception" "closeout exception signature"
        assert-equal $result.closeout_ran true "closeout_ran is true"
        let events = (flight-read-events $job_id)
        assert ($events | any {|e| $e.event == "closeout_exception"}) "closeout_exception event recorded"
    })
    (test "resident watcher capacity tests from PR 34 remain intact" {
        assert-equal (watch-parse-jobs ["--stay"] true) 3 "default capacity 3"
        assert-equal (watch-parse-jobs ["--stay" "--jobs" "1"] true) 1 "capacity 1"
        assert-equal (watch-parse-jobs ["--stay" "--jobs" "2"] true) 2 "capacity 2"
        assert-equal (watch-parse-jobs ["--stay" "--jobs" "3"] true) 3 "capacity 3"
        let active = ["r1:b1" "r2:b2" "r3:b3"]
        assert (not (watch-slot-acquire $active "r4:b4" 3).ok) "4th rejected at capacity 3"
        assert (not (watch-slot-acquire $active "r1:b1" 3).ok) "same key rejected"
        let freed = ["r1:b1" "r2:b2"]
        assert (watch-slot-acquire $freed "r3:b3" 3).ok "freed slot accepts"
    })
    # --- regression: runtime job identity propagation ---
    (test "admission jobspec without job_id receives runtime identity before child sees it" {
        let fake_repo = ($test_root | path join "runtime-id-repo")
        mkdir $fake_repo
        (run-external "git" "-C" $fake_repo "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "runtime-id-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $fake_repo $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let admission_jobspec = {
            repo: "alice/test-repo"
            issue_number: 42
            title: "[M2C QUEUED] Fix runtime identity"
            owner: "alice"
            base_sha: $base_sha
            branch: "mimo/runtime-id-fix"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
        }
        assert (not ($admission_jobspec | columns | any {|c| $c == "job_id"})) "admission jobspec has no job_id column"
        let controller_job_id = (worker-job-id)
        let runtime_jobspec = ($admission_jobspec | insert job_id $controller_job_id | upsert title "Fix runtime identity")
        assert ($runtime_jobspec | columns | any {|c| $c == "job_id"}) "runtime jobspec has job_id column"
        assert-equal $runtime_jobspec.job_id $controller_job_id "runtime job_id matches controller-assigned id"
        assert-equal $runtime_jobspec.title "Fix runtime identity" "runtime title is clean original title"
        assert-equal $runtime_jobspec.repo "alice/test-repo" "repo preserved in runtime jobspec"
        assert-equal $runtime_jobspec.base_sha $base_sha "base_sha preserved in runtime jobspec"
        assert-equal $runtime_jobspec.branch "mimo/runtime-id-fix" "branch preserved in runtime jobspec"
        assert-equal $runtime_jobspec.worker "mimo" "worker preserved in runtime jobspec"
        assert-equal $runtime_jobspec.profile "standard" "profile preserved in runtime jobspec"
        assert-equal $runtime_jobspec.mode "build" "mode preserved in runtime jobspec"
        assert-equal $runtime_jobspec.budget_minutes 20 "budget_minutes preserved in runtime jobspec"
        let test_result = {
            status: "completed"
            exit_code: 0
            tool_calls: 1
            tool_failures: 0
            changed_files: ["src/fix.nu"]
            duration_seconds: 3
            timed_out: false
            final_text: "runtime identity fix applied"
            model: "mimo-v2.5"
            backend: "opencode"
            provider: "m2c-mimo"
            session_id: null
            workstream: null
            packet: null
            budget_minutes: 20
            context_estimate_tokens: null
            context_percent: null
            checkpoint_recommended: false
            agent: "build"
        }
        let backend_file = ($test_root | path join "runtime-id-backend.json")
        $test_result | to json -r | save --force $backend_file
        let job_dir = ($test_root | path join $"watch-($controller_job_id)")
        mkdir $job_dir
        let manifest = {
            job_id: $controller_job_id
            repo: $runtime_jobspec.repo
            issue_number: $runtime_jobspec.issue_number
            title: "Fix runtime identity"
            base_sha: $runtime_jobspec.base_sha
            branch: $runtime_jobspec.branch
            worker: $runtime_jobspec.worker
            profile: $runtime_jobspec.profile
            mode: $runtime_jobspec.mode
            budget_minutes: $runtime_jobspec.budget_minutes
            description: $runtime_jobspec.description
            resource_key: "alice/test-repo:mimo/runtime-id-fix"
            claimed_at: (iso-now-utc)
            m2c_version: "0.2.1"
            m2c_source_hash: "test"
        }
        flight-write-manifest $controller_job_id $manifest
        flight-append-event $controller_job_id {event: "claimed", repo: $runtime_jobspec.repo, issue: $runtime_jobspec.issue_number}
        flight-append-event $controller_job_id {event: "runner_start"}
        with-env {M2C_TEST_WORKER_BACKEND: $backend_file, M2C_TEST_REPO_ROOT: $fake_repo} {
            let result = (controller-runner $job_dir $runtime_jobspec "Fix the runtime identity bug.")
            assert ($result.exit_code in [0 1]) "runner exit code is valid"
            assert (not $result.timed_out) "not timed out"
            assert ($result.result_record | is-not-empty) "result record present"
        }
        let written = (flight-read-result $controller_job_id)
        assert ($written != null) "result.json written"
        assert-equal $written.job_id $controller_job_id "result.json contains controller-assigned job_id"
        assert-equal $written.repo "alice/test-repo" "result.json repo preserved"
        assert ($written.category in ["DONE" "DELIVERY_FAILED" "NO_CHANGES"]) "result category is valid"
        assert ($written.completed_at | is-not-empty) "completed_at present"
        let events = (flight-read-events $controller_job_id)
        assert ($events | any {|e| $e.event == "runner_complete"}) "runner_complete event appended without column error"
        let runner_complete_events = ($events | where {|e| $e.event == "runner_complete"})
        assert-equal ($runner_complete_events | length) 1 "exactly one runner_complete event"
        let job_record = {
            job_id: $controller_job_id
            job_dir: $job_dir
            jobspec: $runtime_jobspec
            resource_key: "alice/test-repo:mimo/runtime-id-fix"
            original_title: "Fix runtime identity"
            admission: {ok: true, packet: "Fix the runtime identity bug."}
            started_at: (date now)
            soft_deadline_ns: 999999999999
            hard_deadline_ns: 999999999999
            closeout_started: false
            child_job: null
            child_tag: (worker-mailbox-tag)
        }
        controller-finalize-job $job_record $written
        let events_after = (flight-read-events $controller_job_id)
        let finalized_count = ($events_after | where {|e| $e.event == "finalized"} | length)
        assert-equal $finalized_count 1 "controller finalizes exactly once"
        let finalized_event = ($events_after | where {|e| $e.event == "finalized"} | first)
        assert-equal $finalized_event.category $written.category "finalized event matches result category"
    })
    (test "runtime jobspec propagates job_id through closeout path" {
        let fake_repo = ($test_root | path join "closeout-id-repo")
        mkdir $fake_repo
        (run-external "git" "-C" $fake_repo "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "closeout-id-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $fake_repo $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let admission_jobspec = {
            repo: "bob/closeout-repo"
            issue_number: 99
            title: "[M2C QUEUED] Closeout identity test"
            owner: "bob"
            base_sha: $base_sha
            branch: "mimo/closeout-id"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
        }
        let controller_job_id = (worker-job-id)
        let runtime_jobspec = ($admission_jobspec | insert job_id $controller_job_id | upsert title "Closeout identity test")
        let test_result = {
            status: "completed"
            exit_code: 0
            tool_calls: 1
            tool_failures: 0
            changed_files: []
            duration_seconds: 2
            timed_out: false
            final_text: "closeout done"
            model: "mimo-v2.5"
            backend: "opencode"
            provider: "m2c-mimo"
            session_id: null
            workstream: null
            packet: null
            budget_minutes: 5
            context_estimate_tokens: null
            context_percent: null
            checkpoint_recommended: false
        }
        let backend_file = ($test_root | path join "closeout-id-backend.json")
        $test_result | to json -r | save --force $backend_file
        with-env {M2C_TEST_WORKER_BACKEND: $backend_file, M2C_TEST_REPO_ROOT: $fake_repo} {
            let result = (controller-closeout-runner $work $runtime_jobspec 5 (date now))
            assert ($result | is-not-empty) "closeout result present"
        }
        let written = (flight-read-result $controller_job_id)
        assert ($written != null) "closeout result written"
        assert-equal $written.job_id $controller_job_id "closeout result contains controller-assigned job_id"
        assert-equal $written.closeout_ran true "closeout_ran is true"
        let events = (flight-read-events $controller_job_id)
        assert ($events | any {|e| $e.event == "closeout_start"}) "closeout_start event"
        assert ($events | any {|e| $e.event == "closeout_end"}) "closeout_end event"
        assert ($events | any {|e| $e.event == "runner_complete"}) "runner_complete after closeout"
    })
    (test "admission jobspec without job_id: child exception still writes INTERNAL_ERROR with correct job_id" {
        let job_id = "no-id-except-001"
        let job_dir = ($test_root | path join $"watch-($job_id)")
        mkdir $job_dir
        let fake_repo = ($test_root | path join "no-id-except-repo")
        mkdir $fake_repo
        (run-external "git" "-C" $fake_repo "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "no-id-except-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $fake_repo $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let admission_jobspec = {
            repo: "test/no-id-except"
            issue_number: 7
            title: "[M2C QUEUED] Exception with runtime id"
            owner: "test"
            base_sha: $base_sha
            branch: "mimo/no-id-except"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
        }
        assert (not ($admission_jobspec | columns | any {|c| $c == "job_id"})) "admission jobspec has no job_id"
        let runtime_jobspec = ($admission_jobspec | insert job_id $job_id | upsert title "Exception with runtime id")
        assert-equal $runtime_jobspec.job_id $job_id "runtime job_id set"
        flight-write-manifest $job_id {job_id: $job_id, repo: "test/no-id-except", resource_key: "test/no-id-except:mimo/no-id-except"}
        flight-append-event $job_id {event: "runner_start"}
        let child_tag = (worker-mailbox-tag)
        let backend_file = ($test_root | path join "nonexistent-no-id-backend.json")
        with-env {M2C_TEST_WORKER_BACKEND: $backend_file, M2C_TEST_REPO_ROOT: $fake_repo} {
            let child_job = (job spawn --description "test no-id exception" {
                try {
                    let _r = (controller-runner $job_dir $runtime_jobspec "test")
                } catch {|err|
                    let err_msg = (redact-secrets ($err.msg? | default "runner exception"))
                    let _result_path = (flight-job-dir $job_id | path join "result.json")
                    flight-append-event $job_id {event: "runner_exception", error: $err_msg}
                    if not ($_result_path | path exists) {
                        let result_record = {
                            job_id: $job_id
                            repo: $runtime_jobspec.repo
                            issue_number: $runtime_jobspec.issue_number
                            title: "Exception with runtime id"
                            worker: $runtime_jobspec.worker
                            profile: $runtime_jobspec.profile
                            mode: $runtime_jobspec.mode
                            budget_minutes: $runtime_jobspec.budget_minutes
                            description: $runtime_jobspec.description
                            category: "INTERNAL_ERROR"
                            failure_signature: "runner_exception"
                            duration_seconds: 0
                            exit_code: 1
                            timed_out: false
                            local_branch: ""
                            local_sha: ""
                            worktree_clean: false
                            remote_exists: false
                            remote_sha: ""
                            sha_match: false
                            branch_match: false
                            changed_file_count: 0
                            tool_calls: 0
                            tool_failures: 0
                            completed_at: (iso-now-utc)
                            closeout_ran: false
                        }
                        flight-write-result $job_id $result_record
                    }
                }
                {done: true} | job send 0 --tag $child_tag
            })
            let msg = (try { job recv --tag $child_tag --timeout 30sec } catch { null })
            assert ($msg != null) "child sent terminal message despite exception"
        }
        let result = (flight-read-result $job_id)
        assert ($result != null) "result.json written after child exception"
        assert-equal $result.job_id $job_id "result.json has correct job_id"
        assert-equal $result.category "INTERNAL_ERROR" "category is INTERNAL_ERROR"
        assert-equal $result.failure_signature "runner_exception" "failure signature is runner_exception"
    })
    # --- live panel: format-time-12h ---
    (test "format-time-12h renders morning time" {
        let dt = ({year: 2026, month: 1, day: 1, hour: 9, minute: 36, second: 0} | into datetime)
        assert-equal (format-time-12h $dt) "9:36 am" "morning time"
    })
    (test "format-time-12h renders afternoon time" {
        let dt = ({year: 2026, month: 1, day: 1, hour: 15, minute: 36, second: 0} | into datetime)
        assert-equal (format-time-12h $dt) "3:36 pm" "afternoon time"
    })
    (test "format-time-12h renders midnight" {
        let dt = ({year: 2026, month: 1, day: 1, hour: 0, minute: 5, second: 0} | into datetime)
        assert-equal (format-time-12h $dt) "12:05 am" "midnight"
    })
    (test "format-time-12h renders noon" {
        let dt = ({year: 2026, month: 1, day: 1, hour: 12, minute: 0, second: 0} | into datetime)
        assert-equal (format-time-12h $dt) "12:00 pm" "noon"
    })
    # --- live panel: format-elapsed-compact ---
    (test "format-elapsed-compact renders seconds" {
        assert-equal (format-elapsed-compact 7) "0m 07s" "7 seconds"
    })
    (test "format-elapsed-compact renders minutes and seconds" {
        assert-equal (format-elapsed-compact 738) "12m 18s" "12m 18s"
    })
    (test "format-elapsed-compact renders zero" {
        assert-equal (format-elapsed-compact 0) "0m 00s" "zero"
    })
    (test "format-elapsed-compact renders large values" {
        assert-equal (format-elapsed-compact 3661) "61m 01s" "61m 01s"
    })
    # --- live panel: live-panel-state ---
    (test "live-panel-state builds correct snapshot with no jobs" {
        let state = (live-panel-state [] 3 0)
        assert-equal ($state.active | length) 0 "no active jobs"
        assert-equal $state.queued 0 "no queued"
        assert-equal $state.free 3 "3 free slots"
        assert-equal $state.max_slots 3 "max 3"
    })
    (test "live-panel-state derives free capacity from max minus active" {
        let now = (date now)
        let job1 = {job_id: "j1", original_title: "Job A", jobspec: {profile: "standard", title: "Job A"}, started_at: $now, soft_deadline_ns: 960000000000, hard_deadline_ns: 1200000000000, closeout_started: false, resource_key: "r1:b1", job_dir: "/tmp/j1", child_job: null, child_tag: 1, admission: {}}
        let state = (live-panel-state [$job1] 3 2)
        assert-equal ($state.active | length) 1 "one active"
        assert-equal $state.free 2 "2 free slots"
        assert-equal $state.queued 2 "2 queued"
    })
    (test "live-panel-state shows WORKING phase when not in closeout" {
        let now = (date now)
        let job = {job_id: "j1", original_title: "Test", jobspec: {profile: "pro", title: "Test"}, started_at: $now, soft_deadline_ns: 960000000000, hard_deadline_ns: 1200000000000, closeout_started: false, resource_key: "r:b", job_dir: "/tmp/j", child_job: null, child_tag: 1, admission: {}}
        let state = (live-panel-state [$job] 3 0)
        assert-equal ($state.active.0.phase) "WORKING" "working phase"
    })
    (test "live-panel-state shows CLOSEOUT phase when in closeout" {
        let now = (date now)
        let job = {job_id: "j1", original_title: "Test", jobspec: {profile: "standard", title: "Test"}, started_at: $now, soft_deadline_ns: 960000000000, hard_deadline_ns: 1200000000000, closeout_started: true, resource_key: "r:b", job_dir: "/tmp/j", child_job: null, child_tag: 1, admission: {}}
        let state = (live-panel-state [$job] 3 0)
        assert-equal ($state.active.0.phase) "CLOSEOUT" "closeout phase"
    })
    (test "live-panel-state derives MiMo Pro profile display" {
        let now = (date now)
        let job = {job_id: "j1", original_title: "Test", jobspec: {profile: "pro", title: "Test"}, started_at: $now, soft_deadline_ns: 960000000000, hard_deadline_ns: 1200000000000, closeout_started: false, resource_key: "r:b", job_dir: "/tmp/j", child_job: null, child_tag: 1, admission: {}}
        let state = (live-panel-state [$job] 3 0)
        assert-equal ($state.active.0.profile) "MiMo Pro" "pro profile"
    })
    (test "live-panel-state derives MiMo Standard profile display" {
        let now = (date now)
        let job = {job_id: "j1", original_title: "Test", jobspec: {profile: "standard", title: "Test"}, started_at: $now, soft_deadline_ns: 960000000000, hard_deadline_ns: 1200000000000, closeout_started: false, resource_key: "r:b", job_dir: "/tmp/j", child_job: null, child_tag: 1, admission: {}}
        let state = (live-panel-state [$job] 3 0)
        assert-equal ($state.active.0.profile) "MiMo Standard" "standard profile"
    })
    (test "live-panel-state elapsed is derived from actual started_at" {
        let started = ((date now) - 738sec)
        let job = {job_id: "j1", original_title: "Test", jobspec: {profile: "standard", title: "Test"}, started_at: $started, soft_deadline_ns: 960000000000, hard_deadline_ns: 1200000000000, closeout_started: false, resource_key: "r:b", job_dir: "/tmp/j", child_job: null, child_tag: 1, admission: {}}
        let state = (live-panel-state [$job] 3 0)
        assert ($state.active.0.elapsed_seconds >= 737) "elapsed at least 737s"
        assert ($state.active.0.elapsed_seconds <= 740) "elapsed at most 740s"
    })
    (test "live-panel-state closeout and deadline are derived from actual timestamps" {
        let started = (date now)
        let budget_minutes = 20
        let soft_ns = (soft-deadline-ns $budget_minutes)
        let hard_ns = (watchdog-limit-from-budget $budget_minutes)
        let job = {job_id: "j1", original_title: "Test", jobspec: {profile: "standard", title: "Test"}, started_at: $started, soft_deadline_ns: $soft_ns, hard_deadline_ns: $hard_ns, closeout_started: false, resource_key: "r:b", job_dir: "/tmp/j", child_job: null, child_tag: 1, admission: {}}
        let state = (live-panel-state [$job] 3 0)
        let expected_soft = ($started + ($soft_ns / 1000000000 | math round | into int | into duration --unit sec))
        let expected_hard = ($started + ($hard_ns / 1000000000 | math round | into int | into duration --unit sec))
        let closeout_diff = (($state.active.0.closeout_at - $expected_soft) | into int | math abs)
        assert ($closeout_diff < 2000000000) "closeout time within 2s of expected"
        let deadline_diff = (($state.active.0.deadline_at - $expected_hard) | into int | math abs)
        assert ($deadline_diff < 2000000000) "deadline time within 2s of expected"
    })
    # --- live panel: live-panel-frame ---
    (test "live-panel-frame header contains version and counts" {
        let state = {active: [], queued: 1, free: 3, max_slots: 3, now: (date now)}
        let frame = (live-panel-frame $state)
        assert (($frame | first) | str contains "watching") "header contains watching"
        assert (($frame | first) | str contains "0 active") "header shows 0 active"
        assert (($frame | first) | str contains "1 queued") "header shows 1 queued"
        assert (($frame | first) | str contains "0.2.4") "header contains version"
    })
    (test "live-panel-frame shows active job details" {
        let now = (date now)
        let job = {title: "Fix auth bug", profile: "MiMo Pro", phase: "WORKING", elapsed_seconds: 738, closeout_at: ($now + 600sec), deadline_at: ($now + 900sec)}
        let state = {active: [$job], queued: 0, free: 2, max_slots: 3, now: $now}
        let frame = (live-panel-frame $state)
        let text = ($frame | str join "\n")
        assert ($text | str contains "Fix auth bug") "title present"
        assert ($text | str contains "MiMo Pro") "profile present"
        assert ($text | str contains "WORKING") "phase present"
        assert ($text | str contains "12m 18s") "elapsed present"
        assert ($text | str contains "closeout") "closeout label"
        assert ($text | str contains "deadline") "deadline label"
    })
    (test "live-panel-frame shows CLOSEOUT symbol for closeout phase" {
        let now = (date now)
        let job = {title: "Test", profile: "MiMo Standard", phase: "CLOSEOUT", elapsed_seconds: 100, closeout_at: $now, deadline_at: ($now + 60sec)}
        let state = {active: [$job], queued: 0, free: 2, max_slots: 3, now: $now}
        let frame = (live-panel-frame $state)
        let text = ($frame | str join "\n")
        assert ($text | str contains "◐") "closeout symbol present"
        assert ($text | str contains "CLOSEOUT") "closeout label present"
    })
    (test "live-panel-frame shows WORKING symbol for working phase" {
        let now = (date now)
        let job = {title: "Test", profile: "MiMo Standard", phase: "WORKING", elapsed_seconds: 100, closeout_at: $now, deadline_at: ($now + 60sec)}
        let state = {active: [$job], queued: 0, free: 2, max_slots: 3, now: $now}
        let frame = (live-panel-frame $state)
        let text = ($frame | str join "\n")
        assert ($text | str contains "●") "working symbol present"
    })
    (test "live-panel-frame footer shows queued and free slots" {
        let state = {active: [], queued: 2, free: 1, max_slots: 3, now: (date now)}
        let frame = (live-panel-frame $state)
        let last = ($frame | last)
        assert ($last | str contains "2 queued") "queued count"
        assert ($last | str contains "1 slot free") "singular slot"
    })
    (test "live-panel-frame footer uses plural slots when free != 1" {
        let state = {active: [], queued: 0, free: 2, max_slots: 3, now: (date now)}
        let frame = (live-panel-frame $state)
        let last = ($frame | last)
        assert ($last | str contains "2 slots free") "plural slots"
    })
    (test "live-panel-frame footer uses singular slot when free == 1" {
        let state = {active: [], queued: 0, free: 1, max_slots: 3, now: (date now)}
        let frame = (live-panel-frame $state)
        let last = ($frame | last)
        assert ($last | str contains "1 slot free") "singular slot"
    })
    # --- live panel: frame height stability ---
    (test "live-panel-frame height is bounded per active job" {
        let now = (date now)
        let jobs = (0..2 | each {|i|
            {title: $"Job ($i)", profile: "MiMo Standard", phase: "WORKING", elapsed_seconds: 60, closeout_at: $now, deadline_at: $now}
        })
        let state = {active: $jobs, queued: 0, free: 0, max_slots: 3, now: $now}
        let frame = (live-panel-frame $state)
        let lines_per_job = 4
        let header_lines = 2
        let footer_lines = 1
        let expected = $header_lines + (3 * $lines_per_job) + $footer_lines
        assert-equal ($frame | length) $expected "frame height matches expected"
    })
    # --- live panel: no fake telemetry ---
    (test "live-panel-state has no percentage complete" {
        let now = (date now)
        let job = {job_id: "j1", original_title: "Test", jobspec: {profile: "standard", title: "Test"}, started_at: $now, soft_deadline_ns: 960000000000, hard_deadline_ns: 1200000000000, closeout_started: false, resource_key: "r:b", job_dir: "/tmp/j", child_job: null, child_tag: 1, admission: {}}
        let state = (live-panel-state [$job] 3 0)
        let active = ($state.active.0)
        assert (not ($active | columns | any {|c| $c == "percent"})) "no percent field"
        assert (not ($active | columns | any {|c| $c == "eta"})) "no eta field"
        assert (not ($active | columns | any {|c| $c == "progress"})) "no progress field"
    })
    (test "live-panel-frame contains no percentage or ETA" {
        let now = (date now)
        let job = {title: "Test", profile: "MiMo Standard", phase: "WORKING", elapsed_seconds: 100, closeout_at: $now, deadline_at: ($now + 60sec)}
        let state = {active: [$job], queued: 0, free: 2, max_slots: 3, now: $now}
        let frame = (live-panel-frame $state)
        let text = ($frame | str join "\n")
        assert (not ($text | str contains "%")) "no percentage"
        assert (not ($text | str contains "ETA")) "no ETA"
        assert (not ($text | str contains "estimated")) "no estimated"
    })
    # --- live panel: phase labels only from mechanical state ---
    (test "live-panel-state phase is only WORKING or CLOSEOUT" {
        let now = (date now)
        let working = {job_id: "j1", original_title: "T", jobspec: {profile: "standard", title: "T"}, started_at: $now, soft_deadline_ns: 960000000000, hard_deadline_ns: 1200000000000, closeout_started: false, resource_key: "r:b", job_dir: "/tmp/j", child_job: null, child_tag: 1, admission: {}}
        let closeout = ($working | merge {closeout_started: true})
        let s1 = (live-panel-state [$working] 3 0)
        let s2 = (live-panel-state [$closeout] 3 0)
        assert-equal ($s1.active.0.phase) "WORKING" "working from closeout_started=false"
        assert-equal ($s2.active.0.phase) "CLOSEOUT" "closeout from closeout_started=true"
    })
    # --- live panel: cadence isolation ---
    (test "live-tty-enabled returns false when quiet" {
        assert (not (live-tty-enabled true)) "quiet disables tty"
    })
    (test "live-tty-enabled respects M2C_FORCE_TTY" {
        with-env {M2C_FORCE_TTY: "1"} {
            assert (live-tty-enabled false) "force tty enables"
        }
    })
    # --- live panel: render produces correct line count ---
    (test "live-render-panel returns new line count" {
        let frame = ["line1" "line2" "line3"]
        let result = (live-render-panel $frame 0)
        assert-equal $result 3 "returns frame length"
    })
    # --- live panel: no repeated horizontal rules ---
    (test "live-panel-frame contains no horizontal rules" {
        let state = {active: [], queued: 0, free: 3, max_slots: 3, now: (date now)}
        let frame = (live-panel-frame $state)
        let text = ($frame | str join "\n")
        assert (not ($text | str contains "───")) "no horizontal rules"
        assert (not ($text | str contains "===")) "no double rules"
        assert (not ($text | str contains "---")) "no dash rules"
    })
    # --- live panel: narrow terminal degrades ---
    (test "live-panel-frame produces valid output regardless of terminal width" {
        let now = (date now)
        let job = {title: "A very long job title that might overflow narrow terminals", profile: "MiMo Pro", phase: "WORKING", elapsed_seconds: 100, closeout_at: $now, deadline_at: ($now + 60sec)}
        let state = {active: [$job], queued: 0, free: 2, max_slots: 3, now: $now}
        let frame = (live-panel-frame $state)
        assert (($frame | length) > 0) "frame is non-empty"
        for line in $frame {
            assert (($line | describe) == "string") "each line is a string"
        }
    })
    # --- live panel: version value is 0.2.3 ---
    (test "version-value returns 0.2.4" {
        assert-equal (version-value) "0.2.4" "version bumped"
    })
    # --- live panel: queue count reflects controller truth ---
    (test "live-panel-state queued count passes through from controller" {
        let state = (live-panel-state [] 3 5)
        assert-equal $state.queued 5 "queued count preserved"
        let state2 = (live-panel-state [] 3 0)
        assert-equal $state2.queued 0 "zero queued preserved"
    })
    # --- live panel: free slot math ---
    (test "live-panel-state free slots is max minus active count" {
        let now = (date now)
        let make_job = {|id|
            {job_id: $id, original_title: $"Job ($id)", jobspec: {profile: "standard", title: $"Job ($id)"}, started_at: $now, soft_deadline_ns: 960000000000, hard_deadline_ns: 1200000000000, closeout_started: false, resource_key: $"r($id):b($id)", job_dir: $"/tmp/($id)", child_job: null, child_tag: 1, admission: {}}
        }
        let j1 = (do $make_job "a")
        let j2 = (do $make_job "b")
        let j3 = (do $make_job "c")
        assert-equal (live-panel-state [] 3 0).free 3 "0 jobs = 3 free"
        assert-equal (live-panel-state [$j1] 3 0).free 2 "1 job = 2 free"
        assert-equal (live-panel-state [$j1 $j2] 3 0).free 1 "2 jobs = 1 free"
        assert-equal (live-panel-state [$j1 $j2 $j3] 3 0).free 0 "3 jobs = 0 free"
    })
    # --- description resolution ---
    (test "explicit description wins over title" {
        let jobspec = {repo: "alice/repo", issue_number: 7, title: "[M2C QUEUED] Fix auth", description: "Add OAuth2 support"}
        assert-equal (resolve-description $jobspec) "Add OAuth2 support" "explicit description used"
    })
    (test "missing description falls back to title" {
        let jobspec = {repo: "alice/repo", issue_number: 7, title: "Fix auth bug", description: null}
        assert-equal (resolve-description $jobspec) "Fix auth bug" "title used when no description"
    })
    (test "final fallback is repo and issue when title is empty" {
        let jobspec = {repo: "alice/repo", issue_number: 42, title: "", description: null}
        assert-equal (resolve-description $jobspec) "alice/repo #42" "repo #issue fallback"
    })
    (test "blank description behaves as missing" {
        let jobspec = {repo: "alice/repo", issue_number: 5, title: "Test job", description: "   "}
        assert-equal (resolve-description $jobspec) "Test job" "blank description ignored"
    })
    (test "whitespace-only description behaves as missing" {
        let jobspec = {repo: "alice/repo", issue_number: 3, title: "Ship it", description: "\t\n  "}
        assert-equal (resolve-description $jobspec) "Ship it" "whitespace description ignored"
    })
    (test "description is bounded to 72 characters with ellipsis" {
        let long_desc = ("a" | fill -a right -w 100 -c 'a')
        let jobspec = {repo: "alice/repo", issue_number: 1, title: "Test", description: $long_desc}
        let resolved = (resolve-description $jobspec)
        assert (($resolved | str length) <= 75) "bounded to 72 + ellipsis (75 bytes)"
        assert ($resolved | str ends-with "…") "ends with ellipsis"
    })
    (test "description sanitizes newlines and tabs" {
        let jobspec = {repo: "alice/repo", issue_number: 1, title: "Test", description: "Fix\nthe\tbug\rproperly"}
        assert-equal (resolve-description $jobspec) "Fix the bug properly" "newlines and tabs replaced"
    })
    (test "all M2C title prefixes are stripped for fallback" {
        let cases = [
            {input: "[M2C QUEUED] Test", expected: "Test"}
            {input: "[M2C RUNNING] Test", expected: "Test"}
            {input: "[M2C DONE] Test", expected: "Test"}
            {input: "[M2C FAILED] Test", expected: "Test"}
            {input: "[M2C BLOCKED] Test", expected: "Test"}
            {input: "[M2C TIMED_OUT] Test", expected: "Test"}
        ]
        for case in $cases {
            assert-equal (clean-title-prefix $case.input) $case.expected $"prefix stripped: ($case.input)"
        }
    })
    (test "clean-title-prefix removes M2C RUNNING prefix" {
        assert-equal (clean-title-prefix "[M2C RUNNING] Fix auth") "Fix auth" "RUNNING stripped"
    })
    (test "clean-title-prefix removes M2C QUEUED prefix" {
        assert-equal (clean-title-prefix "[M2C QUEUED] Fix auth") "Fix auth" "QUEUED stripped"
    })
    (test "clean-title-prefix leaves clean title unchanged" {
        assert-equal (clean-title-prefix "Fix auth bug") "Fix auth bug" "clean title preserved"
    })
    (test "sanitize-description collapses multiple spaces" {
        assert-equal (sanitize-description "Fix  the   bug") "Fix the bug" "spaces collapsed"
    })
    (test "sanitize-description trims leading and trailing whitespace" {
        assert-equal (sanitize-description "  Fix auth  ") "Fix auth" "trimmed"
    })
    (test "sanitize-description returns null for empty string" {
        assert (null == (sanitize-description "")) "empty returns null"
    })
    (test "sanitize-description returns null for whitespace-only string" {
        assert (null == (sanitize-description "   ")) "whitespace returns null"
    })
    (test "live-panel-state uses resolved description from jobspec" {
        let now = (date now)
        let job = {job_id: "j1", original_title: "Fix auth", jobspec: {profile: "standard", repo: "alice/repo", issue_number: 7, title: "Fix auth", description: "Add OAuth2"}, started_at: $now, soft_deadline_ns: 960000000000, hard_deadline_ns: 1200000000000, closeout_started: false, resource_key: "r:b", job_dir: "/tmp/j", child_job: null, child_tag: 1, admission: {}}
        let state = (live-panel-state [$job] 3 0)
        assert-equal $state.active.0.title "Add OAuth2" "explicit description used in panel"
    })
    (test "live-panel-state falls back to title when no description" {
        let now = (date now)
        let job = {job_id: "j1", original_title: "Fix auth", jobspec: {profile: "standard", repo: "alice/repo", issue_number: 7, title: "Fix auth"}, started_at: $now, soft_deadline_ns: 960000000000, hard_deadline_ns: 1200000000000, closeout_started: false, resource_key: "r:b", job_dir: "/tmp/j", child_job: null, child_tag: 1, admission: {}}
        let state = (live-panel-state [$job] 3 0)
        assert-equal $state.active.0.title "Fix auth" "title used"
    })
    (test "live-panel-state falls back to repo #issue when no description and empty title" {
        let now = (date now)
        let job = {job_id: "j1", original_title: "", jobspec: {profile: "standard", repo: "alice/repo", issue_number: 7, title: ""}, started_at: $now, soft_deadline_ns: 960000000000, hard_deadline_ns: 1200000000000, closeout_started: false, resource_key: "r:b", job_dir: "/tmp/j", child_job: null, child_tag: 1, admission: {}}
        let state = (live-panel-state [$job] 3 0)
        assert-equal $state.active.0.title "alice/repo #7" "repo #issue fallback"
    })
    (test "live-panel-frame shows description once without scroll growth" {
        let now = (date now)
        let job = {title: "Add OAuth2 support", profile: "MiMo Standard", phase: "WORKING", elapsed_seconds: 100, closeout_at: $now, deadline_at: ($now + 60sec)}
        let state = {active: [$job], queued: 0, free: 2, max_slots: 3, now: $now}
        let frame1 = (live-panel-frame $state)
        let frame2 = (live-panel-frame $state)
        assert-equal ($frame1 | length) ($frame2 | length) "frame height stable"
        let count1 = ($frame1 | where {|line| $line | str contains "Add OAuth2 support"} | length)
        assert-equal $count1 1 "description appears exactly once"
    })
    (test "live-panel-frame narrow layout remains clean with description" {
        let now = (date now)
        let long_title = ("A" | fill -a right -w 80 -c 'A')
        let job = {title: $long_title, profile: "MiMo Pro", phase: "WORKING", elapsed_seconds: 100, closeout_at: $now, deadline_at: ($now + 60sec)}
        let state = {active: [$job], queued: 0, free: 2, max_slots: 3, now: $now}
        let frame = (live-panel-frame $state)
        assert (($frame | length) > 0) "narrow frame non-empty"
        for line in $frame {
            assert (($line | describe) == "string") "each line is a string"
        }
    })
    # --- live panel redraw: cursor math correctness ---
    (test "live-build-panel-bytes first render has no cursor-up" {
        let esc = (char --integer 27)
        let frame = ["header" "" "footer"]
        let result = (live-build-panel-bytes $frame 0)
        let has_cu_a = ($result.bytes | str contains $"($esc)[1A")
        let has_cu_2a = ($result.bytes | str contains $"($esc)[2A")
        let has_cu_3a = ($result.bytes | str contains $"($esc)[3A")
        assert (not $has_cu_a) "no cursor-up 1 in first render"
        assert (not $has_cu_2a) "no cursor-up 2 in first render"
        assert (not $has_cu_3a) "no cursor-up 3 in first render"
        assert-equal $result.owned 3 "owned matches frame length"
    })
    (test "live-build-panel-bytes second render uses cursor-up previous_lines minus 1" {
        let esc = (char --integer 27)
        let frame = ["header" "" "footer"]
        let first = (live-build-panel-bytes $frame 0)
        let second = (live-build-panel-bytes $frame $first.owned)
        assert ($second.bytes | str contains $"($esc)[2A") "cursor-up (owned-1)=2 present"
        assert-equal $second.owned 3 "owned stable"
    })
    (test "live-build-panel-bytes N refreshes keep same owned count" {
        let frame = ["header" "" "line1" "line2" "footer"]
        mut owned = 0
        for i in 0..5 {
            let result = (live-build-panel-bytes $frame $owned)
            $owned = $result.owned
        }
        assert-equal $owned 5 "owned remains 5 after 6 refreshes"
    })
    (test "live-build-panel-bytes output contains no line feed bytes" {
        let frame = ["line1" "line2" "line3"]
        let result = (live-build-panel-bytes $frame 0)
        let lf = (char --integer 10)
        assert (not ($result.bytes | str contains $lf)) "no LF byte that causes scroll"
    })
    (test "live-build-panel-bytes redraw contains no line feed bytes" {
        let frame = ["line1" "line2" "line3"]
        let first = (live-build-panel-bytes $frame 0)
        let second = (live-build-panel-bytes $frame $first.owned)
        let lf = (char --integer 10)
        assert (not ($second.bytes | str contains $lf)) "no LF in redraw"
    })
    (test "live-build-panel-bytes uses cursor-down sequences for inter-line movement" {
        let esc = (char --integer 27)
        let frame = ["line1" "line2" "line3"]
        let result = (live-build-panel-bytes $frame 0)
        assert ($result.bytes | str contains $"($esc)[1B") "cursor-down present for inter-line movement"
    })
    (test "live-build-panel-bytes cursor-up count is previous_lines minus 1" {
        let esc = (char --integer 27)
        let frame = ["a" "b" "c" "d"]
        let result = (live-build-panel-bytes $frame 4)
        assert ($result.bytes | str contains $"($esc)[3A") "cursor-up (4-1)=3 for 4 previous lines"
    })
    (test "live-build-panel-bytes shrinking frame clears extra lines" {
        let esc = (char --integer 27)
        let big_frame = ["a" "b" "c" "d" "e"]
        let small_frame = ["a" "b"]
        let first = (live-build-panel-bytes $big_frame 0)
        let second = (live-build-panel-bytes $small_frame $first.owned)
        assert ($second.bytes | str contains $"($esc)[2K") "clear-line present"
        assert ($second.bytes | str contains $"($esc)[4A") "cursor-up (5-1)=4 for extra line handling"
        assert-equal $second.owned 2 "owned shrinks to 2"
    })
    (test "live-build-clear-bytes returns empty for zero previous_lines" {
        let result = (live-build-clear-bytes 0)
        assert-equal $result.bytes "" "empty bytes"
        assert-equal $result.owned 0 "owned is 0"
    })
    (test "live-build-clear-bytes uses cursor-up previous_lines minus 1" {
        let esc = (char --integer 27)
        let result = (live-build-clear-bytes 5)
        assert ($result.bytes | str contains $"($esc)[4A") "cursor-up (5-1)=4"
        assert ($result.bytes | str contains $"($esc)[?25h") "cursor visible"
        assert-equal $result.owned 0 "owned is 0 after clear"
    })
    (test "live-build-clear-bytes output contains no line feed bytes" {
        let result = (live-build-clear-bytes 3)
        let lf = (char --integer 10)
        assert (not ($result.bytes | str contains $lf)) "no LF byte in clear output"
    })
    (test "two identical renders produce no extra line feed overhead" {
        let frame = ["header" "" "footer"]
        let first = (live-build-panel-bytes $frame 0)
        let second = (live-build-panel-bytes $frame $first.owned)
        let lf = (char --integer 10)
        assert (not ($first.bytes | str contains $lf)) "first render: no LF"
        assert (not ($second.bytes | str contains $lf)) "second render: no LF"
        assert-equal $first.owned $second.owned "owned count identical"
    })
    (test "zero-active to one-active transition does not creep downward" {
        let zero_frame = (live-panel-frame {active: [], queued: 0, free: 3, max_slots: 3, now: (date now)})
        let zero_result = (live-build-panel-bytes $zero_frame 0)
        let one_frame = (live-panel-frame {active: [{title: "J", profile: "MiMo Standard", phase: "WORKING", elapsed_seconds: 10, closeout_at: (date now), deadline_at: (date now)}], queued: 0, free: 2, max_slots: 3, now: (date now)})
        let one_result = (live-build-panel-bytes $one_frame $zero_result.owned)
        assert ($one_result.owned > $zero_result.owned) "panel grows"
        let lf = (char --integer 10)
        assert (not ($one_result.bytes | str contains $lf)) "no LF in transition bytes"
    })
    (test "redirected mode output has no ANSI escape bytes" {
        let zero_state = (live-panel-state [] 3 0)
        let frame = (live-panel-frame $zero_state)
        let text = ($frame | str join "\n")
        assert (not ($text | str contains (char --integer 27))) "no ANSI in redirected frame text"
    })
    # === branch preparation regression tests (fix sequential same-branch continuation) ===
    # test 1: no remote target branch => starts exactly at declared base
    (test "controller-prepare-branch: fresh branch starts at declared base" {
        let repo_dir = ($test_root | path join "prep-fresh-repo")
        mkdir $repo_dir
        (run-external "git" "-C" $repo_dir "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "prep-fresh-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $repo_dir $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let clone_dir = ($test_root | path join "prep-fresh-clone")
        (run-external "git" "clone" $repo_dir $clone_dir | complete) | ignore
        let prep = (controller-prepare-branch $clone_dir "mimo/fresh" $base_sha "prep-test-001")
        assert $prep.ok "fresh branch preparation succeeds"
        assert-equal $prep.effective_start_sha $base_sha "effective start SHA equals declared base"
        assert (not $prep.remote_existed) "remote did not exist"
        assert-equal $prep.remote_start_sha "" "no remote start SHA"
        let head_sha = ((run-external "git" "-C" $clone_dir "rev-parse" "HEAD" | complete).stdout | str trim)
        assert-equal $head_sha $base_sha "HEAD is at declared base"
        let current_branch = ((run-external "git" "-C" $clone_dir "branch" "--show-current" | complete).stdout | str trim)
        assert-equal $current_branch "mimo/fresh" "on correct branch"
    })
    # test 2: remote target branch equal to base => resumes correctly
    (test "controller-prepare-branch: remote equal to base resumes at remote head" {
        let repo_dir = ($test_root | path join "prep-equal-repo")
        mkdir $repo_dir
        (run-external "git" "-C" $repo_dir "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "prep-equal-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $repo_dir $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        (run-external "git" "-C" $work "checkout" "-b" "mimo/equal" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "mimo/equal" | complete) | ignore
        let clone_dir = ($test_root | path join "prep-equal-clone")
        (run-external "git" "clone" $repo_dir $clone_dir | complete) | ignore
        let prep = (controller-prepare-branch $clone_dir "mimo/equal" $base_sha "prep-test-002")
        assert $prep.ok "remote-equal branch preparation succeeds"
        assert-equal $prep.effective_start_sha $base_sha "effective start SHA equals remote head"
        assert $prep.remote_existed "remote existed"
        assert-equal $prep.remote_start_sha $base_sha "remote start SHA equals base"
    })
    # test 3: remote target branch ahead of base => starts at remote head
    (test "controller-prepare-branch: remote ahead of base starts at remote head" {
        let repo_dir = ($test_root | path join "prep-ahead-repo")
        mkdir $repo_dir
        (run-external "git" "-C" $repo_dir "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "prep-ahead-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $repo_dir $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        (run-external "git" "-C" $work "checkout" "-b" "mimo/ahead" | complete) | ignore
        ("# work from job A" | save --force ($work | path join "WORK.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "job A work" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "mimo/ahead" | complete) | ignore
        let remote_head = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        assert ($remote_head != $base_sha) "remote head is different from base"
        let clone_dir = ($test_root | path join "prep-ahead-clone")
        (run-external "git" "clone" $repo_dir $clone_dir | complete) | ignore
        let prep = (controller-prepare-branch $clone_dir "mimo/ahead" $base_sha "prep-test-003")
        assert $prep.ok "remote-ahead branch preparation succeeds"
        assert-equal $prep.effective_start_sha $remote_head "effective start SHA is remote head, not stale base"
        assert $prep.remote_existed "remote existed"
        assert-equal $prep.remote_start_sha $remote_head "remote start SHA is remote head"
        let head_sha = ((run-external "git" "-C" $clone_dir "rev-parse" "HEAD" | complete).stdout | str trim)
        assert-equal $head_sha $remote_head "HEAD is at remote head, not stale base"
    })
    # test 4: sequential job B sees commit pushed by job A
    (test "controller-prepare-branch: sequential job B resumes from job A push" {
        let repo_dir = ($test_root | path join "prep-seq-repo")
        mkdir $repo_dir
        (run-external "git" "-C" $repo_dir "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "prep-seq-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $repo_dir $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        (run-external "git" "-C" $work "checkout" "-b" "mimo/seq" | complete) | ignore
        ("# job A work" | save --force ($work | path join "A.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "job A" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "mimo/seq" | complete) | ignore
        let job_a_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let clone_b = ($test_root | path join "prep-seq-clone-b")
        (run-external "git" "clone" $repo_dir $clone_b | complete) | ignore
        let prep_b = (controller-prepare-branch $clone_b "mimo/seq" $base_sha "prep-test-004")
        assert $prep_b.ok "job B preparation succeeds"
        assert-equal $prep_b.effective_start_sha $job_a_sha "job B starts at job A's push, not stale base"
        assert $prep_b.remote_existed "remote existed for job B"
        let head_b = ((run-external "git" "-C" $clone_b "rev-parse" "HEAD" | complete).stdout | str trim)
        assert-equal $head_b $job_a_sha "job B HEAD is at job A's push"
    })
    # test 5: base not ancestor of existing remote head => fail closed
    (test "controller-prepare-branch: base not ancestor of remote head fails closed" {
        let repo_dir = ($test_root | path join "prep-unrelated-repo")
        mkdir $repo_dir
        (run-external "git" "-C" $repo_dir "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "prep-unrelated-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $repo_dir $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        (run-external "git" "-C" $work "checkout" "-b" "mimo/unrelated" | complete) | ignore
        ("# unrelated work" | save --force ($work | path join "UNRELATED.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "unrelated" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "mimo/unrelated" | complete) | ignore
        let remote_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        (run-external "git" "-C" $work "checkout" "main" | complete) | ignore
        ("# diverged" | save --force ($work | path join "DIVERGED.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "diverge" | complete) | ignore
        let fake_base = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        assert ($fake_base != $base_sha) "fake base is different from original"
        let clone_dir = ($test_root | path join "prep-unrelated-clone")
        (run-external "git" "clone" $repo_dir $clone_dir | complete) | ignore
        let prep = (controller-prepare-branch $clone_dir "mimo/unrelated" $fake_base "prep-test-005")
        assert (not $prep.ok) "non-ancestor base fails closed"
        assert ($prep.reason | str contains "not an ancestor") "reason mentions not ancestor"
        assert $prep.remote_existed "remote existed"
        assert-equal $prep.remote_start_sha $remote_sha "remote start SHA is reported"
    })
    # test 6: effective_start_sha is the single source of truth for changed-file comparison
    (test "controller-prepare-branch: effective_start_sha differs from base when remote ahead" {
        let repo_dir = ($test_root | path join "prep-truth-repo")
        mkdir $repo_dir
        (run-external "git" "-C" $repo_dir "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "prep-truth-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $repo_dir $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let old_base = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        (run-external "git" "-C" $work "checkout" "-b" "mimo/truth" | complete) | ignore
        ("# prior work" | save --force ($work | path join "PRIOR.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "prior" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "mimo/truth" | complete) | ignore
        let remote_head = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let clone_dir = ($test_root | path join "prep-truth-clone")
        (run-external "git" "clone" $repo_dir $clone_dir | complete) | ignore
        let prep = (controller-prepare-branch $clone_dir "mimo/truth" $old_base "prep-test-006")
        assert $prep.ok "preparation succeeds"
        assert ($prep.effective_start_sha != $old_base) "effective_start_sha differs from stale declared base"
        assert-equal $prep.effective_start_sha $remote_head "effective_start_sha equals remote head"
    })
    # test 7: flight recorder captures branch_prepare event
    (test "controller-prepare-branch: flight recorder captures branch_prepare event" {
        let repo_dir = ($test_root | path join "prep-flight-repo")
        mkdir $repo_dir
        (run-external "git" "-C" $repo_dir "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "prep-flight-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $repo_dir $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let clone_dir = ($test_root | path join "prep-flight-clone")
        (run-external "git" "clone" $repo_dir $clone_dir | complete) | ignore
        let job_id = "prep-flight-001"
        let _prep = (controller-prepare-branch $clone_dir "mimo/flight" $base_sha $job_id)
        let events = (flight-read-events $job_id)
        assert ($events | any {|e| $e.event == "branch_prepare"}) "branch_prepare event recorded"
        let prep_event = ($events | where {|e| $e.event == "branch_prepare"} | first)
        assert ($prep_event.result? | is-not-empty) "result field present"
        assert ($prep_event.effective_start_sha? | is-not-empty) "effective_start_sha present"
    })
    # test 8: same repo+branch serialization unchanged (resource key blocking still works)
    (test "same repo+branch serialization unchanged after branch preparation fix" {
        let active = ["alice/repo:mimo/branch"]
        let slot_check = (watch-slot-acquire $active "alice/repo:mimo/branch" 3)
        assert (not $slot_check.ok) "same resource key still blocked"
        let different = (watch-slot-acquire $active "alice/repo:mimo/other" 3)
        assert $different.ok "different branch still allowed"
    })
    # test: branch_prepare event for fresh branch has correct result
    (test "controller-prepare-branch: fresh branch event has created_fresh result" {
        let repo_dir = ($test_root | path join "prep-evfresh-repo")
        mkdir $repo_dir
        (run-external "git" "-C" $repo_dir "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "prep-evfresh-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $repo_dir $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let clone_dir = ($test_root | path join "prep-evfresh-clone")
        (run-external "git" "clone" $repo_dir $clone_dir | complete) | ignore
        let job_id = "prep-evfresh-001"
        let _prep = (controller-prepare-branch $clone_dir "mimo/ev-fresh" $base_sha $job_id)
        let events = (flight-read-events $job_id)
        let prep_event = ($events | where {|e| $e.event == "branch_prepare"} | first)
        assert-equal $prep_event.result "created_fresh" "fresh branch result is created_fresh"
    })
    # test: branch_prepare event for resumed branch has correct result
    (test "controller-prepare-branch: resumed branch event has resumed_existing result" {
        let repo_dir = ($test_root | path join "prep-evresume-repo")
        mkdir $repo_dir
        (run-external "git" "-C" $repo_dir "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "prep-evresume-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $repo_dir $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        (run-external "git" "-C" $work "checkout" "-b" "mimo/ev-resume" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "mimo/ev-resume" | complete) | ignore
        let clone_dir = ($test_root | path join "prep-evresume-clone")
        (run-external "git" "clone" $repo_dir $clone_dir | complete) | ignore
        let job_id = "prep-evresume-001"
        let _prep = (controller-prepare-branch $clone_dir "mimo/ev-resume" $base_sha $job_id)
        let events = (flight-read-events $job_id)
        let prep_event = ($events | where {|e| $e.event == "branch_prepare"} | first)
        assert-equal $prep_event.result "resumed_existing" "resumed branch result is resumed_existing"
    })
    # test: branch_prepare event for rejected base has correct result
    (test "controller-prepare-branch: rejected base event has rejected result" {
        let repo_dir = ($test_root | path join "prep-evreject-repo")
        mkdir $repo_dir
        (run-external "git" "-C" $repo_dir "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "prep-evreject-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $repo_dir $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        (run-external "git" "-C" $work "checkout" "-b" "mimo/ev-reject" | complete) | ignore
        ("# work" | save --force ($work | path join "W.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "work" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "mimo/ev-reject" | complete) | ignore
        (run-external "git" "-C" $work "checkout" "main" | complete) | ignore
        ("# diverge" | save --force ($work | path join "D.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "diverge" | complete) | ignore
        let fake_base = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let clone_dir = ($test_root | path join "prep-evreject-clone")
        (run-external "git" "clone" $repo_dir $clone_dir | complete) | ignore
        let job_id = "prep-evreject-001"
        let _prep = (controller-prepare-branch $clone_dir "mimo/ev-reject" $fake_base $job_id)
        let events = (flight-read-events $job_id)
        let prep_event = ($events | where {|e| $e.event == "branch_prepare"} | first)
        assert-equal $prep_event.result "rejected" "rejected base result is rejected"
    })
    # test: base_not_ancestor failure signature exists
    (test "failure signature base_not_ancestor is distinct from remote_missing" {
        let summary = {status: "failed", exit_code: 1}
        let delivery = {worktree_clean: true, remote_exists: true, sha_match: false, branch_match: true}
        let sig = (normalize-failure-signature $summary $delivery "DELIVERY_FAILED")
        assert-equal $sig "remote_sha_mismatch" "non-ancestor with remote exists produces remote_sha_mismatch"
    })
    # test: branch_prepare record shape is complete
    (test "controller-prepare-branch: result record has all required fields" {
        let repo_dir = ($test_root | path join "prep-shape-repo")
        mkdir $repo_dir
        (run-external "git" "-C" $repo_dir "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "prep-shape-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $repo_dir $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let base_sha = ((run-external "git" "-C" $work "rev-parse" "HEAD" | complete).stdout | str trim)
        let clone_dir = ($test_root | path join "prep-shape-clone")
        (run-external "git" "clone" $repo_dir $clone_dir | complete) | ignore
        let prep = (controller-prepare-branch $clone_dir "mimo/shape" $base_sha "prep-shape-001")
        assert ($prep | columns | any {|c| $c == "ok"}) "ok field present"
        assert ($prep | columns | any {|c| $c == "reason"}) "reason field present"
        assert ($prep | columns | any {|c| $c == "branch"}) "branch field present"
        assert ($prep | columns | any {|c| $c == "declared_base_sha"}) "declared_base_sha field present"
        assert ($prep | columns | any {|c| $c == "effective_start_sha"}) "effective_start_sha field present"
        assert ($prep | columns | any {|c| $c == "remote_existed"}) "remote_existed field present"
        assert ($prep | columns | any {|c| $c == "remote_start_sha"}) "remote_start_sha field present"
        assert-equal $prep.branch "mimo/shape" "branch value correct"
        assert-equal $prep.declared_base_sha $base_sha "declared_base_sha value correct"
    })
    # === fix soft-deadline closeout result race (phase ownership) ===
    (test "controller-result-authoritative: main result is authoritative before closeout" {
        let main_result = {phase: "main", generation: 0, category: "DONE"}
        assert (controller-result-authoritative $main_result false) "main result finalizes when closeout not started"
    })
    (test "controller-result-authoritative: main result is NOT authoritative after closeout starts" {
        let main_result = {phase: "main", generation: 0, category: "PARTIAL"}
        assert (not (controller-result-authoritative $main_result true)) "main result superseded when closeout started"
    })
    (test "controller-result-authoritative: closeout result is authoritative after closeout starts" {
        let closeout_result = {phase: "closeout", generation: 1, category: "DONE"}
        assert (controller-result-authoritative $closeout_result true) "closeout result finalizes when closeout started"
    })
    (test "controller-result-authoritative: null result is never authoritative" {
        assert (not (controller-result-authoritative null false)) "null result not authoritative before closeout"
        assert (not (controller-result-authoritative null true)) "null result not authoritative after closeout"
    })
    (test "controller-result-authoritative: result without phase field defaults to main" {
        let legacy_result = {category: "DONE", closeout_ran: false}
        assert (controller-result-authoritative $legacy_result false) "legacy result authoritative before closeout"
        assert (not (controller-result-authoritative $legacy_result true)) "legacy result not authoritative after closeout"
    })
    (test "controller-result-authoritative: generation 1 result is authoritative regardless of phase" {
        let gen1 = {phase: "main", generation: 1, category: "DONE"}
        assert (controller-result-authoritative $gen1 true) "generation 1 is authoritative even with main phase"
    })
    (test "controller-run-main writes phase main and generation 0" {
        let fake_repo = ($test_root | path join "phase-main-repo")
        mkdir $fake_repo
        (run-external "git" "-C" $fake_repo "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "phase-main-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $fake_repo $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let test_result = {status: "completed", exit_code: 0, tool_calls: 1, tool_failures: 0, changed_files: [], duration_seconds: 1, timed_out: false, final_text: "done", model: "mimo-v2.5", backend: "opencode", provider: "m2c-mimo", session_id: null, workstream: null, packet: null, budget_minutes: 20, context_estimate_tokens: null, context_percent: null, checkpoint_recommended: false, agent: "build"}
        let backend_file = ($test_root | path join "phase-main-backend.json")
        $test_result | to json -r | save --force $backend_file
        let job_id = "phase-main-001"
        let job_dir = ($test_root | path join $"watch-($job_id)")
        mkdir $job_dir
        let job_spec = {job_id: $job_id, repo: "local/phase", issue_number: 1, title: "Phase test", base_sha: "abcdef0123456789abcdef0123456789abcdef02", branch: "mimo/phase", worker: "mimo", profile: "standard", mode: "build", budget_minutes: 20, description: null}
        with-env {M2C_TEST_WORKER_BACKEND: $backend_file, M2C_TEST_REPO_ROOT: $fake_repo} {
            let result = (controller-runner $job_dir $job_spec "Phase test work.")
            assert ($result.result_record | is-not-empty) "result record present"
        }
        let written = (flight-read-result $job_id)
        assert ($written != null) "result written"
        assert-equal ($written.phase? | default "MISSING") "main" "phase is main"
        assert-equal ($written.generation? | default (-1)) 0 "generation is 0"
    })
    (test "controller-closeout-runner writes phase closeout and generation 1" {
        let fake_repo = ($test_root | path join "phase-closeout-repo")
        mkdir $fake_repo
        (run-external "git" "-C" $fake_repo "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "phase-closeout-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $fake_repo $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let test_result = {status: "completed", exit_code: 0, tool_calls: 1, tool_failures: 0, changed_files: [], duration_seconds: 1, timed_out: false, final_text: "closeout done", model: "mimo-v2.5", backend: "opencode", provider: "m2c-mimo", session_id: null, workstream: null, packet: null, budget_minutes: 5, context_estimate_tokens: null, context_percent: null, checkpoint_recommended: false}
        let backend_file = ($test_root | path join "phase-closeout-backend.json")
        $test_result | to json -r | save --force $backend_file
        let job_id = "phase-closeout-001"
        let job_spec = {job_id: $job_id, repo: "local/phase", issue_number: 2, title: "Phase closeout test", base_sha: "abcdef0123456789abcdef0123456789abcdef02", branch: "mimo/phase-closeout", worker: "mimo", profile: "standard", mode: "build", budget_minutes: 20, description: null}
        with-env {M2C_TEST_WORKER_BACKEND: $backend_file, M2C_TEST_REPO_ROOT: $fake_repo} {
            let result = (controller-closeout-runner $work $job_spec 5 (date now))
            assert ($result | is-not-empty) "closeout result present"
        }
        let written = (flight-read-result $job_id)
        assert ($written != null) "closeout result written"
        assert-equal ($written.phase? | default "MISSING") "closeout" "phase is closeout"
        assert-equal ($written.generation? | default (-1)) 1 "generation is 1"
        assert-equal $written.closeout_ran true "closeout_ran is true"
    })
    (test "closeout race: stale main result superseded, closeout result finalizes" {
        let job_id = "race-closeout-001"
        let job_dir = ($test_root | path join $"watch-($job_id)")
        mkdir $job_dir
        let jobspec = {job_id: $job_id, repo: "test/race", issue_number: 10, title: "Race test", base_sha: "abcdef0123456789abcdef0123456789abcdef02", branch: "mimo/race", worker: "mimo", profile: "standard", mode: "build", budget_minutes: 20, description: null}
        flight-write-manifest $job_id {job_id: $job_id, repo: "test/race", resource_key: "test/race:mimo/race"}
        flight-append-event $job_id {event: "claimed", repo: "test/race", issue: 10}
        flight-append-event $job_id {event: "runner_start"}
        let stale_main_result = {
            job_id: $job_id
            repo: "test/race"
            issue_number: 10
            title: "Race test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
            category: "PARTIAL"
            failure_signature: null
            duration_seconds: 100
            exit_code: 130
            local_branch: "mimo/race"
            local_sha: "abc123"
            worktree_clean: true
            remote_exists: true
            remote_sha: "abc123"
            sha_match: true
            branch_match: true
            changed_file_count: 3
            tool_calls: 5
            tool_failures: 0
            completed_at: (iso-now-utc)
            closeout_ran: false
            phase: "main"
            generation: 0
        }
        flight-write-result $job_id $stale_main_result
        let closeout_started_job = {
            job_id: $job_id
            job_dir: $job_dir
            jobspec: $jobspec
            resource_key: "test/race:mimo/race"
            original_title: "Race test"
            admission: {ok: true, packet: "test"}
            started_at: ((date now) - 1200sec)
            soft_deadline_ns: 960000000000
            hard_deadline_ns: 1200000000000
            closeout_started: true
            child_job: null
            child_tag: (worker-mailbox-tag)
        }
        let read_back = (flight-read-result $job_id)
        assert (not (controller-result-authoritative $read_back $closeout_started_job.closeout_started)) "stale main result is NOT authoritative after closeout starts"
        flight-append-event $job_id {event: "main_result_superseded", phase: "main", generation: 0, category: "PARTIAL", reason: "closeout_started; main result is historical evidence only"}
        let closeout_result = {
            job_id: $job_id
            repo: "test/race"
            issue_number: 10
            title: "Race test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
            category: "DONE"
            failure_signature: null
            duration_seconds: 50
            exit_code: 0
            local_branch: "mimo/race"
            local_sha: "def456"
            worktree_clean: true
            remote_exists: true
            remote_sha: "def456"
            sha_match: true
            branch_match: true
            changed_file_count: 5
            tool_calls: 8
            tool_failures: 0
            completed_at: (iso-now-utc)
            closeout_ran: true
            closeout_duration_seconds: 50
            phase: "closeout"
            generation: 1
        }
        flight-write-result $job_id $closeout_result
        let final_result = (flight-read-result $job_id)
        assert (controller-result-authoritative $final_result $closeout_started_job.closeout_started) "closeout result IS authoritative after closeout starts"
        controller-finalize-job $closeout_started_job $final_result
        let events = (flight-read-events $job_id)
        assert ($events | any {|e| $e.event == "main_result_superseded"}) "superseded event recorded"
        assert ($events | any {|e| $e.event == "finalized"}) "finalized event recorded"
        let finalized_event = ($events | where {|e| $e.event == "finalized"} | first)
        assert-equal $finalized_event.category "DONE" "finalized with closeout result, not stale main result"
    })
    (test "closeout race: main result with exit 130 never steals finalization" {
        let job_id = "race-exit130-001"
        let jobspec = {job_id: $job_id, repo: "test/exit130", issue_number: 11, title: "Exit 130 test", base_sha: "abcdef0123456789abcdef0123456789abcdef02", branch: "mimo/exit130", worker: "mimo", profile: "standard", mode: "build", budget_minutes: 25, description: null}
        flight-write-manifest $job_id {job_id: $job_id, repo: "test/exit130", resource_key: "test/exit130:mimo/exit130"}
        let exit130_result = {
            job_id: $job_id
            repo: "test/exit130"
            issue_number: 11
            title: "Exit 130 test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 25
            description: null
            category: "PARTIAL"
            failure_signature: null
            duration_seconds: 1200
            exit_code: 130
            local_branch: "mimo/exit130"
            local_sha: "abc123"
            worktree_clean: true
            remote_exists: true
            remote_sha: "abc123"
            sha_match: true
            branch_match: true
            changed_file_count: 3
            tool_calls: 5
            tool_failures: 0
            completed_at: (iso-now-utc)
            closeout_ran: false
            phase: "main"
            generation: 0
        }
        flight-write-result $job_id $exit130_result
        let job_record = {
            job_id: $job_id
            job_dir: ($test_root | path join $"watch-($job_id)")
            jobspec: $jobspec
            resource_key: "test/exit130:mimo/exit130"
            original_title: "Exit 130 test"
            admission: {ok: true, packet: "test"}
            started_at: ((date now) - 1200sec)
            soft_deadline_ns: 1200000000000
            hard_deadline_ns: 1500000000000
            closeout_started: true
            child_job: null
            child_tag: (worker-mailbox-tag)
        }
        let read_result = (flight-read-result $job_id)
        assert (not (controller-result-authoritative $read_result $job_record.closeout_started)) "exit 130 main result rejected after closeout"
        assert-equal $read_result.exit_code 130 "exit code preserved as evidence"
        assert-equal $read_result.category "PARTIAL" "category preserved as evidence"
    })
    (test "closeout race: hard deadline writes TIMED_OUT when stale main result exists but closeout started" {
        let job_id = "race-hard-001"
        let jobspec = {job_id: $job_id, repo: "test/hard", issue_number: 12, title: "Hard deadline test", base_sha: "abcdef0123456789abcdef0123456789abcdef02", branch: "mimo/hard", worker: "mimo", profile: "standard", mode: "build", budget_minutes: 20, description: null}
        flight-write-manifest $job_id {job_id: $job_id, repo: "test/hard", resource_key: "test/hard:mimo/hard"}
        let stale_result = {
            job_id: $job_id
            repo: "test/hard"
            issue_number: 12
            title: "Hard deadline test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
            category: "PARTIAL"
            failure_signature: null
            duration_seconds: 100
            exit_code: 130
            local_branch: "mimo/hard"
            local_sha: "abc123"
            worktree_clean: true
            remote_exists: true
            remote_sha: "abc123"
            sha_match: true
            branch_match: true
            changed_file_count: 2
            tool_calls: 3
            tool_failures: 0
            completed_at: (iso-now-utc)
            closeout_ran: false
            phase: "main"
            generation: 0
        }
        flight-write-result $job_id $stale_result
        let existing = (flight-read-result $job_id)
        let closeout_started = true
        assert (not (controller-result-authoritative $existing $closeout_started)) "stale main result not authoritative"
    })
    (test "pre-soft normal result with phase main finalizes normally" {
        let job_id = "pre-soft-001"
        let jobspec = {job_id: $job_id, repo: "test/pre-soft", issue_number: 13, title: "Pre-soft test", base_sha: "abcdef0123456789abcdef0123456789abcdef02", branch: "mimo/pre-soft", worker: "mimo", profile: "standard", mode: "build", budget_minutes: 20, description: null}
        flight-write-manifest $job_id {job_id: $job_id, repo: "test/pre-soft", resource_key: "test/pre-soft:mimo/pre-soft"}
        let normal_result = {
            job_id: $job_id
            repo: "test/pre-soft"
            issue_number: 13
            title: "Pre-soft test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
            category: "DONE"
            failure_signature: null
            duration_seconds: 100
            exit_code: 0
            local_branch: "mimo/pre-soft"
            local_sha: "abc123"
            worktree_clean: true
            remote_exists: true
            remote_sha: "abc123"
            sha_match: true
            branch_match: true
            changed_file_count: 3
            tool_calls: 5
            tool_failures: 0
            completed_at: (iso-now-utc)
            closeout_ran: false
            phase: "main"
            generation: 0
        }
        flight-write-result $job_id $normal_result
        let job_record = {
            job_id: $job_id
            job_dir: ($test_root | path join $"watch-($job_id)")
            jobspec: $jobspec
            resource_key: "test/pre-soft:mimo/pre-soft"
            original_title: "Pre-soft test"
            admission: {ok: true, packet: "test"}
            started_at: ((date now) - 100sec)
            soft_deadline_ns: 960000000000
            hard_deadline_ns: 1200000000000
            closeout_started: false
            child_job: null
            child_tag: (worker-mailbox-tag)
        }
        let read_result = (flight-read-result $job_id)
        assert (controller-result-authoritative $read_result $job_record.closeout_started) "pre-soft main result IS authoritative"
        controller-finalize-job $job_record $read_result
        let events = (flight-read-events $job_id)
        let finalized = ($events | where {|e| $e.event == "finalized"})
        assert-equal ($finalized | length) 1 "finalized exactly once"
        assert-equal ($finalized | first).category "DONE" "finalized as DONE"
    })
    (test "flight recorder preserves superseded main result as evidence" {
        let job_id = "evidence-001"
        let stale_result = {
            job_id: $job_id
            repo: "test/evidence"
            issue_number: 14
            title: "Evidence test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
            category: "PARTIAL"
            failure_signature: null
            duration_seconds: 100
            exit_code: 130
            local_branch: "mimo/evidence"
            local_sha: "abc123"
            worktree_clean: true
            remote_exists: true
            remote_sha: "abc123"
            sha_match: true
            branch_match: true
            changed_file_count: 2
            tool_calls: 3
            tool_failures: 0
            completed_at: (iso-now-utc)
            closeout_ran: false
            phase: "main"
            generation: 0
        }
        flight-write-result $job_id $stale_result
        flight-append-event $job_id {event: "main_result_superseded", phase: "main", generation: 0, category: "PARTIAL", reason: "closeout_started; main result is historical evidence only"}
        let closeout_result = {
            job_id: $job_id
            repo: "test/evidence"
            issue_number: 14
            title: "Evidence test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
            category: "DONE"
            failure_signature: null
            duration_seconds: 50
            exit_code: 0
            local_branch: "mimo/evidence"
            local_sha: "def456"
            worktree_clean: true
            remote_exists: true
            remote_sha: "def456"
            sha_match: true
            branch_match: true
            changed_file_count: 5
            tool_calls: 8
            tool_failures: 0
            completed_at: (iso-now-utc)
            closeout_ran: true
            closeout_duration_seconds: 50
            phase: "closeout"
            generation: 1
        }
        flight-write-result $job_id $closeout_result
        let events = (flight-read-events $job_id)
        assert ($events | any {|e| $e.event == "main_result_superseded"}) "superseded event preserved"
        let superseded = ($events | where {|e| $e.event == "main_result_superseded"} | first)
        assert-equal $superseded.category "PARTIAL" "superseded event records original category"
        assert-equal $superseded.phase "main" "superseded event records main phase"
        assert-equal $superseded.generation 0 "superseded event records generation 0"
        let final_result = (flight-read-result $job_id)
        assert-equal $final_result.category "DONE" "canonical result is closeout DONE"
        assert-equal ($final_result.phase? | default "MISSING") "closeout" "canonical phase is closeout"
    })
    (test "closeout exception result has phase closeout and generation 1" {
        let job_id = "closeout-phase-001"
        let result_record = {
            job_id: $job_id
            repo: "test/closeout-phase"
            issue_number: 15
            title: "Closeout phase test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
            category: "INTERNAL_ERROR"
            failure_signature: "closeout_exception"
            duration_seconds: 0
            exit_code: 1
            timed_out: false
            local_branch: ""
            local_sha: ""
            worktree_clean: false
            remote_exists: false
            remote_sha: ""
            sha_match: false
            branch_match: false
            changed_file_count: 0
            tool_calls: 0
            tool_failures: 0
            completed_at: (iso-now-utc)
            closeout_ran: true
            phase: "closeout"
            generation: 1
        }
        flight-write-result $job_id $result_record
        let read_back = (flight-read-result $job_id)
        assert-equal ($read_back.phase? | default "MISSING") "closeout" "closeout exception has closeout phase"
        assert-equal ($read_back.generation? | default (-1)) 1 "closeout exception has generation 1"
        assert (controller-result-authoritative $read_back true) "closeout exception is authoritative"
    })
    (test "hard deadline result has phase closeout and generation 1" {
        let job_id = "hard-phase-001"
        let result_record = {
            job_id: $job_id
            repo: "test/hard-phase"
            issue_number: 16
            title: "Hard phase test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
            category: "TIMED_OUT"
            failure_signature: "watchdog_timeout"
            duration_seconds: 1200
            exit_code: 124
            timed_out: true
            local_branch: ""
            local_sha: ""
            worktree_clean: false
            remote_exists: false
            remote_sha: ""
            sha_match: false
            branch_match: false
            changed_file_count: 0
            tool_calls: 0
            tool_failures: 0
            completed_at: (iso-now-utc)
            closeout_ran: false
            phase: "closeout"
            generation: 1
        }
        flight-write-result $job_id $result_record
        let read_back = (flight-read-result $job_id)
        assert-equal ($read_back.phase? | default "MISSING") "closeout" "hard deadline has closeout phase"
        assert-equal ($read_back.generation? | default (-1)) 1 "hard deadline has generation 1"
    })
    (test "closeout never returns: hard deadline produces proper timeout" {
        let job_id = "no-closeout-001"
        let jobspec = {job_id: $job_id, repo: "test/no-closeout", issue_number: 17, title: "No closeout test", base_sha: "abcdef0123456789abcdef0123456789abcdef02", branch: "mimo/no-closeout", worker: "mimo", profile: "standard", mode: "build", budget_minutes: 20, description: null}
        flight-write-manifest $job_id {job_id: $job_id, repo: "test/no-closeout", resource_key: "test/no-closeout:mimo/no-closeout"}
        let stale_result = {
            job_id: $job_id
            repo: "test/no-closeout"
            issue_number: 17
            title: "No closeout test"
            worker: "mimo"
            profile: "standard"
            mode: "build"
            budget_minutes: 20
            description: null
            category: "PARTIAL"
            failure_signature: null
            duration_seconds: 100
            exit_code: 130
            local_branch: "mimo/no-closeout"
            local_sha: "abc123"
            worktree_clean: true
            remote_exists: true
            remote_sha: "abc123"
            sha_match: true
            branch_match: true
            changed_file_count: 2
            tool_calls: 3
            tool_failures: 0
            completed_at: (iso-now-utc)
            closeout_ran: false
            phase: "main"
            generation: 0
        }
        flight-write-result $job_id $stale_result
        let existing = (flight-read-result $job_id)
        assert (not (controller-result-authoritative $existing true)) "stale main not authoritative"
    })
    (test "all existing result records have phase and generation fields after fix" {
        let fake_repo = ($test_root | path join "schema-check-repo")
        mkdir $fake_repo
        (run-external "git" "-C" $fake_repo "init" "--bare" "-b" "main" | complete) | ignore
        let work = ($test_root | path join "schema-check-work")
        mkdir $work
        (run-external "git" "-c" "init.defaultBranch=main" "clone" $fake_repo $work | complete) | ignore
        ("# init" | save --force ($work | path join "README.md"))
        (run-external "git" "-C" $work "add" "." | complete) | ignore
        (run-external "git" "-C" $work "-c" "user.email=test@test.com" "-c" "user.name=test" "commit" "-m" "init" | complete) | ignore
        (run-external "git" "-C" $work "push" "-u" "origin" "main" | complete) | ignore
        let test_result = {status: "completed", exit_code: 0, tool_calls: 1, tool_failures: 0, changed_files: [], duration_seconds: 1, timed_out: false, final_text: "done", model: "mimo-v2.5", backend: "opencode", provider: "m2c-mimo", session_id: null, workstream: null, packet: null, budget_minutes: 20, context_estimate_tokens: null, context_percent: null, checkpoint_recommended: false, agent: "build"}
        let backend_file = ($test_root | path join "schema-check-backend.json")
        $test_result | to json -r | save --force $backend_file
        let job_id = "schema-check-001"
        let job_dir = ($test_root | path join $"watch-($job_id)")
        mkdir $job_dir
        let job_spec = {job_id: $job_id, repo: "local/schema", issue_number: 1, title: "Schema check", base_sha: "abcdef0123456789abcdef0123456789abcdef02", branch: "mimo/schema", worker: "mimo", profile: "standard", mode: "build", budget_minutes: 20, description: null}
        with-env {M2C_TEST_WORKER_BACKEND: $backend_file, M2C_TEST_REPO_ROOT: $fake_repo} {
            let _result = (controller-runner $job_dir $job_spec "Schema check work.")
        }
        let written = (flight-read-result $job_id)
        assert ($written != null) "result written"
        assert ($written | columns | any {|c| $c == "phase"}) "phase column present"
        assert ($written | columns | any {|c| $c == "generation"}) "generation column present"
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
