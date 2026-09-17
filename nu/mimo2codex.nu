def state-root [] {
    if ($env.MIMO2CODEX_STATE_ROOT? | is-not-empty) {
        $env.MIMO2CODEX_STATE_ROOT | path expand
    } else {
        $nu.data-dir | path join "mimo2codex"
    }
}

def source-root [] {
    if ($env.MIMO2CODEX_SOURCE_ROOT? | is-not-empty) {
        $env.MIMO2CODEX_SOURCE_ROOT | path expand
    } else {
        state-root
    }
}

def config-path [name: string] { source-root | path join "config" $name }
def state-path [name: string] { state-root | path join $name }
def catalogue-path [] { state-root | path join "codex-home" | path join "model-catalogs" | path join "model-catalogs.json" }
def provider-data [] { open (config-path "mimo.json") }
def catalogue-data [] { open (config-path "model-catalogs.json") }
def required-models [] { let data = (provider-data); [$data.models.standard $data.models.pro] }

def valid-key [value: string] {
    let key = ($value | str trim)
    ($key | is-not-empty) and ($key | str starts-with "tp-") and (($key | str length) > 3)
}

def key-file-value [] {
    let credential_path = (state-path "credential")
    if ($credential_path | path exists) { try { open --raw $credential_path | str trim } catch { "" } } else { "" }
}

def credential-info [] {
    let env_key = ($env.MIMO_API_KEY? | default "" | str trim)
    if ($env_key | is-not-empty) {
        if (valid-key $env_key) { {status: "configured", value: $env_key, source: "environment"} } else { {status: "invalid format", value: "", source: "environment"} }
    } else {
        let stored = (key-file-value)
        if ($stored | is-empty) { {status: "missing", value: "", source: "none"} } else if (valid-key $stored) { {status: "configured", value: $stored, source: "stored"} } else { {status: "invalid format", value: "", source: "stored"} }
    }
}

def credential-status [] { credential-info | get status }

def protect-credential-file [file_path: path] {
    if $nu.os-info.family == "unix" {
        do --ignore-errors { run-external "chmod" "600" $file_path | ignore }
    } else if $nu.os-info.family == "windows" {
        let username = ($env.USERNAME? | default "")
        if ($username | is-not-empty) { do --ignore-errors { run-external "icacls" $file_path "/inheritance:r" "/grant:r" $"($username):(R,W)" | ignore } }
    }
}

def write-credential [value: string] {
    mkdir (state-root)
    $value | save --force (state-path "credential")
    protect-credential-file (state-path "credential")
}

def check-catalogue [] {
    let data = (catalogue-data)
    let slugs = ($data.models | get slug)
    let required = (required-models)
    (($data.models | length) > 0) and (($required | all {|model| $slugs | any {|slug| $slug == $model}}))
}

def toml-config [model: string] {
    let provider = (provider-data).provider
    let catalogue = (catalogue-path | path expand)
    {
        model: $model
        model_provider: $provider.id
        model_reasoning_effort: "high"
        model_supports_reasoning_summaries: true
        model_reasoning_summary: "none"
        model_context_window: $provider.context_window
        web_search: $provider.web_search
        model_catalog_json: $catalogue
        model_providers: {
            mimo: {
                name: $provider.name
                base_url: $provider.endpoint
                env_key: $provider.env_key
                wire_api: $provider.protocol
                requires_openai_auth: $provider.requires_openai_auth
            }
        }
    } | to toml
}

def write-codex-config [model: string] {
    mkdir (state-path "codex-home")
    (toml-config $model) | save --force (state-path "codex-home" | path join "config.toml")
}

def model-records [] {
    let data = (provider-data)
    let catalogue = (catalogue-data).models
    [
        {alias: "standard", model: $data.models.standard}
        {alias: "pro", model: $data.models.pro}
    ] | each {|row|
        let detail = ($catalogue | where slug == $row.model | first)
        {alias: $row.alias, model: $row.model, reasoning: (if $detail.supports_reasoning_summaries { "yes" } else { "no" })}
    }
}

def version-value [] { open (source-root | path join "VERSION") | str trim }
def nu-version [] { run-external $nu.current-exe "--version" | str trim }

def print-help [] {
    print "mimo2codex - Xiaomi MiMo Token Plan launcher for OpenAI Codex"
    print ""
    print "Usage: m2c [command] [Codex arguments...]"
    print ""
    print "Commands:"
    print "  m2c                 launch mimo-v2.5-pro"
    print "  m2c pro             launch mimo-v2.5-pro"
    print "  m2c standard        launch mimo-v2.5"
    print "  m2c models          list supported models"
    print "  m2c setup           install/repair isolated MiMo configuration"
    print "  m2c doctor [--live] diagnose configuration; --live checks the provider"
    print "  m2c key status      show credential status without revealing it"
    print "  m2c key replace     replace the locally stored credential"
    print "  m2c key remove      remove the locally stored credential"
    print "  m2c uninstall       remove the installed command and MiMo state"
    print "  m2c version         show the installed version"
    print "  m2c help            show this help"
}

def read-codex-version [] {
    let found = (which codex | get path? | first | default "")
    if ($found | is-empty) { "missing" } else { try { run-external "codex" "--version" | str trim } catch { "unavailable" } }
}

def check-row [label: string status: string detail: string] { {check: $label, status: $status, detail: $detail} }

def live-check [credential: record] {
    let provider = (provider-data).provider
    let body = {model: (provider-data).models.standard, input: "Reply with exactly OK.", max_output_tokens: 16, stream: false} | to json
    let headers = {Authorization: $"Bearer ($credential.value)", Content-Type: "application/json"}
    try { http post --headers $headers $"($provider.endpoint)/responses" $body | ignore; "PASS" } catch { "FAIL" }
}

def doctor [args: list<string> = []] {
    let live = ($args | any {|arg| $arg == "--live"})
    let provider = (provider-data).provider
    let catalog_ok = (try { check-catalogue } catch { false })
    let credential = (credential-info)
    let codex_path = (which codex | get path? | first | default "")
    let codex_ok = ($codex_path | is-not-empty)
    let config = (state-root | path join "codex-home" | path join "config.toml")
    let catalogue_path = (catalogue-path)
    let rows = [
        (check-row "Platform" (if (["windows", "unix"] | any {|x| $x == $nu.os-info.family}) { "PASS" } else { "FAIL" }) $nu.os-info.name)
        (check-row "Nushell" "PASS" (nu-version))
        (check-row "Codex" (if $codex_ok { "PASS" } else { "FAIL" }) (if $codex_ok { (read-codex-version) } else { "not found" }))
        (check-row "MiMo config directory" (if (state-root | path exists) { "PASS" } else { "FAIL" }) (state-root))
        (check-row "Isolated CODEX_HOME" (if (state-root | path join "codex-home" | path exists) { "PASS" } else { "FAIL" }) (state-root | path join "codex-home"))
        (check-row "MiMo config.toml" (if ($config | path exists) { "PASS" } else { "FAIL" }) $config)
        (check-row "Model catalogue" (if (($catalogue_path | path exists) and $catalog_ok) { "PASS" } else { "FAIL" }) $catalogue_path)
        (check-row "mimo-v2.5" (if ($catalog_ok and ((required-models).0 in ((catalogue-data).models | get slug))) { "PASS" } else { "FAIL" }) "required model")
        (check-row "mimo-v2.5-pro" (if ($catalog_ok and ((required-models).1 in ((catalogue-data).models | get slug))) { "PASS" } else { "FAIL" }) "required model")
        (check-row "Credential" $credential.status $credential.source)
        (check-row "Credential format" (if $credential.status == "configured" { "PASS" } else { "FAIL" }) "Token Plan prefix tp-")
        (check-row "Endpoint" (if $provider.endpoint == "https://token-plan-ams.xiaomimimo.com/v1" { "PASS" } else { "FAIL" }) $provider.endpoint)
        (check-row "Child environment injection" (child-injection-status $credential) "scoped to Codex child")
        (check-row "Live API" (if $live { live-check $credential } else { "SKIP" }) (if $live { "explicit check" } else { "use --live" }))
    ]
    print ($rows | table)
    let required = ($rows | where check != "Live API" | all {|row| ($row.status == "PASS") or (($row.check == "Credential") and ($row.status == "configured"))})
    if ($live and (($rows | where check == "Live API" | get status | first) != "PASS")) { error make {msg: "Live provider check failed."} }
    if (not $required) { error make {msg: "Configuration is not ready. Run m2c setup."} }
}

def setup [] {
    print "MiMo2Codex setup"
    print $"Nushell ............. OK
Codex ................ (if (which codex | is-not-empty) { 'OK' } else { 'MISSING' })
Platform ............. ($nu.os-info.name)
MiMo configuration ... installing"
    mkdir (state-root)
    mkdir (state-root | path join "codex-home" | path join "model-catalogs")
    let data = (provider-data)
    let default_model = ($data.models | get $data.default)
    write-codex-config $default_model
    (catalogue-data | to json) | save --force (catalogue-path)
    let status = (credential-status)
    if $status != "configured" {
        print ""
        let value = ((input --suppress-output "MiMo Token Plan API key: ") | str trim)
        if not (valid-key $value) { error make {msg: "The credential must be non-empty and start with tp-."} }
        write-credential $value
        print "Credential stored locally."
    } else { print "Credential already configured; leaving it unchanged." }
    print "Testing configuration..."
    print (mimo2codex-model-line "mimo-v2.5")
    print (mimo2codex-model-line "mimo-v2.5-pro")
    print ""
    print "Ready."
}

def mimo2codex-model-line [model: string] { $"($model) ............ OK" }

def prompt-and-write-key [message: string] {
    let value = ((input --suppress-output $message) | str trim)
    if not (valid-key $value) { error make {msg: "The credential must be non-empty and start with tp-."} }
    write-credential $value
}

def remove-stored-key [] {
    let credential_path = (state-root | path join "credential")
    if ($credential_path | path exists) { rm $credential_path }
}

def child-injection-status [credential: record] {
    if $credential.status != "configured" { "FAIL" } else {
        try {
            with-env {MIMO_API_KEY: $credential.value} {
                run-external $nu.current-exe "-n" "-c" "if (($env.MIMO_API_KEY? | default '') | str starts-with 'tp-') { exit 0 } else { exit 1 }"
            }
            "PASS"
        } catch { "FAIL" }
    }
}

def launch [model: string args: list<string>] {
    let credential = (credential-info)
    if $credential.status != "configured" { error make {msg: "MiMo Token Plan credential is not configured. Run: m2c setup"} }
    if not (required-models | any {|item| $item == $model}) { error make {msg: "Unknown MiMo model. Use m2c models."} }
    let config = (state-root | path join "codex-home" | path join "config.toml")
    if not ($config | path exists) { error make {msg: "MiMo configuration is not installed. Run: m2c setup"} }
    with-env {CODEX_HOME: (state-root | path join "codex-home"), MIMO_API_KEY: $credential.value} {
        run-external "codex" "--model" $model ...$args
    }
}

def key-command [args: list<string>] {
    let action = ($args | first | default "status")
    if $action == "status" { print (credential-status) } else if $action == "replace" {
        prompt-and-write-key "MiMo Token Plan API key: "
        print "Credential replaced locally."
    } else if $action == "remove" {
        remove-stored-key
        print "Stored credential removed."
    } else { error make {msg: "Unknown key command. Use status, replace, or remove."} }
}

def uninstall [] {
    print "This removes only mimo2codex's installed command and isolated state."
        let answer = ((input "Type REMOVE to continue: ") | str trim)
    if $answer != "REMOVE" { print "Uninstall cancelled."; return }
    let autoload = ($nu.user-autoload-dirs | first | path join "m2c.nu")
    if ($autoload | path exists) { rm $autoload }
    let root = (state-root)
    if ($root | path exists) { rm --recursive $root }
    print "mimo2codex removed. Normal Codex configuration and repositories were not touched."
}

export def version [] { print (version-value) }

export def invoke [...args: string] {
    let command = ($args | first | default "")
    if $command in ["help", "--help", "-h"] { print-help } else if $command == "version" { version } else if $command == "models" { model-records | table } else if $command == "setup" { setup } else if $command == "doctor" { doctor ($args | skip 1) } else if $command == "key" { key-command ($args | skip 1) } else if $command == "uninstall" { uninstall } else if $command == "pro" { launch (provider-data).models.pro ($args | skip 1) } else if $command == "standard" { launch (provider-data).models.standard ($args | skip 1) } else { launch (provider-data).models.pro $args }
}
