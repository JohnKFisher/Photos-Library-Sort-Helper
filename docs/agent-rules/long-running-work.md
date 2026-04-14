# Long-Running Work, Outputs, and Sync Rules

Read this file when the task involves rendering, encoding, syncing, indexing, scanning, uploading, downloading, imports, exports, migrations, or subprocess orchestration.

## Long-Running Work, Outputs, and Sync

- Keep the UI responsive. No heavy work on the main thread.
- Support cancellation where feasible.
- Use bounded waits and explicit timeouts.
- Detect no-progress conditions and fail clearly rather than hanging forever.
- Prefer graceful shutdown first; use force-kill only as a last resort.
- Clean up temp artifacts on success, failure, and cancel unless retention is explicitly needed for approved recovery/debug flows.

### Progress and Liveness Visibility

- Do not leave the user guessing whether the app is working or frozen.
- For any operation that may take noticeable time, show progress, activity, or clear current-state feedback.
- If exact progress is not available, show liveness through heartbeat activity, phase text, or recent progress updates.
- Distinguish clearly between working, waiting, paused, completed, failed, and cancelled states.

## Outputs and Sync Artifacts

If the project generates outputs such as exports, renders, reports, archives, packages, backups, transformed files, downloads, or sync artifacts:
- Use app-scoped temp/intermediate directories.
- Default output settings to conservative, broadly compatible behavior unless I ask otherwise.
- Provide deterministic behavior where feasible.
- Do not hang indefinitely waiting for download or sync completion.
- Large download/sync actions should show progress, be cancellable when feasible, and be bounded.

## Multi-Source and Sync

If the project integrates multiple sources, synced storage, or scheduled/time-based actions:
- Treat connectors as adapters, not as the product.
- Normalize source data before UI or decision logic uses it.
- Keep source-specific quirks out of the core architecture unless explicitly documented.
- Prevent duplicate scheduled execution by default when multiple devices or processes may be involved.
- Record enough execution state to determine whether an action already ran and what path it took.
- Distinguish clearly between unavailable, stale, empty, unauthorized, and not-yet-configured states.
- Prefer graceful degradation over collapse when integrity is not compromised.
