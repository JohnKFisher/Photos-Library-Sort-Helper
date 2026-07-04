# Local RTK Rules

Read only when `rtk` is available on PATH or the user asks about RTK/token-compressed command output.

Do not read this otherwise.

- Prefix shell commands with `rtk` for commands with large or unknown output when it would reduce context use.
- Do not use RTK for small deterministic output where normal commands are clearer.
- Do not assume RTK exists on other machines, CI, Codex cloud, or cloned repos.
- If unavailable, fall back to byte-capped commands.
- Do not install or configure RTK unless explicitly asked.
