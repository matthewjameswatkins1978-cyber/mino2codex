def --wrapped m2c [...args: string] {
    source ($nu.data-dir | path join "mimo2codex" | path join "mimo2codex.nu")
    invoke ...$args
}
