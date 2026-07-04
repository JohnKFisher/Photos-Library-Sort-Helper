# Long-Running Work, Progress, Sync, and Cleanup Rules

Read this when the task involves expensive or long-running operations, background work, queues, sync scheduling, progress/liveness, cancellation, resume/retry behavior, subprocess orchestration, uploads/downloads, large scans/indexing, partial outputs, interrupted work, or cleanup of temp/intermediate artifacts.

Do not read this for short synchronous imports, exports, migrations, renders, or file operations unless progress, cancellation, retry, scheduling, partial-output safety, or cleanup behavior may affect the plan.

## Progress and liveness

Long-running work should provide user-visible progress or at least clear liveness. Avoid blocking the UI. Prefer cancellable, resumable, or recoverable work where practical.

## Runtime discipline

Prefer event-driven updates over polling loops. Bound concurrency deliberately. Avoid unbounded memory growth; stream, page, batch, or incrementally process large datasets/files where feasible.

Handle errors explicitly. No silent failures. Surface actionable errors over generic failures.

## Retries and fallbacks

Do not hide risky retries, fallback backends, uploads, writes, overwrites, permission expansions, or quality changes. Fallback behavior must be approved and surfaced when it affects output, privacy, cost, or reliability.

## Outputs and cleanup

Write outputs atomically where practical. Prefer temp files plus verified move/rename. Clean only app-owned temp artifacts. Preserve recoverability for expensive work.

## Preflight and shutdown

Before starting expensive or long-running work, preflight:

- inputs,
- output paths,
- required tools/capabilities,
- permissions,
- disk/storage availability when relevant,
- obvious blockers.

Do not start expensive work that is likely to fail when a cheap preflight can catch the issue.

Prefer graceful cancel/shutdown first. Use force-kill only as a last resort.

Clean up app-owned temp artifacts on success, failure, and cancel unless retention is explicitly needed for approved recovery or debugging.

Do not hang indefinitely waiting for downloads, sync, render, export, or tool completion. Use bounded waits, timeouts, progress/liveness checks, or actionable failure states.

Distinguish clearly between unavailable, stale, empty, unauthorized, denied, failed, and not-yet-configured states.

## Multi-source, sync, and scheduled work

When a project integrates multiple sources, synced storage, connectors, or scheduled/time-based actions:

- treat connectors/adapters as edges, not the core product,
- normalize source data before UI or decision logic uses it,
- keep source-specific quirks out of core architecture unless explicitly documented,
- prevent duplicate scheduled execution by default when multiple devices, processes, or sync states may be involved,
- record enough execution state to determine whether an action already ran and what path it took,
- prefer graceful degradation over collapse when data integrity is not compromised.

If source state is uncertain, distinguish clearly between unavailable, stale, empty, unauthorized, denied, failed, and not-yet-configured.

## Generated outputs from long-running work

When a project generates outputs such as exports, renders, reports, archives, packages, backups, transformed files, downloads, or sync artifacts:

- use app-scoped temp/intermediate directories,
- prefer deterministic behavior where feasible,
- default output settings to conservative, broadly compatible behavior unless the user asks otherwise,
- make final output location/name clear when user-visible,
- avoid overwriting existing outputs unless the behavior is explicit, safe, and approved.
