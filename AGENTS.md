# AGENTS.md — Universal Project Rules

This file is the single source of truth for AI coding agents across this project. It is read by both OpenAI Codex (natively) and Claude Code (via `CLAUDE.md` pointer).
Work safely, conservatively, and transparently.
Assume I may not deeply review code and may not notice hidden risks in my request.
If a change is destructive, user-visible, security-sensitive, privacy-sensitive, materially worse for the app’s core job, materially slower/heavier, architecturally surprising, or meaningfully expands scope, stop and ask first.
Follow everything in this file regardless of which agent is running. Conditional rule files apply when their triggers match the task.

## Rule Hierarchy

Apply instructions in this order:

1. Safety, security, privacy, data integrity, reversibility, and truthfulness
2. Explicit project approvals in the brief, milestone plan, or decision log
3. Project workflow and continuity rules
4. Default product, UX, implementation, and communication preferences

If there is a conflict, the higher-priority rule wins unless I explicitly override it.

## Who I Am

Solo developer building personal-use apps. Optimize for usefulness, clarity, reliability, and low friction over impressiveness. Not building for a broad market. Favor practical daily usability over feature count. Favor understandable, inspectable behavior over magic or hidden automation. Do not add complexity in anticipation of future needs unless there is a strong reason.

Default stack: Swift for Apple-native projects, Tauri (Rust + WebView) for cross-platform desktop apps, unless I specify otherwise. If a different stack would be meaningfully better for a given project, suggest it with reasoning — but do not switch without approval.

Core values: safe by default; local-first and least-privilege by default; visible behavior over hidden behavior; reversible changes over destructive changes; measured impact over assumptions; explicit tradeoffs over silent fallbacks; honest status over confident-sounding partial work.

## Session Startup

At the start of every session, read these files if they exist in the repo:
- `docs/DECISIONS.md` — the project decision log
- `docs/WHERE_WE_STAND.md` — the current project status snapshot
- any current project brief or milestone plan if present

Use them to understand approved decisions, current state, known risks, open priorities, and prior constraints that should not be re-litigated accidentally before beginning work.

After reading the core project docs, identify all conditional rule files that apply to the task. More than one often applies. Read every matching file before planning or coding. Do not stop after the first match.

## Safety-First Principles (Non-Negotiable)

- Do not run destructive commands or perform destructive actions without explicit approval.
  - Examples: deleting files, bulk modifications, irreversible migrations, removing user content, force-overwriting outputs, resetting data, discarding current work, or destructive rollback.
- Do not modify files outside the current repository or explicitly approved workspace.
- Do not introduce telemetry, analytics, tracking, ads, or background network calls unless I explicitly request them. Local-only crash logs and explicit user-initiated "send report" actions are acceptable without per-project approval, but must not phone home silently.
- Do not add new third-party dependencies unless they are necessary, justified, and called out before implementation.
- Never include secrets in code, config, logs, tests, screenshots, docs, or commits.
  - Store secrets in platform keychain/credential store or runtime environment variables. Use `.env` files only for local development and always include `.env` in `.gitignore`.
- Avoid "download and execute" patterns such as `curl | bash`.
- Do not silently weaken privacy, security, data integrity, or determinism through hidden retries, fallbacks, uploads, writes, overwrites, or permission expansion.
- If actual behavior differs from requested behavior, report both the requested result and the actual result, with the reason.

## Ask-First Gate

Stop and ask first unless the behavior is already clearly approved by the project brief, the decision log (`docs/DECISIONS.md`), the current milestone plan, or an explicit user instruction.

Especially ask before:
- destructive actions or irreversible outputs,
- user-visible behavior changes,
- compatibility breaks,
- permission or entitlement changes,
- new network behavior,
- new long-running background work,
- materially heavier behavior,
- architectural pivots,
- reduced privacy/security,
- or major/minor version changes,
- or scope expansion beyond the request.

If approval is needed, present 2 to 3 options with pros/cons and recommend one.

If a project-specific brief, milestone plan, or decision log explicitly approves behavior that would otherwise require re-asking under these general rules, follow that approval while still honoring safety, privacy, reversibility, and transparency. If there is a conflict, the stricter safety/privacy rule wins unless I explicitly override it.

## Working With Me

- Ask clarifying questions freely when they will improve the result, expose a tradeoff, or reduce the chance of a wrong turn.
- Offer suggestions freely when they may improve safety, usability, maintainability, fit, or overall quality.
- Distinguish clearly between what I asked for, what you recommend, and what is optional.
- Do not treat suggestions as approved changes unless I explicitly approve them.
- I value back-and-forth iteration and course correction more than one giant "finished" pass.
- Small related improvements are welcome when low-risk and clearly disclosed. Do not silently turn one requested change into a broad rewrite. If additional improvements seem worthwhile, mention them in the plan before coding, or list them separately as suggestions. Smart adjacent judgment is useful. Silent scope expansion is not.
- Be clear, direct, and practical. Do not hide uncertainty behind confident language. Surface meaningful tradeoffs. When there are real choices, present them cleanly and recommend one. Avoid unnecessary jargon when a plain description will do. Be helpful without becoming overeager or sprawling.
- Do not treat defaults or preferences in this file as approval to make behavior-changing edits without the normal ask-first checks.

## Implementation Style

- Prefer the simplest solution that genuinely solves the problem.
- Prefer small, reviewable steps over large, sweeping rewrites.
- Prefer straightforward code over clever code.
- Prefer explicitness over hidden indirection.
- Keep comments concise, useful, and focused on intent.
- Avoid broad tooling churn unless it clearly helps.
- Do not modify dependency manifests, lockfiles, formatter rules, lint rules, compiler settings, CI config, or build scripts unless the task actually requires it. If such changes are required, call them out explicitly in the plan and summary.
- Follow the project's existing code formatting and linting conventions. If none exist, use the language's community-standard formatter (e.g., swift-format for Swift, rustfmt for Rust, Prettier for JS/TS) with default settings.
- Preserve existing behavior unless the requested task requires changing it.
- Update docs when behavior, setup, architecture, or operational expectations materially change.
- For risky, user-visible, or behavior-changing work, prefer opt-in controls, staged rollout paths, feature flags, or isolated code paths. Default new risky behavior to off unless the project plan clearly says otherwise.

## Task Workflow

### Before Coding

Provide:
1. a short plan,
2. the files expected to change,
3. any new dependencies, permissions, entitlements, migrations, external tools, or network behavior,
4. risk level: low / medium / high.

Also:
- Call out meaningful uncertainty or hidden risk.
- Note whether the task appears likely to affect performance, reliability, compatibility, output quality, or user data.
- Check `docs/DECISIONS.md` for relevant prior decisions before proposing something that may have already been decided.
- State which conditional rule files were reviewed for this task and why. If none, say "none."

### Verification (Required Output)

Provide:
- exact build/run/test steps,
- a short manual smoke-test checklist,
- meaningful before/after measurements when performance, reliability, or output quality may have changed.

If the task could affect user data, permissions, fallbacks, or long-running work, verify the relevant safety conditions from the applicable conditional sections below.

### Change Summary (Required Output)

Provide:
- files changed,
- what was added, removed, or behaviorally changed,
- known limitations,
- follow-ups or deferred risks,
- whether a new build was completed, not completed, or not attempted (make this the final line — do not make me infer build status from context).

## Decision Log

Maintain `docs/DECISIONS.md` as a living decision log for the project.

**When to update it:** when a meaningful architectural, design, scope, tooling, or behavioral decision is made or approved; when an open question is resolved; when a decision is reversed or superseded.

**Format:** date, short decision summary, brief rationale (why this over alternatives), status (approved / reversed / superseded).

**Rules:**
- Append new entries; do not delete or rewrite old ones. Mark superseded entries as such.
- Keep entries concise — one to three sentences each.
- Do not use the decision log for task status, changelogs, or TODO lists. Those belong in `docs/WHERE_WE_STAND.md` or issue trackers.
- Do not propose something that contradicts an approved decision without flagging the conflict.

## Status Document

For projects with meaningful versioning, milestone releases, or durable rollback points, maintain a concise status document at `docs/WHERE_WE_STAND.md`.

**When to update it:** at the end of every session that changes the project materially; on major or minor version bumps; when a durable known-good anchor is created; when I ask; when implemented-vs-missing status materially changes.

**What to include:** project name, current version/build, plain-language overall status, what works now, what is partial, what is not implemented yet, known limitations and trust warnings, setup/runtime requirements, important operational risks, recommended next priorities, most recent durable known-good anchor if one exists.

**Rules:**
- Keep it short, practical, and written for a tech-savvy but programming-new owner.
- Do not let it become marketing copy, vague filler, or a changelog dump.
- Update it at session end if the project state changed.

## Git Workflow and Recovery

- Default branch strategy is commit-to-main unless I specify otherwise. Do not create feature branches, pull requests, or branch-based workflows without being asked.
- Write commit messages as short imperative sentences, ≤72 characters for the subject line. e.g. `Add login screen`, `Fix empty CSV export crash`. Add a body paragraph for non-obvious changes explaining why, not just what.
- At session end, commit completed work with a clear message. Leave work-in-progress uncommitted and note what remains in the change summary.
- Do not make material code changes in a repo with no commit history. If no baseline commit exists, stop and ask first.
- For medium- or high-risk tasks, create or recommend a rollback point before material edits.
- Prefer small, reviewable commits at stable milestones over large opaque changes.
- Do not delete history, rewrite history, reset branches, or discard uncommitted work without explicit approval.
- If I explicitly identify a state as known good, create or recommend a durable rollback anchor using the repo's normal workflow.
- Before any rollback or reset-like action, explain exactly what target would be restored and what current work could be lost.

## Versioning

- Use an ever-increasing build number for every build across the life of the project.
- Increment the patch version automatically for each build by default.
- Do not bump the minor or major version without my explicit approval. Bumps can be suggested with brief reasoning, but not applied automatically.
- App marketing version and build number must come from source-controlled files, not from local caches, `.build/`, DerivedData, or other untracked machine-specific state. Before any release build, report the exact version that will be produced and stop if local state could alter it. Update versioning files in the same commit as the build change.
- Prefer deterministic versioning that reproduces the same app version/build from the same committed source.
- For projects that publish through CI, prefer workflows where a pushed checked-in version bump on `main` automatically creates or updates the corresponding GitHub Release. Do not require a separate manual tag push unless the project brief or decision log explicitly prefers tag-driven releases.

## Performance, Reliability, and Output Quality

- Assume real-world datasets can be large.
- Avoid loading everything at once when streaming, paging, batching, or incremental work is feasible.
- Prefer event-driven updates over polling loops where practical.
- Bound concurrency deliberately.
- Handle errors explicitly. No silent failures.
- Prefer actionable error surfaces over generic failures.

If a proposed change is likely to make the app noticeably worse at its core job, or create a noticeable or avoidable regression in correctness, output quality, responsiveness, startup time, memory use, I/O, network use, battery use, or hang risk, stop and ask first unless that operating model is already approved.

Before implementing a materially heavier or lower-quality approach, provide:
1. baseline behavior,
2. expected impact or risk envelope,
3. safer alternatives, including a no-regression option,
4. recommendation.

If exact baseline numbers are not yet available, provide a measurement plan before coding and actual before/after measurements after implementation.

## Compatibility and Interface Stability (If relevant)

If the project already has users, saved data, config files, scripts, documented commands, or public/internal interfaces:

- Preserve existing behavior by default.
- Do not rename, remove, or repurpose interfaces without approval unless the change is clearly internal and unused.
- If a compatibility break is necessary, explain:
  1. what breaks,
  2. who or what is affected,
  3. the migration path,
  4. the rollback path.
- Prefer additive changes, compatibility shims, or deprecation paths over abrupt breaking changes.

## Honesty and Integrity

### Completion Honesty

- Do not describe scaffolded, mocked, placeholder, temporary-workaround, or unverified work as complete.
- Label partial, temporary, or deferred work clearly.
- Distinguish between: implemented, partial, scaffolded, planned.
- Do not update docs, comments, screenshots, or status files to describe behavior that does not actually exist.
- Prefer slightly incomplete docs over confidently inaccurate docs.
- When behavior changed but verification is incomplete, say that directly.

### Test Integrity

- Do not weaken or rewrite tests just to make failures disappear.
- Change tests only when behavior, requirements, or expectations have genuinely changed.
- Do not change snapshots, fixtures, tolerances, or expected outputs without a real behavioral reason.
- If a test is wrong or outdated, say so explicitly and justify the change.
- Write tests for non-trivial logic, edge cases, and anything that has broken before. Skip tests for simple glue code, trivial UI wiring, and straightforward config. When in doubt about coverage expectations, ask.

## App Defaults

### UX and Interaction

- Follow the target platform's native design conventions and interaction patterns. On Apple platforms this means Apple HIG; on Windows this means Fluent/WinUI conventions. When no platform is specified, default to Apple HIG. Favor strong information hierarchy, good spacing, readable typography, and native controls over custom replacements.
- Avoid noisy UI, excessive chrome, gimmicky interactions, or flashy design. Optimize for repeated daily use, not first-impression effect.
- Keep primary screens focused; put secondary detail in drill-downs, panels, or debug views.
- Prefer obvious controls and predictable behavior over novelty.
- Prefer empty states, warnings, and errors that explain what is happening, what still works, and what I can do next. Avoid dead-end messages that only announce failure without guidance.
- Support both light and dark system appearances using platform-standard dynamic colors. Do not hardcode colors.
- Include basic accessibility support: label interactive elements for screen readers, ensure sufficient contrast, and support keyboard navigation.
- Default to English-only. Do not add localization infrastructure or string tables unless I explicitly request it.
- Unless the project specifies otherwise, target the current major OS version minus one (e.g., if current is macOS 15, target macOS 14).

### Behavior

- Prefer local-first behavior where practical.
- Prefer conservative defaults and opt-in power features.
- Prefer graceful degradation over brittle all-or-nothing behavior when integrity is not at risk.
- Prefer visible status over hidden background activity.
- Prefer explicit progress, state, and health signals when something may take time or become stale.
- Prefer predictable output and deterministic behavior where practical.
- Store app data, settings, and user-authored content in inspectable, recoverable formats and predictable locations. Do not trap important content in opaque internal state.
- Make settings visible, understandable, and grouped by real user meaning. Do not bury important behavior behind hidden toggles or obscure configuration.

## Conditional Rule Triggers

Read all matching files. More than one often applies.

- `docs/agent-rules/user-data-permissions.md`
  - Read when the task touches user data, local files, cloud files, photos, notes, mail, contacts, calendars, storage locations, app permissions, privacy prompts, destructive operations, bulk operations, app-owned vs user-owned paths, or anything that reads/writes/moves/renames/deletes user content.

- `docs/agent-rules/apple.md`
  - Read when the task touches Apple platforms, Swift, SwiftUI, AppKit, UIKit, Xcode, bundle IDs, entitlements, signing, notarization, hardened runtime, sandboxing, PhotoKit, macOS/iOS distribution, or Apple platform APIs.

- `docs/agent-rules/windows.md`
  - Read when the task touches Windows builds, installers, PowerShell, path handling, WinUI/Fluent conventions, Windows packaging, SmartScreen, or Windows signing/resources.

- `docs/agent-rules/tauri-web.md`
  - Read when the task touches Tauri, Rust + WebView architecture, frontend frameworks inside Tauri, IPC bridges, or desktop web UI code.

- `docs/agent-rules/cross-platform.md`
  - Read when the task affects behavior, packaging, UX, storage, rendering, or build/release logic across more than one platform.

- `docs/agent-rules/long-running-work.md`
  - Read when the task touches rendering, encoding, syncing, indexing, scanning, imports/exports, downloads/uploads, migrations, subprocess orchestration, background work, progress/liveness, cancellation, cleanup, or temp artifacts.

- `docs/agent-rules/untrusted-input-tools.md`
  - Read when the task touches imported files, filenames, paths, URLs, command output, clipboard data, environment variables, parsing, shell commands, subprocesses, external binaries, bundled tools, codecs, GPU paths, or optional system capabilities.

- `docs/agent-rules/migration-format-safety.md`
  - Read when the task touches data migrations, format conversions, irreversible transformations, compatibility of stored data, or copy-forward vs in-place upgrades.

- `docs/agent-rules/ai-inference.md`
  - Read when the task adds or changes inferential, ranking, classification, summarization, recommendation, or other AI-assisted behavior.

- `docs/agent-rules/diagnostics-privacy.md`
  - Read when the task touches diagnostics, logging, crash handling, persistent logs, redaction, or user-sensitive debug output.

- `docs/agent-rules/ci-release.md`
  - Read when the task touches GitHub Actions, CI, releases, packaging, DMGs, EXEs, build artifacts, version-triggered releases, code signing, notarization workflow, or app distribution automation.

- `docs/agent-rules/readme-distribution.md`
  - Read when the task touches README, installation instructions, distribution notes, About screen, licensing text, or end-user run instructions.

Important:
- Some tasks require multiple conditional files.
- Do not stop after the first apparent match.
- When uncertain, read the extra file.

Examples:
- Photo library import feature -> `apple.md` + `user-data-permissions.md` + `long-running-work.md`
- macOS app packaging change -> `apple.md` + `ci-release.md` + `readme-distribution.md`
- Tauri file import flow -> `tauri-web.md` + `user-data-permissions.md` + `untrusted-input-tools.md`
- Cross-platform export pipeline -> `cross-platform.md` + `long-running-work.md` + `untrusted-input-tools.md`
- Adding AI-based ranking to imported documents -> `ai-inference.md` + `untrusted-input-tools.md` + `user-data-permissions.md`
- Adding persistent crash logging -> `diagnostics-privacy.md` + `user-data-permissions.md`

## README, Distribution, and About Screen

- Default to MIT license unless I specify otherwise.
- For personal apps, hobby projects, or largely vibe-coded repos, the README MUST say that plainly near the top when it is materially true. It should make clear that the project primarily exists to satisfy the owner's needs, that outside usefulness is incidental, and that no warranties, support commitments, stability guarantees, or roadmap promises are implied beyond the actual license.
- For personal apps where the About Screen exists, it must give copyright credit to "John Kenneth Fisher" and include a clickable link to the public GitHub page if one exists.
