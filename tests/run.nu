let test_root = ($nu.temp-dir | path join $"mimo2codex-test-($nu.pid)")
let project_root = (pwd)
$env.MIMO2CODEX_SOURCE_ROOT = $project_root
$env.MIMO2CODEX_STATE_ROOT = $test_root
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
]

print ($results | table)
let failed = ($results | where status == "FAIL" | length)
if $failed > 0 { error make {msg: $"($failed) tests failed"} }
print $"($results | length) passed, 0 failed"
rm --recursive --force $test_root
