# Untrusted Input and External Tools Rules

Read this when the task handles untrusted or user-provided input, imported files, filenames/paths/URLs, clipboard/environment data, network responses, parsing of external data, shell command construction, subprocess orchestration, external binaries, bundled tools, codecs, GPU paths, platform services, or optional system capabilities.

Do not read this merely because routine repo commands, searches, builds, or tests produce command output. Use it when command construction, external data parsing, subprocess behavior, downloads, secrets, or tool trust may affect the plan.

## Untrusted input

Treat file contents, filenames, paths, URLs, command output, clipboard content, environment variables, imported data, and network responses as untrusted.

- Validate and constrain inputs before use.
- Prefer safe APIs over shell interpolation.
- Avoid command injection, path traversal, unsafe deserialization, and unchecked dynamic execution.
- Use parameterized queries and structured parsing where applicable.
- Fail clearly on malformed input rather than guessing silently.

## External tools and optional capabilities

If the project depends on external binaries, bundled tools, hardware codecs, GPU paths, platform services, or optional capabilities:

- preflight required capabilities and versions before expensive work,
- prefer pinned versions and checksum verification where practical,
- record provenance and licensing when redistribution is involved,
- fail early with actionable guidance when missing,
- do not silently substitute a different backend unless approved and surfaced.

## Command discipline

Prefer structured APIs over shell commands. When shell commands are necessary, avoid interpolation, cap unknown output, exclude generated/vendor/build/cache folders unless relevant, and do not rerun unchanged commands without a changed hypothesis.

## Secrets and download safety

Never include secrets, API keys, tokens, credentials, private certificates, provisioning profiles, personal data, or sensitive identifiers in code, config, logs, tests, screenshots, docs, commits, build artifacts, or support bundles.

Use platform credential stores, keychains, secure project settings, CI secrets, or runtime environment variables.

Use `.env` files only for local development. Ensure `.env` and local secret files are ignored by git.

Avoid download-and-execute patterns such as `curl | bash`, piping remote scripts into shells, or running unverified downloaded binaries.

If a task requires handling secrets, certificates, profiles, signing identities, or credentials, explain the safe storage path and avoid exposing the secret value.
