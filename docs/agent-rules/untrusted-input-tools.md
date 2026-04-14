# Untrusted Input and External Tools Rules

Read this file when the task touches imported files, filenames, paths, URLs, command output, clipboard content, environment variables, parsing, shell commands, subprocesses, external binaries, bundled tools, hardware codecs, GPU paths, platform services, or optional system capabilities.

## Untrusted Input

Treat file contents, filenames, paths, URLs, command output, clipboard content, environment variables, imported data, and network responses as untrusted input.

- Validate and constrain inputs before use.
- Prefer safe APIs over shell interpolation.
- Avoid command injection, path traversal, unsafe deserialization, and unchecked dynamic execution.
- Use parameterized queries and structured parsing where applicable.
- Fail clearly on malformed input rather than guessing silently.

## External Tools and Optional Capabilities

If the project depends on external binaries, bundled tools, hardware codecs, GPU paths, platform services, or optional system capabilities:
- Preflight required capabilities and verify versions/availability before starting expensive work.
- Prefer pinned versions and checksum verification where practical.
- Record provenance and licensing requirements in repo docs when redistribution is involved.
- Fail early with actionable guidance when a required tool or capability is missing.
- Do not silently substitute a different backend unless that fallback is already approved and clearly surfaced.
