$request = ($input | Out-String | ConvertFrom-Json)
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$source = $root.Replace('\', '/') + '/nu/mimo2codex.nu'
function Invoke-Nu([string]$expression) {
    $output = (& nu --no-config-file -c "source '$source'; ($expression) | to json -r" | Out-String).Trim()
    try { return $output | ConvertFrom-Json } catch { return $output }
}
$decision = switch ($request.case_id) {
    'build-agent' { $agent = Invoke-Nu "worker-agent 'Edit the file and run its tests'"; @{action='dispatch'; choice_id=$(if($agent -eq 'build'){'build'}else{'wrong'}); reason_codes=@('explicit_build')} }
    'plan-agent' { $agent = Invoke-Nu "worker-agent 'Plan only; do not edit files'"; @{action='dispatch'; choice_id=$(if($agent -eq 'plan'){'plan'}else{'wrong'}); reason_codes=@('explicit_plan')} }
    'explore-agent' { $agent = Invoke-Nu "worker-agent 'Review only, read-only, do not modify files'"; @{action='dispatch'; choice_id=$(if($agent -eq 'explore'){'explore'}else{'wrong'}); reason_codes=@('explicit_review')} }
    'same-mode' { $fork = Invoke-Nu "worker-fork-required 'ses-old' 'build' 'build'"; @{action='reuse'; choice_id=$(if(-not $fork){'reuse'}else{'wrong'}); reason_codes=@('compatible_mode')} }
    'mode-change' { $fork = Invoke-Nu "worker-fork-required 'ses-old' 'plan' 'build'"; @{action='fork'; choice_id=$(if($fork){'fork'}else{'wrong'}); reason_codes=@('incompatible_mode')} }
    'zero-exit-no-evidence' { $s = Invoke-Nu "worker-summary [] 'mimo-v2.5' null null 1 0 false"; @{action='reject'; choice_id=$(if($s.status -eq 'failed'){'fail'}else{'wrong'}); reason_codes=@('missing_evidence')} }
    'zero-exit-tool-failure' { $s = Invoke-Nu "worker-summary [{type:'tool_use',part:{tool:'edit',state:{status:'error'}}}] 'mimo-v2.5' null null 1 0 false"; @{action='reject'; choice_id=$(if($s.status -eq 'failed'){'fail'}else{'wrong'}); reason_codes=@('tool_failure')} }
    'malformed-scalar' { $n = Invoke-Nu "(parse-worker-events 'not-json') | length"; @{action='discard'; choice_id=$(if($n -eq 0){'discard'}else{'wrong'}); reason_codes=@('malformed_event')} }
    'linux-windows-exe' { $s = Invoke-Nu "opencode-platform-status-for 'unix' '/usr/bin/opencode.exe'"; @{action='reject'; choice_id=$(if($s.status -eq 'invalid'){'reject'}else{'wrong'}); reason_codes=@('platform_boundary')} }
    'context-ceiling' { $s = Invoke-Nu 'checkpoint-state {context_percent: 50.0}'; @{action='reject'; choice_id=$(if($s -eq 'hard_ceiling'){'ceiling'}else{'wrong'}); reason_codes=@('context_ceiling')} }
    'unknown-context' { $s = Invoke-Nu "worker-summary [] 'mimo-v2.5' null null 1 1 false"; @{action='withhold-pass'; choice_id=$(if($null -eq $s.context_percent){'unknown'}else{'wrong'}); reason_codes=@('unknown_evidence')} }
}
$decision.case_id = $request.case_id
$decision.schema = 'telltail.decision.v1'
$decision | ConvertTo-Json -Compress
