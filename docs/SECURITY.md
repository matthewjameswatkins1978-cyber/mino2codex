# Security model

The Token Plan key is captured with Nushell's suppressed-output input, validated only for non-empty `tp-` format, and stored outside the checkout in a dedicated credential file. On Unix the file is chmod 600; on Windows inheritance is removed and the current user is granted read/write where `icacls` is available. The key is never intentionally printed or included in generated configuration, snapshots, CI, or logs.

Environment precedence is explicit: a valid `MIMO_API_KEY` in the current environment wins; otherwise the private local credential is used. An invalid non-empty environment value is reported as invalid rather than silently replaced. Missing credentials fail closed. No provider fallback exists.
