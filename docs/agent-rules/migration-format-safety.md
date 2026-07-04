# Migration and Format Safety Rules

Read this when the task touches data migrations, format conversions, irreversible transformations, stored data compatibility, package/import/export formats, schema changes, copy-forward vs in-place upgrades, or rollback paths.

Do not read this for changes that do not affect stored data or formats.

## Defaults

Preserve compatibility by default. Prefer additive changes, compatibility shims, copy-forward upgrades, and explicit migration paths over abrupt breaks.

Do not perform irreversible in-place transformations without approval.

Before implementing a stored-data, schema, package, import, export, or file-format change, design the migration as if old real user data must still open successfully.

Prefer dry-run, copy-forward, compatibility-reader, or backup-before-write behavior where practical.

For import/export formats, preserve backward compatibility by default. New versions should read older exported files/packages unless the user explicitly approves a break.

Do not silently change what an exported package, backup, or portable file includes. If contents change, state what now travels, what stays local, and what is intentionally excluded.

## Before changing formats

Explain:

- what format/schema changes,
- who or what is affected,
- backward/forward compatibility,
- migration path,
- rollback path,
- how corrupted/partial data is handled.

## Verification

Test old data, new data, malformed data, interrupted migration, and rollback/recovery paths when practical. Do not present a migration as safe without verifying representative cases.
