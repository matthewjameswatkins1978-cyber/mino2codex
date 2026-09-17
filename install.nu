let source = (pwd | path expand)
let root = ($nu.data-dir | path join "mimo2codex")
let autoload_dir = ($nu.user-autoload-dirs | first | path expand)
mkdir ($root | path join "config")
mkdir ($root | path join "codex-home" | path join "model-catalogs")
cp --force ($source | path join "nu" | path join "mimo2codex.nu") ($root | path join "mimo2codex.nu")
cp --force ($source | path join "VERSION") ($root | path join "VERSION")
cp --force ($source | path join "config" | path join "mimo.json") ($root | path join "config" | path join "mimo.json")
cp --force ($source | path join "config" | path join "model-catalogs.json") ($root | path join "config" | path join "model-catalogs.json")
mkdir $autoload_dir
cp --force ($source | path join "nu" | path join "autoload-m2c.nu") ($autoload_dir | path join "m2c.nu")
print "mimo2codex installed for Nushell."
print $"Runtime state: ($root)"
print "Open a new Nushell session so the m2c command is autoloaded, then run:"
print "  m2c setup"
