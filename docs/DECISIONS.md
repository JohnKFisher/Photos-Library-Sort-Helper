# Photos Library Sort Helper — Decision Log

- 2026-04-13 — Keep discard-first manual review as the only review mode. Best-shot suggestion logic was removed because it was not reliable enough for the owner's real workflow. Status: approved.
- 2026-04-13 — Defer Photos permission prompts until explicit user actions. The app no longer prompts at launch; it asks only when the user starts scanning or queues Photos album changes, while still honoring PhotoKit's single library authorization model on macOS. Status: approved.
- 2026-04-13 — Store scan preferences in inspectable Application Support files. This keeps important local state visible and recoverable instead of hiding it in opaque defaults blobs. Status: approved.
- 2026-04-13 — Use `Resources/Info.plist` as the version/build source of truth with a dedicated release bump script and two-workflow GitHub Actions release flow. This keeps packaging deterministic and ties releases to checked-in version changes on `main`. Status: approved.
