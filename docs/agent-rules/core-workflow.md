# Core Workflow Rules

Read this when the task is non-trivial, risky, ambiguous, broad, multi-step, or when planning, verification, approval gates, or scope control may materially affect the result.

Do not read this for tiny read-only lookups, clearly localized edits, or narrow requested UI/copy/behavior changes unless uncertainty or risk increases.

## Ask-first gate

When the user explicitly asks for a change, approval is implied for the narrow, low-risk implementation of that request.

Ask before changes that are outside the requested scope or materially affect:

- destructive or irreversible behavior,
- existing user workflows beyond the requested change,
- compatibility, saved data, migrations, or durable file/package formats,
- permissions, entitlements, signing, privacy, or network behavior,
- new dependencies, bundled tools, or tooling churn,
- performance, reliability, output quality, or accessibility,
- architecture,
- versioning, release, CI, packaging, or distribution.

Ask before choosing among materially different product or technical approaches unless the user has already selected the approach.

If approval is needed, present 2–3 options with pros/cons and recommend one.

## Planning

For tiny/low-risk tasks: briefly state the intended edit, make it, verify narrowly, summarize.

Treat risk by impact, not diff size: small changes touching data, permissions, signing, release, compatibility, security, privacy, or durable formats are not tiny/low-risk.

For normal/risky tasks, before coding provide:
1. short plan,
2. files expected to change,
3. major risk areas or special constraints that affect the plan,
4. new dependencies, permissions, migrations, external tools, network behavior, or release effects,
5. risk level: low, medium, or high.

Do not report rule files loaded or skipped unless a rule conflict, safety gate, or repo-specific constraint materially affects the task.

Check existing project decisions/status docs before proposing something that may already be decided.

## Scope control

Prefer the smallest safe change that solves the request.

Do not escalate a localized task into broad cleanup, architecture work, formatting churn, dependency changes, or unrelated refactors without approval.

Small related improvements are allowed only when low-risk, tightly related, and disclosed.

Preserve existing structure, naming, formatting, ordering, public identifiers, documented commands, file/package formats, URLs, APIs, bundle identifiers, and durable workflows unless the task requires changing them.

When existing code appears unusual, first consider whether it may intentionally handle an edge case. Briefly explain the apparent purpose before replacing or simplifying it.

## Implementation style

Prefer:

- simple explicit behavior,
- small reviewable patches,
- existing project patterns,
- targeted edits over rewrites,
- additive compatibility over breaking changes.

Avoid:

- cleverness,
- opportunistic refactors,
- hidden behavior changes,
- formatter/linter/compiler/build-setting churn,
- new abstractions unless they clearly reduce risk or complexity.

Do not add comments that merely narrate obvious code. Use comments for non-obvious intent, constraints, tradeoffs, invariants, safety reasons, or platform quirks.

## Verification

Verification should prove the change, not perform a ritual.

Use the cheapest meaningful check that catches likely errors from the actual change. Batch verification after coherent related edits instead of rebuilding after every small change.

Typical scale:

- docs/copy-only changes: diff/whitespace checks are often enough,
- small UI/copy/layout changes: focused diff checks and one compile/build only if compile risk exists,
- state, validation, persistence, queues, permissions, data, rendering/export, migrations, or platform behavior: targeted tests/checks for affected behavior,
- media/render/HDR/color, destructive operations, user data, signing, packaging, release, or migration work: stronger verification scaled to the risk.

If prior verification in the same session still proves unchanged paths, do not rerun it.

If a check fails for environment/tooling reasons, do not repeatedly rerun it. Explain the failure, change the hypothesis or environment once if justified, then stop or choose a narrower check.

After two failed attempts at the same problem, stop and reassess. Summarize what failed, what it suggests, and the next likely cause.

Report verification proportional to task size and risk. For tiny/local changes, summarize the narrow check briefly. For normal/risky changes, include exact checks run, pass/fail, meaningful skipped checks, and known limitations.

## Integrity

Do not present unverified, mocked, scaffolded, placeholder, partial, or planned work as complete.

Keep docs, comments, tests, screenshots, and status aligned with actual behavior.

Do not weaken tests merely to make failures disappear. If a test is wrong or obsolete, explain why and update it to verify the approved behavior.

For bug fixes, report the likely root cause, what changed, why the fix is narrow, how it was verified, and any remaining uncertainty when relevant.

## Docs vs implementation

Current implementation is authoritative for what the project actually does.

If implementation conflicts with docs, historical notes, redesign rationale, product scope, or old plans:

- surface the conflict,
- explain the likely drift or tradeoff,
- do not silently rewrite current behavior to match older docs,
- ask whether the drift is intentional unless the safe fix is obvious and local.

Historical docs provide context; they do not override current implementation, current project decisions, or explicit user instructions.

## Completion

Once the requested task is completed and verified, stop.

Do not keep exploring, refactoring, optimizing, or expanding unless requested or a meaningful unresolved risk remains.

Be direct about hidden risks, tradeoffs, uncertainty, and user-visible consequences. Clearly separate requested work, recommendations, optional follow-ups, and work requiring approval.