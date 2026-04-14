# Diagnostics and Privacy Rules

Read this file when the task touches diagnostics, logging, crash handling, persistent logs, redaction, or user-sensitive debug output.

## Diagnostics and Privacy

- Persistent logs should be opt-in, local, and redacted/minimized.
- Do not include filenames, paths, metadata, or identifiers unless necessary for diagnosis.
- Never commit sensitive logs, sample user data, or crash artifacts without explicit approval.
