# Diagnostics and Privacy Rules

Read this when the task touches diagnostics, logging, crash handling, persistent logs, support bundles, screenshots, redaction, debug output, or user-sensitive diagnostic data.

Do not read this for tasks with no logging/diagnostics/debug-output impact.

## Defaults

Persistent logs should be local, minimal, redacted, and opt-in unless explicitly approved otherwise.

Do not expose filenames, paths, identifiers, metadata, personal data, or user content unless necessary for diagnosis and clearly surfaced.

Never commit sensitive logs, crash artifacts, screenshots, support bundles, or sample user data without approval.

## Support/debug exports

Support bundles should be user-initiated, previewable when feasible, and redacted by default. Clearly distinguish local diagnostics from anything that sends data externally.

## Telemetry and network diagnostics

Do not introduce telemetry, analytics, tracking, ads, remote diagnostics, or background network calls unless the user explicitly requests them.

Local-only crash logs and user-initiated "send report" actions are acceptable when they are clear, previewable when feasible, and redacted by default.

Nothing should phone home silently.
