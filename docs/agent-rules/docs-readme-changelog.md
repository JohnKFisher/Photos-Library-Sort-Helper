# Docs, README, Decision Log, Status, and Changelog Rules

Read this when the task touches README, installation instructions, distribution notes, public docs, `docs/DECISIONS.md`, `docs/WHERE_WE_STAND.md`, `docs/WORKING_CHANGELOG.md`, end-user run instructions, or release-intended user-facing changes that may need release-note source material.

Do not read this for code-only edits unless docs/status may become inaccurate or the change is intended for release-note capture.

## README

Keep READMEs minimal, accurate, and current.

READMEs should be minimal: briefly describe the app/tool and point readers to `https://sidelarklabs.com`.

Do not claim setup, installation, distribution, platform support, release availability, public access, package contents, signing, notarization, compatibility, or generated outputs that are not currently true.

When changing behavior that makes README instructions inaccurate, update the README or clearly report the needed doc follow-up.

Do not turn the README into a changelog, planning document, architecture history, or long project diary. Route durable decisions, current project state, and release-note source material to the appropriate project docs when they exist.

## Decision log

Maintain `docs/DECISIONS.md` as a living decision log when meaningful decisions are made.

Update it when:

- a meaningful architectural, design, scope, tooling, or behavioral decision is approved,
- an open question is resolved,
- a decision is reversed or superseded.

Format:

- date,
- short decision summary,
- brief rationale,
- status: approved, reversed, or superseded.

Append new entries. Do not delete old entries; mark them superseded instead. Do not use the decision log for task status, changelogs, or TODO lists.

## Status document

For projects with meaningful versioning, milestone releases, or durable rollback points, maintain `docs/WHERE_WE_STAND.md`.

Update it only when material project state changes, such as major/minor version changes, durable known-good anchors, implemented-vs-missing status changes, or when asked.

Keep it short, practical, and written for a tech-savvy but programming-new owner. Do not let it become marketing copy or a changelog dump.

## Working changelog

Standard filename: `docs/WORKING_CHANGELOG.md`.

Update it for release-intended user-facing changes as internal release-note source material, not polished public copy.

Do not update it for tiny copy/layout fixes, exploratory changes, temporary experiments, internal-only changes, or changes the user has not decided to keep unless explicitly requested.

When unsure whether a change deserves changelog capture, do not edit the changelog automatically. Mention the possible changelog entry in the final summary instead.

Use moderately non-technical language:

- clear enough for a normal user,
- specific enough to trace back to actual work.

Focus on what changed for the user, what is safer, clearer, faster, more reliable, or easier to understand.

Avoid commit hashes, branch names, internal-only refactor notes, and speculative plans.

Do not rename an existing project changelog file unless the user explicitly asks; note the standard and let the user migrate manually if desired.

## Working changelog style

Use lightweight markers when helpful:

- `[public candidate]` for changes that may deserve public release-note mention,
- `[needs review]` for changes that are uncertain, incomplete, still being tested, or not ready for public wording.

Do not overuse markers for routine internal notes.

## Breadcrumbs

When implementing behavior that is likely to confuse a future maintainer, leave a small breadcrumb in the most appropriate place.

Prefer concise documentation, decision logs, or targeted comments over extensive inline explanation.