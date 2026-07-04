# User Data, Files, and Permissions Rules

Read this when the task touches user data, local files, cloud files, photos, notes, contacts, calendars, mail, messages, personal documents, storage locations, app permissions, privacy prompts, destructive operations, bulk operations, or app-owned vs user-owned paths.

Do not read this for tasks that do not read/write user content or permissions.

## Defaults

Default to read-only behavior unless write behavior is explicitly requested or already approved.

Any write operation should be user-initiated and should include, where feasible:

- dry-run or preview,
- explicit scope display,
- counts for bulk operations,
- confirmation for large/risky scopes,
- reversible alternatives.

Never implement deletion or destructive changes unless explicitly requested.

## Files and paths

When reading, writing, moving, renaming, or deleting files:

- resolve and surface exact target paths before destructive/user-visible operations,
- guard against path traversal, ambiguous relative paths, and unintended broad globs,
- prefer app-owned directories and explicitly approved workspace roots,
- never overwrite existing user-owned files without explicit confirmation,
- do not touch source media or final exports unless the user explicitly asked.

## Permissions, entitlements, sandbox, and privacy prompts

Do not add or modify app permissions, entitlements, sandbox settings, signing settings, privacy strings, hardened runtime settings, or OS capabilities without asking first and explaining:

1. what changes,
2. why it is required,
3. what user-visible prompts or impacts occur,
4. the least-privilege alternative.

Request only what is required, as late as practical. Handle denied, restricted, and limited-access states gracefully.

## Bulk or destructive scope

Any destructive or broad-scope write behavior should be previewable when feasible. Guard against accidental all-library/all-folder/all-account actions.

## App state vs user content

Keep app/account/device state separate from portable user content unless the user explicitly approves combining them.

Do not silently include purchase/support state, account state, device-local cache, diagnostics, private paths, credentials, tokens, or entitlement proof in:

- exports,
- backups,
- shared project files,
- imported/exported packages,
- user-visible archives.

When designing import/export or backup behavior, specify what data travels, what stays local, and what is intentionally excluded.

## Permission-denied and limited-access UX

When permissions are denied, restricted, limited, unavailable, or not yet configured, show a graceful state.

Explain:

- what capability is limited,
- what still works,
- how the user can recover or grant access when appropriate.

Do not treat denied permissions as fatal if a useful read-only, local-only, degraded, or manual path is feasible.
