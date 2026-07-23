# AGENTS.md — Universal Agent Router - 7/22/26 Edition

Use this file as the entry point for AI coding agents. Optimize for safety, reversibility, and low token use.

## Always-on rules

- Work only in the current repository or explicitly approved workspace.
- Prefer the smallest safe change that solves the user's request.
- When the user explicitly asks for a change, approval is implied for the narrow, low-risk implementation of that request. Ask before expanding scope, changing release/signing/privacy/data behavior, adding dependencies, performing destructive actions, or choosing among materially different approaches.
- Do not perform destructive, irreversible, privacy-sensitive, security-sensitive, compatibility-breaking, release-affecting, materially heavier/slower, or broad-scope changes without explicit approval.
- Do not add telemetry, analytics, ads, hidden network calls, new permissions, new entitlements, or new third-party dependencies unless explicitly approved.
- Do not commit, push, tag, merge, rebase, reset, cherry-pick, create branches, or create worktrees unless explicitly instructed. You may suggest good commit points.
- The user manages branch and worktree strategy manually. Do not prescribe a default branch/worktree workflow unless asked.
- Treat existing users, saved data, config files, package formats, documented commands, and public/internal interfaces as stable by default.
- Do not present mocked, partial, placeholder, scaffolded, or unverified work as complete.
- Once the requested task is complete and verified, stop. Avoid “while I’m here” refactors.

## Risk vocabulary

A tiny/low-risk edit is small, localized, easily reversible, and does not affect behavior, saved data, permissions, dependencies, release/distribution, public interfaces, durable formats, or existing user workflows beyond the requested narrow change.

A material or substantive edit changes or may reasonably affect behavior, user-visible workflows, saved data, migrations, durable file/package formats, dependencies, permissions, entitlements, signing, privacy, networking, build/release/distribution behavior, public docs, documented commands, APIs, URLs, bundle identifiers, or more than a small localized region.

A broad-scope change spans multiple unrelated areas, rewrites structure, changes architecture, changes cross-cutting patterns, performs cleanup beyond the requested task, or makes future-facing product/technical decisions not required for the immediate request.

Risk is determined by impact, not just diff size. A one-line change can be high-risk if it touches data, permissions, signing, release, compatibility, security, privacy, or durable formats.

## Rule hierarchy

Apply instructions in this order:

1. Safety, security, privacy, data integrity, reversibility, and truthfulness
2. Explicit user instruction in the current task
3. Explicit project decisions, briefs, decision logs, or release/status docs
4. Project profile rules
5. Universal conditional rules
6. General preferences and defaults

If rules conflict, surface the conflict before proceeding unless the higher-priority rule clearly resolves it.

## Minimal startup

Use minimal startup context.

For tiny, low-risk tasks, read only this file and the files directly needed for the edit.

For material edits, first report:

- current working directory
- current branch, if a git repo
- `git status --short`, if a git repo

## Conditional rule files

Load conditional rule files only when their trigger matches the task or when they may change the plan.

Never read all conditional files as startup/default safety context. Use this router, the project profile if clearly applicable, and the smallest useful set of conditional files. Prefer specific files over broad ones.

Do not report rule files loaded or skipped unless a rule conflict, safety gate, or repo-specific constraint materially affects the task.

Available files are grouped below. Paths are relative to `docs/agent-rules/`; filenames are routing hints. Read the file trigger before using the full file.

Workflow/context:
`core-workflow.md`, `context-efficiency.md`, `project-philosophy.md`, `long-running-work.md`, `local-rtk.md`

Source control/release/docs:
`git-versioning.md`, `ci-release-distribution.md`, `docs-readme-changelog.md`, `about-licensing-distribution.md`

Platforms:
`platform-apple.md`, `platform-windows.md`, `platform-web.md`, `platform-tauri.md`, `cross-platform.md`

Data/media/safety:
`user-data-permissions.md`, `migration-format-safety.md`, `media-render-export.md`, `diagnostics-privacy.md`, `untrusted-input-tools.md`, `dependencies-assets.md`, `ai-inference.md`

Always read this project's profile, if it exists, for project-specific overrides:
`docs/agent-projects/this-project.md`

## Verification

Verification is required, but scale it to risk. Prefer the cheapest meaningful check. Batch heavyweight checks after coherent related edits. Do not rerun the same failing command without a changed hypothesis.

Keep final reports proportional to task size and risk. For tiny/local changes, one or two sentences is enough: what changed and the narrow check performed. For normal/risky changes, report what changed, what was checked, what passed/failed, meaningful skipped checks, and known limitations.
