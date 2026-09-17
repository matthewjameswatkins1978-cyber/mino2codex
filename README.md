# mimo2codex

`mimo2codex` lets you run Xiaomi MiMo V2.5 models through the OpenAI Codex CLI without replacing or modifying your normal Codex setup. It is a small Nushell launcher, not an AI proxy or a generic provider framework.

Requirements: OpenAI Codex CLI, Nushell 0.115 or newer, and a Xiaomi MiMo Token Plan. Windows 11, Linux, and WSL2/Ubuntu are supported.

## Quick start

```text
git clone https://github.com/matthewjameswatkins1978-cyber/mino2codex
cd mino2codex
nu install.nu
```

Open a new Nushell session, then:

```text
m2c setup
m2c
m2c standard
m2c pro
m2c models
m2c doctor
```

The default is `mimo-v2.5-pro`. Arguments that are not part of this small command namespace are passed to Codex, for example `m2c standard --help`.

## Isolation and security

The launcher sets a dedicated `CODEX_HOME` for MiMo runs. It never changes the ordinary Codex home, profiles, login state, or configuration. The current working directory, terminal streams, and Codex exit status are preserved.

Nushell stores application state under its platform-aware data directory, in a `mimo2codex` subdirectory. The generated MiMo `config.toml` and model catalogue live there. The Token Plan key is stored separately in a local private credential file; it is injected only into the launched Codex child process and is never written to JSON, TOML, the repository, diagnostics, or logs. Use `m2c key status`, `m2c key replace`, and `m2c key remove` to manage it. Removing the stored key cannot remove an already-exported `MIMO_API_KEY` from the parent shell.

No key is needed in CI. Live checks are opt-in with `m2c doctor --live`.

## Windows and WSL

Nushell's `$nu.data-dir`, autoload paths, and `path join` provide the platform-specific paths. Installation places an autoloaded `m2c` command in Nushell's user autoload directory. WSL has its own Nushell data directory and credential, so run `nu install.nu` and `m2c setup` inside WSL if you want a WSL installation. The repository and working directory are not moved or copied into `CODEX_HOME`.

## Provider details

The owned configuration uses Xiaomi's OpenAI Responses-compatible Token Plan endpoint, `https://token-plan-ams.xiaomimimo.com/v1`, and `MIMO_API_KEY`. The current Xiaomi guide also documents a China Token Plan endpoint; this project deliberately uses the Europe endpoint supplied for this installation. Both required models use the official catalogue fields, have reasoning enabled, and have web search disabled because compatibility with MiMo's Responses route is not established.

The Token Plan is intended for supported AI programming/development tools. This project launches OpenAI Codex directly; it does not expose an HTTP service, proxy, daemon, or unattended general-purpose API.

## Uninstall

Run `m2c uninstall` and type `REMOVE`, or run `nu uninstall.nu` from the checkout. This removes the installed Nushell command, isolated MiMo `CODEX_HOME`, local state, and stored credential. It does not delete repositories or normal Codex configuration. If the command was installed from a checkout that has since moved, remove the `m2c.nu` file from Nushell's user autoload directory and the `mimo2codex` directory from Nushell's data directory.

## Troubleshooting

Run `m2c doctor`. It is offline by default. Use `m2c doctor --live` only when you explicitly want a provider request. If the credential is missing or invalid, run `m2c setup` or `m2c key replace`; the launcher never falls back to OpenAI. If `m2c` is not found immediately after installation, open a new Nushell session so the user autoload directory is read.

The upstream repository currently has the historical name `mino2codex`; the product and code use `mimo2codex`. The project is unofficial and is not affiliated with Xiaomi or OpenAI.

## Development

General tests are Nushell-native and do not require a live key:

```text
nu tests/run.nu
```

The GitHub Actions matrix runs the same non-live tests on Ubuntu and Windows. Version `0.1.0` is the initial target, but it must not be called a release until both real Windows and WSL smoke tests verify both models and normal Codex remains unaffected.
