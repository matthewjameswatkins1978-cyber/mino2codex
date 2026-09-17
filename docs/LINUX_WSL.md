# Linux and WSL

Use Nushell for installation and execution. Linux and WSL have independent Nushell data and autoload directories, so each environment needs its own `nu install.nu` and `m2c setup`. Ubuntu CI exercises Linux semantics; a real local WSL smoke test is still required before release.
