# Architecture

Nushell owns policy, path construction, configuration generation, credential loading, diagnostics, and process launching. Codex remains the only inference client.

`nu/mimo2codex.nu` is copied by `nu install.nu` into Nushell's user data and autoload directories. Static provider/model data is copied under the same private application root. The launcher then sets `CODEX_HOME` to that root's `codex-home` directory and runs the installed `codex` executable directly.

The only semantic model mapping is `config/mimo.json`; detailed model capability metadata is in `config/model-catalogs.json`, based on Xiaomi's current Codex guide. No credential is present in either file.
