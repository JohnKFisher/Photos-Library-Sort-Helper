# User Data, Files, and Permissions Rules

Read this file when the task touches user data such as local files, cloud files, photos, notes, contacts, calendars, mail, messages, or personal documents.

## Defaults

- Default to read-only behavior unless I explicitly request write features.
- Any write operation must be user-initiated and should include, where feasible: dry-run mode, preview of changes, explicit scope display, and additional confirmation for large scopes.
- Add guardrails against unintended scope.
- Never implement deletion or destructive changes unless I explicitly ask.
- Prefer reversible alternatives.

## Files and Paths

When reading, writing, moving, renaming, or deleting files:
- Resolve and surface the exact target path before destructive or user-visible operations.
- Guard against path traversal, ambiguous relative paths, and unintended broad globs.
- Prefer app-owned directories and explicitly approved workspace roots.
- For bulk operations, preview scope and count before execution when feasible.
- Never overwrite existing files without explicit confirmation when the target is user-owned or outside normal app-owned storage.

## Permissions, Entitlements, Sandbox, and Privacy Prompts

For app permissions, entitlements, sandbox settings, signing settings, privacy strings, hardened runtime settings, or OS capabilities:
- Never add or modify them without asking first and explaining:
  1. what changes,
  2. why it is required,
  3. what user-visible prompts or impacts occur,
  4. the least-privilege alternative.
- Request only what is required, and as late as possible.
- Handle denied, restricted, and limited-access states gracefully. Explain what is limited and what still works.

## Bulk or Destructive Scope

- Any destructive or broad-scope write behavior should be previewable when feasible.
- Prefer explicit scope display and confirmation for large or risky operations.
- Guard against accidental all-library/all-folder/all-account actions.
- Prefer reversible alternatives over destructive in-place changes.
